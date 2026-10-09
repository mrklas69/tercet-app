using System.Drawing;
using System.Windows;

namespace Tercet;

/// <summary>
/// Systray používá stejný ICO resource jako exe a WPF okna.
/// Volající vlastní vrácenou Icon a musí ji uvolnit přes Dispose.
/// </summary>
public static class TrayIconRenderer
{
    public static Icon Create()
    {
        // Pack URI čte resource z assembly, nikoli soubor vedle exe.
        // ICO obsahuje více rozměrů; vybereme velikost malé systémové ikony.
        using var stream = Application.GetResourceStream(new Uri(
            "pack://application:,,,/Tercet;component/Assets/Tercet.ico"))!.Stream;
        using var icon = new Icon(stream, System.Windows.Forms.SystemInformation.SmallIconSize);
        // Clone oddělí životnost výsledku od streamu, který using zavře.
        return (Icon)icon.Clone();
    }
}
