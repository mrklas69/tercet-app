using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

namespace Tercet;

/// <summary>
/// Kde aplikace drží svá data. Nebalíčkový běh (skript nebo MSI) používá
/// <c>%LOCALAPPDATA%\Tercet</c> jako dosud. Běh
/// s identitou balíčku (MSIX) používá LocalState balíčku:
/// pod virtualizací AppData by nová složka vznikla v LocalCache a odinstalace
/// by ji smazala. Při prvním balíčkovém
/// startu se jednorázově převezmou soubory z dosavadní složky.
/// </summary>
public static class DataLocation
{
    /// <summary>
    /// Soubory tvořící data jednoho počítače: fronta, její záloha a nastavení.
    /// Odkaz na frontu a ETag v nastavení patří k bajtům fronty, proto se
    /// importují spolu. Pořadí je pořadím importu: fronta
    /// jde poslední, aby po výpadku uprostřed kopírování zbyla nanejvýš záloha,
    /// kterou příští start nabídne k obnově, nikdy fronta bez zálohy.
    /// </summary>
    public static readonly IReadOnlyList<string> DataFiles = ["settings.json", "queue.json.bak", "queue.json"];

    // Návratové kódy GetCurrentPackageFamilyName podle dokumentace Win32.
    private const int ErrorSuccess = 0;
    private const int ErrorInsufficientBuffer = 122;
    private const int AppModelErrorNoPackage = 15700;

    /// <summary>
    /// Rodinné jméno balíčku (Package Family Name) tohoto procesu, nebo null
    /// bez identity. Zjišťuje se jednou při prvním použití třídy; statická
    /// vlastnost s inicializátorem je v C# zkrácený zápis takové jednorázové
    /// hodnoty.
    /// </summary>
    public static string? PackageFamilyName { get; } = QueryPackageFamilyName();

    public static bool IsPackaged => PackageFamilyName is not null;

    /// <summary>Dosavadní složka: MSI, skript i zdroj importu pro balíček.</summary>
    public static string LegacyDirectory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tercet");

    /// <summary>
    /// LocalState balíčku složené podle konvence <c>Packages\&lt;PFN&gt;\LocalState</c>.
    /// Dokumentované API je WinRT <c>ApplicationData</c>, které by vyžadovalo
    /// TFM s Windows SDK a projekci CsWinRT, tedy další DLL v payloadu a další
    /// los v loterii SAC; konvence umístění platí od Windows 8.
    /// </summary>
    public static string PackageStateDirectory(string packageFamilyName) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Packages", packageFamilyName, "LocalState");

    /// <summary>Datový adresář tohoto procesu. Bez IO, jen podle identity.</summary>
    public static string Resolve()
        => PackageFamilyName is { } family ? PackageStateDirectory(family) : LegacyDirectory;

    /// <summary>
    /// Jednorázový import dosavadních dat do balíčkové složky. Převezme ty
    /// z trojice <see cref="DataFiles"/>, které ve zdroji jsou, ale jen když
    /// cíl zatím žádný z nich nemá a zdroj má frontu nebo zálohu (samotné
    /// nastavení bez fronty se nepřebírá). Zdroj zůstává netknutý: slouží
    /// jako záloha a umožňuje návrat k MSI verzi. Při chybě uprostřed
    /// smaže, co už zkopíroval, a chybu předá dál — půl importu by příští
    /// start považoval za vlastní data. Vrací jména převzatých souborů.
    /// </summary>
    public static IReadOnlyList<string> ImportLegacy(string sourceDirectory, string targetDirectory)
    {
        // LINQ Any: true, jakmile predikát platí pro jediný prvek.
        if (DataFiles.Any(name => File.Exists(Path.Combine(targetDirectory, name)))) return [];
        bool hasQueue = File.Exists(Path.Combine(sourceDirectory, "queue.json"))
            || File.Exists(Path.Combine(sourceDirectory, "queue.json.bak"));
        if (!hasQueue) return [];
        Directory.CreateDirectory(targetDirectory);
        var copied = new List<string>();
        try
        {
            foreach (string name in DataFiles)
            {
                string source = Path.Combine(sourceDirectory, name);
                if (!File.Exists(source)) continue;
                // Stejný trvanlivý zápis jako Save: po výpadku napájení nesmí
                // v LocalState ležet fronta správné délky plná NUL.
                DurableFile.WriteNew(Path.Combine(targetDirectory, name), File.ReadAllBytes(source));
                copied.Add(name);
            }
        }
        catch
        {
            // Holé catch bez filtru: úklid patří ke každé chybě, výjimka jde
            // dál nezměněná (throw; zachová původní stack trace).
            foreach (string name in copied) File.Delete(Path.Combine(targetDirectory, name));
            throw;
        }
        return copied;
    }

    // Dvojí volání podle vzoru Win32: první s prázdným bufferem vrátí délku,
    // druhé naplní buffer. Délka zahrnuje koncovou nulu, kterou do řetězce
    // nebereme. Nedokumentovaný návratový kód je chyba, ne „bez balíčku":
    // balíček, který by se mylně považoval za nebalíčkový, by psal do
    // virtualizované složky místo zvoleného LocalState.
    private static string? QueryPackageFamilyName()
    {
        uint length = 0;
        int result = GetCurrentPackageFamilyName(ref length, null);
        if (result == AppModelErrorNoPackage) return null;
        if (result != ErrorInsufficientBuffer) throw new Win32Exception(result);
        var buffer = new char[length];
        result = GetCurrentPackageFamilyName(ref length, buffer);
        if (result != ErrorSuccess) throw new Win32Exception(result);
        return new string(buffer, 0, (int)length - 1);
    }

    // Win32 API dostupné od Windows 8; bez identity vrací APPMODEL_ERROR_NO_PACKAGE.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetCurrentPackageFamilyName(ref uint length, [Out] char[]? packageFamilyName);
}
