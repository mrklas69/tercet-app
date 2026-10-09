namespace Tercet;

// Record nese neměnný snímek řádku, nikoli druhý datový model. Hloubka je
// od nuly; pořadí řádků určuje průchod dokumentu rodič před potomky.
public sealed record QueueRow(string Title, string Kind, int Depth,
    string? Situation, string? Perspective);
