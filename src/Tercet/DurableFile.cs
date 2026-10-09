using System.IO;

namespace Tercet;

/// <summary>
/// Trvanlivý zápis nového souboru, společný pro frontu i nastavení.
/// Flush(flushToDisk: true) žádá vyprázdnění i diskových bufferů dřív, než
/// volající soubor přejmenuje na cílové jméno. Bez toho může NTFS po výpadku
/// napájení dokončit přejmenování a délku, ale ne obsah: zůstane soubor
/// správné velikosti plný NUL. Stejnou ochranu potřebuje i SettingsStore:
/// poškozený settings.json by vypnul synchronizaci.
/// </summary>
internal static class DurableFile
{
    // CreateNew odmítne existující soubor: volající dává dočasné jedinečné jméno.
    public static void WriteNew(string destination, byte[] bytes)
    {
        using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        output.Write(bytes);
        output.Flush(flushToDisk: true);
    }
}
