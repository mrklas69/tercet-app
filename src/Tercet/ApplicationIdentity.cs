namespace Tercet;

/// <summary>
/// Jediný zdroj uživatelského názvu distribuce. Název souboru EXE,
/// datové složky ani technické identifikátory oken se tím nemění.
/// </summary>
public static class ApplicationIdentity
{
    // Identitu zjišťuje DataLocation jednou přes Win32. Stejná binárka tak
    // rozliší MSI/skript, testovací MSIX a budoucí balíček ze Storu.
    public static string DisplayName { get; } = GetDisplayName(DataLocation.PackageFamilyName);

    /// <summary>
    /// PFN má tvar Name_PublisherId. Přesný název před podtržítkem zabrání
    /// záměně prototypu s jiným balíčkem, jehož jméno jen podobně začíná.
    /// Čistá funkce umožňuje ověřit pravidlo i bez instalace tří distribucí.
    /// Operátor podmínka ? ano : ne zde postupně vybírá jednu ze tří větví.
    /// </summary>
    public static string GetDisplayName(string? packageFamilyName)
        => packageFamilyName is null ? "Tercet Preview"
            : packageFamilyName.StartsWith("Tercet.Prototype_", StringComparison.Ordinal)
                ? "Tercet Prototype" : "Tercet";

    /// <summary>Jednotný titulek okna, dialogu nebo oznámení s názvem operace.</summary>
    public static string Title(string operation) => $"{DisplayName} — {operation}";
}
