using System.IO;

namespace Tercet;

/// <summary>
/// Přenosná záloha celé fronty včetně archivu. Obsahuje jen dokument
/// fronty, nikoli nastavení a přístupový odkaz. Obnova zde pouze čte a ověřuje;
/// provozní soubor mění až běžné Save z editoru.
/// </summary>
public static class QueueBackup
{
    // Zápis přes sousední dočasný soubor zachová starší zálohu, když selže
    // serializace nebo zápis. Přepsání cíle předem potvrzuje SaveFileDialog.
    public static void Write(QueueDocument document, string destination, string dataRoot)
    {
        string target = Path.GetFullPath(destination);
        string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(dataRoot));
        if (target.Equals(root, StringComparison.OrdinalIgnoreCase)
            || target.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Choose a backup location outside Tercet's data folder, such as Documents.");
        document.Validate();
        byte[] bytes = document.ToBytes();
        string temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            DurableFile.WriteNew(temporary, bytes);
            File.Move(temporary, target, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    // Stejná validace schématu i stromu jako při startu. Chybný nebo novější
    // formát se odmítne dřív, než vznikne editor s obnovovaným obsahem.
    public static QueueDocument Read(string source) => QueueDocument.Parse(File.ReadAllBytes(source));
}
