using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;

namespace Tercet;

/// <summary>
/// HTTP klient serveru fronty: GET s `If-None-Match`, PUT s `If-Match`,
/// token v hlavičce. Neřeší, co s odpovědí dělat; to je QueueSynchronizer.
/// Metody jsou synchronní (HttpClient.Send), aby šly volat i z testů bez
/// dispatcheru; aplikace je spouští na vlákně fondu (Task.Run).
/// </summary>
public sealed class QueueSyncClient(HttpClient http, QueueLink link)
{
    public const string TokenHeader = "X-Tercet-Token";

    /// <summary>
    /// Stejný výpočet jako server (`TercetStore.ComputeETag`): prvních 32 hex
    /// znaků SHA-256 přesných bajtů v uvozovkách. Díky tomu lokální soubor
    /// „zná“ svou serverovou verzi bez dotazu a synchronizace pozná, zda se
    /// od posledního sladění změnil. Parametr je pole, ne ReadOnlySpan jako
    /// na serveru: PowerShell testy Span nepředají.
    /// </summary>
    public static string ComputeETag(byte[] content)
        => "\"" + Convert.ToHexString(SHA256.HashData(content)).ToLowerInvariant()[..32] + "\"";

    // Známá verze jde v If-None-Match: server odpoví 304 bez těla, když se
    // nic nezměnilo. Bez známé verze (první sladění) se stáhne vždy celý dokument.
    public FetchResult Fetch(string? knownETag)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, link.Api);
        request.Headers.Add(TokenHeader, link.Token);
        if (knownETag is not null) request.Headers.TryAddWithoutValidation("If-None-Match", knownETag);
        using var response = http.Send(request, HttpCompletionOption.ResponseContentRead);
        switch (response.StatusCode)
        {
            case HttpStatusCode.NotModified:
                return new FetchResult(FetchStatus.NotModified, ETag: knownETag);
            case HttpStatusCode.NotFound:
                return new FetchResult(FetchStatus.NotFound);
            case HttpStatusCode.OK:
                byte[] content = ReadBody(response);
                // Kdyby server ETag neposlal, spočítáme ho stejně jako on.
                string etag = response.Headers.ETag?.Tag ?? ComputeETag(content);
                return new FetchResult(FetchStatus.Changed, content, etag, response.Content.Headers.LastModified);
            default:
                return new FetchResult(FetchStatus.Failed, Error: Describe(response));
        }
    }

    // PUT nahradí dokument jen tehdy, když server stále drží verzi z If-Match;
    // jinak 412 s aktuálním ETagem (souběžná změna z jiného zařízení).
    public PushResult Push(byte[] content, string expectedETag)
    {
        using var request = new HttpRequestMessage(HttpMethod.Put, link.Api);
        request.Headers.Add(TokenHeader, link.Token);
        request.Headers.TryAddWithoutValidation("If-Match", expectedETag);
        request.Content = new ByteArrayContent(content);
        request.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
        using var response = http.Send(request, HttpCompletionOption.ResponseContentRead);
        return response.StatusCode switch
        {
            HttpStatusCode.NoContent => new PushResult(PushStatus.Stored, response.Headers.ETag?.Tag ?? ComputeETag(content)),
            HttpStatusCode.PreconditionFailed => new PushResult(PushStatus.Conflict, response.Headers.ETag?.Tag),
            HttpStatusCode.NotFound => new PushResult(PushStatus.NotFound),
            _ => new PushResult(PushStatus.Failed, Error: Describe(response))
        };
    }

    private static byte[] ReadBody(HttpResponseMessage response)
    {
        using var stream = response.Content.ReadAsStream();
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return buffer.ToArray();
    }

    // Chybová odpověď serveru je krátký text (viz TercetEndpoints); do zprávy
    // pro uživatele jde stavový kód a první řádek textu.
    private static string Describe(HttpResponseMessage response)
    {
        string text;
        try { text = System.Text.Encoding.UTF8.GetString(ReadBody(response)).Trim(); }
        catch (Exception ex) when (ex is IOException or HttpRequestException) { text = ""; }
        int newline = text.IndexOf('\n');
        if (newline >= 0) text = text[..newline].TrimEnd();
        if (text.Length > 200) text = text[..200] + "…";
        return "HTTP " + (int)response.StatusCode + (text.Length > 0 ? ": " + text : "");
    }
}

public enum FetchStatus { NotModified, Changed, NotFound, Failed }

/// <summary>Výsledek GET: u Changed nese bajty dokumentu, ETag a čas změny.</summary>
public sealed record FetchResult(FetchStatus Status, byte[]? Content = null, string? ETag = null,
    DateTimeOffset? LastModified = null, string? Error = null);

public enum PushStatus { Stored, Conflict, NotFound, Failed }

/// <summary>Výsledek PUT: u Stored nový ETag, u Conflict ETag verze na serveru.</summary>
public sealed record PushResult(PushStatus Status, string? ETag = null, string? Error = null);
