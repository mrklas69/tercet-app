using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;

namespace Tercet;

/// <summary>
/// Probuzený lísteček je běžné aktivovatelné okno. Pasivní verze zatím zmizí
/// z plochy; tělo rendereru zůstane na stejném místě, přibude hlavička a patička.
/// </summary>
internal sealed class QueueEditorWindow : Window
{
    private readonly QueueDocument original;
    private readonly QueueDocument workingCopy;
    private readonly Action<QueueDocument> save;
    private bool discardConfirmed;
    private const double HeaderHeight = 28;
    private const double FooterHeight = 34;
    private readonly double restoreNoticeHeight;
    // Horní okraj, na kterém má okno stát, aby tělo zůstalo na místě pasivního
    // lístečku. Pamatujeme si ho, protože se k němu vracíme při každé
    // změně výšky; skutečné Top může být menší, když se okno nevejde na plochu.
    private readonly double desiredTop;

    public QueueEditorWindow(QueueDocument original, Action<QueueDocument> save, Rect bodyBounds)
        : this(original, save, bodyBounds, null) { }

    // Při obnově porovnáváme pracovní kopii s dosavadní frontou, ne se zálohou:
    // Alt+F4 tak chrání i obnovu bez jediné ruční editace. Původní dokument
    // se nemění, dokud uživatel nepotvrdí Save.
    public QueueEditorWindow(QueueDocument original, Action<QueueDocument> save, Rect bodyBounds,
        QueueDocument? restored)
    {
        this.original = original;
        this.save = save;
        workingCopy = (restored ?? original).Clone();
        Title = ApplicationIdentity.Title("Editor");
        SetResourceReference(IconProperty, "ApplicationIcon");
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        FontFamily = new System.Windows.Media.FontFamily("Segoe UI");
        FontSize = 14;
        SetResourceReference(BackgroundProperty, "ApplicationBackgroundBrush");
        SetResourceReference(ForegroundProperty, "TextFillColorPrimaryBrush");

        // Na obvyklé ploše je tělo přesně pod původním lístečkem. Pokud nahoře
        // není místo na hlavičku, posuneme celé okno do pracovní plochy.
        // Šířka se určí jednou; výška sleduje obsah (FitBody).
        Rect area = SystemParameters.WorkArea;
        Width = Math.Max(bodyBounds.Width, 250);
        TextBlock? restoreNotice = null;
        if (restored is not null)
        {
            restoreNotice = new TextBlock
            {
                Text = "Restored queue. Save replaces the current queue and keeps it in the local backup. "
                    + "If connected to a server, normal synchronization follows. Cancel keeps the current queue.",
                TextWrapping = TextWrapping.Wrap, FontSize = 12, Padding = new Thickness(8),
                Name = "RestoreNotice"
            };
            // Measure určí výšku zalomeného textu při skutečné šířce editoru;
            // FitBody ji přičte a delší frontu dál nechá rolovat.
            restoreNotice.Measure(new Size(Width, double.PositiveInfinity));
            restoreNoticeHeight = restoreNotice.DesiredSize.Height;
        }
        Left = Math.Clamp(bodyBounds.Left, area.Left, Math.Max(area.Left, area.Right - Width));
        desiredTop = bodyBounds.Top - HeaderHeight;
        FitBody(bodyBounds.Height);
        var shell = new DockPanel();
        // Reflexe čte metadata této aplikace, nikoli hostitele (např. PowerShellu
        // v testech). SDK odvozuje verzi z <Version> a za + přidává hash commitu;
        // Split ponechá číslo vydání. ?. a ?? zobrazí ? při chybějícím atributu.
        var version = typeof(QueueEditorWindow).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "?";
        var header = new DockPanel { Height = HeaderHeight };
        var versionLabel = new TextBlock
        {
            Text = $"v{version}", FontSize = 12, FontWeight = FontWeights.Normal,
            Padding = new Thickness(8, 5, 5, 0)
        };
        // Nejprve vyhradíme místo verzi vpravo; poslední dítě DockPanelu vyplní
        // zbytek šířky. Výška hlavičky a poloha těla editoru zůstávají stejné.
        DockPanel.SetDock(versionLabel, Dock.Right);
        header.Children.Add(versionLabel);
        header.Children.Add(new TextBlock
        {
            Text = Title, Padding = new Thickness(5, 4, 5, 0),
            FontWeight = FontWeights.SemiBold
        });
        DockPanel.SetDock(header, Dock.Top);
        shell.Children.Add(header);
        if (restoreNotice is not null)
        {
            DockPanel.SetDock(restoreNotice, Dock.Top);
            shell.Children.Add(restoreNotice);
        }
        // Patička: vlevo Archiv…, vpravo Zrušit / Uložit. DockPanel
        // přitiskne archiv k levému okraji a zbytek šířky dá pravé dvojici.
        var footer = new DockPanel { Height = FooterHeight };
        var view = new QueueView(workingCopy);
        // Po každém překreslení z pracovní kopie (přidání, odstranění, převod
        // řádku) se okno přizpůsobí novému obsahu, stejně jako pasivní lísteček
        // po uložení. Lambda (_, _) => … je obsluha události bez použití
        // parametrů odesílatel a argumenty.
        view.ContentChanged += (_, _) => FitBody(view.ContentSize.Height);
        var archive = new Button { Content = "Archive…", Margin = new Thickness(3), Padding = new Thickness(7, 0, 7, 0) };
        archive.Click += (_, _) => view.ShowArchive();
        DockPanel.SetDock(archive, Dock.Left);
        footer.Children.Add(archive);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Cancel", Margin = new Thickness(3), Padding = new Thickness(7, 0, 7, 0) };
        var accept = new Button { Content = "Save", Margin = new Thickness(3), Padding = new Thickness(7, 0, 7, 0) };
        cancel.Click += (_, _) => { discardConfirmed = true; Close(); };
        accept.Click += (_, _) => SaveAndClose();
        actions.Children.Add(cancel);
        actions.Children.Add(accept);
        footer.Children.Add(actions);
        DockPanel.SetDock(footer, Dock.Bottom);
        shell.Children.Add(footer);

        // UserControl má životní cyklus těla editoru; kvůli sdílení rendereru
        // už nevytváříme a nezavíráme pomocné pasivní Window.
        shell.Children.Add(view);
        Content = shell;
    }

    // Výška okna = tělo + hlavička + patička, nejvýše však pracovní plocha;
    // delší obsah pak roluje uvnitř těla. Když se okno při požadovaném Top
    // nevejde, posune se nahoru, aby zůstalo celé viditelné. Tentýž výpočet
    // platí při otevření i po každé změně obsahu.
    private void FitBody(double bodyHeight)
    {
        Rect area = SystemParameters.WorkArea;
        Height = Math.Min(bodyHeight + HeaderHeight + restoreNoticeHeight + FooterHeight, area.Height);
        Top = Math.Clamp(desiredTop, area.Top, Math.Max(area.Top, area.Bottom - Height));
    }

    private bool SaveAndClose()
    {
        try
        {
            save(workingCopy);
            discardConfirmed = true;
            Close();
            return true;
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            MessageBox.Show(this, ex.Message, ApplicationIdentity.Title("Changes not saved"), MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }
    }

    // Alt+F4 i Exit mají stejnou ochranu rozpracované kopie. Cancel je návrat
    // do editoru; No znamená výslovné zahození celé editace bez uložení.
    public bool CanExit()
    {
        if (discardConfirmed || workingCopy.HasSameData(original)) return true;
        var result = MessageBox.Show(this, "Save pending changes?\nYes = save, No = discard, Cancel = keep editing.",
            ApplicationIdentity.DisplayName, MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (result == MessageBoxResult.Yes) return SaveAndClose();
        if (result == MessageBoxResult.No) { discardConfirmed = true; return true; }
        return false;
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // Při systémovém zavírání nevoláme Close rekurzivně přes SaveAndClose.
        if (!discardConfirmed && !workingCopy.HasSameData(original))
        {
            e.Cancel = true;
            Dispatcher.BeginInvoke(new Action(() => { if (CanExit() && IsVisible) { discardConfirmed = true; Close(); } }));
        }
        base.OnClosing(e);
    }
}
