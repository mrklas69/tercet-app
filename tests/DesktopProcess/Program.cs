using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using System.Xml;
using Microsoft.Win32;
using Tercet.Checks;

namespace DesktopDiagnostics;

/// <summary>
/// Sonda DPI ve vlastním EXE: proces dědí manifest aplikace (DPI režim
/// PerMonitor), který PowerShell jako hostitel testů nemá. Spustí skutečnou
/// obnovovací smyčku App nad testovací frontou a šest ticků hlídá, že se
/// lísteček znovu nevytváří a že rozměry WPF obsahu i nativního okna souhlasí.
/// Testovací podtřídu App s potlačeným OnStartup sdílí s PowerShell testy
/// (tests/TestApplication.cs, přibraný v csproj). Vstup: args[0] = cesta logu,
/// args[1] = kořen repa. Návratový kód 1 = chyba, podrobnosti v logu.
/// </summary>
public static class Program
{
    // Reflexe: App drží lísteček, host plochy a příznaky v soukromých polích
    // a metodách. Sonda je čte a volá stejně jako Check-DesktopRefresh.ps1;
    // BindingFlags říkají „instanční a neveřejné členy".
    private const BindingFlags Hidden = BindingFlags.Instance | BindingFlags.NonPublic;
    private static readonly Type AppType = typeof(Tercet.App);
    // `null!` umlčí nullable analýzu: hodnota se nastaví v Main před použitím.
    private static TestApplication app = null!;
    private static string output = "";

    private static object? Field(string name) => AppType.GetField(name, Hidden)!.GetValue(app);
    private static void SetField(string name, object value) => AppType.GetField(name, Hidden)!.SetValue(app, value);
    private static void Call(string name) => AppType.GetMethod(name, Hidden)!.Invoke(app, null);
    private static void Log(string message)
        => File.AppendAllText(output, DateTimeOffset.Now.ToString("o") + " " + message + Environment.NewLine);

    // WPF vyžaduje STA vlákno (jednovláknový apartment COM); atribut ho zajistí.
    [STAThread]
    public static void Main(string[] args)
    {
        output = args[0];
        try { Run(args[1]); }
        catch (Exception e)
        {
            Log("ERROR " + e);
            Environment.ExitCode = 1;
        }
    }

    private static void Run(string repo)
    {
        Log("Before WPF: " + Native.Thread());
        // Stejný přepínač jako runtimeconfig aplikace: bez Mica přes DWM.
        AppContext.SetSwitch("Switch.System.Windows.Appearance.DisableFluentThemeWindowBackdrop", true);
        // Skutečný App.xaml se změnou jen kořenového typu: ThemeMode a resources
        // zůstávají produkční, produkční OnStartup potlačí testovací podtřída
        // (týž trik jako tests/New-TestApplication.ps1).
        var xml = new XmlDocument();
        xml.Load(Path.Combine(repo, "src/Tercet/App.xaml"));
        xml.DocumentElement!.RemoveAttribute("Class", "http://schemas.microsoft.com/winfx/2006/xaml");
        string ns = "clr-namespace:Tercet.Checks;assembly=" + typeof(Program).Assembly.GetName().Name;
        string markup = xml.OuterXml
            .Replace("<Application ", "<checks:TestApplication xmlns:checks=\"" + ns + "\" ")
            .Replace("</Application>", "</checks:TestApplication>");
        app = (TestApplication)System.Windows.Markup.XamlReader.Parse(markup);

        var document = Tercet.QueueDocument.Parse(File.ReadAllBytes(Path.Combine(repo, "tests/queue-fixture.json")));
        SetField("document", document);
        SetField("rows", document.Rows());
        // Skrytá ikona: UpdateTrayText uvnitř MaintainDesktop potřebuje objekt, ne systray.
        SetField("trayIcon", new System.Windows.Forms.NotifyIcon());
        // Skutečné události prostředí plochy, stejně jako v produkčním OnStartup;
        // CreateDelegate obalí soukromou metodu App do delegáta události.
        var display = (EventHandler)AppType.GetMethod("OnDesktopEnvironmentChanged", Hidden)!
            .CreateDelegate(typeof(EventHandler), app);
        var session = (SessionSwitchEventHandler)AppType.GetMethod("OnDesktopSessionSwitch", Hidden)!
            .CreateDelegate(typeof(SessionSwitchEventHandler), app);
        SystemEvents.DisplaySettingsChanged += display;
        SystemEvents.SessionSwitch += session;

        int count = 0;
        IntPtr firstHandle = IntPtr.Zero;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += (_, _) =>
        {
            try
            {
                // Několik skutečných ticků zachytí události zařazené až po
                // SetParent. Původní okamžitý test je míjel.
                Log("Before tick: " + Snapshot());
                var window = (Tercet.MainWindow?)Field("note")
                    ?? throw new InvalidOperationException("No desktop note");
                var handle = new WindowInteropHelper(window).Handle;
                if ((bool)Field("desktopRefreshPending")!)
                    throw new InvalidOperationException("Unexpected repeated desktop refresh");
                if (firstHandle != IntPtr.Zero && firstHandle != handle)
                    throw new InvalidOperationException("Idle note HWND changed");
                firstHandle = handle;
                // TransformToDevice převádí WPF jednotky (1/96 palce) na pixely monitoru.
                var matrix = PresentationSource.FromVisual(window)!.CompositionTarget!.TransformToDevice;
                var content = (FrameworkElement)window.Content;
                Native.CheckGeometry(handle, content.ActualWidth * matrix.M11, content.ActualHeight * matrix.M22);
                Call("MaintainDesktop");
                app.Dispatcher.BeginInvoke(new Action(() => Log("After tick: " + Snapshot())), DispatcherPriority.ApplicationIdle);
                if (++count == 6)
                {
                    timer.Stop();
                    app.Dispatcher.BeginInvoke(new Action(() => app.Shutdown()), DispatcherPriority.ApplicationIdle);
                }
            }
            catch (Exception e)
            {
                Log("ERROR tick " + e);
                timer.Stop();
                app.Shutdown(1);
            }
        };
        Log("Before first note: " + Native.Thread());
        Call("MaintainDesktop");
        timer.Start();
        try { app.Run(); }
        finally
        {
            SystemEvents.DisplaySettingsChanged -= display;
            SystemEvents.SessionSwitch -= session;
        }
    }

    // Jeden řádek logu: příznak odložené obnovy, DPI vlákna, stav hosta a rozměry.
    private static string Snapshot()
    {
        var note = (Tercet.MainWindow?)Field("note");
        var host = Field("desktop");
        string status = "pending=" + Field("desktopRefreshPending") + " " + Native.Thread();
        if (note == null || host == null) return status + " no note";
        var hostType = host.GetType();
        // ReadDisplay má dva `out` parametry; reflexe je po volání vrací v poli argumentů.
        var arguments = new object?[] { null, (uint)0 };
        hostType.GetMethod("ReadDisplay", Hidden)!.Invoke(host, arguments);
        var source = PresentationSource.FromVisual(note);
        return status
            + " attached=" + hostType.GetProperty("IsAttached")!.GetValue(host)
            + " changed=" + hostType.GetProperty("HasDisplayChanged")!.GetValue(host)
            + " initial=" + RectFields(hostType.GetField("initialWorkArea", Hidden)!.GetValue(host)!)
            + " current=" + RectFields(arguments[0]!) + " dpi=" + arguments[1]
            + " WPF=" + note.ActualWidth + "x" + note.ActualHeight
            + " transform=" + source?.CompositionTarget?.TransformToDevice
            + " " + Native.Window(new WindowInteropHelper(note).Handle);
    }

    // Soukromá struktura Rect z DesktopHost: její pole čteme reflexí podle jména.
    private static string RectFields(object rect)
        => string.Join(",", Array.ConvertAll(new[] { "Left", "Top", "Right", "Bottom" },
            name => rect.GetType().GetField(name)!.GetValue(rect)!.ToString()));
}

/// <summary>P/Invoke na user32: DPI kontext vlákna a klientské rozměry HWND.</summary>
internal static class Native
{
    [DllImport("user32.dll")] private static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] private static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern uint GetDpiForSystem();
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr handle);
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr handle, out Rect rect);

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }

    // Kontrola porovnává vykreslený WPF obsah s klientskou plochou HWND,
    // ne pouze dvě nativní okna, která mohou být zvětšena stejně chybně.
    // Hodnota 2 = DPI_AWARENESS_PER_MONITOR_AWARE.
    public static void CheckGeometry(IntPtr handle, double width, double height)
    {
        if (GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext()) != 2)
            throw new InvalidOperationException("Application thread is not per-monitor-aware");
        if (!GetClientRect(handle, out var rect) || Math.Abs(width - rect.Right) > 1 || Math.Abs(height - rect.Bottom) > 1)
            throw new InvalidOperationException("WPF and native sizes differ");
    }

    public static string Thread()
        => "threadDpiMode=" + GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext())
            + " systemDpi=" + GetDpiForSystem();

    public static string Window(IntPtr handle)
    {
        GetClientRect(handle, out var rect);
        return $"hwnd={handle} client={rect.Right}x{rect.Bottom} dpi={GetDpiForWindow(handle)}";
    }
}
