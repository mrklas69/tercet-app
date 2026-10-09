using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Tercet;

/// <summary>
/// Ctrl+Alt+T přijímá vlastní neviditelné message-only HWND, nezávislé na Exploreru.
/// Registrace nepoužívá globální keyboard hook a při ukončení se uvolní.
/// </summary>
internal sealed class ActivationHotKey : IDisposable
{
    private readonly HwndSource source;
    private readonly Action activate;
    private const int Identifier = 1;

    public ActivationHotKey(Action activate)
    {
        this.activate = activate;
        source = new HwndSource(new HwndSourceParameters("Tercet.ActivationHotKey")
        {
            ParentWindow = new nint(-3), Width = 0, Height = 0, WindowStyle = 0
        });
        source.AddHook(OnMessage);
        // MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, virtuální klávesa T.
        if (!RegisterHotKey(source.Handle, Identifier, 0x4003, 0x54))
        {
            int error = Marshal.GetLastWin32Error();
            source.Dispose();
            throw new Win32Exception(error, "Ctrl+Alt+T could not be registered.");
        }
    }

    private nint OnMessage(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == 0x0312 && wParam == Identifier)
        {
            handled = true;
            activate();
        }
        return 0;
    }

    public void Dispose()
    {
        UnregisterHotKey(source.Handle, Identifier);
        source.Dispose();
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(nint hwnd, int id);
}
