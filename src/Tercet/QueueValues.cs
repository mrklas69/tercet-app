namespace Tercet;

/// <summary>
/// Pevné hodnoty datového kontraktu, společné pro validátor a nabídky.
/// ReadOnly obal nedovolí volajícím měnit seznam; datové hodnoty se nemění
/// s popisky UI ani barvami, které patří zobrazovací vrstvě.
/// </summary>
public static class QueueValues
{
    public static IReadOnlyList<string> Situations { get; } = Array.AsReadOnly(
        new[] { "inactive", "inProgress", "underReview", "needsAttention", "done" });
    public static IReadOnlyList<string> Priorities { get; } = Array.AsReadOnly(
        new[] { "low", "normal", "high" });
    public static IReadOnlyList<string> Perspectives { get; } = Array.AsReadOnly(
        new[] { "minutes", "hours", "days" });
}
