param([Tercet.App]$Application, [byte[]]$Bytes, [string]$TestDirectory, [Reflection.Assembly]$Assembly)
# Dílčí sada Check-Editor: přenosná záloha, skutečný editor obnovy a jeho
# Save/Cancel, produkční návaznost na sync nad falešným serverem. Reflexe
# přesměruje App na dočasná data; produkční OnStartup se nikdy nespustí.
$backupDirectory = Join-Path $TestDirectory 'backup'
$dataRoot = Join-Path $backupDirectory 'package'
$localState = Join-Path $dataRoot 'LocalState'
[IO.Directory]::CreateDirectory($localState) | Out-Null
$backupFile = Join-Path $backupDirectory 'export.json'
$backupOriginal = [Tercet.QueueDocument]::Parse($Bytes)
[Tercet.QueueBackup]::Write($backupOriginal, $backupFile, $dataRoot)
$restored = [Tercet.QueueBackup]::Read($backupFile)
Assert ($restored.HasSameData($backupOriginal)) 'Backup lost queue or archive data'
Assert ($restored.ArchiveEntries().Count -gt 0) 'Backup fixture must include archive'
$backupBytes = [IO.File]::ReadAllBytes($backupFile)

# Cíl v celém kořeni balíčku se odmítne; podobný název sousední složky
# naopak smí projít. Po neúspěchu musí starší záloha zůstat bajtově stejná.
foreach ($target in @((Join-Path $localState 'queue.json'), (Join-Path $dataRoot 'backup.json'), (Join-Path $dataRoot 'LocalState/../cache.json'))) {
    Reject { [Tercet.QueueBackup]::Write($backupOriginal, $target, $dataRoot) } ([IO.InvalidDataException])
    Assert (-not [IO.File]::Exists($target)) 'Rejected backup wrote inside package data'
}
$sibling = $dataRoot + '-external'
[IO.Directory]::CreateDirectory($sibling) | Out-Null
[Tercet.QueueBackup]::Write($backupOriginal, (Join-Path $sibling 'queue.json'), $dataRoot)
$invalidBackup = $backupOriginal.Clone()
$invalidBackup.QueueItems()[0]['title'] = [Text.Json.Nodes.JsonValue]::Create('')
Reject { [Tercet.QueueBackup]::Write($invalidBackup, $backupFile, $dataRoot) } ([IO.InvalidDataException])
Assert-SyncFile $backupFile $backupBytes
$locked = [IO.File]::Open($backupFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try {
    $replaceRejected = $false
    try { [Tercet.QueueBackup]::Write($backupOriginal, $backupFile, $dataRoot) }
    catch {
        $failure = $_.Exception
        while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
        # Windows může odmítnuté přejmenování na zamčený cíl hlásit jako
        # access denied, nikoli sharing violation. Obě chyby UI obsluhuje.
        Assert ($failure -is [IO.IOException] -or $failure -is [UnauthorizedAccessException]) 'Unexpected overwrite failure'
        $replaceRejected = $true
    }
    Assert $replaceRejected 'Locked backup was overwritten'
}
finally { $locked.Dispose() }
Assert-SyncFile $backupFile $backupBytes
Assert (@([IO.Directory]::GetFiles($backupDirectory, '*.tmp')).Count -eq 0) 'Failed export left temporary files'
$badFile = Join-Path $backupDirectory 'invalid.json'
foreach ($bad in @([byte[]]::new(64), [Text.Encoding]::UTF8.GetBytes('{'), $invalidBackup.ToBytes())) {
    [IO.File]::WriteAllBytes($badFile, $bad)
    Reject { [Tercet.QueueBackup]::Read($badFile) } ([IO.InvalidDataException])
}
[IO.File]::WriteAllText($badFile, '{"schemaVersion":2,"queue":[],"archive":[]}')
Reject { [Tercet.QueueBackup]::Read($badFile) } ([Tercet.UnsupportedQueueVersionException])
'PASS: external backup roundtrip with archive, path guard, invalid/future files, failed overwrite preserves backup'

# Zachycení WPF obsahu po skutečném Show a layoutu, nikoli jen property před
# interakcí. PNG slouží také ruční vizuální kontrole zalomeného upozornění.
function Save-BackupPreview($window, [string]$name) {
    $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($window.ActualWidth * 2), [int][Math]::Ceiling($window.ActualHeight * 2), 192, 192, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $output = [IO.File]::Create((Join-Path $TestDirectory $name))
    try { $encoder.Save($output) } finally { $output.Dispose() }
}
function Click-BackupEditor($window, [string]$label) {
    $actions = @($window.Content.Children | Where-Object { $_ -is [Windows.Controls.DockPanel] } |
        ForEach-Object { $_.Children } | Where-Object { $_ -is [Windows.Controls.StackPanel] })[0]
    $button = @($actions.Children | Where-Object { $_.Content -ceq $label })[0]
    Assert ($null -ne $button) "Missing editor button: $label"
    $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
}
$backupFlags = [Reflection.BindingFlags]'Instance,NonPublic'
$backupAppType = [Tercet.App]
function Get-BackupField([string]$name) { $backupAppType.GetField($name, $backupFlags).GetValue($Application) }
function Set-BackupField([string]$name, $value) { $backupAppType.GetField($name, $backupFlags).SetValue($Application, $value) }
function Invoke-BackupMethod([string]$name, [object[]]$arguments = @()) { $backupAppType.GetMethod($name, $backupFlags).Invoke($Application, $arguments) }
$backupFields = @{}
foreach ($name in 'store','settingsStore','settings','document','rows','trayIcon','trayImage','trayMenu','openWebItem','synchronizeItem','backupItem','restoreItem','queueLink','synchronizer','syncRunning','syncAfterEditor','syncStatus','editor','note','desktop','errorReported','backupDialogOpen') {
    $backupFields[$name] = Get-BackupField $name
}
$backupServer = [Tercet.Checks.FakeTercetServer]::new()
$backupToken = '0123456789abcdef0123456789abcdef'
$backupNotifyIcon = [Windows.Forms.NotifyIcon]::new()
$backupQueuePath = Join-Path $localState 'queue.json'
$backupStore = [Tercet.QueueStore]::new($backupQueuePath)
$currentQueue = $backupOriginal.Clone()
$currentQueue.QueueItems()[0]['title'] = [Text.Json.Nodes.JsonValue]::Create('Current queue before restore')
$backupStream = [IO.MemoryStream]::new($currentQueue.ToBytes())
try { $null = $backupStore.Load($backupStream) } finally { $backupStream.Dispose() }
$backupStore.Save($currentQueue)
$currentBytes = $currentQueue.ToBytes()
$backupSettings = [Tercet.SettingsStore]::new((Join-Path $localState 'settings.json'))
$backupSettings.Save([Tercet.SyncSettings]::new(($backupServer.Prefix + 'Tercet/tercet.html#' + $backupToken), [Tercet.QueueSyncClient]::ComputeETag($currentBytes)))
$backupServer.Documents[$backupToken] = $currentBytes
$initialBackupTheme = $Application.ThemeMode
try {
    Set-BackupField 'store' $backupStore
    Set-BackupField 'settingsStore' $backupSettings
    Set-BackupField 'settings' ($backupSettings.Load())
    Set-BackupField 'document' $currentQueue
    Set-BackupField 'rows' ($currentQueue.Rows())
    Set-BackupField 'trayIcon' $backupNotifyIcon
    $null = Invoke-BackupMethod 'ConfigureSync'
    $null = Invoke-BackupMethod 'CreateTrayMenu'
    $null = Invoke-BackupMethod 'UpdateTrayIcon'
    $backupMenu = Get-BackupField 'trayMenu'
    # Událost Opening musí přepočítat dostupnost v reálně otevřeném menu.
    foreach ($busy in @($false, $true)) {
        Set-BackupField 'syncRunning' $busy
        $backupMenu.Show(40,40)
        Assert ((Get-BackupField 'backupItem').Enabled -eq (-not $busy)) 'Backup menu sync guard'
        Assert ((Get-BackupField 'restoreItem').Enabled -eq (-not $busy)) 'Restore menu sync guard'
        $backupMenu.Close()
    }
    Set-BackupField 'syncRunning' $false
    Set-BackupField 'backupDialogOpen' $true
    $null = Invoke-BackupMethod 'ShowEditor'
    Assert ($null -eq (Get-BackupField 'editor')) 'Hotkey opened editor during file dialog'
    Set-BackupField 'backupDialogOpen' $false

    # Obnova projde skutečnou metodou App.OpenEditor. Cancel nesmí měnit
    # frontu ani settings a nesmí spustit jediný síťový požadavek.
    $settingsBefore = [IO.File]::ReadAllBytes((Join-Path $localState 'settings.json'))
    foreach ($mode in 'System','Light','Dark') {
        $Application.ThemeMode = [Windows.ThemeMode].GetProperty($mode).GetValue($null)
        $null = Invoke-BackupMethod 'OpenEditor' ([object[]]@($restored))
        $restoreEditor = Get-BackupField 'editor'
        $restoreEditor.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $draft = $restoreEditor.GetType().GetField('workingCopy', $backupFlags).GetValue($restoreEditor)
        Assert ($draft.HasSameData($restored) -and -not $draft.HasSameData($currentQueue)) 'Restore preview is not the selected backup'
        $baseline = $restoreEditor.GetType().GetField('original', $backupFlags).GetValue($restoreEditor)
        Assert ($baseline.HasSameData($currentQueue)) 'Restore close comparison lost original queue'
        $notice = @($restoreEditor.Content.Children | Where-Object { $_.Name -ceq 'RestoreNotice' })[0]
        Assert ($notice.IsVisible -and $notice.ActualHeight -gt 30 -and $notice.Text -clike '*synchronization*') 'Visible restoration notice missing'
        $backupMenu.Show(40,40)
        Assert (-not (Get-BackupField 'restoreItem').Enabled -and -not (Get-BackupField 'backupItem').Enabled) 'Transfer allowed with editor open'
        $backupMenu.Close()
        Save-BackupPreview $restoreEditor "restore-$mode.png"
        Assert-SyncFile $backupQueuePath $currentBytes
        Click-BackupEditor $restoreEditor 'Cancel'
        Assert ($null -eq (Get-BackupField 'editor')) 'Cancel left editor reference'
        Assert-SyncFile $backupQueuePath $currentBytes
        Assert-SyncFile (Join-Path $localState 'settings.json') $settingsBefore
        Assert ($backupServer.Requests.Count -eq 0) 'Restore preview or Cancel synchronized'
        $null = Invoke-BackupMethod 'CloseNote'
    }

    # Save z editoru musí zálohovat dosavadní frontu a teprve po Closed
    # spustit produkční async synchronizaci. Čekání pumpuje WPF dispatcher.
    $null = Invoke-BackupMethod 'OpenEditor' ([object[]]@($restored))
    Click-BackupEditor (Get-BackupField 'editor') 'Save'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $Application.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        Start-Sleep -Milliseconds 20
    } while ((Get-BackupField 'syncRunning') -and [DateTime]::UtcNow -lt $deadline)
    Assert (-not (Get-BackupField 'syncRunning')) 'Restore synchronization timed out'
    Assert-SyncFile $backupQueuePath ($restored.ToBytes())
    Assert-SyncFile ($backupQueuePath + '.bak') $currentBytes
    Assert ([Tercet.QueueDocument]::Parse($backupServer.Documents[$backupToken]).HasSameData($restored)) 'Saved restore was not uploaded'
    Assert (@($backupServer.Requests | Where-Object { $_ -clike 'PUT *' }).Count -eq 1) 'Restore must upload once after Save'
    Assert ((Get-BackupField 'document').HasSameData($restored)) 'App kept old queue after restore'
    Assert ($backupSettings.Load().QueueLink -ceq ($backupServer.Prefix + 'Tercet/tercet.html#' + $backupToken)) 'Restore changed the server link'
    $null = Invoke-BackupMethod 'CloseNote'
    'PASS: actual tray Opening, restore editor System/Light/Dark, Cancel isolation, Save backup and automatic upload'

    # Stejný build, oba režimy Settings: hostitelský pwsh na STELLE má vlastní
    # Store identitu, proto tuto hodnotu předáváme výslovně.
    foreach ($packaged in @($false, $true)) {
        foreach ($mode in 'Light','Dark') {
            $Application.ThemeMode = [Windows.ThemeMode].GetProperty($mode).GetValue($null)
            $settingsDialog = [Tercet.SettingsWindow]::new($null, 'Not synchronized yet.', [Action[string]]{ param($value) throw 'Settings must not be saved' }, $packaged)
            try {
                $settingsDialog.Show()
                Save-BackupPreview $settingsDialog "backup-settings-$packaged-$mode.png"
                Assert ($settingsDialog.FindName('UninstallNotice').IsVisible -eq $packaged) 'Wrong Store uninstall notice visibility'
                Assert ($settingsDialog.FindName('CancelButton').IsVisible) 'Settings buttons clipped'
            } finally { $settingsDialog.Close() }
        }
    }
    'PASS: Settings uninstall warning only for packaged app, Light/Dark layouts'
} finally {
    $remainingEditor = Get-BackupField 'editor'
    if ($null -ne $remainingEditor) { Click-BackupEditor $remainingEditor 'Cancel' }
    $null = Invoke-BackupMethod 'CloseNote'
    $menu = Get-BackupField 'trayMenu'
    if ($null -ne $menu) { $menu.Dispose() }
    $image = Get-BackupField 'trayImage'
    if ($null -ne $image) { $image.Dispose() }
    $backupNotifyIcon.Dispose()
    $backupServer.Dispose()
    foreach ($name in $backupFields.Keys) { Set-BackupField $name $backupFields[$name] }
    $Application.ThemeMode = $initialBackupTheme
}
