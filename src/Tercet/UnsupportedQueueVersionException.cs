using System.IO;

namespace Tercet;

/// <summary>
/// Čitelný dokument jiné verze není poškozený dokument. Samostatný typ
/// výjimky zabrání nabídce obnovy starší zálohy místo potřebné migrace.
/// IOException umožní stávající obsluze načítání zobrazit příčinu a skončit.
/// </summary>
public sealed class UnsupportedQueueVersionException(int version)
    : IOException($"Queue format version {version} is not supported by this version of Tercet (expected 1). Use a compatible version of Tercet; the file was left unchanged.");
