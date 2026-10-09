param([byte[]]$Bytes, [string]$TestDirectory, [Reflection.Assembly]$Assembly)
# Dílčí sada spouštěná z Check-Editor.ps1 po inicializaci WPF Application.
# Dot-sourcing sdílí Assert/Reject z hlavního skriptu; vlastní data každého
# scénáře zůstávají oddělená. Skript se nespouští samostatně.

# Čtecí projekce už nevaliduje, proto zde chráníme původní doménové invarianty
# i validaci obálky. Každá změna začíná novou kopií původního JSON.
$json = [Text.Encoding]::UTF8.GetString($Bytes)
$invalidCases = @(
    @{ Name = 'missing-version'; Change = { param($root) $null = $root.Remove('schemaVersion') } },
    @{ Name = 'unknown-version'; Change = { param($root) $root['schemaVersion'] = [Text.Json.Nodes.JsonValue]::Create(2) } },
    @{ Name = 'string-version'; Change = { param($root) $root['schemaVersion'] = [Text.Json.Nodes.JsonValue]::Create('1') } },
    @{ Name = 'missing-queue'; Change = { param($root) $null = $root.Remove('queue') } },
    @{ Name = 'wrong-queue-type'; Change = { param($root) $root['queue'] = [Text.Json.Nodes.JsonObject]::new() } },
    @{ Name = 'missing-archive'; Change = { param($root) $null = $root.Remove('archive') } },
    @{ Name = 'duplicate-id-across-archive'; Change = { param($root) $root['archive'][0]['item']['id'] = [Text.Json.Nodes.JsonValue]::Create($root['queue'][0]['id'].GetValue[string]()) } },
    @{ Name = 'incomplete-done-composite'; Change = { param($root) $root['queue'][4]['children'][0]['situation'] = [Text.Json.Nodes.JsonValue]::Create('done') } },
    @{ Name = 'group-under-composite'; Change = { param($root) $root['queue'][4]['children'][0]['children'].Add([Tercet.QueueDocument]::NewGroup('Invalid group')) } },
    @{ Name = 'archived-incomplete-child'; Change = { param($root) $root['archive'][0]['item']['children'][0]['situation'] = [Text.Json.Nodes.JsonValue]::Create('inactive') } },
    @{ Name = 'negative-archive-index'; Change = { param($root) $root['archive'][0]['originalIndex'] = [Text.Json.Nodes.JsonValue]::Create(-1) } },
    @{ Name = 'unknown-situation'; Change = { param($root) $root['queue'][1]['children'][0]['situation'] = [Text.Json.Nodes.JsonValue]::Create('unknown') } },
    @{ Name = 'unknown-priority'; Change = { param($root) $root['queue'][1]['children'][0]['priority'] = [Text.Json.Nodes.JsonValue]::Create('urgent') } },
    @{ Name = 'unknown-perspective'; Change = { param($root) $root['queue'][1]['children'][0]['perspective'] = [Text.Json.Nodes.JsonValue]::Create('weeks') } },
    @{ Name = 'running-without-assignee'; Change = { param($root) $root['queue'][1]['children'][1]['assignee'] = $null } },
    @{ Name = 'task-with-children'; Change = { param($root) $root['queue'][1]['children'][0]['children'] = [Text.Json.Nodes.JsonArray]::new() } },
    @{ Name = 'fourth-level'; Change = { param($root) $root['queue'][0]['children'][0]['children'].Add($root['queue'][4]['children'][0].DeepClone()); $root['queue'][4]['children'].Clear() } }
)
foreach ($case in $invalidCases) {
    $root = [Text.Json.Nodes.JsonNode]::Parse($json)
    & $case.Change $root
    $expectedError = if ($case.Name -eq 'unknown-version') { [Tercet.UnsupportedQueueVersionException] } else { [IO.InvalidDataException] }
    Reject { [Tercet.QueueDocument]::Parse([Text.Encoding]::UTF8.GetBytes($root.ToJsonString())) } $expectedError
}
"PASS: $($invalidCases.Count) envelope and model validation cases"

# Duplicitní klíče musí selhat jako datová chyba ve všech částech dokumentu,
# i když hodnoty souhlasí nebo je jméno zapsané přes JSON unicode escape.
$duplicates = @(
    $json.Replace('"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 1'),
    $json.Replace('"schemaVersion": 1', '"schemaVersion": 1, "schema\u0056ersion": 1'),
    $json.Replace('"title": "Workshop"', '"title": "Workshop", "title": "Other"'),
    $json.Replace('"originalIndex": 1', '"originalIndex": 1, "originalIndex": 2'),
    $json.Replace('"title": "Replace hinges"', '"title": "Replace hinges", "title": "Other"')
)
foreach ($duplicate in $duplicates) {
    Assert ($duplicate -cne $json) 'Duplicate fixture did not change input'
    Reject { [Tercet.QueueDocument]::Parse([Text.Encoding]::UTF8.GetBytes($duplicate)) } ([IO.InvalidDataException])
}
'PASS: duplicate properties rejected in envelope, queue and archive'

# Pomocná funkce sbírá skutečné TextBoxy aktuálně vykresleného těla.
function Get-TitleInputs($queueView) {
    $queueView.FindName('QueueGrid').Children | Where-Object { $_ -is [Windows.Controls.DockPanel] } |
        ForEach-Object { $_.Children } | Where-Object { $_ -is [Windows.Controls.TextBox] }
}
$fillMenu = [Tercet.QueueView].GetMethod('FillStructureMenu', [Reflection.BindingFlags]'Instance,NonPublic')
foreach ($scenario in 'empty-insert','spaces-move','empty-convert','empty-remove','empty-move-to','empty-archive') {
    $draft = [Tercet.QueueDocument]::Parse($Bytes)
    $blankItem = $draft.QueueItems()[0]
    $initialId = $blankItem['id'].GetValue[string]()
    $queueView = [Tercet.QueueView]::new($draft)
    $titleInputs = @(Get-TitleInputs $queueView)
    $titleInputs[0].Text = if ($scenario -eq 'spaces-move') { '   ' } else { '' }
    Assert ($titleInputs[0].ToolTip -eq $titleInputs[0].Text) 'Blank tooltip stayed stale'
    if ($scenario -eq 'empty-remove') {
        # Potvrzovací MessageBox je ruční UI; zde ověřujeme následující cestu
        # Remove + Rebuild, při které před opravou selhal jiný prázdný řádek.
        $null = $draft.Remove($draft.QueueItems()[-1])
        $queueView.Rebuild()
    } else {
        $menu = [Windows.Controls.ContextMenu]::new()
        $target = $null
        if ($scenario -eq 'spaces-move') { $target = $blankItem }
        if ($scenario -eq 'empty-convert') { $target = $draft.QueueItems()[6] }
        if ($scenario -eq 'empty-move-to') { $target = $draft.QueueItems()[2] }
        if ($scenario -eq 'empty-archive') {
            # Repair the fence s oběma částmi Hotovo: jediná archivovatelná položka s podstromem v demu.
            $target = $draft.QueueItems()[15]
            $target['situation'] = [Text.Json.Nodes.JsonValue]::Create('done')
            $target['children'][1]['situation'] = [Text.Json.Nodes.JsonValue]::Create('done')
        }
        $null = $fillMenu.Invoke($queueView, [object[]]@($menu, $target))
        $choice = switch ($scenario) {
            'empty-insert' { $menu.Items[1] }
            'spaces-move' { @($menu.Items | Where-Object { $_.Header -eq 'Move down' })[0] }
            'empty-convert' { @($menu.Items | Where-Object { $_.Header -like 'Split*' })[0] }
            'empty-move-to' {
                # Podmenu Move to: cíl „Top level“ je první, cesty dalších cílů následují v pořadí fronty.
                $moveTo = @($menu.Items | Where-Object { $_.Header -eq 'Move to' })[0]
                Assert ($null -ne $moveTo -and $moveTo.IsEnabled) 'Move-to submenu missing or disabled'
                # První řádek má v tomto scénáři prázdný název, cesta cíle proto vychází z aktuální kopie.
                Assert ($moveTo.Items[0].Header -eq 'Top level' -and $moveTo.Items[1].Header -eq $draft.PathOf($draft.QueueItems()[0])) 'Move-to targets or labels'
                Assert (-not ($moveTo.Items | Where-Object { $_.Header -like '*Backlog' })) 'Current parent offered as target'
                @($moveTo.Items | Where-Object { $_.Header -eq 'Garden › Repair the fence' })[0]
            }
            'empty-archive' {
                $archive = @($menu.Items | Where-Object { $_.Header -eq 'Archive' })[0]
                Assert ($null -ne $archive -and $archive.IsEnabled) 'Archive command missing or disabled for completed composite'
                $archive
            }
        }
        Assert ($null -ne $choice) "Missing command for $scenario"
        $choice.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
    }
    # Ověřujeme efekt příkazu, nejen to, že nevyhodil výjimku.
    switch ($scenario) {
        'empty-insert' { Assert ($draft.QueueItems().Count -eq 22) 'Insert did not happen' }
        'spaces-move' { Assert ($draft.QueueItems()[0]['title'].GetValue[string]() -eq 'Tercet') 'Move did not happen' }
        'empty-convert' { Assert ($draft.QueueItems()[6]['kind'].GetValue[string]() -eq 'compositeTask') 'Conversion did not happen' }
        'empty-remove' { Assert ($draft.QueueItems().Count -eq 20) 'Remove did not happen' }
        'empty-move-to' {
            $moved = $draft.QueueItems() | Where-Object { $_['title'].GetValue[string]() -eq 'TASK-101' }
            Assert ($draft.PathOf($moved) -eq 'Garden › Repair the fence › TASK-101' -and $draft.QueueItems().Count -eq 21) 'Move-to did not happen'
        }
        'empty-archive' { Assert ($draft.QueueItems().Count -eq 18 -and $draft.ArchiveEntries().Count -eq 2) 'Archive did not happen' }
    }
    $currentInputs = @(Get-TitleInputs $queueView)
    Assert ($currentInputs.Count -eq $draft.QueueItems().Count) 'View stale after operation'
    Assert ($blankItem['id'].GetValue[string]() -eq $initialId) 'Draft changed identity'
    $draftPath = Join-Path $TestDirectory ($scenario + '.json')
    $draftStore = [Tercet.QueueStore]::new($draftPath)
    $stream = [IO.MemoryStream]::new($Bytes)
    try { $null = $draftStore.Load($stream) } finally { $stream.Dispose() }
    $draftStore.Save([Tercet.QueueDocument]::Parse($Bytes))
    Reject { $draftStore.Save($draft) } ([IO.InvalidDataException])
    Assert ([Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes($draftPath)).HasSameData([Tercet.QueueDocument]::Parse($Bytes))) 'Invalid save changed file'
    $blankInput = @($currentInputs | Where-Object { [string]::IsNullOrWhiteSpace($_.Text) })
    Assert ($blankInput.Count -eq 1) 'Unfinished title lost during rebuild'
    $blankInput[0].Text = 'Repaired title'
    Assert ($blankInput[0].ToolTip -eq 'Repaired title') 'Tooltip not repaired'
    $draftStore.Save($draft)
    Assert ([Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes($draftPath)).HasSameData($draft)) 'Corrected edit did not save'
}
'PASS: unfinished titles survive insert, move, convert, move-to, archive and remove; invalid save rejected; correction saves'

# Archive v menu: skupina volbu nemá, nehotový úkol ji vidí zašedlou, hotový povolenou.
$draft = [Tercet.QueueDocument]::Parse($Bytes)
$queueView = [Tercet.QueueView]::new($draft)
$archiveChoice = {
    param($item)
    $menu = [Windows.Controls.ContextMenu]::new()
    $null = $fillMenu.Invoke($queueView, [object[]]@($menu, $item))
    @($menu.Items | Where-Object { $_ -is [Windows.Controls.MenuItem] -and $_.Header -eq 'Archive' })
}
Assert ((& $archiveChoice $draft.QueueItems()[0]).Count -eq 0) 'Group offers Archive'
$undone = & $archiveChoice $draft.QueueItems()[2]
Assert ($undone.Count -eq 1 -and -not $undone[0].IsEnabled) 'Undone task must show Archive disabled'
$done = & $archiveChoice $draft.QueueItems()[4]
Assert ($done.Count -eq 1 -and $done[0].IsEnabled) 'Done task must show Archive enabled'
# Seznam archivu: nejnovější nahoře, popisek s počtem a cílem obnovy, Restore předá záznam.
$done[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
Assert ($draft.ArchiveEntries().Count -eq 2 -and $draft.QueueItems().Count -eq 20) 'Archive from menu did not happen'
$buildList = [Tercet.QueueView].GetMethod('BuildArchiveList', [Reflection.BindingFlags]'Instance,NonPublic')
$script:restoredEntry = $null
$onRestore = [Action[Text.Json.Nodes.JsonObject]]{ param($entry) $script:restoredEntry = $entry }
$list = $buildList.Invoke($queueView, [object[]]@($onRestore))
$archiveRows = @($list.Children | Where-Object { $_ -is [Windows.Controls.DockPanel] })
# Popisek skládá dva Run: TextBlock.Text obsah Inlines nevrací, čte se přes TextRange.
$labels = @($archiveRows | ForEach-Object {
    $block = @($_.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] })[0]
    Assert ($block.ToolTip -eq [Windows.Documents.TextRange]::new($block.ContentStart, $block.ContentEnd).Text) 'Archive tooltip differs from label'
    $block.ToolTip
})
Assert ($archiveRows.Count -eq 2 -and $labels[0] -eq 'Meeting notes · Workshop' -and $labels[1] -eq 'Repair the gate · 3 items · Garden') "Archive labels: $($labels -join ' | ')"
$restoreButton = @($archiveRows[1].Children | Where-Object { $_ -is [Windows.Controls.Button] })[0]
$restoreButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
Assert ($null -ne $script:restoredEntry -and [Tercet.QueueDocument]::ArchivedItem($script:restoredEntry)['title'].GetValue[string]() -eq 'Repair the gate') 'Restore button did not pass its entry'
$restoredGate = $draft.Restore($script:restoredEntry)
Assert ($draft.PathOf($restoredGate) -eq 'Garden › Repair the gate' -and $draft.ArchiveEntries().Count -eq 1) 'Restore from list did not happen'
$emptyDraft = [Tercet.QueueDocument]::Parse($Bytes)
$null = $emptyDraft.Restore($emptyDraft.ArchiveEntries()[0])
$emptyList = $buildList.Invoke([Tercet.QueueView]::new($emptyDraft), [object[]]@($onRestore))
Assert (@($emptyList.Children)[0].Text -eq 'The archive is empty.') 'Empty archive message'
'PASS: archive command availability by type and state, archive list order, labels and restore'

# Identita rodiče je hodnota UUID, nikoli její zápis. Kombinujeme odlišné
# formáty na obou stranách vazby; kontrolujeme umístění i zachování textů.
foreach ($parentFormat in @('D','N','B','upper')) {
    foreach ($referenceFormat in @('D','N','B','upper')) {
        $draft = [Tercet.QueueDocument]::Parse($Bytes)
        $entry = $draft.ArchiveEntries()[0]
        $identity = [guid]$entry['originalParentId'].GetValue[string]()
        $parent = @($draft.QueueItems() | Where-Object { [guid]$_['id'].GetValue[string]() -eq $identity })[0]
        $parentText = if ($parentFormat -ceq 'upper') { $identity.ToString('D').ToUpperInvariant() } else { $identity.ToString($parentFormat) }
        $referenceText = if ($referenceFormat -ceq 'upper') { $identity.ToString('D').ToUpperInvariant() } else { $identity.ToString($referenceFormat) }
        $parent['id'] = [Text.Json.Nodes.JsonValue]::Create($parentText)
        $entry['originalParentId'] = [Text.Json.Nodes.JsonValue]::Create($referenceText)
        $draft.Validate()
        $position = $draft.RestorePlacement($entry)
        Assert ([object]::ReferenceEquals($position.Item1, $parent) -and $position.Item2 -eq 1) "UUID placement: $parentFormat / $referenceFormat"
        $restored = $draft.Restore($entry)
        Assert ([object]::ReferenceEquals($draft.ParentOf($restored), $parent) -and [object]::ReferenceEquals($parent['children'][1], $restored)) 'UUID restore changed the destination or index'
        Assert ($parent['id'].GetValue[string]() -ceq $parentText -and $entry['originalParentId'].GetValue[string]() -ceq $referenceText) 'Restore rewrote an identity'
        $draft.Validate()
    }
}
'PASS: 16 UUID spelling combinations restore to the same parent and index without rewriting identities'

# Skutečný editor hostí UserControl přímo, bez dalšího pomocného Window.
$originalDocument = [Tercet.QueueDocument]::Parse($Bytes)
$windowCount = [Windows.Application]::Current.Windows.Count
$editorType = $Assembly.GetType('Tercet.QueueEditorWindow', $true)
$unusedSave = [Action[Tercet.QueueDocument]]{ param($document) throw 'Unmodified editor must not save' }
$editorWindow = [Activator]::CreateInstance($editorType, [object[]]@($originalDocument, $unusedSave, [Windows.Rect]::new(20,40,266,374)))
Assert ([Windows.Application]::Current.Windows.Count -eq $windowCount + 1) 'Editor created an extra Window'
$editorViews = @($editorWindow.Content.Children | Where-Object { $_ -is [Tercet.QueueView] })
Assert ($editorViews.Count -eq 1) 'Editor does not host QueueView directly'
# Výška editoru sleduje obsah: tělo + hlavička 28 + patička 34, nejvýše
# pracovní plocha; po přidání řádku vyroste, po odebrání se vrátí.
$fitHeight = { [math]::Min($editorViews[0].ContentSize.Height + 62, [Windows.SystemParameters]::WorkArea.Height) }
$openHeight = $editorWindow.Height
$draft = $editorType.GetField('workingCopy', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($editorWindow)
$grown = [Tercet.QueueDocument]::NewTask('Grows the editor')
$draft.AppendChild($null, $grown)
$editorViews[0].Rebuild()
Assert ($editorWindow.Height -eq (& $fitHeight) -and $editorWindow.Height -gt $openHeight) 'Editor did not grow with a new row'
$grownHeight = $editorWindow.Height
$null = $draft.Remove($grown)
$editorViews[0].Rebuild()
Assert ($editorWindow.Height -eq (& $fitHeight) -and $editorWindow.Height -lt $grownHeight) 'Editor did not shrink after removal'
# Paticka nese Archiv… vlevo a Zrusit / Uložit vpravo.
$footerButtons = @($editorWindow.Content.Children | Where-Object { $_ -is [Windows.Controls.DockPanel] } |
    ForEach-Object { $_.Children } | Where-Object { $_ -is [Windows.Controls.Button] })
Assert ($footerButtons.Count -eq 1 -and $footerButtons[0].Content -eq 'Archive…') 'Archive button missing in the footer'
# Otevřeme skutečné menu editoru. AccessText.Text může obsahovat podtržítko,
# které se ve výsledku nezobrazí; důkazem jsou proto znaky vykreslených glyphů.
function Get-DrawingText($Drawing) {
    if ($Drawing -is [Windows.Media.GlyphRunDrawing]) { -join $Drawing.GlyphRun.Characters }
    if ($Drawing -is [Windows.Media.DrawingGroup]) {
        foreach ($child in $Drawing.Children) { Get-DrawingText $child }
    }
}
function Get-VisualText($Visual) {
    Get-DrawingText ([Windows.Media.VisualTreeHelper]::GetDrawing($Visual))
    for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Visual); $i++) {
        Get-VisualText ([Windows.Media.VisualTreeHelper]::GetChild($Visual, $i))
    }
}
$draft.QueueItems()[0]['title'] = [Text.Json.Nodes.JsonValue]::Create('_project__alpha_')
$draft.QueueItems()[2]['title'] = [Text.Json.Nodes.JsonValue]::Create('task__one_')
$editorViews[0].Rebuild()
$editorWindow.Show()
$editorWindow.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
Assert ($editorWindow.Title -ceq ([Tercet.ApplicationIdentity]::DisplayName + ' — Editor')) 'Editor title lost distribution name'
# Nejdelší distribuční název musí vejít vedle verze i při minimální šířce.
# Měníme jen text pro měření layoutu; výběr názvu ověřuje Check-TrayIcon.
$header = $editorWindow.Content.Children[0]
$headerTitle = $header.Children[1]
$originalHeader = $headerTitle.Text
$originalWidth = $editorWindow.Width
try {
    $editorWindow.Width = 250
    foreach ($name in @('Tercet Preview', 'Tercet Prototype', 'Tercet')) {
        $headerTitle.Text = $name + ' — Editor'
        $editorWindow.UpdateLayout()
        $available = $headerTitle.ActualWidth
        $headerTitle.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        Assert ($headerTitle.DesiredSize.Width -le $available + 0.5) "Editor header clipped at 250 px: $name"
    }
} finally {
    $headerTitle.Text = $originalHeader
    $editorWindow.Width = $originalWidth
    $editorWindow.UpdateLayout()
}
'PASS: editor distribution title, all three names fit beside version at 250 px'
$titleInput = @($editorViews[0].FindName('QueueGrid').Children | Where-Object { $_ -is [Windows.Controls.DockPanel] } |
    ForEach-Object { $_.Children } | Where-Object { $_ -is [Windows.Controls.TextBox] })[0]
$menu = $titleInput.ContextMenu
$null = $fillMenu.Invoke($editorViews[0], [object[]]@($menu, $draft.QueueItems()[2]))
$menu.PlacementTarget = $titleInput
try {
    $menu.IsOpen = $true
    $editorWindow.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $moveTo = @($menu.Items | Where-Object { $_.Header -ceq 'Move to' })[0]
    $moveTo.IsSubmenuOpen = $true
    $editorWindow.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $caption = -join @(Get-VisualText $menu.Items[0])
    $destination = -join @(Get-VisualText $moveTo.Items[1])
    Assert ($caption.Contains('task__one_')) "Menu caption changed literal title: $caption"
    Assert ($destination -ceq '_project__alpha_') "Move destination changed literal path: $destination"
    Assert ($draft.QueueItems()[0]['title'].GetValue[string]() -ceq '_project__alpha_') 'Menu rewrote the stored title'
} finally {
    if ($null -ne $moveTo) { $moveTo.IsSubmenuOpen = $false }
    $menu.IsOpen = $false
    # Testovací přejmenování zahodíme stejným tlačítkem jako uživatel,
    # aby Close nevyvolalo potvrzení neuložených změn.
    $cancelButton = @($editorWindow.Content.Children | Where-Object { $_ -is [Windows.Controls.DockPanel] } |
        ForEach-Object { $_.Children } | Where-Object { $_ -is [Windows.Controls.StackPanel] } |
        ForEach-Object { $_.Children } | Where-Object { $_ -is [Windows.Controls.Button] -and $_.Content -ceq 'Cancel' })[0]
    $cancelButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
}
'PASS: opened menu renders literal leading, repeated and trailing underscores in captions and destinations'
Assert ([Windows.Application]::Current.Windows.Count -eq $windowCount) 'Editor leaked a Window'
'PASS: editor hosts shared UserControl without an auxiliary Window'
