param([Windows.Application]$Application, [byte[]]$Bytes, [string]$TestDirectory, [Reflection.Assembly]$Assembly, [switch]$Review)
# Dílčí sada z Check-Editor: skutečné soubory, parser, zámek i dialog.
# Každý případ má vlastní dočasný adresář. Provozní fronta se ani nečte.

function New-RecoveryCase([string]$name, [AllowNull()][byte[]]$main, [AllowNull()][byte[]]$backup) {
    $directory = Join-Path $TestDirectory ('recovery-' + $name)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $file = Join-Path $directory 'queue.json'
    if ($null -ne $main) { [IO.File]::WriteAllBytes($file, $main) }
    if ($null -ne $backup) { [IO.File]::WriteAllBytes($file + '.bak', $backup) }
    return @{ Directory = $directory; File = $file; Store = [Tercet.QueueStore]::new($file) }
}

function Read-RecoveryCase($case, [Func[Tercet.QueueRecovery,bool]]$confirmation) {
    $stream = [IO.MemoryStream]::new($Bytes)
    try { return $case.Store.Load($stream, $confirmation) } finally { $stream.Dispose() }
}

# Porovnání bajtů nezaměňuje JSON se stejným významem za stejný soubor.
function Assert-FileBytes([string]$file, [byte[]]$expected) {
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -ceq [Convert]::ToBase64String($expected)) "Unexpected bytes: $file"
}

$corrupt = [byte[]](0,0,0,0)
$confirm = [Func[Tercet.QueueRecovery,bool]]{ param($info) return $true }
$never = [Func[Tercet.QueueRecovery,bool]]{ param($info) throw 'Recovery must not be offered' }
$originalDocument = [Tercet.QueueDocument]::Parse($Bytes)
$future = [Text.Encoding]::UTF8.GetBytes(([Text.Encoding]::UTF8.GetString($Bytes)).Replace('"schemaVersion": 1', '"schemaVersion": 2'))
Assert ([Convert]::ToBase64String($future) -cne [Convert]::ToBase64String($Bytes)) 'Future-version fixture unchanged'

# Platná fronta má přednost i před špatnou zálohou. První start nic nepíše.
$case = New-RecoveryCase 'valid' $Bytes $corrupt
Assert ((Read-RecoveryCase $case $never).HasSameData($originalDocument)) 'Valid primary ignored'
Assert-FileBytes ($case.File + '.bak') $corrupt
$case = New-RecoveryCase 'first-start' $null $null
Assert ((Read-RecoveryCase $case $never).HasSameData($originalDocument)) 'Demo was not loaded'
Assert (-not [IO.File]::Exists($case.File)) 'First start wrote demo'
Assert (@([IO.Directory]::GetFiles($case.Directory)).Count -eq 0) 'First start touched files'

# Nabídka je pouze čtení. Odmítnutí nesmí vytvořit ani .lock či kopii.
foreach ($missing in @($false, $true)) {
    $main = if ($missing) { $null } else { $corrupt }
    $case = New-RecoveryCase "cancel-$missing" $main $Bytes
    $state = @{ Called = $false; Missing = $missing; Path = $case.File }
    $cancel = [Func[Tercet.QueueRecovery,bool]]{
        param($info)
        $state.Called = $true
        Assert ($info.IsMissing -eq $state.Missing) 'Wrong missing-file explanation'
        Assert ($info.FilePath -eq $state.Path) 'Wrong recovery path'
        return $false
    }
    Assert ($null -eq (Read-RecoveryCase $case $cancel)) 'Declined recovery returned data'
    Assert $state.Called 'No recovery confirmation'
    Assert-FileBytes ($case.File + '.bak') $Bytes
    if ($missing) { Assert (-not [IO.File]::Exists($case.File)) 'Cancel created primary' }
    else { Assert-FileBytes $case.File $corrupt }
    $expectedFiles = if ($missing) { 1 } else { 2 }
    Assert (@([IO.Directory]::GetFiles($case.Directory)).Count -eq $expectedFiles) 'Cancel wrote extra files'
}

# Celá fronta i archiv, přesné bajty zálohy, uchování vadného originálu,
# skutečný další start a následné Save s běžnou rotací .bak.
foreach ($scenario in @('corrupt', 'missing', 'empty', 'model-invalid')) {
    $main = switch ($scenario) {
        'missing' { $null }
        'empty' { ,([byte[]]::new(0)) }
        'model-invalid' { ,([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"queue":[],"archive":42}')) }
        default { ,$corrupt }
    }
    $case = New-RecoveryCase $scenario $main $Bytes
    $loaded = Read-RecoveryCase $case $confirm
    Assert ($loaded.HasSameData($originalDocument)) "Incomplete restored document: $scenario"
    Assert-FileBytes $case.File $Bytes
    Assert-FileBytes ($case.File + '.bak') $Bytes
    $copies = @([IO.Directory]::GetFiles($case.Directory, 'queue.json.corrupt-*.json'))
    if ($scenario -eq 'missing') { Assert ($copies.Count -eq 0) 'Invented missing-file copy' }
    else {
        Assert ($copies.Count -eq 1) "Missing preserved original: $scenario"
        Assert-FileBytes $copies[0] $main
    }
    $restart = @{ Store = [Tercet.QueueStore]::new($case.File) }
    Assert ((Read-RecoveryCase $restart $never).HasSameData($loaded)) 'Restart did not read restored data'
    $edited = $loaded.Clone()
    $edited.QueueItems()[0]['title'] = [Text.Json.Nodes.JsonValue]::Create('After recovery')
    $case.Store.Save($edited)
    Assert ([Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes($case.File)).HasSameData($edited)) 'Save after recovery failed'
    Assert-FileBytes ($case.File + '.bak') $Bytes
    if ($copies.Count -eq 1) { Assert-FileBytes $copies[0] $main }
    $edited.QueueItems()[0]['title'] = [Text.Json.Nodes.JsonValue]::Create('Next save')
    $case.Store.Save($edited)
    Assert ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($case.File + '.bak')).Contains('After recovery')) 'Backup rotation after recovery failed'
}

# Bez použitelné zálohy není souhlas vůbec vyžádán. Novější hlavní formát
# nesmí nabídnout downgrade, ani když vedle leží platná starší záloha.
foreach ($scenario in @('no-backup', 'invalid-backup', 'missing-invalid-backup', 'future-backup', 'future-primary')) {
    $main = if ($scenario -eq 'missing-invalid-backup') { $null } elseif ($scenario -eq 'future-primary') { $future } else { $corrupt }
    $backup = switch ($scenario) { 'no-backup' { $null }; 'future-primary' { ,$Bytes }; 'future-backup' { ,$future }; default { ,$corrupt } }
    $case = New-RecoveryCase $scenario $main $backup
    $expected = if ($scenario -eq 'future-primary') { [Tercet.UnsupportedQueueVersionException] } else { [IO.InvalidDataException] }
    Reject { Read-RecoveryCase $case $never } $expected
    if ($null -ne $main) { Assert-FileBytes $case.File $main }
    if ($null -ne $backup) { Assert-FileBytes ($case.File + '.bak') $backup }
    Assert (@([IO.Directory]::GetFiles($case.Directory, '*.corrupt-*.json')).Count -eq 0) 'Rejected input wrote copy'
}

# Změna kteréhokoli souboru během dialogu, včetně vzniku či zmizení,
# musí skončit konfliktem před obnovou a zachováním externí změny.
foreach ($scenario in @('main-change', 'backup-change', 'main-delete', 'backup-delete', 'main-appears')) {
    $main = if ($scenario -eq 'main-appears') { $null } else { $corrupt }
    $case = New-RecoveryCase $scenario $main $Bytes
    $mutate = [Func[Tercet.QueueRecovery,bool]]{
        param($info)
        switch ($scenario) {
            'main-change' { [IO.File]::WriteAllBytes($case.File, $Bytes) }
            'backup-change' { [IO.File]::WriteAllBytes($case.File + '.bak', $corrupt) }
            'main-delete' { [IO.File]::Delete($case.File) }
            'backup-delete' { [IO.File]::Delete($case.File + '.bak') }
            'main-appears' { [IO.File]::WriteAllBytes($case.File, $Bytes) }
        }
        return $true
    }
    Reject { Read-RecoveryCase $case $mutate } ([IO.IOException])
    if ($scenario -in @('main-change','main-appears')) { Assert-FileBytes $case.File $Bytes }
    elseif ($scenario -eq 'main-delete') { Assert (-not [IO.File]::Exists($case.File)) 'Conflict recreated main' }
    else { Assert-FileBytes $case.File $corrupt }
    if ($scenario -eq 'backup-change') { Assert-FileBytes ($case.File + '.bak') $corrupt }
    elseif ($scenario -eq 'backup-delete') { Assert (-not [IO.File]::Exists($case.File + '.bak')) 'Conflict recreated backup' }
    else { Assert-FileBytes ($case.File + '.bak') $Bytes }
    Assert (@([IO.Directory]::GetFiles($case.Directory, '*.corrupt-*.json')).Count -eq 0) 'Conflict wrote preserved copy'
}

# Sdílecí zámek simulující souběžného zapisovatele, pak skutečné selhání
# přístupu ke vstupu a selhání výměny read-only cíle po vytvoření kopie.
$case = New-RecoveryCase 'locked-writer' $corrupt $Bytes
$lock = [IO.File]::Open($case.File + '.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { Reject { Read-RecoveryCase $case $confirm } ([IO.IOException]) } finally { $lock.Dispose() }
Assert-FileBytes $case.File $corrupt
Assert-FileBytes ($case.File + '.bak') $Bytes
foreach ($target in @('main','backup')) {
    $case = New-RecoveryCase "locked-$target" $corrupt $Bytes
    $lockedPath = if ($target -eq 'main') { $case.File } else { $case.File + '.bak' }
    $lock = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Reject { Read-RecoveryCase $case $never } ([IO.IOException]) } finally { $lock.Dispose() }
    Assert-FileBytes $case.File $corrupt
    Assert-FileBytes ($case.File + '.bak') $Bytes
}
$case = New-RecoveryCase 'read-only-main' $corrupt $Bytes
[IO.File]::SetAttributes($case.File, [IO.FileAttributes]::ReadOnly)
try { Reject { Read-RecoveryCase $case $confirm } ([UnauthorizedAccessException]) }
finally { [IO.File]::SetAttributes($case.File, [IO.FileAttributes]::Normal) }
Assert-FileBytes $case.File $corrupt
Assert-FileBytes ($case.File + '.bak') $Bytes
$copies = @([IO.Directory]::GetFiles($case.Directory, 'queue.json.corrupt-*.json'))
Assert ($copies.Count -eq 1) 'Failed replacement lost original copy'
Assert-FileBytes $copies[0] $corrupt
Assert (@([IO.Directory]::GetFiles($case.Directory)).Count -eq 4) 'Failed replacement left temporary payload'
# Další pokus nesmí přepsat první kopii; úspěch vyrobí druhé jedinečné jméno.
Assert ((Read-RecoveryCase $case $confirm).HasSameData($originalDocument)) 'Retry failed'
Assert (@([IO.Directory]::GetFiles($case.Directory, 'queue.json.corrupt-*.json')).Count -eq 2) 'Retry overwrote original copy'

# Neúspěšná či odmítnutá obnova nesmí zrušit původní ochranu konfliktu Save.
$case = New-RecoveryCase 'cancel-after-load' $Bytes $Bytes
$loaded = Read-RecoveryCase $case $never
[IO.File]::WriteAllBytes($case.File, $corrupt)
$cancel = [Func[Tercet.QueueRecovery,bool]]{ param($info) return $false }
Assert ($null -eq (Read-RecoveryCase $case $cancel)) 'Cancel returned document'
Reject { $case.Store.Save($loaded) } ([IO.IOException])
Assert-FileBytes $case.File $corrupt
'PASS: recovery data, archive, cancel, missing files, incompatible format, conflicts, IO failures, retry and subsequent Save'

# Opravdové ShowDialog: ověříme focus po Loaded, default/cancel a oba
# výsledky. Callback doběhne v dispatcheru modálního okna. Chybu uložíme
# a vyhodíme až po zavření, aby test nenechal viset okno.
# ShowDialog doběhne před další iterací, proto není třeba GetNewClosure.
# Ten by vytvořil dynamický modul bez lokální funkce Assert při spuštění
# hlavní sady přes &. Běžný scriptblock používá scope běžícího testu.
$dialogType = $Assembly.GetType('Tercet.QueueRecoveryWindow', $true)
foreach ($mode in @('Light','Dark')) {
    $Application.ThemeMode = [Windows.ThemeMode].GetProperty($mode).GetValue($null)
    foreach ($action in @('restore','exit','close','enter','escape')) {
        $dialog = [Activator]::CreateInstance($dialogType, @([Tercet.QueueRecovery]::new('C:\Temporary test data\queue.json', ($action -eq 'restore'))))
        $state = @{ Error = $null; Dialog = $dialog; Action = $action; Mode = $mode; Captured = $false; Invoked = $false }
        $dialog.Add_ContentRendered({
            try {
                $state.Invoked = $true
                $body = $state.Dialog.Content.Content
                $buttons = $body.Children[$body.Children.Count - 1].Children
                $restoreButton = $buttons[0]
                $exitButton = $buttons[1]
                Assert ($restoreButton.Content -ceq 'Restore backup') 'Wrong restore label'
                Assert ($exitButton.Content -ceq 'Exit') 'Wrong exit label'
                Assert $exitButton.IsDefault 'Exit is not default'
                Assert $exitButton.IsCancel 'Exit is not cancel'
                Assert $exitButton.IsKeyboardFocused 'Exit has no real focus on opening'
                if ($state.Action -eq 'exit') {
                    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($state.Dialog.ActualWidth * 2), [int][Math]::Ceiling($state.Dialog.ActualHeight * 2),192,192,[Windows.Media.PixelFormats]::Pbgra32)
                    $bitmap.Render($state.Dialog)
                    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
                    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                    $output = [IO.File]::Create((Join-Path $TestDirectory ("recovery-dialog-$($state.Mode).png")))
                    try { $encoder.Save($output) } finally { $output.Dispose() }
                    $state.Captured = $true
                }
                switch ($state.Action) {
                    'restore' { $restoreButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
                    'exit' { $exitButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
                    'close' { $state.Dialog.Close() }
                    default {
                        $key = if ($state.Action -eq 'enter') { [Windows.Input.Key]::Enter } else { [Windows.Input.Key]::Escape }
                        $input = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, [Windows.PresentationSource]::FromVisual($exitButton), 0, $key)
                        $input.RoutedEvent = [Windows.Input.Keyboard]::KeyDownEvent
                        [Windows.Input.InputManager]::Current.ProcessInput($input) | Out-Null
                        Assert (-not $state.Dialog.IsVisible) "Key did not close dialog: $($state.Action)"
                    }
                }
            }
            catch { $state.Error = $_; $state.Dialog.Close() }
        })
        $result = $dialog.ShowDialog()
        Assert ($dialog.Title -ceq ([Tercet.ApplicationIdentity]::DisplayName + ' — Restore backup')) 'Recovery title lost distribution name'
        if ($state.Error) { throw $state.Error }
        Assert $state.Invoked "Dialog was not rendered: $mode / $action"
        Assert (($result -eq $true) -eq ($action -eq 'restore')) "Wrong dialog result: $mode / $action / result=$result / property=$($dialog.DialogResult)"
        if ($action -eq 'exit') { Assert $state.Captured 'Missing dialog snapshot' }
    }
}
'PASS: recovery dialog Light/Dark, actual opening, focus, Restore, Exit, close, Enter and Escape'

# Volitelné ruční přijetí v RDP používá tentýž callback jako App, ale
# cestu nového dočasného případu. Obě možné volby mají kontrolu účinku.
if ($Review) {
    $Application.ThemeMode = [Windows.ThemeMode]::System
    $case = New-RecoveryCase 'manual-review' $corrupt $Bytes
    $showDialog = [Func[Tercet.QueueRecovery,bool]]{
        param($info)
        $reviewWindow = [Activator]::CreateInstance($dialogType, @($info))
        $reviewWindow.Title = [Tercet.ApplicationIdentity]::Title('Recovery test (temporary data)')
        return $reviewWindow.ShowDialog() -eq $true
    }
    $reviewResult = Read-RecoveryCase $case $showDialog
    if ($null -eq $reviewResult) {
        Assert-FileBytes $case.File $corrupt
        Assert (@([IO.Directory]::GetFiles($case.Directory)).Count -eq 2) 'Manual Exit changed files'
        'REVIEW: Exit left temporary data unchanged'
    } else {
        Assert ($reviewResult.HasSameData($originalDocument)) 'Manual recovery lost document content'
        Assert-FileBytes $case.File $Bytes
        $copies = @([IO.Directory]::GetFiles($case.Directory, 'queue.json.corrupt-*.json'))
        Assert ($copies.Count -eq 1) 'Manual recovery lost original'
        Assert-FileBytes $copies[0] $corrupt
        'REVIEW: Restore backup restored the full temporary document and preserved the invalid original'
    }
    Assert-FileBytes ($case.File + '.bak') $Bytes
}
