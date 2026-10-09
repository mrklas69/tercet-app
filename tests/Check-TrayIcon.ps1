param([Tercet.App]$Application, [byte[]]$Bytes, [string]$TestDirectory, [Reflection.Assembly]$Assembly)
# Dílčí sada hlavního Check-Editor.ps1. Ikona zůstává skrytá a úložiště
# je dočasné; OnStartup se nevolá a provozní fronta se nikdy neotevře.
Add-Type -AssemblyName System.Windows.Forms
# Kontrola mapování nezávisí na tom, zda je hostitelský pwsh ze Storu.
# Reflexe předá skutečné null, které PowerShell u string parametru jinak
# může převést na prázdný řetězec. Podobný prefix nesmí znamenat prototyp.
$nameMethod = [Tercet.ApplicationIdentity].GetMethod('GetDisplayName')
foreach ($case in @(
    @{ Family = $null; Name = 'Tercet Preview' },
    @{ Family = 'Tercet.Prototype_arwecbhkrscbj'; Name = 'Tercet Prototype' },
    @{ Family = 'StoreIdentity_publisher'; Name = 'Tercet' },
    @{ Family = 'Tercet.PrototypeOther_publisher'; Name = 'Tercet' }
)) {
    Assert ($nameMethod.Invoke($null, [object[]]@($case.Family)) -ceq $case.Name) 'Distribution display name mismatch'
    $lengthProbe = [Windows.Forms.NotifyIcon]::new()
    try {
        $lengthProbe.Text = $case.Name + ' — Needs attention — waiting for the desktop'
        Assert ($lengthProbe.Text.EndsWith(' — waiting for the desktop')) 'Distribution tooltip lost status'
    } finally { $lengthProbe.Dispose() }
}
$trayName = [Tercet.ApplicationIdentity]::DisplayName
Assert ([Tercet.ApplicationIdentity]::Title('Synchronize') -ceq "$trayName — Synchronize") 'Notification title mismatch'
'PASS: Preview/Prototype/Store names, similar package prefix, full tooltip status fits NotifyIcon'
$situations = @('needsAttention','underReview','inProgress','inactive','done')
for ($mask = 0; $mask -lt 32; $mask++) {
    $testRows = [Collections.Generic.List[Tercet.QueueRow]]::new()
    $expected = $null
    for ($index = 0; $index -lt 5; $index++) {
        if ($mask -band (1 -shl $index)) {
            if ($null -eq $expected) { $expected = $situations[$index] }
            $testRows.Add([Tercet.QueueRow]::new('Task','task',2,$situations[$index],'hours'))
        }
    }
    Assert ([Tercet.QueueAttention]::SelectSituation($testRows) -ceq $expected) "Tray combination $mask"
    $testRows.Reverse()
    Assert ([Tercet.QueueAttention]::SelectSituation($testRows) -ceq $expected) "Tray order dependence $mask"
}
'PASS: all 32 situation combinations, independent of row order'

# Porovnáme skutečné pixely vloženého resource s jediným zdrojovým ICO.
# Stream uvnitř Create už je zavřený, takže ověřujeme i životnost ikony.
$icon = [Tercet.TrayIconRenderer]::Create()
$expectedIcon = [Drawing.Icon]::new((Join-Path $PSScriptRoot '../src/Tercet/Assets/Tercet.ico'), $icon.Size)
$pixels = $icon.ToBitmap()
$expectedPixels = $expectedIcon.ToBitmap()
$preview = [Drawing.Bitmap]::new(128,64)
$previewGraphics = [Drawing.Graphics]::FromImage($preview)
$previewGraphics.Clear([Drawing.Color]::White)
$previewGraphics.FillRectangle([Drawing.Brushes]::Black, 64, 0, 64, 64)
try {
    Assert ($pixels.Size -eq $expectedPixels.Size) 'Application/tray icon dimensions differ'
    for ($y = 0; $y -lt $pixels.Height; $y++) {
        for ($x = 0; $x -lt $pixels.Width; $x++) {
            Assert ($pixels.GetPixel($x,$y).ToArgb() -eq $expectedPixels.GetPixel($x,$y).ToArgb()) "Application/tray icon pixel mismatch at $x,$y"
        }
    }
    $previewGraphics.DrawIcon($icon, 16, 16)
    $previewGraphics.DrawIcon($icon, 80, 16)
    $previewPath = Join-Path $TestDirectory 'tray-icons.png'
    $preview.Save($previewPath, [Drawing.Imaging.ImageFormat]::Png)
} finally {
    $previewGraphics.Dispose(); $preview.Dispose()
    $pixels.Dispose(); $expectedPixels.Dispose(); $expectedIcon.Dispose(); $icon.Dispose()
}
'PASS: tray icon pixels match application ICO after resource stream disposal'
"Tray preview (light/dark): $previewPath"

# Základ s prázdnou frontou ponechává archiv z dema. Jeho dokončené položky
# nesmějí ovlivnit situaci v tooltipu. Skupina je také bez vlastní situace.
$trayRoot = [Text.Json.Nodes.JsonNode]::Parse([Text.Encoding]::UTF8.GetString($Bytes))
$trayRoot['queue'].Clear()
$trayDocument = [Tercet.QueueDocument]::Parse([Text.Encoding]::UTF8.GetBytes($trayRoot.ToJsonString()))
Assert ($null -eq [Tercet.QueueAttention]::SelectSituation($trayDocument.Rows())) 'Archive affects tray'
$group = [Tercet.QueueDocument]::NewGroup('Group')
$trayDocument.AppendChild($null, $group)
Assert ($null -eq [Tercet.QueueAttention]::SelectSituation($trayDocument.Rows())) 'Groups affect tray'
$composite = [Tercet.QueueDocument]::NewTask('Composite')
$trayDocument.AppendChild($group, $composite)
$trayDocument.SplitIntoParts($composite)
$composite['situation'] = [Text.Json.Nodes.JsonValue]::Create('needsAttention')
Assert ([Tercet.QueueAttention]::SelectSituation($trayDocument.Rows()) -ceq 'needsAttention') 'Empty composite ignored'
$part = [Tercet.QueueDocument]::NewTask('Part')
$trayDocument.AppendChild($composite, $part)
$composite['situation'] = [Text.Json.Nodes.JsonValue]::Create('inactive')
$part['situation'] = [Text.Json.Nodes.JsonValue]::Create('underReview')
$part['assignee'] = [Text.Json.Nodes.JsonValue]::Create('Test reviewer')
Assert ([Tercet.QueueAttention]::SelectSituation($trayDocument.Rows()) -ceq 'underReview') 'Third-level part ignored'
$trayDocument.Validate()

# Reflexe napojí skutečnou ukládací metodu App na dočasný QueueStore.
# V produkci zůstává store readonly; test po sobě vrací původní reference.
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$appType = [Tercet.App]
$savedFields = @{}
foreach ($name in 'store','document','rows','trayIcon','trayImage','errorReported') {
    $savedFields[$name] = $appType.GetField($name,$flags).GetValue($Application)
}
$notifyIcon = [Windows.Forms.NotifyIcon]::new()
$trayStore = [Tercet.QueueStore]::new((Join-Path $TestDirectory 'tray-queue.json'))
$trayStream = [IO.MemoryStream]::new($trayDocument.ToBytes())
try { $null = $trayStore.Load($trayStream) } finally { $trayStream.Dispose() }
$saveMethod = $appType.GetMethod('SaveDocument',$flags)
$saveAction = $saveMethod.CreateDelegate([Action[Tercet.QueueDocument]],$Application)
$editorType = $Assembly.GetType('Tercet.QueueEditorWindow',$true)
try {
    $appType.GetField('store',$flags).SetValue($Application,$trayStore)
    $appType.GetField('document',$flags).SetValue($Application,$trayDocument)
    $appType.GetField('rows',$flags).SetValue($Application,$trayDocument.Rows())
    $appType.GetField('trayIcon',$flags).SetValue($Application,$notifyIcon)
    $null = $appType.GetMethod('UpdateTrayIcon',$flags).Invoke($Application,@())
    Assert ($notifyIcon.Text -ceq "$trayName — Under review") 'Startup tray text'
    $initialIcon = $notifyIcon.Icon

    # Skutečné tlačítko Cancel zahodí změnu pracovní kopie bez publikace.
    $cancelEditor = [Activator]::CreateInstance($editorType,[object[]]@($trayDocument,$saveAction,[Windows.Rect]::new(20,40,266,374)))
    $draft = $editorType.GetField('workingCopy',$flags).GetValue($cancelEditor)
    $draft.QueueItems()[2]['situation'] = [Text.Json.Nodes.JsonValue]::Create('needsAttention')
    Assert ($notifyIcon.Text -ceq "$trayName — Under review" -and [object]::ReferenceEquals($initialIcon,$notifyIcon.Icon)) 'Unsaved edit changed tray'
    $actions = @($cancelEditor.Content.Children | Where-Object { $_ -is [Windows.Controls.DockPanel] } |
        ForEach-Object { $_.Children } | Where-Object { $_ -is [Windows.Controls.StackPanel] })[0]
    $cancelButton = @($actions.Children | Where-Object { $_.Content -eq 'Cancel' })[0]
    $cancelButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ($notifyIcon.Text -ceq "$trayName — Under review" -and [object]::ReferenceEquals($initialIcon,$notifyIcon.Icon)) 'Cancel changed tray'

    $saveEditor = [Activator]::CreateInstance($editorType,[object[]]@($trayDocument,$saveAction,[Windows.Rect]::new(20,40,266,374)))
    $draft = $editorType.GetField('workingCopy',$flags).GetValue($saveEditor)
    $draft.QueueItems()[2]['situation'] = [Text.Json.Nodes.JsonValue]::Create('needsAttention')
    $null = $editorType.GetMethod('SaveAndClose',$flags).Invoke($saveEditor,@())
    Assert ($notifyIcon.Text -ceq "$trayName — Needs attention") 'Editor Save did not refresh tray'
    $savedIcon = $notifyIcon.Icon
    Assert ([object]::ReferenceEquals($initialIcon,$savedIcon)) 'Save replaced the static application icon'
    $onDisk = [Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes((Join-Path $TestDirectory 'tray-queue.json')))
    Assert ([Tercet.QueueAttention]::SelectSituation($onDisk.Rows()) -ceq 'needsAttention') 'Tray differs from disk'

    $invalidDraft = $onDisk.Clone()
    $invalidDraft.QueueItems()[0]['title'] = [Text.Json.Nodes.JsonValue]::Create('')
    $invalidDraft.QueueItems()[2]['situation'] = [Text.Json.Nodes.JsonValue]::Create('inactive')
    Reject { $saveAction.Invoke($invalidDraft) } ([IO.InvalidDataException])
    Assert ($notifyIcon.Text -ceq "$trayName — Needs attention" -and [object]::ReferenceEquals($savedIcon,$notifyIcon.Icon)) 'Failed save changed tray'

    # Chyba připojení k ploše přidává dovětek a její odeznění jej odstraní.
    $appType.GetField('errorReported',$flags).SetValue($Application,$true)
    $null = $appType.GetMethod('UpdateTrayText',$flags).Invoke($Application,@())
    Assert ($notifyIcon.Text -ceq "$trayName — Needs attention — waiting for the desktop") 'Desktop failure hid situation'
    $appType.GetField('errorReported',$flags).SetValue($Application,$false)
    $null = $appType.GetMethod('UpdateTrayText',$flags).Invoke($Application,@())
    Assert ($notifyIcon.Text -ceq "$trayName — Needs attention") 'Desktop recovery hid situation'
    Assert (-not $notifyIcon.Visible) 'Test exposed tray icon'
} finally {
    $notifyIcon.Dispose()
    $image = $appType.GetField('trayImage',$flags).GetValue($Application)
    if ($null -ne $image) { $image.Dispose() }
    foreach ($name in $savedFields.Keys) { $appType.GetField($name,$flags).SetValue($Application,$savedFields[$name]) }
}
'PASS: archive excluded, groups, composites, deep parts, startup, editor Save/Cancel, failed save, desktop status'
