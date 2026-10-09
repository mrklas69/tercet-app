using System.IO;
using System.Net.Http;

namespace Tercet;

/// <summary>
/// Sladění lokální fronty se serverem. Tři verze: lokální soubor,
/// naposledy sladěná (`LastSyncedETag` v settings) a serverová. Lokální
/// soubor zůstává zdrojem pravdy při výpadku sítě; nic se nemění bez
/// úspěšné odpovědi serveru a konflikt rozhoduje uživatel přes callback.
/// </summary>
/// <remarks>
/// Rozhodovací tabulka (P = lokální změna od posledního sladění,
/// S = server změněn od posledního sladění):
/// ¬P ¬S → up to date · P ¬S → PUT · ¬P S → stáhnout · P S → dotaz.
/// První sladění (žádný LastSyncedETag) s daty na obou stranách je také
/// dotaz: obě strany mají různý dokument a nikdo neví, který platí.
/// </remarks>
public sealed class QueueSynchronizer(QueueStore queue, SettingsStore settings, QueueSyncClient client)
{
    // Func<SyncConflict, ConflictChoice> je předaná funkce: UI ukáže dialog,
    // testy vrátí volbu rovnou. Synchronizátor sám žádné okno nezná.
    public SyncResult Synchronize(Func<SyncConflict, ConflictChoice> resolveConflict)
    {
        try { return Run(resolveConflict); }
        catch (HttpRequestException ex)
        {
            return new SyncResult(SyncOutcome.Offline, "The server is not reachable; the queue on this computer is unchanged. " + ex.Message);
        }
        catch (TaskCanceledException)
        {
            // HttpClient hlásí vypršení časového limitu jako zrušení úlohy.
            return new SyncResult(SyncOutcome.Offline, "The server did not respond in time; the queue on this computer is unchanged.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new SyncResult(SyncOutcome.Failed, "Synchronization stopped: " + ex.Message);
        }
        catch (InvalidDataException ex)
        {
            // Poškozené settings.json (ruční zásah, NUL po výpadku napájení) hlásí
            // SettingsStore touto výjimkou, která NENÍ IOException. Bez této větve
            // propadla až do zahozeného Tasku v App a uživatel neviděl nic.
            // Náprava je ruční: soubor smazat, odkaz vložit znovu.
            return new SyncResult(SyncOutcome.Failed,
                "The settings file could not be read, so nothing was synchronized. Delete settings.json in the data folder and enter the queue link again. " + ex.Message);
        }
    }

    private SyncResult Run(Func<SyncConflict, ConflictChoice> resolveConflict)
    {
        string? lastSynced = settings.Load().LastSyncedETag;
        byte[]? local = queue.CurrentBytes();
        // Bez souboru (první start, jen demo) není co odesílat.
        string? localETag = local is null ? null : QueueSyncClient.ComputeETag(local);
        bool pending = local is not null && localETag != lastSynced;

        var fetch = client.Fetch(lastSynced);
        switch (fetch.Status)
        {
            case FetchStatus.NotModified:
                // Server drží sladěnou verzi: buď není co dělat, nebo odešleme
                // lokální změnu; If-Match zachytí závod s jiným zařízením.
                return pending
                    ? Upload(local!, lastSynced!, resolveConflict, retryOnConflict: true)
                    : new SyncResult(SyncOutcome.UpToDate, "Up to date.");
            case FetchStatus.NotFound:
                return new SyncResult(SyncOutcome.NotFound, "No queue exists for this link. Check the link in Settings.");
            case FetchStatus.Failed:
                return new SyncResult(SyncOutcome.Failed, "The server could not provide the queue. " + fetch.Error);
        }

        // Server má jinou verzi, než jakou známe.
        if (fetch.ETag == localETag)
        {
            // Stejné bajty na obou stranách (např. ručně zkopírovaný soubor):
            // jen si verzi zapamatujeme.
            Remember(fetch.ETag!);
            return new SyncResult(SyncOutcome.UpToDate, "Up to date.");
        }
        if (!pending) return Download(fetch);
        var choice = resolveConflict(new SyncConflict(lastSynced is null, fetch.LastModified));
        return choice switch
        {
            ConflictChoice.KeepLocal => Upload(local!, fetch.ETag!, resolveConflict, retryOnConflict: false),
            ConflictChoice.TakeServer => Download(fetch),
            _ => new SyncResult(SyncOutcome.Cancelled, "Synchronization cancelled; nothing was changed.")
        };
    }

    // Serverový dokument se přijme jen po validaci klientem (server obsah
    // nekontroluje). Zapisují se přesné bajty, aby lokální ETag zůstal
    // shodný se serverem; předchozí lokální verze zůstane v .bak.
    private SyncResult Download(FetchResult fetch)
    {
        QueueDocument document;
        try { document = queue.Import(fetch.Content!); }
        catch (Exception ex) when (ex is InvalidDataException or UnsupportedQueueVersionException)
        {
            return new SyncResult(SyncOutcome.InvalidDocument,
                "The queue on the server is not valid; the queue on this computer was kept. " + ex.Message);
        }
        Remember(fetch.ETag!);
        return new SyncResult(SyncOutcome.Downloaded, "Queue loaded from the server.", document);
    }

    private SyncResult Upload(byte[] local, string expectedETag, Func<SyncConflict, ConflictChoice> resolveConflict, bool retryOnConflict)
    {
        var push = client.Push(local, expectedETag);
        switch (push.Status)
        {
            case PushStatus.Stored:
                Remember(push.ETag ?? QueueSyncClient.ComputeETag(local));
                return new SyncResult(SyncOutcome.Uploaded, "Queue sent to the server.");
            case PushStatus.Conflict:
                // Server se změnil mezi GET a PUT. Jednou to zkusíme celé znovu
                // (nový GET najde změnu a položí dotaz); po dotazu už ne, jinak
                // by se dialog mohl opakovat donekonečna.
                return retryOnConflict
                    ? Run(resolveConflict)
                    : new SyncResult(SyncOutcome.Failed, "The queue on the server changed again meanwhile. Synchronize once more.");
            case PushStatus.NotFound:
                return new SyncResult(SyncOutcome.NotFound, "No queue exists for this link. Check the link in Settings.");
            default:
                return new SyncResult(SyncOutcome.Failed, "The server did not accept the queue. " + push.Error);
        }
    }

    // Nastavení se čte znovu: uživatel mohl mezitím v dialogu změnit odkaz.
    private void Remember(string etag) => settings.Save(settings.Load() with { LastSyncedETag = etag });
}

public enum SyncOutcome { UpToDate, Uploaded, Downloaded, Cancelled, Offline, NotFound, InvalidDocument, Failed }

/// <summary>
/// Výsledek sladění: co se stalo, věta pro uživatele a u stažení nový dokument,
/// který má aplikace zobrazit místo dosavadního.
/// </summary>
public sealed record SyncResult(SyncOutcome Outcome, string Message, QueueDocument? Document = null)
{
    public bool IsProblem => Outcome is SyncOutcome.Cancelled or SyncOutcome.Offline
        or SyncOutcome.NotFound or SyncOutcome.InvalidDocument or SyncOutcome.Failed;
}

public enum ConflictChoice { KeepLocal, TakeServer, Cancel }

/// <summary>
/// Popis konfliktu pro dialog: zda jde o první sladění s tímto odkazem
/// a kdy se serverová verze změnila (je-li známo).
/// </summary>
public sealed record SyncConflict(bool FirstSync, DateTimeOffset? ServerModified);
