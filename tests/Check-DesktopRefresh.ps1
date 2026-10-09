param([string]$Configuration = 'Release')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
[AppContext]::SetSwitch('Switch.System.Windows.Appearance.DisableFluentThemeWindowBackdrop', $true)
$assembly = [Reflection.Assembly]::LoadFrom((Join-Path $repo "src/Tercet/bin/$Configuration/net10.0-windows/Tercet.dll"))
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
# Stejná izolace jako Check-Editor: skutečné resources, potlačený produkční
# OnStartup (sdílený New-TestApplication.ps1 nastaví $app), testovací fronta
# a skrytá ikona. Síť ani provozní data neotevřeme.
. (Join-Path $PSScriptRoot 'New-TestApplication.ps1') -Assembly $assembly
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
public static class DesktopRefreshProbe {
 [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
 [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
 public static int[] Sizes(IntPtr h) {
  if (!GetClientRect(h,out var c) || !GetClientRect(GetParent(h),out var p))
   throw new InvalidOperationException("Missing note/surface HWND");
  return new[] {c.Right,c.Bottom,p.Right,p.Bottom,(int)GetDpiForWindow(h)};
 }
 // Delegát běží na vlákně bez WPF dispatcheru: testuje přechod z SystemEvents.
 public static void NotifyFromWorker(EventHandler handler) =>
  Task.Run(() => handler(null,EventArgs.Empty)).GetAwaiter().GetResult();
}
'@
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$appType = [Tercet.App]
function Field([string]$name) { $appType.GetField($name,$flags).GetValue($app) }
function Set-Field([string]$name, $value) { $appType.GetField($name,$flags).SetValue($app,$value) }
function Invoke-App([string]$name, [object[]]$arguments = @()) { $null = $appType.GetMethod($name,$flags).Invoke($app,$arguments) }
function Drain { $app.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle) }
function Check-Geometry {
    Drain
    $note = Field 'note'
    Assert ($null -ne $note) 'Note was not created'
    $handle = [Windows.Interop.WindowInteropHelper]::new($note).Handle
    $sizes = [DesktopRefreshProbe]::Sizes($handle)
    Assert ($sizes[0] -eq $sizes[2] -and $sizes[1] -eq $sizes[3]) 'Native child/surface sizes differ'
    $transform = [Windows.PresentationSource]::FromVisual($note).CompositionTarget.TransformToDevice
    Assert ([math]::Abs($note.Content.ActualWidth * $transform.M11 - $sizes[0]) -le 1) 'WPF/native width mismatch'
    Assert ([math]::Abs($note.Content.ActualHeight * $transform.M22 - $sizes[1]) -le 1) 'WPF/native height mismatch'
    Assert (-not (Field 'desktop').HasDisplayChanged) 'Fresh surface considers its display stale'
    "Geometry: $($sizes[0])x$($sizes[1]), DPI=$($sizes[4]), WPF=$($note.Content.ActualWidth)x$($note.Content.ActualHeight)"
}
function Check-Replaced($oldNote, $oldHost) {
    Assert (-not [object]::ReferenceEquals($oldNote,(Field 'note'))) 'Old WPF note reused'
    Assert (-not [object]::ReferenceEquals($oldHost,(Field 'desktop'))) 'Old native host reused'
    Assert (-not $oldNote.IsVisible) 'Old note remains visible'
    Assert ($oldHost.GetType().GetField('surface',$flags).GetValue($oldHost) -eq [IntPtr]::Zero) 'Old surface not disposed'
    Check-Geometry
}
$document = [Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'queue-fixture.json')))
$initialBytes = [Convert]::ToBase64String($document.ToBytes())
$notify = [Windows.Forms.NotifyIcon]::new()
Set-Field 'trayIcon' $notify
Set-Field 'document' $document
Set-Field 'rows' $document.Rows()
try {
    Invoke-App 'MaintainDesktop'
    Check-Geometry
    $oldNote = Field 'note'; $oldHost = Field 'desktop'
    Invoke-App 'MaintainDesktop'
    Assert ([object]::ReferenceEquals($oldNote,(Field 'note'))) 'Normal tick unnecessarily recreated note'

    $handler = $appType.GetMethod('OnDesktopEnvironmentChanged',$flags).CreateDelegate([EventHandler],$app)
    [DesktopRefreshProbe]::NotifyFromWorker($handler)
    Drain
    Invoke-App 'MaintainDesktop'
    Check-Replaced $oldNote $oldHost
    'PASS: display notification from worker replaces both windows; normal tick preserves them'

    foreach ($reason in 'RemoteDisconnect','ConsoleConnect','RemoteConnect') {
        $oldNote = Field 'note'; $oldHost = Field 'desktop'
        Invoke-App 'OnDesktopSessionSwitch' @($null,[Microsoft.Win32.SessionSwitchEventArgs]::new([Microsoft.Win32.SessionSwitchReason]$reason))
        Drain
        Invoke-App 'MaintainDesktop'
        Check-Replaced $oldNote $oldHost
    }
    'PASS: remote disconnect, console connect and remote connect notifications'

    # Emulujeme rozdíl proti uloženému prostředí; systémové DPI/rozlišení
    # test nemění. Skutečný přechod RDP/RustDesk musí přijmout uživatel.
    foreach ($change in 'Dpi','WorkArea') {
        $oldNote = Field 'note'; $oldHost = Field 'desktop'
        if ($change -eq 'Dpi') {
            $slot = $oldHost.GetType().GetField('initialDpi',$flags)
            $slot.SetValue($oldHost,[uint32]($slot.GetValue($oldHost) + 24))
        } else {
            $slot = $oldHost.GetType().GetField('initialWorkArea',$flags)
            $area = $slot.GetValue($oldHost); $area.Right -= 100
            $slot.SetValue($oldHost,$area)
        }
        Invoke-App 'MaintainDesktop'
        Check-Replaced $oldNote $oldHost
    }
    'PASS: changed DPI/work-area snapshot triggers recreation without an event'

    Invoke-App 'ShowEditor'
    $editor = Field 'editor'
    $draft = $editor.GetType().GetField('workingCopy',$flags).GetValue($editor)
    $draft.QueueItems()[0]['title'] = [Text.Json.Nodes.JsonValue]::Create('Unsaved desktop refresh test')
    [DesktopRefreshProbe]::NotifyFromWorker($handler)
    Drain
    Invoke-App 'MaintainDesktop'
    Assert ([object]::ReferenceEquals($editor,(Field 'editor')) -and $editor.IsVisible) 'Refresh replaced editor'
    Assert ((Field 'desktopRefreshPending') -and $null -eq (Field 'note')) 'Refresh not deferred during editing'
    Assert ($draft.QueueItems()[0]['title'].GetValue[string]() -ceq 'Unsaved desktop refresh test') 'Unsaved draft lost'
    Assert ([Convert]::ToBase64String($document.ToBytes()) -ceq $initialBytes) 'Original queue modified'
    # Skutečné Cancel zahodí pracovní kopii; Closed obnoví lísteček.
    $footer = @($editor.Content.Children | Where-Object { $_ -is [Windows.Controls.DockPanel] })[1]
    $actions = @($footer.Children | Where-Object { $_ -is [Windows.Controls.StackPanel] })[0]
    $cancel = @($actions.Children | Where-Object { $_.Content -eq 'Cancel' })[0]
    $cancel.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Drain
    Assert (-not (Field 'desktopRefreshPending')) 'Deferred refresh not consumed'
    Check-Geometry
    'PASS: unsaved editor survives notification, note returns after closing'
} finally {
    $editor = Field 'editor'
    if ($null -ne $editor) { $editor.GetType().GetField('discardConfirmed',$flags).SetValue($editor,$true); $editor.Close() }
    Invoke-App 'CloseNote'
    $app.Shutdown()
}
