namespace Tercet;

/// <summary>
/// Společná paleta a popisky koleček; tooltip vybírá situaci s nejvyšším Rank.
/// Datová situace zůstává ruční, tento výběr žádnou položku nemění.
/// </summary>
public static class QueueAttention
{
    // Pojmenovaná čtveřice (tuple) drží barvu, popisek, přednost a tempo
    // blikání pohromadě. BlinkSeconds je perioda celého cyklu svítí → zhaslé
    // → svítí; nula znamená statické kolečko. Rychlost kóduje naléhavost
    // — jen pracovní situace blikají, neaktivní a hotové ne.
    // Null označuje frontu bez pracovních položek, nikoli šestou situaci.
    public static (string Color, string Description, int Rank, double BlinkSeconds) Describe(string? situation) => situation switch
    {
        "inactive" => ("#9A9D96", "Inactive", 2, 0),
        "inProgress" => ("#628448", "In progress", 3, 4),
        "underReview" => ("#BD812B", "Under review", 4, 2),
        "needsAttention" => ("#B64740", "Needs attention", 5, 1),
        "done" => ("#527CBA", "Done", 1, 0),
        null => (Describe("inactive").Color, "No tasks", 0, 0),
        _ => throw new ArgumentException("Unknown situation.", nameof(situation))
    };

    // Rows obsahuje celou aktuální frontu včetně vlastních situací celků,
    // ale ne archiv. Maximum nezávisí na pořadí sourozenců ani na hloubce.
    public static string? SelectSituation(IEnumerable<QueueRow> rows)
    {
        string? selected = null;
        int rank = 0;
        foreach (var row in rows)
        {
            if (row.Kind == "group") continue;
            int candidateRank = Describe(row.Situation).Rank;
            if (candidateRank > rank)
            {
                selected = row.Situation;
                rank = candidateRank;
            }
        }
        return selected;
    }
}
