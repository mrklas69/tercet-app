using System.IO;

namespace Tercet;

/// <summary>
/// Jeden JSON dokument, dočasný soubor na stejném disku a záloha předchozí verze.
/// Cesta přichází z App; ověření proto může použít výhradně dočasný adresář.
/// </summary>
public sealed class QueueStore(string path)
{
    private byte[]? loadedBytes;

    // Volající bez UI nemůže obnovu potvrdit. Ponechá proto původní chování
    // striktního Load: při potřebě obnovy vyhodí datovou chybu a nic nezapíše.
    public QueueDocument Load(Stream initialData)
        => Load(initialData, _ => throw new InvalidDataException(
            "The queue requires recovery. Start Tercet to restore the validated backup."))!;

    // Func je předaná funkce: UI rozhodne ano/ne, úložiště samo WPF nezná.
    // Null návrat znamená odmítnutou obnovu, nikoli prázdnou frontu.
    public QueueDocument? Load(Stream initialData, Func<QueueRecovery, bool> confirmRecovery)
    {
        byte[]? current = ReadExisting(path);
        InvalidDataException? invalid = null;
        if (current is not null)
        {
            try
            {
                var document = QueueDocument.Parse(current);
                // Stav potvrdíme až po validaci. Neúspěšný reload nesmí
                // přijmout cizí bajty jako základ následujícího Save.
                loadedBytes = current;
                return document;
            }
            catch (InvalidDataException ex) { invalid = ex; }
            // Chyby přístupu a UnsupportedQueueVersionException sem
            // nespadají: musí skončit hlášením bez nabídky obnovy.
        }

        byte[]? backup = ReadExisting(path + ".bak");
        if (current is null && backup is null)
        {
            using var buffer = new MemoryStream();
            initialData.CopyTo(buffer);
            var document = QueueDocument.Parse(buffer.ToArray());
            loadedBytes = null;
            return document;
        }
        if (backup is null)
            throw new InvalidDataException("The queue is invalid and no backup is available. " + invalid?.Message, invalid);

        QueueDocument recovered;
        try { recovered = QueueDocument.Parse(backup); }
        catch (Exception ex) when (ex is InvalidDataException or UnsupportedQueueVersionException)
        {
            throw new InvalidDataException("The queue could not be loaded and its backup is not usable. " + ex.Message, ex);
        }
        // Bajty zůstávají soukromé v této metodě. Callback smí rozhodnout,
        // ale nemůže podstrčit jinou zálohu nebo změnit validovaný dokument.
        if (!confirmRecovery(new QueueRecovery(Path.GetFullPath(path), current is null))) return null;
        RestoreBackup(current, backup);
        return recovered;
    }

    // Uložení vlastní editace: dokument se ověří a serializuje zdejším tvarem.
    public void Save(QueueDocument document)
    {
        document.Validate();
        WriteChecked(document.ToBytes());
    }

    // Přijetí dokumentu z jiného zdroje (server): ověří se parsováním
    // a zapíší se přesné bajty, aby lokální ETag zůstal shodný se serverem
    // a příští sladění nepovažovalo soubor za změněný. Vrací přijatý dokument.
    public QueueDocument Import(byte[] bytes)
    {
        var document = QueueDocument.Parse(bytes);
        WriteChecked(bytes);
        return document;
    }

    // Bajty souboru tak, jak leží na disku (null = soubor dosud nevznikl).
    // Sladění z nich počítá lokální verzi; Save dál hlídá cizí změny samo.
    public byte[]? CurrentBytes() => ReadExisting(path);

    // FileShare.None serializuje naše zapisovatele. Kontrola původních bajtů
    // navíc zabrání tomu, aby starší instance přepsala novější uloženou editaci.
    private void WriteChecked(byte[] bytes)
    {
        string directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(directory);
        using var writeLock = new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        byte[]? current = ReadExisting(path);
        if (!SameBytes(current, loadedBytes))
            throw new IOException("The data was changed by another instance. Changes are not saved; close the editor and start Tercet again.");
        WriteDocument(bytes, current, path + ".bak");
    }

    // Obnova používá stejný zámek jako Save a znovu kontroluje oba snímky
    // z doby před dialogem. Při konfliktu neudělá ani kopii vadného souboru.
    private void RestoreBackup(byte[]? original, byte[] backup)
    {
        using var writeLock = new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        if (!SameBytes(ReadExisting(path), original) || !SameBytes(ReadExisting(path + ".bak"), backup))
            throw new IOException("The queue or its backup changed while recovery was being offered. Nothing was restored; start Tercet again.");
        if (original is not null)
        {
            // CreateNew nikdy nepřepíše dřívější záchrannou kopii. Čas slouží
            // člověku, GUID odliší i několik pokusů v jedné milisekundě.
            string preserved = path + $".corrupt-{DateTime.UtcNow:yyyyMMddTHHmmssfffZ}-{Guid.NewGuid():N}.json";
            DurableFile.WriteNew(preserved, original);
        }
        // Null backupFile u File.Replace ponechá existující .bak nedotčenou.
        // Při chybě zůstává záchranná kopie k dispozici, automaticky ji nemažeme.
        WriteDocument(backup, original, backupFile: null);
    }

    // Společný trvanlivý zápis; volající už drží zámek a ověřil konflikt.
    // Běžné Save vytváří .bak, obnova používá samostatně zachovaný originál.
    private void WriteDocument(byte[] bytes, byte[]? current, string? backupFile)
    {
        string directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        string temporary = Path.Combine(directory, Path.GetRandomFileName());
        try
        {
            DurableFile.WriteNew(temporary, bytes);
            if (current is null) File.Move(temporary, path);
            else File.Replace(temporary, path, backupFile);
            loadedBytes = bytes;
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    // Nepřítomnost souboru je odlišná od přítomného prázdného souboru.
    private static bool SameBytes(byte[]? left, byte[]? right)
        => left is null ? right is null : right is not null && left.AsSpan().SequenceEqual(right);

    // File.Exists by schovalo i odmítnutí přístupu. Null vracíme jen pro
    // skutečně chybějící soubor; první start určí Load podle obou cest.
    private static byte[]? ReadExisting(string filePath)
    {
        try { return File.ReadAllBytes(filePath); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }
}

/// <summary>
/// Neměnný popis pro potvrzovací dialog. Record vytváří vlastnosti z parametrů;
/// neobsahuje obsah souborů, aby jej UI nemohlo před obnovou změnit.
/// </summary>
public sealed record QueueRecovery(string FilePath, bool IsMissing);
