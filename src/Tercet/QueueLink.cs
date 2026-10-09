using System.Text.RegularExpressions;

namespace Tercet;

/// <summary>
/// Rozložený odkaz na frontu: stránka pro prohlížeč, adresa API a token.
/// Jediná hodnota v Settings je odkaz, který server vydá při založení fronty
/// (`https://example.com/Tercet/tercet.html#token`). API i token
/// se z něj odvodí: stránka volá `/api/tercet` na svém originu a token nese
/// jen fragment za `#`, který prohlížeč nikdy neposílá na server.
/// </summary>
/// <remarks>
/// `record` je neměnný typ: vlastnosti se nastaví jen v konstruktoru
/// a dvě instance se stejnými hodnotami jsou si rovny.
/// </remarks>
public sealed record QueueLink(Uri Page, Uri Api, string Token)
{
    public const string ApiPath = "/api/tercet";

    // Token má tvar serveru: 32 malých hexadecimálních znaků (128 bitů).
    // Regex je předkompilovaný jednou pro celou aplikaci (static readonly).
    private static readonly Regex TokenPattern = new("^[0-9a-f]{32}$", RegexOptions.CultureInvariant);

    /// <summary>
    /// Ověří text odkazu a rozloží ho. Chybný tvar hlásí FormatException
    /// s větou pro uživatele; dialog Settings ji zobrazí a odkaz neuloží.
    /// </summary>
    public static QueueLink Parse(string text)
    {
        // Uri.TryCreate vrací bool a výsledek předává přes `out` parametr;
        // relativní nebo nesmyslný text skončí false místo výjimky.
        if (!Uri.TryCreate(text.Trim(), UriKind.Absolute, out var page) || page.Host.Length == 0)
            throw new FormatException("The link is not a complete web address.");
        // https je povinné: token by jinak šel sítí nešifrovaně. http trpíme
        // jen pro loopback (lokální náhled serveru a automatické kontroly).
        bool https = page.Scheme == Uri.UriSchemeHttps;
        bool localHttp = page.Scheme == Uri.UriSchemeHttp && page.IsLoopback;
        if (!https && !localHttp)
            throw new FormatException("The link must start with https://.");
        // Uri.Fragment vrací i úvodní `#`; bez fragmentu je řetězec prázdný.
        string token = page.Fragment.TrimStart('#');
        if (!TokenPattern.IsMatch(token))
            throw new FormatException("The link must end with #token, where token has 32 hexadecimal characters.");
        // GetLeftPart(Authority) = schéma + host + port, tedy origin stránky.
        var api = new Uri(page.GetLeftPart(UriPartial.Authority) + ApiPath);
        return new QueueLink(page, api, token);
    }
}
