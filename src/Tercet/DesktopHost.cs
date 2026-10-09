using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Tercet;

/// <summary>
/// Jediné místo znalosti nativní plochy Exploreru. WorkerW není veřejný kontrakt;
/// jde o experimentální vazbu na vnitřní okna Exploreru, ne veřejné API.
/// Po restartu Exploreru nebo změně relace je proto nutné připojení obnovit.
/// </summary>
internal sealed class DesktopHost(nint parent, nint insertAfter, nint wallpaper) : IDisposable
{
    private nint window;
    private nint surface;
    private double contentWidth;
    private double contentHeight;
    private uint initialDpi;
    private Rect initialWorkArea;
    private const int StyleIndex = -16;
    private const int ExtendedStyleIndex = -20;
    private const int ChildStyle = 0x40000000;
    private const int PopupStyle = unchecked((int)0x80000000);
    private const int NoActivateStyle = 0x08000000;
    // Okraje lístečku na ploše v DIP (1/96 palce): vpravo a dole 16, nahoře 32
    // kvůli hlavičce editoru. Sdílí je App.ShowEditor pro náhradní
    // polohu editoru, když lísteček zrovna není připojený.
    internal const double Margin = 16;
    internal const double TopMargin = 32;

    // Primary constructor výše ukládá parametry instance. nint je celé číslo
    // šířky pointeru: HWND musí zůstat 64bitový v 64bitovém procesu.
    public bool IsAttached => IsWindow(window) && IsWindow(surface) && IsWindow(parent)
        && GetParent(window) == surface && GetParent(surface) == parent
        && (wallpaper == 0 || (IsWindow(wallpaper) && GetParent(wallpaper) == parent))
        && (insertAfter == 0 || (IsWindow(insertAfter) && GetParent(insertAfter) == parent));

    // Nový Explorer: layered lísteček je sourozenec ikon a tapety uvnitř Progman.
    // Starší Explorer: lísteček je dítě samostatného WorkerW za okny s ikonami.
    // Rozhodujeme podle skutečného stromu HWND, nikoli podle verze Windows.
    public static DesktopHost Find()
    {
        nint progman = FindWindow("Progman", null);
        if (progman == 0)
            throw new InvalidOperationException("Explorer has no desktop yet.");
        DesktopHost? host = Discover(progman);
        if (host is not null)
            return host;

        // Nedokumentovaná zpráva vyžádá oddělení tapety a ikon. Timeout zajistí,
        // že zamrzlý Explorer nezablokuje systray na neurčito. Nic mu neskrýváme.
        SendMessageTimeout(progman, 0x052C, 0xD, 1, 0x0002, 1000, out _);
        return Discover(progman)
            ?? throw new InvalidOperationException("The wallpaper layer could not be found.");
    }

    private static DesktopHost? Discover(nint progman)
    {
        nint icons = FindWindowEx(progman, 0, "SHELLDLL_DefView", null);
        nint background = FindWindowEx(progman, 0, "WorkerW", null);
        if (icons != 0 && background != 0)
            return new DesktopHost(progman, icons, background);

        DesktopHost? result = null;
        // Delegate předává .NET funkci Win32 enumerátoru; false zastaví hledání.
        EnumWindows((candidate, _) =>
        {
            if (FindWindowEx(candidate, 0, "SHELLDLL_DefView", null) == 0)
                return true;
            nint worker = FindWindowEx(0, candidate, "WorkerW", null);
            if (worker == 0)
                return true;
            result = new DesktopHost(worker, 0, 0);
            return false;
        }, 0);
        return result;
    }

    // SetParent samo nepřepne WS_POPUP na WS_CHILD; style měníme předem.
    // Ověřujeme skutečného rodiče, protože nula z SetParent může být i úspěch
    // (původní top-level okno nemělo rodiče).
    public void Attach(nint handle, double width, double height)
    {
        window = handle;
        contentWidth = width;
        contentHeight = height;
        // WPF per-pixel layered HWND se v moderním Progman přes RDP nevykreslilo,
        // přestože PrintWindow vracelo správné pixely. Nativní system-layered
        // obal s konstantní alpha=255 prošel stejným pokusem. WPF uvnitř je obyčejné
        // neprůhledné child okno; STATIC je vestavěná Win32 třída, nic neregistrujeme.
        surface = CreateWindowEx(0x00080000 | NoActivateStyle, "STATIC", "Tercet.DesktopSurface",
            ChildStyle | 0x02000000 | 0x04000000, 0, 0, 1, 1, parent, 0, 0, 0);
        if (surface == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (!SetLayeredWindowAttributes(surface, 0, 255, 0x00000002))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        SetStyle(StyleIndex, (GetWindowLong(window, StyleIndex) & ~PopupStyle) | ChildStyle);
        SetStyle(ExtendedStyleIndex, GetWindowLong(window, ExtendedStyleIndex) | NoActivateStyle);
        SetParent(window, surface);
        int error = Marshal.GetLastWin32Error();
        if (GetParent(window) != surface)
            throw new Win32Exception(error, "Attaching to the desktop failed.");
        ReadDisplay(out initialWorkArea, out initialDpi);
        Position();
    }

    // Obal zobrazíme až po přípravě obsahu; SW_SHOWNOACTIVATE nezmění focus.
    public void Show() => ShowWindow(surface, 4);

    // Editor potřebuje skutečnou polohu těla, nikoli odhad z Width/Left WPF
    // okna, jehož rozměry změnil nativní host. Souřadnice převádíme z pixelů.
    public System.Windows.Rect Bounds
    {
        get
        {
            if (!GetWindowRect(surface, out Rect rect))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            double scale = GetDpiForWindow(surface) / 96.0;
            if (scale == 0) throw new InvalidOperationException("The desktop disappeared while measuring.");
            return new System.Windows.Rect(rect.Left / scale, rect.Top / scale,
                (rect.Right - rect.Left) / scale, (rect.Bottom - rect.Top) / scale);
        }
    }

    // Nativní obal vlastníme my, nikoli Explorer. Volající nejprve zavře WPF
    // obsah; opakované Dispose je bezpečné i po zániku plochy.
    public void Dispose()
    {
        nint old = surface;
        surface = 0;
        if (IsWindow(old))
            DestroyWindow(old);
    }

    // Změnu DPI nemusí doprovázet DisplaySettingsChanged. Porovnáváme proto
    // i skutečné prostředí s okamžikem vzniku obalu. Při rozdílu obnovíme
    // WPF i layered HWND, nejen jejich velikost.
    public bool HasDisplayChanged
    {
        get
        {
            ReadDisplay(out Rect area, out uint dpi);
            return dpi != initialDpi || !area.Equals(initialWorkArea);
        }
    }

    private void ReadDisplay(out Rect area, out uint dpi)
    {
        if (!SystemParametersInfo(0x0030, 0, out area, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        dpi = GetDpiForWindow(parent);
        if (dpi == 0)
            throw new InvalidOperationException("The desktop disappeared while positioning.");
    }

    // Win32 používá pixely, WPF jednotky po 1/96 palce. DPI rodiče odpovídá
    // prostoru souřadnic po SetParent. SPI_GETWORKAREA vrací hlavní monitor
    // bez taskbaru; ScreenToClient odečte počátek rodiče (může být záporný).
    public void Position()
    {
        ReadDisplay(out Rect area, out uint dpi);
        int margin = (int)Math.Round(Margin * dpi / 96.0);
        // Nad tělem rezervujeme místo pro hlavičku editoru (28 DIP), aby při
        // probuzení na běžné ploše neposkočily řádky.
        int topMargin = (int)Math.Round(TopMargin * dpi / 96.0);
        // Na menší ploše se okno vejde do pracovní oblasti; WPF nabídne svislý
        // scrollbar. Nezkracujeme samotný seznam a při zvětšení vrátíme plnou výšku.
        int width = Math.Max(1, Math.Min((int)Math.Ceiling(contentWidth * dpi / 96.0),
            area.Right - area.Left - 2 * margin));
        int height = Math.Max(1, Math.Min((int)Math.Ceiling(contentHeight * dpi / 96.0),
            area.Bottom - area.Top - topMargin - margin - (int)Math.Round(34 * dpi / 96.0)));
        Point origin = new() { X = Math.Max(area.Left, area.Right - width - margin), Y = area.Top + topMargin };
        if (!ScreenToClient(parent, ref origin))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        // SWP_NOACTIVATE | SWP_FRAMECHANGED: nepřevzít focus a promítnout styly.
        // V moderní ploše je pořadí: ikony, náš lísteček, tapeta.
        if (!SetWindowPos(surface, insertAfter, origin.X, origin.Y, width, height, 0x0010 | 0x0020))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (!SetWindowPos(window, 0, 0, 0, width, height, 0x0010 | 0x0020))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    // Nula může být platný předchozí style; rozhoduje až GetLastError.
    private void SetStyle(int index, int value)
    {
        Marshal.SetLastPInvokeError(0);
        int previous = SetWindowLong(window, index, value);
        int error = Marshal.GetLastWin32Error();
        if (previous == 0 && error != 0)
            throw new Win32Exception(error);
    }

    // P/Invoke je most do user32.dll. Struktury mají pořadí a šířku polí Win32;
    // BOOL se marshaluje na .NET bool, řetězce používají Unicode varianty API.
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }
    private delegate bool EnumWindowsCallback(nint handle, nint parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindowEx(int extendedStyle, string className, string title,
        int style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetLayeredWindowAttributes(nint handle, uint colorKey, byte alpha, uint flags);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(nint handle, int command);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyWindow(nint handle);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint FindWindow(string className, string? title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint FindWindowEx(nint parent, nint after, string className, string? title);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsCallback callback, nint parameter);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(nint handle);
    [DllImport("user32.dll")]
    private static extern nint GetParent(nint handle);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetParent(nint handle, nint parent);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong(nint handle, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static extern int SetWindowLong(nint handle, int index, int value);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(nint handle, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ScreenToClient(nint handle, ref Point point);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, out Rect value, uint flags);
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint handle);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint handle, out Rect rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint SendMessageTimeout(nint handle, uint message, nuint wParam, nint lParam,
        uint flags, uint timeout, out nuint result);
}
