using System.IO;

namespace Tercet;

/// <summary>
/// Exkluzivní handle souboru chrání jednu frontu před dvěma běžícími UI.
/// Zámek sdílí i instalátor; cesta k exe ani přihlašovací sezení nerozhoduje.
/// </summary>
public sealed class SingleInstanceLock : IDisposable
{
    private readonly FileStream handle;
    private SingleInstanceLock(FileStream handle) => this.handle = handle;

    // FileShare.None odmítne další otevření stejného souboru i v jiném
    // procesu. Po ukončení nebo pádu OS zavře handle; prázdný soubor smí
    // zůstat na disku, jeho existence sama neznamená obsazený zámek.
    public static SingleInstanceLock? TryAcquire(string dataDirectory)
    {
        Directory.CreateDirectory(dataDirectory);
        try
        {
            return new SingleInstanceLock(new FileStream(
                Path.Combine(dataDirectory, ".instance.lock"),
                FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None));
        }
        // Jen sharing/lock violation znamená druhou instanci. Např. chybějící
        // oprávnění se musí ohlásit jako chyba, nikoli zamaskovat tichým Exit.
        catch (IOException ex) when ((ex.HResult & 0xffff) is 32 or 33)
        {
            return null;
        }
    }

    public void Dispose() => handle.Dispose();
}
