using System.Windows;

namespace Tercet.Checks;

/// <summary>
/// Testy používají skutečné metody a resources App, ale dispatcher nesmí
/// spustit produkční OnStartup: ten získává zámek provozní instance a čte
/// uživatelovu frontu. Tato podtřída žije pouze v testovacím procesu.
/// </summary>
public sealed class TestApplication : App
{
    // Bez base.OnStartup: úložiště a okna si každý test připraví explicitně
    // nad svým dočasným adresářem. Nepřipojujeme se k ploše ani k systray.
    protected override void OnStartup(StartupEventArgs e) { }
}
