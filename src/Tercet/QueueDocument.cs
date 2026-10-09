using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tercet;

/// <summary>
/// Pracovní dokument prvního editoru. JsonObject zachová i dosud needitované
/// údaje a archiv. Kopie má vlastní uzly, takže Zrušit nemění uloženou frontu.
/// </summary>
public sealed class QueueDocument
{
    private readonly JsonObject root;
    private QueueDocument(JsonObject root) => this.root = root;

    // Parser odmítá duplicitní klíče i uvnitř potomků a neznámých polí.
    // Chyba syntaxe dostane stejný datový typ výjimky jako chyba modelu;
    // programátorské výjimky se zde na chybný vstup nepřevádějí.
    public static QueueDocument Parse(byte[] bytes)
    {
        try
        {
            var options = new JsonDocumentOptions { AllowDuplicateProperties = false };
            var document = new QueueDocument(JsonNode.Parse(bytes, documentOptions: options) as JsonObject
                ?? throw new InvalidDataException("The document root must be an object."));
            document.Validate();
            return document;
        }
        catch (JsonException ex)
        {
            throw new InvalidDataException("Invalid queue JSON document. " + ex.Message, ex);
        }
    }

    public QueueDocument Clone() => new((JsonObject)root.DeepClone());
    public byte[] ToBytes() => JsonSerializer.SerializeToUtf8Bytes(root, new JsonSerializerOptions { WriteIndented = true });
    public bool HasSameData(QueueDocument other) => JsonNode.DeepEquals(root, other.root);

    // Projekce čte uzly přímo, nic neserializuje ani znovu nevaliduje. Rozepsaný
    // název může být prázdný: zobrazení musí fungovat i před úspěšným Uložit.
    // Struktura už prošla validací při načtení a mění ji operace modelu.
    public IReadOnlyList<QueueRow> Rows()
    {
        var rows = new List<QueueRow>();
        foreach (var item in Flatten((JsonArray)root["queue"]!))
        {
            string kind = Text(item, "kind");
            rows.Add(new QueueRow(Text(item, "title"), kind, Depth(item),
                kind == "group" ? null : Text(item, "situation"),
                kind == "group" ? null : Text(item, "perspective")));
        }
        return rows;
    }

    public IReadOnlyList<JsonObject> QueueItems() => Flatten((JsonArray)root["queue"]!).ToList();

    // Nové položky vznikají s výchozími hodnotami modelu: úkol
    // šedý (inactive), běžná priorita, perspektiva hodin, bez řešitele (null
    // je vyplnitelný údaj, ne chybějící). Skupina má jen prázdné potomky.
    public static JsonObject NewTask(string title) => new()
    {
        ["id"] = Guid.NewGuid().ToString(), ["kind"] = "task", ["title"] = title,
        ["situation"] = "inactive", ["priority"] = "normal", ["perspective"] = "hours", ["assignee"] = null
    };

    public static JsonObject NewGroup(string title) => new()
    {
        ["id"] = Guid.NewGuid().ToString(), ["kind"] = "group", ["title"] = title, ["children"] = new JsonArray()
    };

    // JsonNode zná svého rodiče: položka → pole potomků → objekt rodiče.
    // Rodičem položky v technickém kořeni je samotný root dokumentu, tedy null.
    public JsonObject? ParentOf(JsonObject item)
    {
        var siblings = item.Parent as JsonArray
            ?? throw new InvalidOperationException("The item is not part of the queue.");
        return ReferenceEquals(siblings.Parent, root) ? null : (JsonObject)siblings.Parent!;
    }

    // Hloubka od nuly, shodná s QueueRow.Depth; kořen dokumentu se nepočítá.
    public int Depth(JsonObject item)
    {
        int depth = 0;
        for (var parent = ParentOf(item); parent is not null; parent = ParentOf(parent)) depth++;
        return depth;
    }

    public int SubtreeCount(JsonObject item)
        => 1 + (item["children"] is JsonArray children ? children.OfType<JsonObject>().Sum(SubtreeCount) : 0);

    // Výška podstromu: list má 0, rodič o jedna víc než jeho nejvyšší potomek.
    // Při přesunu rozhoduje spolu s hloubkou cíle, zda se podstrom vejde
    // pod strop tří úrovní: Depth(cíl) + 1 + výška ≤ 2.
    public int SubtreeHeight(JsonObject item)
        => item["children"] is JsonArray { Count: > 0 } children
            ? 1 + children.OfType<JsonObject>().Max(SubtreeHeight) : 0;

    // Pravidla vložení: typy, strop tří úrovní a zákaz nehotové práce pod
    // dokončeným celkem. Null = technický kořen.
    // UI podle téhle metody položky menu skrývá, operace ji vynucují znovu.
    // Skupina se zakládá jen na první a druhé úrovni: na třetí by už nemohla
    // mít potomky a nic by neorganizovala. Validace načtených dat
    // takovou skupinu dál přijímá; pravidlo omezuje jen vytváření.
    // Parametr `completed` říká, zda je vkládaná práce celá Hotovo: taková smí
    // i pod dokončený celek (obnova z archivu, přesun hotového úkolu).
    // Výchozí hodnota false odpovídá nové položce, která vzniká šedá.
    public bool CanInsertInto(JsonObject? parent, string kind, bool completed = false)
    {
        if (parent is null) return true;
        string parentKind = Text(parent, "kind");
        if (parentKind == "task" || Depth(parent) >= 2) return false;
        if (kind == "group") return parentKind == "group" && Depth(parent) == 0;
        if (completed) return true;
        for (var ancestor = parent; ancestor is not null; ancestor = ParentOf(ancestor))
            if (ancestor["situation"] is JsonValue situation && situation.GetValue<string>() == "done") return false;
        return true;
    }

    // Celý podstrom je Hotovo: úkol nebo celek se situací done a všechny části
    // rekurzivně také. Skupina situaci nemá, nikdy není dokončená.
    // Pracovní kopie smí dočasně držet hotový celek s nehotovou částí, proto
    // se rozhoduje z aktuálního stavu uzlů, ne z validace při načtení.
    public bool IsCompleted(JsonObject item)
        => item["situation"] is JsonValue situation && situation.GetValue<string>() == "done"
            && (item["children"] is not JsonArray children || children.OfType<JsonObject>().All(IsCompleted));

    // Nová položka jde na konec potomků zvoleného rodiče.
    public void AppendChild(JsonObject? parent, JsonObject item)
    {
        if (!CanInsertInto(parent, Text(item, "kind")))
            throw new InvalidOperationException("The item cannot be inserted here.");
        var children = parent is null ? (JsonArray)root["queue"]! : (JsonArray)parent["children"]!;
        children.Add(item);
    }

    // Nový sourozenec vznikne hned za vybraným řádkem, nikoli
    // na konci seznamu jako při AppendChild; pořadí lze dále měnit přesunem.
    public void InsertAfter(JsonObject anchor, JsonObject item)
    {
        if (!CanInsertInto(ParentOf(anchor), Text(item, "kind")))
            throw new InvalidOperationException("The item cannot be inserted here.");
        var siblings = (JsonArray)anchor.Parent!;
        siblings.Insert(siblings.IndexOf(anchor) + 1, item);
    }

    // Převody typů zachovávají identitu i pracovní údaje, mění jen kind
    // a přítomnost pole potomků. Rozdělení jde i na třetí úrovni:
    // prázdný celek tam části nedostane, dokud ho uživatel nepřesune výš
    // (MoveTo).
    public bool CanSplit(JsonObject item) => Text(item, "kind") == "task";

    public void SplitIntoParts(JsonObject item)
    {
        if (!CanSplit(item)) throw new InvalidOperationException("This task cannot be split into parts.");
        item["kind"] = "compositeTask";
        item["children"] = new JsonArray();
    }

    // Zpětný převod jen bez částí, aby se sledovaná práce nezahodila.
    public bool CanMerge(JsonObject item)
        => Text(item, "kind") == "compositeTask" && item["children"] is JsonArray { Count: 0 };

    public void MergeIntoTask(JsonObject item)
    {
        if (!CanMerge(item)) throw new InvalidOperationException("A composite task with parts cannot be merged into a task.");
        item["kind"] = "task";
        item.Remove("children");
    }

    // Posun o jednu pozici mezi sourozenci, s celým podstromem.
    // Na okraji seznamu vrací false a nic nemění; UI podle toho volbu zašedí.
    // Vzor Try*: místo výjimky vrací bool, protože okraj není chyba.
    public bool TryMove(JsonObject item, int delta)
    {
        var siblings = item.Parent as JsonArray
            ?? throw new InvalidOperationException("The item is not part of the queue.");
        int index = siblings.IndexOf(item);
        int target = index + delta;
        if (target < 0 || target >= siblings.Count) return false;
        siblings.RemoveAt(index);
        siblings.Insert(target, item);
        return true;
    }

    public bool CanMove(JsonObject item, int delta)
    {
        var siblings = (JsonArray)item.Parent!;
        int target = siblings.IndexOf(item) + delta;
        return target >= 0 && target < siblings.Count;
    }

    // Přesun k jinému rodiči: celý podstrom, cíl null = technický kořen.
    // Odmítá současného rodiče (prázdná operace), položku samu a její potomky
    // (cyklus), typy rodiče a potomka a stav dokončeného celku (obojí
    // přes CanInsertInto) a podstrom, který by přesáhl tři úrovně.
    public bool CanMoveTo(JsonObject item, JsonObject? newParent)
    {
        if (ReferenceEquals(newParent, ParentOf(item))) return false;
        for (var ancestor = newParent; ancestor is not null; ancestor = ParentOf(ancestor))
            if (ReferenceEquals(ancestor, item)) return false;
        return CanPlace(item, newParent);
    }

    // Společná část přesunu a obnovy z archivu: typ a dokončenost podle
    // CanInsertInto, strop tří úrovní podle hloubky cíle a výšky podstromu.
    private bool CanPlace(JsonObject item, JsonObject? parent)
    {
        if (!CanInsertInto(parent, Text(item, "kind"), IsCompleted(item))) return false;
        int targetDepth = parent is null ? 0 : Depth(parent) + 1;
        return targetDepth + SubtreeHeight(item) <= 2;
    }

    // Přesunutá položka jde na konec potomků cíle, stejně jako nová položka
    // a obnova z archivu; pořadí pak upraví TryMove.
    public void MoveTo(JsonObject item, JsonObject? newParent)
    {
        if (!CanMoveTo(item, newParent)) throw new InvalidOperationException("The item cannot be moved here.");
        ((JsonArray)item.Parent!).Remove(item);
        var children = newParent is null ? (JsonArray)root["queue"]! : (JsonArray)newParent["children"]!;
        children.Add(item);
    }

    // Platné cíle přesunu v pořadí fronty; UI z nich skládá podmenu. Kořen
    // se hlásí jako null. Prázdný výčet znamená „teď není kam“ (volba
    // zůstává vidět zašedlá, protože ji nezakazuje typ, jen aktuální strom).
    public IReadOnlyList<JsonObject?> MoveTargets(JsonObject item)
    {
        var targets = new List<JsonObject?>();
        if (CanMoveTo(item, null)) targets.Add(null);
        foreach (var candidate in QueueItems())
            if (CanMoveTo(item, candidate)) targets.Add(candidate);
        return targets;
    }

    // Cesta k položce od první úrovně, např. „Workshop › Backlog“; nejvýš dva články,
    // protože cíl přesunu leží nejhlouběji na druhé úrovni.
    public string PathOf(JsonObject item)
    {
        var titles = new List<string>();
        for (JsonObject? node = item; node is not null; node = ParentOf(node)) titles.Insert(0, Text(node, "title"));
        return string.Join(" › ", titles);
    }

    // Odstranění celého podstromu; potvrzení s počtem je věcí UI.
    // Vrací počet odstraněných položek včetně vybrané.
    public int Remove(JsonObject item)
    {
        int count = SubtreeCount(item);
        var siblings = item.Parent as JsonArray
            ?? throw new InvalidOperationException("The item is not part of the queue.");
        siblings.Remove(item);
        return count;
    }

    // Archivace: jen úkol nebo celek, jehož celý podstrom je
    // Hotovo. Skupina se nearchivuje, nemá dokončení. UI podle toho volbu
    // u skupiny skryje a u nehotové práce zašedí.
    public bool CanArchive(JsonObject item) => Text(item, "kind") != "group" && IsCompleted(item);

    // Záznam archivu si pamatuje původního rodiče (id, null = kořen) a index
    // mezi sourozenci. JsonNode smí mít jen jednoho rodiče, proto se
    // položka nejdřív vyjme z fronty a teprve pak vloží do záznamu. Záznam jde
    // na konec pole `archive`; pořadí zobrazení je věcí UI.
    public JsonObject Archive(JsonObject item)
    {
        if (!CanArchive(item)) throw new InvalidOperationException("Only completed work can be archived.");
        var siblings = (JsonArray)item.Parent!;
        var parent = ParentOf(item);
        var record = new JsonObject
        {
            ["originalParentId"] = parent is null ? null : Text(parent, "id"),
            ["originalIndex"] = siblings.IndexOf(item)
        };
        siblings.Remove(item);
        record["item"] = item;
        ((JsonArray)root["archive"]!).Add(record);
        return record;
    }

    // Záznamy archivu v uloženém pořadí (nejstarší první). Položka záznamu
    // je pod klíčem `item`; ArchivedItem ji vrací bez opakování přetypování.
    public IReadOnlyList<JsonObject> ArchiveEntries() => ((JsonArray)root["archive"]!).OfType<JsonObject>().ToList();

    public static JsonObject ArchivedItem(JsonObject entry) => (JsonObject)entry["item"]!;

    // Kam se záznam obnoví: k původnímu rodiči na původní
    // index (nejvýš na konec), pokud rodič ve frontě existuje a vložení splňuje
    // typ, dokončenost a strop tří úrovní. Jinak na konec technického kořene.
    // Původní umístění v kořeni se pozná podle originalParentId = null.
    // Vrací dvojici (tuple): rodič nebo null pro kořen, a index vložení.
    public (JsonObject? Parent, int Index) RestorePlacement(JsonObject entry)
    {
        var item = ArchivedItem(entry);
        string? parentId = entry["originalParentId"]?.GetValue<string>();
        int originalIndex = entry["originalIndex"]!.GetValue<int>();
        var queue = (JsonArray)root["queue"]!;
        if (parentId is null) return (null, Math.Min(originalIndex, queue.Count));
        // Stejné UUID smí mít různé přijaté textové zápisy. Porovnáváme
        // hodnotu Guid jako při validaci jedinečnosti, uložený text neměníme.
        var parentIdentity = Guid.Parse(parentId);
        var parent = QueueItems().FirstOrDefault(candidate => Guid.Parse(Text(candidate, "id")) == parentIdentity);
        if (parent is null || !CanPlace(item, parent)) return (null, queue.Count);
        return (parent, Math.Min(originalIndex, ((JsonArray)parent["children"]!).Count));
    }

    // Obnova nikdy neselže, jen mění cíl; identita i situace Hotovo zůstávají.
    // Odebrání klíče `item` uvolní položku ze záznamu, aby ji šlo
    // vložit do fronty. Vrací obnovenou položku, aby na ni UI mohlo dát focus.
    public JsonObject Restore(JsonObject entry)
    {
        var archive = (JsonArray)root["archive"]!;
        if (!ReferenceEquals(entry.Parent, archive)) throw new InvalidOperationException("The entry is not in the archive.");
        var (parent, index) = RestorePlacement(entry);
        var item = ArchivedItem(entry);
        archive.Remove(entry);
        entry.Remove("item");
        var children = parent is null ? (JsonArray)root["queue"]! : (JsonArray)parent["children"]!;
        children.Insert(index, item);
        return item;
    }

    private static IEnumerable<JsonObject> Flatten(JsonArray items)
    {
        foreach (var node in items)
        {
            if (node is not JsonObject item)
                throw new InvalidDataException("Invalid item.");
            yield return item;
            if (item["children"] is JsonArray children)
                foreach (var child in Flatten(children)) yield return child;
        }
    }

    // Validace celého dokumentu běží při načtení i před uložením. Editor smí
    // dočasně držet neplatnou kombinaci, ale nemůže ji potvrdit na disk.
    public void Validate()
    {
        if (root["schemaVersion"] is not JsonValue version
            || !version.TryGetValue<int>(out int schemaVersion))
            throw new InvalidDataException("The queue format version is missing or invalid.");
        // Verzi rozlišíme před pravidly dnešní obálky: novější formát může
        // mít jinou strukturu a nesmí být nabídnut jako poškozený k obnově.
        if (schemaVersion != 1) throw new UnsupportedQueueVersionException(schemaVersion);
        if (root["queue"] is not JsonArray queue)
            throw new InvalidDataException("Invalid queue envelope (expected schemaVersion 1 and a queue array).");
        var ids = new HashSet<Guid>();
        foreach (var item in queue) ValidateItem(item, 0, null, false, ids);
        if (root["archive"] is not JsonArray archive)
            throw new InvalidDataException("The archive array is missing.");
        foreach (var entry in archive)
        {
            if (entry is not JsonObject record || !record.ContainsKey("originalParentId")
                || (record["originalParentId"] is not null && !Guid.TryParse(Text(record, "originalParentId"), out _))
                || record["originalIndex"] is not JsonValue index || !index.TryGetValue<int>(out int number) || number < 0)
                throw new InvalidDataException("Invalid original position in the archive.");
            ValidateItem(record["item"], 0, null, true, ids);
        }
    }

    private static void ValidateItem(JsonNode? node, int depth, string? parentKind, bool mustBeDone, HashSet<Guid> ids)
    {
        if (node is not JsonObject item) throw new InvalidDataException("Invalid item.");
        string title = Text(item, "title");
        string kind = Text(item, "kind");
        if (string.IsNullOrWhiteSpace(title) || title.Contains('\n') || title.Contains('\r'))
            throw new InvalidDataException("The title must be a non-empty single-line text.");
        if (!Guid.TryParse(Text(item, "id"), out var id) || !ids.Add(id))
            throw new InvalidDataException($"{title}: invalid or duplicate identity.");
        if (depth > 2 || kind is not ("group" or "compositeTask" or "task")
            || (kind == "group" && (parentKind == "compositeTask" || mustBeDone)))
            throw new InvalidDataException($"{title}: invalid hierarchy.");
        if (kind == "group")
        {
            foreach (string field in new[] { "situation", "priority", "perspective", "assignee" })
                if (item.ContainsKey(field)) throw new InvalidDataException($"{title}: a group has no {field} field.");
        }
        else
        {
            string situation = Text(item, "situation");
            if (!QueueValues.Situations.Contains(situation)
                || !QueueValues.Priorities.Contains(Text(item, "priority"))
                || !QueueValues.Perspectives.Contains(Text(item, "perspective")))
                throw new InvalidDataException($"{title}: unknown situation, priority or perspective.");
            if (mustBeDone && situation != "done")
                throw new InvalidDataException($"{title}: a part of a completed composite task must also be done.");
            if (!item.ContainsKey("assignee") || (item["assignee"] is not null && string.IsNullOrWhiteSpace(Text(item, "assignee"))))
                throw new InvalidDataException($"{title}: the assignee must be a text or null.");
            if (situation is "inProgress" or "underReview" && item["assignee"] is null)
                throw new InvalidDataException($"{title}: work in progress requires an assignee.");
            mustBeDone |= situation == "done";
        }
        if (kind == "task")
        {
            if (item.ContainsKey("children")) throw new InvalidDataException($"{title}: a task must not have children.");
        }
        else
        {
            if (item["children"] is not JsonArray children) throw new InvalidDataException($"{title}: the children array is missing.");
            foreach (var child in children) ValidateItem(child, depth + 1, kind, mustBeDone, ids);
        }
    }

    private static string Text(JsonObject item, string name)
    {
        if (item[name] is JsonValue value && value.TryGetValue<string>(out var text)) return text;
        throw new InvalidDataException($"The text field {name} is missing.");
    }
}
