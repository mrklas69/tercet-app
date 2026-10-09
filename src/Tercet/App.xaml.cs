using Microsoft.Win32;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Tercet;

/// <summary>
/// Vlastní systray, obnovuje lísteček, když Explorer ztratí svou plochu,
/// a řídí sladění fronty se serverem.
/// </summary>
public partial class App : Application
{
    private Forms.NotifyIcon? trayIcon;
    private System.Drawing.Icon? trayImage;
    private Forms.ContextMenuStrip? trayMenu;
    private Forms.ToolStripMenuItem? openWebItem;
    private Forms.ToolStripMenuItem? synchronizeItem;
    private Forms.ToolStripMenuItem? backupItem;
    private Forms.ToolStripMenuItem? restoreItem;
    // Nativní souborový dialog pumpuje zprávy: hotkey ani druhé menu nesmějí
    // během výběru otevřít editor nebo rozběhnout synchronizaci.
    private bool backupDialogOpen;
    private DispatcherTimer? desktopTimer;
    private MainWindow? note;
    private DesktopHost? desktop;
    private IReadOnlyList<QueueRow> rows = [];
    private bool errorReported;
    private bool desktopRefreshPending;
    private SettingsWindow? settingsWindow;
    private QueueEditorWindow? editor;
    private ActivationHotKey? activationHotKey;
    private QueueDocument? document;
    private SingleInstanceLock? instanceLock;
    // Zámek dosavadní složky drží jen balíček během přechodu z MSI.
    private SingleInstanceLock? legacyLock;
    // Bez identity balíčku %LOCALAPPDATA%\Tercet, s ní LocalState balíčku.
    private static readonly string DataDirectory = DataLocation.Resolve();
    private readonly QueueStore store = new(Path.Combine(DataDirectory, "queue.json"));
    private readonly SettingsStore settingsStore = new(Path.Combine(DataDirectory, "settings.json"));
    private SyncSettings settings = SyncSettings.Default;
    // Jeden HttpClient na celý běh aplikace (opakované vytváření vyčerpává
    // sokety). Krátký limit: sladění nesmí držet aplikaci minutu bez sítě.
    private static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(10) };
    private QueueLink? queueLink;
    private QueueSynchronizer? synchronizer;
    private bool syncRunning;
    private bool openEditorAfterSync;
    // Sladění odložené na zavření editoru i s důvodem: po Save stačí tiché
    // AfterSave, po vložení odkazu v Settings chce uživatel výsledek slyšet
    // (Manual). Nullable enum: null = nic nečeká.
    private SyncTrigger? syncAfterEditor;
    private string syncStatus = "Not synchronized yet.";

    // OnStartup nahradí StartupUri: nejprve načtení či potvrzená obnova dat,
    // potom systray a nakonec lísteček hostovaný na ploše.
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Druhé spuštění končí ještě před čtením fronty, vznikem systray
        // a registrací zkratky. Instanci držíme až do úplného úklidu OnExit.
        // Balíček drží navíc zámek dosavadní složky, existuje-li:
        // MSI ze Startup a Store ze StartupTask se tak vylučují i během
        // přechodu. Složku nezakládá — u nového uživatele
        // by vznikla virtualizovaná.
        try
        {
            instanceLock = SingleInstanceLock.TryAcquire(DataDirectory);
            if (instanceLock is not null && DataLocation.IsPackaged && Directory.Exists(DataLocation.LegacyDirectory))
            {
                legacyLock = SingleInstanceLock.TryAcquire(DataLocation.LegacyDirectory);
                if (legacyLock is null)
                {
                    instanceLock.Dispose();
                    instanceLock = null;
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(ApplicationIdentity.DisplayName + " could not access its data folder.\n" + ex.Message,
                ApplicationIdentity.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
            return;
        }
        if (instanceLock is null)
        {
            Shutdown();
            return;
        }
        // První balíčkový start převezme dosavadní data; bez nich,
        // nebo když LocalState už vlastní data má, se nic nekopíruje.
        IReadOnlyList<string> imported = [];
        if (DataLocation.IsPackaged)
        {
            try { imported = DataLocation.ImportLegacy(DataLocation.LegacyDirectory, DataDirectory); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                MessageBox.Show(ApplicationIdentity.DisplayName + " could not take over the data from its previous folder. Nothing was changed.\n" + ex.Message,
                    ApplicationIdentity.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
                Shutdown(1);
                return;
            }
        }
        // Ukázkovou frontu prvního spuštění použijeme jen bez fronty
        // i zálohy. Platnou zálohu vadné nebo chybějící fronty musí uživatel
        // výslovně potvrdit.
        try
        {
            using var source = typeof(App).Assembly.GetManifestResourceStream("Tercet.FirstRunQueue")
                ?? throw new InvalidDataException("The first-run queue is missing from the application.");
            document = store.Load(source, recovery => new QueueRecoveryWindow(recovery).ShowDialog() == true);
            if (document is null)
            {
                Shutdown();
                return;
            }
            rows = document.Rows();
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            MessageBox.Show("The queue could not be loaded. The file was left unchanged.\n" + ex.Message,
                ApplicationIdentity.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
            return;
        }
        // Poškozené nastavení frontu nezastaví: sladění se jen vypne a řekne
        // to balónkem, až bude systray. Soubor se nepřepisuje.
        string? settingsError = null;
        try { settings = settingsStore.Load(); }
        catch (Exception ex) when (ex is InvalidDataException or IOException or UnauthorizedAccessException)
        {
            settingsError = ex.Message;
        }
        ConfigureSync();
        CreateTrayMenu();
        trayIcon = new Forms.NotifyIcon
        {
            Text = ApplicationIdentity.DisplayName,
            ContextMenuStrip = trayMenu
        };
        UpdateTrayIcon();
        trayIcon.Visible = true;
        if (imported.Count > 0)
            trayIcon.ShowBalloonTip(5000, ApplicationIdentity.DisplayName, "Data were taken over from the previous Tercet folder ("
                + string.Join(", ", imported) + "). The previous folder was left unchanged.", Forms.ToolTipIcon.Info);
        if (settingsError is not null)
        {
            syncStatus = "Settings could not be read; synchronization is off. " + settingsError;
            trayIcon.ShowBalloonTip(5000, ApplicationIdentity.DisplayName, syncStatus, Forms.ToolTipIcon.Warning);
        }
        try { activationHotKey = new ActivationHotKey(ShowEditor); }
        catch (Win32Exception ex)
        {
            trayIcon.ShowBalloonTip(5000, ApplicationIdentity.DisplayName,
                ex.Message + " Use Edit in the system tray.", Forms.ToolTipIcon.Warning);
        }

        // DispatcherTimer volá Tick na WPF UI vlákně; nepotřebujeme zámky ani async.
        // Samotné SetWindowPos po změně vzdáleného sezení nemusí obnovit
        // vykreslovací prostředky WPF a layered obalu. Události jen označí
        // obnovu; timer sloučí jejich sérii do jediného nového lístečku.
        SystemEvents.DisplaySettingsChanged += OnDesktopEnvironmentChanged;
        SystemEvents.SessionSwitch += OnDesktopSessionSwitch;
        desktopTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        desktopTimer.Tick += (_, _) => MaintainDesktop();
        MaintainDesktop();
        desktopTimer.Start();
        // Lísteček už stojí z lokálních dat; server ho smí až teď doplnit.
        _ = SynchronizeAsync(SyncTrigger.Startup);
    }

    // Menu lze vytvořit i v izolovaném testu bez produkčního OnStartup;
    // ověřujeme tak skutečné položky a událost Opening nad dočasnými daty.
    private void CreateTrayMenu()
    {
        trayMenu = new Forms.ContextMenuStrip();
        trayMenu.Items.Add("Edit (Ctrl+Alt+T)", null, (_, _) => ShowEditor());
        openWebItem = new Forms.ToolStripMenuItem("Open Web", null, (_, _) => OpenWeb());
        // Discard: výsledek Task nikdo nečeká, chyby hlásí metoda sama.
        synchronizeItem = new Forms.ToolStripMenuItem("Synchronize", null, (_, _) => _ = SynchronizeAsync(SyncTrigger.Manual));
        trayMenu.Items.Add(openWebItem);
        trayMenu.Items.Add(synchronizeItem);
        trayMenu.Items.Add("Settings", null, (_, _) => ShowSettings());
        backupItem = new Forms.ToolStripMenuItem("Back Up Queue…", null, (_, _) => BackUpQueue());
        restoreItem = new Forms.ToolStripMenuItem("Restore Queue…", null, (_, _) => RestoreQueue());
        trayMenu.Items.Add(backupItem);
        trayMenu.Items.Add(restoreItem);
        // Složka zůstává dostupná pro ruční diagnostiku a nastavení.
        trayMenu.Items.Add("Open Data Folder", null, (_, _) => OpenDataFolder());
        trayMenu.Items.Add(new Forms.ToolStripSeparator());
        trayMenu.Items.Add("Exit", null, (_, _) => RequestExit());
        // Dostupnost položek se určí při každém otevření menu podle stavu.
        trayMenu.Opening += (_, _) => UpdateSyncMenu();
        UpdateSyncMenu();
    }

    // Odkaz z nastavení se rozloží jednou; bez odkazu nebo s vadným odkazem
    // sladění neběží a položky menu zůstanou zašedlé.
    private void ConfigureSync()
    {
        queueLink = null;
        synchronizer = null;
        if (settings.QueueLink is null) return;
        try
        {
            queueLink = QueueLink.Parse(settings.QueueLink);
            synchronizer = new QueueSynchronizer(store, settingsStore, new QueueSyncClient(http, queueLink));
        }
        catch (FormatException ex)
        {
            syncStatus = "The queue link in Settings is not usable. " + ex.Message;
        }
    }

    private void UpdateSyncMenu()
    {
        if (openWebItem is not null) openWebItem.Enabled = queueLink is not null;
        // Editor drží pracovní kopii; výměna dokumentu pod ním
        // by ji znehodnotila, proto se během editace nesynchronizuje.
        if (synchronizeItem is not null) synchronizeItem.Enabled = synchronizer is not null && editor is null && !syncRunning && !backupDialogOpen;
        if (backupItem is not null) backupItem.Enabled = CanTransferQueue;
        if (restoreItem is not null) restoreItem.Enabled = CanTransferQueue;
    }

    // Obě operace pracují s uloženou frontou. Otevřený editor nebo Settings
    // se nejprve dokončí; tím nemůže výběr souboru ztratit pracovní změny.
    private bool CanTransferQueue => document is not null && editor is null
        && settingsWindow is null && !syncRunning && !backupDialogOpen;

    private void BackUpQueue()
    {
        if (!CanTransferQueue) return;
        backupDialogOpen = true;
        UpdateSyncMenu();
        try
        {
            var dialog = new SaveFileDialog
            {
                Title = ApplicationIdentity.Title("Back Up Queue"), Filter = "Queue backup (*.json)|*.json", DefaultExt = ".json",
                FileName = "Tercet-queue-" + DateTime.Now.ToString("yyyy-MM-dd-HHmmss") + ".json",
                InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                OverwritePrompt = true
            };
            if (dialog.ShowDialog() != true) return;
            // U Storu vyloučíme celý kořen balíčkových dat, nejen LocalState:
            // odinstalace maže i sousední LocalCache a další jeho podadresáře.
            string dataRoot = DataLocation.IsPackaged ? Path.GetDirectoryName(DataDirectory)! : DataDirectory;
            QueueBackup.Write(document!, dialog.FileName, dataRoot);
            trayIcon?.ShowBalloonTip(5000, ApplicationIdentity.Title("Back Up Queue"), "The queue and archive were backed up. Server settings are not included.", Forms.ToolTipIcon.Info);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            MessageBox.Show("The backup could not be saved.\n" + ex.Message, ApplicationIdentity.DisplayName, MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { backupDialogOpen = false; UpdateSyncMenu(); }
    }

    private void RestoreQueue()
    {
        if (!CanTransferQueue) return;
        QueueDocument? restored = null;
        backupDialogOpen = true;
        UpdateSyncMenu();
        try
        {
            var dialog = new OpenFileDialog
            {
                Title = ApplicationIdentity.Title("Restore Queue"), Filter = "Queue backup (*.json)|*.json|All files (*.*)|*.*",
                InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                CheckFileExists = true
            };
            if (dialog.ShowDialog() == true) restored = QueueBackup.Read(dialog.FileName);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            MessageBox.Show("The backup could not be opened. The current queue was left unchanged.\n" + ex.Message,
                ApplicationIdentity.DisplayName, MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { backupDialogOpen = false; UpdateSyncMenu(); }
        if (restored is not null) OpenEditor(restored);
    }

    // Stránka pro telefon v běžném prohlížeči; ShellExecute vybere výchozí.
    private void OpenWeb()
    {
        if (queueLink is null) return;
        try { Process.Start(new ProcessStartInfo(queueLink.Page.AbsoluteUri) { UseShellExecute = true }); }
        catch (Win32Exception ex)
        {
            trayIcon?.ShowBalloonTip(5000, ApplicationIdentity.DisplayName, "The browser could not be opened. " + ex.Message, Forms.ToolTipIcon.Warning);
        }
    }

    // Datová složka v Exploreru; ShellExecute nad adresářem otevře průzkumníka.
    private void OpenDataFolder()
    {
        try { Process.Start(new ProcessStartInfo(DataDirectory) { UseShellExecute = true }); }
        catch (Win32Exception ex)
        {
            trayIcon?.ShowBalloonTip(5000, ApplicationIdentity.DisplayName, "The data folder could not be opened. " + ex.Message, Forms.ToolTipIcon.Warning);
        }
    }

    private enum SyncTrigger { Startup, AfterSave, Manual }

    // async/await: síťové čekání běží na vlákně fondu (Task.Run), UI vlákno
    // mezitím obsluhuje blikání i systray a po `await` sem pokračuje zase ono.
    // Dotaz při konfliktu se z pracovního vlákna vrátí na UI přes Dispatcher.
    private async Task SynchronizeAsync(SyncTrigger trigger)
    {
        if (synchronizer is null || syncRunning || editor is not null || backupDialogOpen) return;
        syncRunning = true;
        UpdateSyncMenu();
        var current = synchronizer;
        SyncResult result;
        try
        {
            result = await Task.Run(() => current.Synchronize(conflict => Dispatcher.Invoke(() => AskConflict(conflict))));
        }
        catch (Exception ex)
        {
            // Poslední záchytná síť. Metoda se volá bez await (`_ = SynchronizeAsync`),
            // takže by neošetřená výjimka skončila v zahozeném Tasku a nikdo by ji
            // neuviděl. Běžné chyby převádí synchronizátor
            // na SyncResult sám; sem dojde jen neočekávaná, a i ta musí mít balónek.
            result = new SyncResult(SyncOutcome.Failed, "Synchronization failed unexpectedly. " + ex.Message);
        }
        finally { syncRunning = false; }
        // Exit během čekání: systray už neexistuje a není co aktualizovat.
        if (trayIcon is null) return;
        syncStatus = "Last synchronization " + DateTime.Now.ToString("HH:mm") + ": " + result.Message;
        if (result.Document is not null)
        {
            document = result.Document;
            rows = document.Rows();
            UpdateTrayIcon();
            // Lísteček se staví z řádků při vzniku; nový obsah chce nové okno.
            CloseNote();
            MaintainDesktop();
        }
        // Start a Save hlásí jen to, co uživatel nečeká: start mlčí při
        // Up to date, Save i při odeslání, ruční Synchronize hlásí vždy.
        bool report = trigger switch
        {
            SyncTrigger.Startup => result.Outcome != SyncOutcome.UpToDate,
            SyncTrigger.AfterSave => result.Outcome is not (SyncOutcome.UpToDate or SyncOutcome.Uploaded),
            _ => true
        };
        if (report)
            trayIcon.ShowBalloonTip(5000, ApplicationIdentity.Title("Synchronize"), result.Message,
                result.IsProblem ? Forms.ToolTipIcon.Warning : Forms.ToolTipIcon.Info);
        UpdateSyncMenu();
        if (openEditorAfterSync)
        {
            openEditorAfterSync = false;
            ShowEditor();
        }
    }

    // Modální dialog na UI vlákně; křížek i Escape vrátí Cancel (výchozí Choice).
    private static ConflictChoice AskConflict(SyncConflict conflict)
    {
        var dialog = new QueueConflictWindow(conflict);
        dialog.ShowDialog();
        return dialog.Choice;
    }

    // Jedna instance dialogu: další klik ji pouze přenese do popředí.
    // Po zavření vynulujeme referenci, protože zavřený Window nelze znovu Show.
    private void ShowSettings()
    {
        if (backupDialogOpen) return;
        if (settingsWindow is null)
        {
            settingsWindow = new SettingsWindow(settings.QueueLink, syncStatus, ApplySettings);
            settingsWindow.Closed += (_, _) => settingsWindow = null;
            settingsWindow.Show();
        }
        settingsWindow.Activate();
    }

    // Nový odkaz znamená jinou frontu: naposledy sladěná verze se zapomene.
    // Zápis do souboru je první; při chybě dialog zůstane a nic se nezmění.
    private void ApplySettings(string? link)
    {
        var updated = link == settings.QueueLink ? settings : new SyncSettings(link, null);
        settingsStore.Save(updated);
        settings = updated;
        syncStatus = "Not synchronized yet.";
        ConfigureSync();
        UpdateSyncMenu();
        if (synchronizer is null) return;
        // Vložený odkaz se hned vyzkouší; při otevřeném editoru až po jeho zavření,
        // ale se stejnou hlasitostí jako ruční Synchronize.
        if (editor is null) _ = SynchronizeAsync(SyncTrigger.Manual);
        else syncAfterEditor = SyncTrigger.Manual;
    }

    // HWND editoru je běžné aktivovatelné okno, nikoli dítě Exploreru. Pasivní
    // okno proto zavřeme a po dokončení editoru znovu vytvoříme z uložených dat.
    private void ShowEditor()
    {
        if (backupDialogOpen) return;
        if (editor is not null) { editor.Activate(); return; }
        if (document is null) return;
        // Během sladění by editor dostal dokument, který se právě může měnit;
        // otevře se hned po jeho skončení.
        if (syncRunning) { openEditorAfterSync = true; return; }
        OpenEditor(null);
    }

    // Obnova používá stejný životní cyklus jako běžná editace: pracovní kopii,
    // zápis přes SaveDocument a teprve po zavření případnou synchronizaci.
    private void OpenEditor(QueueDocument? restored)
    {
        // Bez připojeného lístečku (plocha zrovna chybí) stojí editor tam, kde by
        // lísteček stál: okraje z DesktopHost; 266 DIP je výchozí šířka těla,
        // 374 běžná výška fronty o dvaceti řádcích.
        Rect bounds = desktop is { IsAttached: true } ? desktop.Bounds
            : new Rect(SystemParameters.WorkArea.Right - DesktopHost.Margin - 266,
                SystemParameters.WorkArea.Top + DesktopHost.TopMargin, 266, 374);
        editor = new QueueEditorWindow(document!, SaveDocument, bounds, restored);
        CloseNote();
        editor.Closed += (_, _) =>
        {
            editor = null;
            MaintainDesktop();
            // Pattern `is { } trigger` vybalí hodnotu z nullable, když není null.
            if (syncAfterEditor is { } trigger)
            {
                syncAfterEditor = null;
                _ = SynchronizeAsync(trigger);
            }
        };
        editor.Show();
        editor.Activate();
    }

    private void RequestExit()
    {
        if (backupDialogOpen) return;
        if (editor is null || editor.CanExit()) Shutdown();
    }

    // Až úspěšný zápis zveřejní novou frontu v lístečku a systray. Výjimka
    // ze Save ponechá obojí beze změny; pracovní kopii vlastní editor.
    // Save je lokální a synchronní: server se dozví o změně až po
    // zavření editoru, výpadek sítě uložení nezdrží ani nezmaří.
    private void SaveDocument(QueueDocument edited)
    {
        store.Save(edited);
        document = edited.Clone();
        rows = document.Rows();
        UpdateTrayIcon();
        // ??= přiřadí jen do prázdné hodnoty: hlasitější Manual z Settings
        // tiché AfterSave nepřebije.
        if (synchronizer is not null) syncAfterEditor ??= SyncTrigger.AfterSave;
    }

    // Stálou ikonu aplikace načteme jen jednou; změny fronty mění tooltip.
    // NotifyIcon ikonu nevlastní, proto ji držíme až do úklidu OnExit.
    private void UpdateTrayIcon()
    {
        if (trayImage is null)
        {
            var image = TrayIconRenderer.Create();
            try { trayIcon!.Icon = image; }
            catch { image.Dispose(); throw; }
            trayImage = image;
        }
        UpdateTrayText();
    }

    // Obnova Exploreru mění jen dovětek, ne informaci o situaci fronty.
    private void UpdateTrayText()
    {
        string description = QueueAttention.Describe(QueueAttention.SelectSituation(rows)).Description;
        trayIcon!.Text = ApplicationIdentity.Title(description)
            + (errorReported ? " — waiting for the desktop" : "");
    }

    // SystemEvents mohou přijít z jiného vlákna. BeginInvoke práci zařadí
    // na WPF dispatcher bez synchronního čekání (a rizika deadlocku).
    // Žádný handler nezavírá editor ani nečte/zapisuje frontu.
    private void OnDesktopEnvironmentChanged(object? sender, EventArgs e)
    {
        if (!Dispatcher.HasShutdownStarted)
            Dispatcher.BeginInvoke(new Action(() => desktopRefreshPending = true));
    }

    private void OnDesktopSessionSwitch(object? sender, SessionSwitchEventArgs e)
        => OnDesktopEnvironmentChanged(sender, e);

    // Neúspěch hostování nesmí vytvořit náhradní plovoucí/topmost okno.
    // Systray zůstane pro Exit, obnovení plochy zkoušíme dál.
    private void MaintainDesktop()
    {
        if (editor is not null) return;
        try
        {
            if (!desktopRefreshPending && note is not null && desktop is not null
                && desktop.IsAttached && !desktop.HasDisplayChanged)
            {
                desktop.Position();
                return;
            }
            // Editor má přednost (návrat výše); čekající obnovu spotřebujeme
            // až zde. Při selhání se další tick znovu pokusí vytvořit lísteček.
            desktopRefreshPending = false;
            CloseNote();
            var host = DesktopHost.Find();
            var window = new MainWindow(rows);
            note = window;
            var size = window.ContentSize;
            window.Width = size.Width;
            window.Height = size.Height;
            window.Closed += (_, _) =>
            {
                if (ReferenceEquals(note, window))
                {
                    note = null;
                    desktop = null;
                    host.Dispose();
                }
            };
            // EnsureHandle vytvoří HWND bez zobrazení: okno neblikne nad aplikacemi
            // předtím, než mu nastavíme rodiče v Exploreru.
            desktop = host;
            host.Attach(new WindowInteropHelper(window).EnsureHandle(), size.Width, size.Height);
            window.Show();
            host.Position();
            host.Show();
            errorReported = false;
            UpdateTrayText();
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException)
        {
            CloseNote();
            if (!errorReported)
            {
                trayIcon!.ShowBalloonTip(5000, ApplicationIdentity.DisplayName,
                    "The note could not be attached to the desktop. Retrying.\n" + ex.Message,
                    Forms.ToolTipIcon.Warning);
                errorReported = true;
            }
            UpdateTrayText();
        }
    }

    // Reference vyčistíme před Close; Closed event se může vyvolat synchronně.
    private void CloseNote()
    {
        var old = note;
        var oldDesktop = desktop;
        note = null;
        desktop = null;
        old?.Close();
        oldDesktop?.Dispose();
    }

    // Dispose vrací nativní prostředky Windows a okamžitě odstraní ikonu.
    protected override void OnExit(ExitEventArgs e)
    {
        desktopTimer?.Stop();
        // Statické události nesmějí držet aplikaci po ukončení ani zařazovat
        // práci během likvidace nativních oken.
        SystemEvents.DisplaySettingsChanged -= OnDesktopEnvironmentChanged;
        SystemEvents.SessionSwitch -= OnDesktopSessionSwitch;
        activationHotKey?.Dispose();
        if (trayIcon is not null)
        {
            trayIcon.Visible = false;
            trayIcon.Dispose();
            trayIcon = null;
        }
        trayMenu?.Dispose();
        trayImage?.Dispose();
        CloseNote();
        legacyLock?.Dispose();
        instanceLock?.Dispose();
        base.OnExit(e);
    }
}
