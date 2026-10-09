using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tercet;

/// <summary>
/// Nastavení tohoto počítače: odkaz na frontu a verze (ETag), se
/// kterou byl lokální soubor naposledy sladěn se serverem. Obojí je vázané
/// na stroj, proto nesmí do `queue.json`, který cestuje na server.
/// </summary>
/// <remarks>
/// `LastSyncedETag` je stav, ne volba uživatele; leží tu proto, že patří
/// k odkazu (změna odkazu ho ruší) a druhý soubor by byl jen další věc,
/// kterou lze zapomenout. Výraz `settings with { LastSyncedETag = x }`
/// vytvoří kopii záznamu s jednou změněnou vlastností.
/// </remarks>
public sealed record SyncSettings(string? QueueLink, string? LastSyncedETag)
{
    public static readonly SyncSettings Default = new(null, null);

    // Vlastní deklarace vlastností nahradí ty, které by record vytvořil sám:
    // prázdný nebo bílý text (ručně upravený soubor, PowerShell předá $null
    // jako "") znamená „žádná hodnota“, stejně jako null. `init` dovoluje
    // nastavení jen při vzniku instance, včetně výrazu `with`.
    public string? QueueLink { get; init; } = Blank(QueueLink);
    public string? LastSyncedETag { get; init; } = Blank(LastSyncedETag);

    private static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;
}

/// <summary>
/// Jeden JSON soubor `settings.json` vedle fronty. Chybějící soubor znamená
/// výchozí nastavení; poškozený se hlásí a nikdy tiše nepřepisuje.
/// </summary>
public sealed class SettingsStore(string path)
{
    private const int SchemaVersion = 1;

    public SyncSettings Load()
    {
        byte[] bytes;
        try { bytes = File.ReadAllBytes(path); }
        catch (FileNotFoundException) { return SyncSettings.Default; }
        catch (DirectoryNotFoundException) { return SyncSettings.Default; }
        try
        {
            var root = JsonNode.Parse(bytes) as JsonObject
                ?? throw new InvalidDataException("The settings file must contain a JSON object.");
            // ?. vrátí null, když klíč chybí; GetValue<int> pak neběží.
            int version = root["schemaVersion"]?.GetValue<int>()
                ?? throw new InvalidDataException("The settings file has no schemaVersion.");
            if (version != SchemaVersion)
                throw new InvalidDataException($"Settings version {version} is not supported (expected {SchemaVersion}).");
            return new SyncSettings(Text(root, "queueLink"), Text(root, "lastSyncedETag"));
        }
        catch (JsonException ex)
        {
            throw new InvalidDataException("The settings file is not valid JSON. " + ex.Message, ex);
        }
        catch (InvalidOperationException ex)
        {
            // GetValue vyhodí InvalidOperationException, když má klíč jiný typ.
            throw new InvalidDataException("The settings file has a value of the wrong type. " + ex.Message, ex);
        }
    }

    // Zápis přes dočasný soubor s flush na disk a přejmenování, stejně jako
    // fronta (DurableFile): čtenář nikdy nevidí soubor rozepsaný napůl a výpadek
    // napájení nenechá soubor plný NUL. Záloha není potřeba, hodnoty jde
    // znovu vložit ručně.
    public void Save(SyncSettings settings)
    {
        var root = new JsonObject
        {
            ["schemaVersion"] = SchemaVersion,
            ["queueLink"] = settings.QueueLink,
            ["lastSyncedETag"] = settings.LastSyncedETag
        };
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(root, new JsonSerializerOptions { WriteIndented = true });
        string directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(directory);
        string temporary = Path.Combine(directory, Path.GetRandomFileName());
        try
        {
            DurableFile.WriteNew(temporary, bytes);
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    // Chybějící klíč i JSON null dají null; jiný typ než řetězec je chyba.
    private static string? Text(JsonObject root, string key)
        => root[key] is JsonValue value ? value.GetValue<string>() : null;
}
