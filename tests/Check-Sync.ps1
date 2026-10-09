param([Windows.Application]$Application, [byte[]]$Bytes, [string]$TestDirectory, [Reflection.Assembly]$Assembly)
# Dílčí sada z Check-Editor: synchronizace se serverem nad falešným
# serverem HttpListener, dočasnými soubory a skutečnými dialogy. Provozní
# data ani skutečný server se nepoužívají.

# Výchozí reference Add-Type v pwsh 7 pokrývají HttpListener, kolekce i SHA-256;
# s výslovným -ReferencedAssemblies by se naopak ztratila System.Private.CoreLib
# (změřeno 2026-09-29: Dictionary<,> „forwarded, add a reference“).
Add-Type -Path (Join-Path $PSScriptRoot 'FakeTercetServer.cs')

function Assert-SyncFile([string]$file, [byte[]]$expected) {
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -ceq [Convert]::ToBase64String($expected)) "Unexpected bytes: $file"
}

$syncDirectory = Join-Path $TestDirectory 'sync'
[IO.Directory]::CreateDirectory($syncDirectory) | Out-Null
$token = '0123456789abcdef0123456789abcdef'
$unknownToken = 'ffffffffffffffffffffffffffffffff'

# ETag: shodný vzorec s example.com (prvních 32 hex znaků SHA-256).
$sha = [Security.Cryptography.SHA256]::HashData($Bytes)
$expectedETag = '"' + (($sha | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 32) + '"'
Assert ([Tercet.QueueSyncClient]::ComputeETag($Bytes) -ceq $expectedETag) 'Desktop ETag differs from the server formula'
Assert ([Tercet.Checks.FakeTercetServer]::ComputeETag($Bytes) -ceq $expectedETag) 'Fake server ETag differs from the server formula'

# Odkaz na frontu: API a token se odvodí z odkazu stránky; http jen pro loopback.
$link = [Tercet.QueueLink]::Parse(" https://example.com/Tercet/tercet.html#$token ")
Assert ($link.Api.AbsoluteUri -ceq 'https://example.com/api/tercet' -and $link.Token -ceq $token) 'Queue link parts'
Assert ($link.Page.AbsoluteUri -ceq "https://example.com/Tercet/tercet.html#$token") 'Queue link page'
$localLink = [Tercet.QueueLink]::Parse("http://127.0.0.1:5188/Tercet/tercet.html#$token")
Assert ($localLink.Api.AbsoluteUri -ceq 'http://127.0.0.1:5188/api/tercet') 'Loopback link keeps the port'
foreach ($bad in @('', 'not a link', 'https://example.com/Tercet/tercet.html', "https://example.com/Tercet/tercet.html#short",
        'https://example.com/Tercet/tercet.html#0123456789ABCDEF0123456789ABCDEF', "http://example.com/Tercet/tercet.html#$token", "ftp://example.com/#$token")) {
    Reject { [Tercet.QueueLink]::Parse($bad) } ([FormatException])
}
'PASS: ETag formula, queue link parsing and rejection'

# Nastavení: chybějící soubor = výchozí, roundtrip, poškozený soubor se hlásí.
$settingsPath = Join-Path $syncDirectory 'settings.json'
$settingsStore = [Tercet.SettingsStore]::new($settingsPath)
$loaded = $settingsStore.Load()
Assert ($null -eq $loaded.QueueLink -and $null -eq $loaded.LastSyncedETag) 'Missing settings must be defaults'
Assert (-not [IO.File]::Exists($settingsPath)) 'Load wrote settings'
$settingsStore.Save([Tercet.SyncSettings]::new("https://example.com/Tercet/tercet.html#$token", $null))
$loaded = $settingsStore.Load()
Assert ($loaded.QueueLink -ceq "https://example.com/Tercet/tercet.html#$token" -and $null -eq $loaded.LastSyncedETag) 'Settings roundtrip'
$settingsStore.Save([Tercet.SyncSettings]::new($loaded.QueueLink, $expectedETag))
Assert ($settingsStore.Load().LastSyncedETag -ceq $expectedETag) 'ETag roundtrip'
Assert (([IO.File]::ReadAllText($settingsPath)) -match '"schemaVersion": 1') 'Settings schema version missing'
foreach ($corrupt in @('{', '[]', '{"queueLink":"x"}', '{"schemaVersion":2}', '{"schemaVersion":1,"queueLink":5}')) {
    [IO.File]::WriteAllText($settingsPath, $corrupt)
    Reject { $settingsStore.Load() } ([IO.InvalidDataException])
}
'PASS: settings defaults, roundtrip, corrupt file rejected'

# Dokumenty: lokální soubor vzniká přes QueueStore (odsazený JSON), server
# ukládá přesně to, co dostane. Tři různé verze pro tři strany konfliktu.
$demoDocument = [Tercet.QueueDocument]::Parse($Bytes)
$savedBytes = $demoDocument.ToBytes()
$editedDocument = $demoDocument.Clone()
$editedDocument.QueueItems()[0]['title'] = [Text.Json.Nodes.JsonValue]::Create('Edited on this computer')
$editedBytes = $editedDocument.ToBytes()
$otherDocument = $demoDocument.Clone()
$otherDocument.QueueItems()[1]['title'] = [Text.Json.Nodes.JsonValue]::Create('Edited elsewhere')
$otherBytes = $otherDocument.ToBytes()
$emptyBytes = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"queue":[],"archive":[]}')
$savedETag = [Tercet.QueueSyncClient]::ComputeETag($savedBytes)

$server = [Tercet.Checks.FakeTercetServer]::new()
$http = [Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds(10)

function New-SyncCase([string]$name, [AllowNull()][byte[]]$local, [AllowNull()][string]$lastSynced, [string]$linkToken = $token, [string]$prefix = $server.Prefix) {
    $directory = Join-Path $syncDirectory $name
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $file = Join-Path $directory 'queue.json'
    if ($null -ne $local) { [IO.File]::WriteAllBytes($file, $local) }
    $queue = [Tercet.QueueStore]::new($file)
    # Load nastaví základ kontroly konfliktů stejně jako start aplikace.
    $stream = [IO.MemoryStream]::new($Bytes)
    try { $null = $queue.Load($stream) } finally { $stream.Dispose() }
    $settings = [Tercet.SettingsStore]::new((Join-Path $directory 'settings.json'))
    $caseLink = "$($prefix)Tercet/tercet.html#$linkToken"
    $settings.Save([Tercet.SyncSettings]::new($caseLink, $lastSynced))
    $client = [Tercet.QueueSyncClient]::new($http, [Tercet.QueueLink]::Parse($caseLink))
    $server.Requests.Clear()
    return @{ Directory = $directory; File = $file; Queue = $queue; Settings = $settings; Synchronizer = [Tercet.QueueSynchronizer]::new($queue, $settings, $client) }
}
function Assert-Outcome($result, [string]$outcome, [string]$context) {
    Assert ($result.Outcome.ToString() -ceq $outcome) "Expected $outcome, got $($result.Outcome): $($result.Message) ($context)"
}
# Callbacky bez GetNewClosure (viz Check-Recovery): stav drží hashtable ve scope skriptu.
$conflict = @{ Choice = [Tercet.ConflictChoice]::Cancel; Asked = 0; FirstSync = $null; Modified = $null }
$never = [Func[Tercet.SyncConflict,Tercet.ConflictChoice]]{ param($info) throw 'Conflict must not be asked' }
$ask = [Func[Tercet.SyncConflict,Tercet.ConflictChoice]]{
    param($info)
    $conflict.Asked++
    $conflict.FirstSync = $info.FirstSync
    $conflict.Modified = $info.ServerModified
    return $conflict.Choice
}
function Reset-Conflict([Tercet.ConflictChoice]$choice) { $conflict.Choice = $choice; $conflict.Asked = 0; $conflict.FirstSync = $null; $conflict.Modified = $null }

try {
    # Nový počítač: bez lokálního souboru se serverová fronta stáhne beze slov.
    $server.Documents[$token] = $otherBytes
    $case = New-SyncCase 'fresh' $null $null
    $result = $case.Synchronizer.Synchronize($never)
    Assert-Outcome $result 'Downloaded' 'fresh'
    Assert ($result.Document.HasSameData($otherDocument)) 'Fresh download returned a different document'
    Assert-SyncFile $case.File $otherBytes
    Assert (-not [IO.File]::Exists($case.File + '.bak')) 'Fresh download created a backup'
    Assert ($case.Settings.Load().LastSyncedETag -ceq $server.ETagOf($token)) 'Fresh download did not remember the version'
    Assert ($server.Requests.Count -eq 1 -and $server.Requests[0] -clike 'GET /api/tercet token=* if-none-match=- *') "Fresh download requests: $($server.Requests -join '; ')"
    # Následný start téhož počítače: 304 a nic víc.
    $result = $case.Synchronizer.Synchronize($never)
    Assert-Outcome $result 'UpToDate' 'fresh-again'
    Assert ($server.Requests.Count -eq 2 -and $server.Requests[1] -clike "GET * if-none-match=$($server.ETagOf($token)) *") 'Second start must revalidate with If-None-Match'

    # Sladěno: stejná verze všude, žádný zápis.
    $server.Documents[$token] = $savedBytes
    $case = New-SyncCase 'up-to-date' $savedBytes $savedETag
    Assert-Outcome ($case.Synchronizer.Synchronize($never)) 'UpToDate' 'up-to-date'
    Assert ($server.Requests.Count -eq 1) 'Up to date must not write'
    Assert-SyncFile $case.File $savedBytes

    # Stejné bajty, ale nikdy nesladěno: verze se jen zapamatuje.
    $case = New-SyncCase 'identical' $savedBytes $null
    Assert-Outcome ($case.Synchronizer.Synchronize($never)) 'UpToDate' 'identical'
    Assert ($case.Settings.Load().LastSyncedETag -ceq $savedETag -and $server.Requests.Count -eq 1) 'Identical content must be remembered without PUT'

    # První sladění s daty na obou stranách: dotaz s FirstSync, tři volby.
    foreach ($choice in @('KeepLocal', 'TakeServer', 'Cancel')) {
        $server.Documents[$token] = $emptyBytes
        $case = New-SyncCase "first-$choice" $savedBytes $null
        Reset-Conflict ([Tercet.ConflictChoice]::$choice)
        $result = $case.Synchronizer.Synchronize($ask)
        Assert ($conflict.Asked -eq 1 -and $conflict.FirstSync -eq $true -and $conflict.Modified -eq $server.LastModified) "First sync must ask once with FirstSync: $choice"
        switch ($choice) {
            'KeepLocal' {
                Assert-Outcome $result 'Uploaded' $choice
                Assert ([Convert]::ToBase64String($server.Documents[$token]) -ceq [Convert]::ToBase64String($savedBytes)) 'Server did not receive the local queue'
                Assert ($server.Requests.Count -eq 2 -and $server.Requests[1] -clike "PUT * if-match=$([Tercet.QueueSyncClient]::ComputeETag($emptyBytes)) bytes=$($savedBytes.Length)") "Keep local requests: $($server.Requests -join '; ')"
                Assert ($case.Settings.Load().LastSyncedETag -ceq $savedETag) 'Upload did not remember the new version'
                Assert-SyncFile $case.File $savedBytes
            }
            'TakeServer' {
                Assert-Outcome $result 'Downloaded' $choice
                Assert ($result.Document.Rows().Count -eq 0) 'Server queue must be the empty one'
                Assert-SyncFile $case.File $emptyBytes
                Assert-SyncFile ($case.File + '.bak') $savedBytes
                Assert ($case.Settings.Load().LastSyncedETag -ceq $server.ETagOf($token) -and $server.Requests.Count -eq 1) 'Take server must remember and not PUT'
            }
            'Cancel' {
                Assert-Outcome $result 'Cancelled' $choice
                Assert ($result.IsProblem) 'Cancel is reported as a problem'
                Assert-SyncFile $case.File $savedBytes
                Assert (-not [IO.File]::Exists($case.File + '.bak') -and $null -eq $case.Settings.Load().LastSyncedETag -and $server.Requests.Count -eq 1) 'Cancel changed something'
            }
        }
    }
    'PASS: fresh download, revalidation, up to date, identical content, first sync with all three choices'

    # Lokální změna po sladění: 304 a PUT s verzí, kterou server stále drží.
    $server.Documents[$token] = $savedBytes
    $case = New-SyncCase 'pending' $editedBytes $savedETag
    $result = $case.Synchronizer.Synchronize($never)
    Assert-Outcome $result 'Uploaded' 'pending'
    Assert ($server.Requests.Count -eq 2 -and $server.Requests[0] -clike "GET * if-none-match=$savedETag *" -and $server.Requests[1] -clike "PUT * if-match=$savedETag bytes=$($editedBytes.Length)") "Pending upload requests: $($server.Requests -join '; ')"
    Assert ([Convert]::ToBase64String($server.Documents[$token]) -ceq [Convert]::ToBase64String($editedBytes)) 'Server did not store the edit'
    Assert ($case.Settings.Load().LastSyncedETag -ceq [Tercet.QueueSyncClient]::ComputeETag($editedBytes)) 'Pending upload did not remember the version'

    # Server novější, lokálně beze změny: stáhnout, předchozí verze do .bak.
    $server.Documents[$token] = $otherBytes
    $case = New-SyncCase 'server-newer' $savedBytes $savedETag
    $result = $case.Synchronizer.Synchronize($never)
    Assert-Outcome $result 'Downloaded' 'server-newer'
    Assert-SyncFile $case.File $otherBytes
    Assert-SyncFile ($case.File + '.bak') $savedBytes
    Assert ($result.Document.HasSameData($otherDocument) -and $case.Settings.Load().LastSyncedETag -ceq [Tercet.QueueSyncClient]::ComputeETag($otherBytes)) 'Server-newer result'
    # Po stažení navazuje běžná editace: Save přes QueueStore drží kontrolu konfliktu.
    $case.Queue.Save($editedDocument)
    Assert-SyncFile ($case.File + '.bak') $otherBytes

    # Změna na obou stranách po sladění: dotaz bez FirstSync.
    foreach ($choice in @('KeepLocal', 'TakeServer')) {
        $server.Documents[$token] = $otherBytes
        $case = New-SyncCase "both-$choice" $editedBytes $savedETag
        Reset-Conflict ([Tercet.ConflictChoice]::$choice)
        $result = $case.Synchronizer.Synchronize($ask)
        Assert ($conflict.Asked -eq 1 -and $conflict.FirstSync -eq $false) "Both changed must ask once without FirstSync: $choice"
        if ($choice -eq 'KeepLocal') {
            Assert-Outcome $result 'Uploaded' $choice
            Assert ($server.Requests[1] -clike "PUT * if-match=$([Tercet.QueueSyncClient]::ComputeETag($otherBytes)) *") 'Keep local must use the server version in If-Match'
            Assert ([Convert]::ToBase64String($server.Documents[$token]) -ceq [Convert]::ToBase64String($editedBytes)) 'Server kept the other version'
            Assert-SyncFile $case.File $editedBytes
        } else {
            Assert-Outcome $result 'Downloaded' $choice
            Assert-SyncFile $case.File $otherBytes
            Assert-SyncFile ($case.File + '.bak') $editedBytes
        }
    }

    # Závod: server se změní mezi GET a PUT → 412 → nový GET najde změnu a položí dotaz.
    $server.Documents[$token] = $savedBytes
    $server.ReplaceAfterGet = $otherBytes
    $case = New-SyncCase 'race' $editedBytes $savedETag
    Reset-Conflict ([Tercet.ConflictChoice]::KeepLocal)
    $result = $case.Synchronizer.Synchronize($ask)
    Assert-Outcome $result 'Uploaded' 'race'
    Assert ($conflict.Asked -eq 1 -and $conflict.FirstSync -eq $false) 'Race must ask once'
    $methods = @($server.Requests | ForEach-Object { $_.Split(' ')[0] }) -join ','
    Assert ($methods -ceq 'GET,PUT,GET,PUT') "Race requests: $($server.Requests -join '; ')"
    Assert ([Convert]::ToBase64String($server.Documents[$token]) -ceq [Convert]::ToBase64String($editedBytes)) 'Race did not store the local queue'
    # Závod po rozhodnutí: druhý 412 už se nezkouší znovu, jen se ohlásí.
    $server.Documents[$token] = $otherBytes
    $server.ReplaceAfterGet = $emptyBytes
    $case = New-SyncCase 'race-after-choice' $editedBytes $savedETag
    Reset-Conflict ([Tercet.ConflictChoice]::KeepLocal)
    $result = $case.Synchronizer.Synchronize($ask)
    Assert-Outcome $result 'Failed' 'race-after-choice'
    Assert ($conflict.Asked -eq 1 -and $result.Message -clike '*changed again*' -and $server.Requests.Count -eq 2) 'Second race must stop after one PUT'
    Assert-SyncFile $case.File $editedBytes
    Assert ($case.Settings.Load().LastSyncedETag -ceq $savedETag -and [Convert]::ToBase64String($server.Documents[$token]) -ceq [Convert]::ToBase64String($emptyBytes)) 'Second race changed state'
    'PASS: pending upload, server newer, both changed, race with retry and stop'

    # Neexistující fronta, výpadek úložiště, nevalidní serverový dokument.
    $case = New-SyncCase 'not-found' $editedBytes $null -linkToken $unknownToken
    $result = $case.Synchronizer.Synchronize($never)
    Assert-Outcome $result 'NotFound' 'not-found'
    Assert ($server.Requests.Count -eq 1 -and $null -eq $case.Settings.Load().LastSyncedETag) 'Not found changed state'
    Assert-SyncFile $case.File $editedBytes
    $server.FailWith = 503
    try {
        $case = New-SyncCase 'server-error' $editedBytes $savedETag
        $result = $case.Synchronizer.Synchronize($never)
        Assert-Outcome $result 'Failed' 'server-error'
        Assert ($result.Message -clike '*HTTP 503*' -and $result.Message -clike '*unavailable*') "Server error message: $($result.Message)"
    } finally { $server.FailWith = 0 }
    foreach ($invalid in @('{"schemaVersion":1,"queue":[],"archive":42}', '{"schemaVersion":2,"queue":[],"archive":[]}', 'not json')) {
        $server.Documents[$token] = [Text.Encoding]::UTF8.GetBytes($invalid)
        $case = New-SyncCase 'invalid' $null $null
        $result = $case.Synchronizer.Synchronize($never)
        Assert-Outcome $result 'InvalidDocument' $invalid
        Assert (-not [IO.File]::Exists($case.File) -and $null -eq $case.Settings.Load().LastSyncedETag) "Invalid server document changed state: $invalid"
        # Nevalidní verze na serveru nesmí přepsat ani sladěný lokální soubor.
        $case = New-SyncCase 'invalid-synced' $savedBytes $savedETag
        Assert-Outcome ($case.Synchronizer.Synchronize($never)) 'InvalidDocument' "synced/$invalid"
        Assert-SyncFile $case.File $savedBytes
        Assert (-not [IO.File]::Exists($case.File + '.bak')) 'Invalid server document created a backup'
    }
    Assert ($result.Message -clike '*not valid*') "Invalid document message: $($result.Message)"

    # Bez sítě: zavřený port, nic se nemění, výsledek je Offline.
    $dead = [Tercet.Checks.FakeTercetServer]::new()
    $deadPrefix = $dead.Prefix
    $dead.Dispose()
    $case = New-SyncCase 'offline' $editedBytes $savedETag -prefix $deadPrefix
    $result = $case.Synchronizer.Synchronize($never)
    Assert-Outcome $result 'Offline' 'offline'
    Assert ($result.IsProblem -and $result.Message -clike '*not reachable*') "Offline message: $($result.Message)"
    Assert-SyncFile $case.File $editedBytes
    Assert ($case.Settings.Load().LastSyncedETag -ceq $savedETag -and -not [IO.File]::Exists($case.File + '.bak')) 'Offline changed state'

    # Import: přesné bajty, .bak, odmítnutí vadných dat a cizí instance.
    $server.Documents[$token] = $otherBytes
    $case = New-SyncCase 'import' $savedBytes $savedETag
    Reject { $case.Queue.Import([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"queue":[],"archive":42}')) } ([IO.InvalidDataException])
    Reject { $case.Queue.Import([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":2,"queue":[],"archive":[]}')) } ([Tercet.UnsupportedQueueVersionException])
    Assert-SyncFile $case.File $savedBytes
    Assert (-not [IO.File]::Exists($case.File + '.bak')) 'Rejected import wrote a backup'
    $imported = $case.Queue.Import($emptyBytes)
    Assert ($imported.Rows().Count -eq 0) 'Import returned a different document'
    Assert-SyncFile $case.File $emptyBytes
    Assert-SyncFile ($case.File + '.bak') $savedBytes
    # Druhá instance nad týmž souborem: její Import i sync musí konflikt ohlásit, ne přepsat.
    $stranger = [Tercet.QueueStore]::new($case.File)
    [IO.File]::WriteAllBytes($case.File, $editedBytes)
    Reject { $case.Queue.Import($otherBytes) } ([IO.IOException])
    Assert-SyncFile $case.File $editedBytes
    # Cizí zápis se tváří jako sladěný (jinak by přišel dotaz na konflikt);
    # stažení pak narazí na kontrolu původních bajtů v QueueStore.
    $case.Settings.Save([Tercet.SyncSettings]::new($case.Settings.Load().QueueLink, [Tercet.QueueSyncClient]::ComputeETag($editedBytes)))
    $result = $case.Synchronizer.Synchronize($never)
    Assert-Outcome $result 'Failed' 'other-instance'
    Assert ($result.Message -clike '*another instance*') "Other instance message: $($result.Message)"
    Assert-SyncFile $case.File $editedBytes
    Assert ($null -ne $stranger) 'Stranger store'

    # Poškozené settings.json za běhu: výsledek Failed
    # s návodem místo výjimky, žádný požadavek na server, lokální soubor beze
    # změny. NUL soubor je tvar po výpadku napájení, druhý je špatný typ hodnoty.
    foreach ($corruptSettings in @([byte[]]::new(64), [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"queueLink":5}'))) {
        $case = New-SyncCase 'corrupt-settings' $editedBytes $savedETag
        [IO.File]::WriteAllBytes((Join-Path $case.Directory 'settings.json'), $corruptSettings)
        $result = $case.Synchronizer.Synchronize($never)
        Assert-Outcome $result 'Failed' 'corrupt-settings'
        Assert ($result.IsProblem -and $result.Message -clike '*settings file*' -and $server.Requests.Count -eq 0) "Corrupt settings: $($result.Message)"
        Assert-SyncFile $case.File $editedBytes
    }
    'PASS: not found, server error, invalid server document, offline, import, other instance and corrupt settings'
} finally {
    $server.Dispose()
    $http.Dispose()
}

# Dialog konfliktu: skutečné ShowDialog, focus na Cancel, všechny výsledky,
# text pro první sladění i pro změnu na obou stranách (vzor Check-Recovery).
$conflictType = $Assembly.GetType('Tercet.QueueConflictWindow', $true)
foreach ($mode in @('Light', 'Dark')) {
    $Application.ThemeMode = [Windows.ThemeMode].GetProperty($mode).GetValue($null)
    foreach ($action in @('keep', 'take', 'cancel', 'close', 'enter', 'escape')) {
        $firstSync = $action -in @('keep', 'close', 'enter')
        $modified = if ($action -eq 'take') { $null } else { [DateTimeOffset]::new(2026, 9, 29, 8, 0, 0, [TimeSpan]::Zero) }
        $dialog = [Activator]::CreateInstance($conflictType, @([Tercet.SyncConflict]::new($firstSync, $modified)))
        $state = @{ Error = $null; Dialog = $dialog; Action = $action; Mode = $mode; FirstSync = $firstSync; HasModified = ($null -ne $modified); Invoked = $false; Captured = $false }
        $dialog.Add_ContentRendered({
            try {
                $state.Invoked = $true
                $body = $state.Dialog.Content.Content
                $heading = $body.Children[0].Text
                Assert (($heading -clike '*differ*') -eq $state.FirstSync) "Wrong heading for FirstSync=$($state.FirstSync): $heading"
                $texts = @($body.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } | ForEach-Object { $_.Text })
                Assert ((@($texts | Where-Object { $_ -clike 'Server version from *' }).Count -eq 1) -eq $state.HasModified) 'Server time line mismatch'
                $buttons = $body.Children[$body.Children.Count - 1].Children
                Assert ($buttons[0].Content -ceq "Keep this computer's queue" -and $buttons[1].Content -ceq "Take the server's queue" -and $buttons[2].Content -ceq 'Cancel') 'Wrong conflict labels'
                Assert ($buttons[2].IsDefault -and $buttons[2].IsCancel -and $buttons[2].IsKeyboardFocused) 'Cancel is not the safe default with focus'
                if ($state.Action -eq 'cancel') {
                    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($state.Dialog.ActualWidth * 2), [int][Math]::Ceiling($state.Dialog.ActualHeight * 2),192,192,[Windows.Media.PixelFormats]::Pbgra32)
                    $bitmap.Render($state.Dialog)
                    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
                    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                    $output = [IO.File]::Create((Join-Path $TestDirectory ("conflict-dialog-$($state.Mode).png")))
                    try { $encoder.Save($output) } finally { $output.Dispose() }
                    $state.Captured = $true
                }
                switch ($state.Action) {
                    'keep' { $buttons[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
                    'take' { $buttons[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
                    'cancel' { $buttons[2].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
                    'close' { $state.Dialog.Close() }
                    default {
                        $key = if ($state.Action -eq 'enter') { [Windows.Input.Key]::Enter } else { [Windows.Input.Key]::Escape }
                        $input = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, [Windows.PresentationSource]::FromVisual($buttons[2]), 0, $key)
                        $input.RoutedEvent = [Windows.Input.Keyboard]::KeyDownEvent
                        [Windows.Input.InputManager]::Current.ProcessInput($input) | Out-Null
                        Assert (-not $state.Dialog.IsVisible) "Key did not close dialog: $($state.Action)"
                    }
                }
            }
            catch { $state.Error = $_; $state.Dialog.Close() }
        })
        $result = $dialog.ShowDialog()
        Assert ($dialog.Title -ceq ([Tercet.ApplicationIdentity]::DisplayName + ' — Queue conflict')) 'Conflict title lost distribution name'
        if ($state.Error) { throw $state.Error }
        Assert $state.Invoked "Conflict dialog was not rendered: $mode / $action"
        $expectedChoice = switch ($action) { 'keep' { 'KeepLocal' } 'take' { 'TakeServer' } default { 'Cancel' } }
        Assert ($dialog.Choice.ToString() -ceq $expectedChoice) "Wrong choice: $mode / $action / $($dialog.Choice)"
        Assert (($result -eq $true) -eq ($action -in @('keep', 'take'))) "Wrong dialog result: $mode / $action / $result"
        if ($action -eq 'cancel') { Assert $state.Captured 'Missing conflict dialog snapshot' }
    }
}
'PASS: conflict dialog Light/Dark, headings, server time, focus, all buttons, close, Enter and Escape'

# Dialog Settings: platný odkaz se předá, neplatný zůstane v okně s chybou,
# prázdný vypne synchronizaci, Cancel nic nepředá.
$Application.ThemeMode = [Windows.ThemeMode]::System
$settingsType = $Assembly.GetType('Tercet.SettingsWindow', $true)
$applied = [Collections.Generic.List[object]]::new()
$apply = [Action[string]]{ param($value) $applied.Add($value) }
$currentLink = "https://example.com/Tercet/tercet.html#$token"
function New-SettingsWindow([AllowNull()][string]$link) {
    $window = [Activator]::CreateInstance($settingsType, [object[]]@($link, 'Last synchronization: 10:37 — Up to date.', $apply))
    $window.Show()
    Assert ($window.Title -ceq ([Tercet.ApplicationIdentity]::DisplayName + ' — Settings')) 'Settings title lost distribution name'
    $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
    return $window
}
function Click-Settings($window, [string]$name) {
    $window.FindName($name).RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
}
$window = New-SettingsWindow $currentLink
Assert ($window.FindName('LinkBox').Text -ceq $currentLink) 'Settings did not show the current link'
Assert ($window.FindName('StatusText').Text -ceq 'Last synchronization: 10:37 — Up to date.') 'Settings did not show the status'
Assert ($window.FindName('ErrorText').Visibility -eq [Windows.Visibility]::Collapsed) 'Error shown before any input'
$window.FindName('LinkBox').Text = 'https://example.com/Tercet/tercet.html'
Click-Settings $window 'SaveButton'
Assert ($window.IsVisible -and $applied.Count -eq 0) 'Invalid link was applied or closed the window'
Assert ($window.FindName('ErrorText').Visibility -eq [Windows.Visibility]::Visible -and $window.FindName('ErrorText').Text -clike '*#token*') 'Invalid link error missing'
$window.FindName('LinkBox').Text = " http://127.0.0.1:5188/Tercet/tercet.html#$unknownToken "
Click-Settings $window 'SaveButton'
Assert (-not $window.IsVisible -and $applied.Count -eq 1 -and $applied[0] -ceq "http://127.0.0.1:5188/Tercet/tercet.html#$unknownToken") 'Valid link was not applied trimmed'
$window = New-SettingsWindow $currentLink
$window.FindName('LinkBox').Text = '   '
Click-Settings $window 'SaveButton'
Assert (-not $window.IsVisible -and $applied.Count -eq 2 -and $null -eq $applied[1]) 'Empty link must apply null'
$window = New-SettingsWindow $null
Assert ($window.FindName('LinkBox').Text -ceq '') 'Missing link must show an empty box'
$window.FindName('LinkBox').Text = $currentLink
Click-Settings $window 'CancelButton'
Assert (-not $window.IsVisible -and $applied.Count -eq 2) 'Cancel applied the link'
'PASS: settings dialog shows link and status, rejects invalid, applies valid, empty and Cancel'
