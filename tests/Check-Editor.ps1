param([string]$Configuration = 'Release', [switch]$CheckFocus, [switch]$UpdateSnapshot, [switch]$ReviewRecovery, [switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'
# Kontroly pracují pouze v dočasném adresáři, nikdy s daty uživatele.
# Adresář se po úspěchu smaže; -KeepArtifacts ho ponechá i s náhledy PNG.
Add-Type -AssemblyName PresentationFramework
[AppContext]::SetSwitch('Switch.System.Windows.Appearance.DisableFluentThemeWindowBackdrop', $true)
$repo = Split-Path $PSScriptRoot -Parent
$assembly = [Reflection.Assembly]::LoadFrom((Join-Path $repo "src/Tercet/bin/$Configuration/net10.0-windows/Tercet.dll"))
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Reject([scriptblock]$action, [type]$exceptionType) {
    $rejected = $false
    # PowerShell a reflexe obalují výjimku volané metody. Rozbalíme jen tyto
    # obaly, nikoli InnerException vlastní datové chyby (ta nese její příčinu).
    try { $null = & $action } catch {
        $failure = $_.Exception
        while (($failure -is [Management.Automation.RuntimeException] -or $failure -is [Reflection.TargetInvocationException]) -and $null -ne $failure.InnerException) {
            $failure = $failure.InnerException
        }
        Assert ($failure.GetType() -eq $exceptionType) "Expected $exceptionType, got $($failure.GetType()): $($failure.Message)"
        $rejected = $true
    }
    Assert $rejected 'Expected rejection'
}
# Ukázková fronta prvního spuštění je přibalený resource, oddělený
# od testovacích dat níže: musí projít validací, ukázat všech pět situací
# (tedy blikající i statické diody), tři úrovně a neprázdný archiv.
$firstRunStream = $assembly.GetManifestResourceStream('Tercet.FirstRunQueue')
Assert ($null -ne $firstRunStream) 'First-run queue resource is missing'
try {
    $firstRunBuffer = [IO.MemoryStream]::new()
    $firstRunStream.CopyTo($firstRunBuffer)
    $firstRun = [Tercet.QueueDocument]::Parse($firstRunBuffer.ToArray())
} finally { $firstRunStream.Dispose() }
$firstRunRows = $firstRun.Rows()
$firstRunSituations = @($firstRunRows | Where-Object { $_.Kind -ne 'group' } | ForEach-Object { $_.Situation } | Sort-Object -Unique)
Assert ($firstRunSituations.Count -eq [Tercet.QueueValues]::Situations.Count) "First-run queue situations: $($firstRunSituations -join ', ')"
Assert (@($firstRunRows | Where-Object { $_.Depth -eq 2 }).Count -gt 0 -and @($firstRunRows | Where-Object { $_.Kind -eq 'compositeTask' }).Count -gt 0) 'First-run queue must show three levels and a composite task'
Assert ($firstRun.ArchiveEntries().Count -gt 0) 'First-run queue must show a non-empty archive'
# Ukázka jde do světa: jen ASCII, žádná čeština ani interní názvy.
Assert (@($firstRunRows | Where-Object { $_.Title -cmatch '[^\x20-\x7E]' }).Count -eq 0) 'First-run queue titles must be plain ASCII'
"PASS: first-run queue resource ($($firstRunRows.Count) rows, $($firstRunSituations.Count) situations, archive $($firstRun.ArchiveEntries().Count))"
$bytes = [IO.File]::ReadAllBytes((Join-Path $repo 'tests/queue-fixture.json'))
$original = [Tercet.QueueDocument]::Parse($bytes)
$copy = $original.Clone()
# Fiktivní text zachovává kontrolu Unicode i po anglické anonymizaci fixture.
$copy.QueueItems()[0]['title'] = [Text.Json.Nodes.JsonValue]::Create('Žluťoučký test')
Assert (-not $copy.HasSameData($original)) 'Copy changed original'
Assert ([Tercet.QueueDocument]::Parse($bytes).HasSameData($original)) 'Original changed'
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('Tercet-check-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($testDir) | Out-Null
$path = Join-Path $testDir 'queue.json'
$store = [Tercet.QueueStore]::new($path)
$stream = [IO.MemoryStream]::new($bytes)
try { $loaded = $store.Load($stream) } finally { $stream.Dispose() }
Assert (-not [IO.File]::Exists($path)) 'Load wrote data'
$store.Save($copy)
Assert ([Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes($path)).HasSameData($copy)) 'Save mismatch'
$second = [Tercet.QueueStore]::new($path)
$stream = [IO.MemoryStream]::new($bytes)
try { $other = $second.Load($stream) } finally { $stream.Dispose() }
$store.Save($original)
Assert ([Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes($path + '.bak')).HasSameData($copy)) 'Backup mismatch'
Reject { $second.Save($other) } ([IO.IOException])
$invalid = $original.Clone()
$invalid.QueueItems()[0]['title'] = [Text.Json.Nodes.JsonValue]::Create('')
Reject { $store.Save($invalid) } ([IO.InvalidDataException])
Assert ([Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes($path)).HasSameData($original)) 'Failed save changed data'
[IO.File]::WriteAllBytes($path, [byte[]](0,0,0))
$stream = [IO.MemoryStream]::new($bytes)
try { Reject { $store.Load($stream) } ([IO.InvalidDataException]) } finally { $stream.Dispose() }
# Neúspěšný reload nesmí posunout základ kontroly konfliktů.
Reject { $store.Save($original) } ([IO.IOException])
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -eq 'AAAA') 'Failed reload/save changed corrupt bytes'
Assert ([Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes($path + '.bak')).HasSameData($copy)) 'Failed reload/save changed backup'
# Další pozitivní scénář dostane vlastní čisté úložiště, ne poškozený soubor.
$path = Join-Path $testDir 'structure.json'
$store = [Tercet.QueueStore]::new($path)
$stream = [IO.MemoryStream]::new($bytes)
try { $null = $store.Load($stream) } finally { $stream.Dispose() }
'PASS: clone, roundtrip, backup, conflict, invalid save, corrupt load'
# Testovací App s potlačeným produkčním startem; proč a jak říká sdílený
# New-TestApplication.ps1 (dot-source nastaví $app).
. (Join-Path $PSScriptRoot 'New-TestApplication.ps1') -Assembly $assembly
Assert ($app.ThemeMode.ToString() -eq 'System') 'Startup must use System theme'
foreach ($key in 'ApplicationBackgroundBrush','TextFillColorPrimaryBrush','TextFillColorSecondaryBrush','AccentFillColorDefaultBrush','TextOnAccentFillColorPrimaryBrush','SolidBackgroundFillColorBaseAltBrush','SolidBackgroundFillColorSecondaryBrush') {
    $brush = $app.TryFindResource($key)
    Assert ($brush -is [Windows.Media.SolidColorBrush]) "Missing startup brush: $key"
    '{0}={1}' -f $key,$brush
}
$window = [Tercet.MainWindow]::new($original.Rows())
Assert ($window.Title -ceq [Tercet.ApplicationIdentity]::DisplayName) 'Desktop title lost distribution name'
Assert ($null -ne $window.Background) 'Missing actual window background'
Assert ($window.Background.Opacity -eq 1 -and $window.Background.Color.A -eq 255) 'Transparent desktop background'
$size = $window.ContentSize
$window.Content.Measure($size)
$window.Content.Arrange([Windows.Rect]::new($size))
$bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int][math]::Ceiling($size.Width * 2), [int][math]::Ceiling($size.Height * 2),192,192,[Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($window.Content)
$pixels = [byte[]]::new($bitmap.PixelWidth * $bitmap.PixelHeight * 4)
$bitmap.CopyPixels($pixels, $bitmap.PixelWidth * 4, 0)
# Vnitřní pixel těla musí být neprůhledný i při renderu bez HWND.
$sample = (100 * $bitmap.PixelWidth + $bitmap.PixelWidth - 15) * 4
Assert ($pixels[$sample + 3] -eq 255) 'Rendered body is transparent'
$encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
# Běžný test zapisuje jen do svého adresáře. Trvalý náhled lze změnit
# pouze výslovným -UpdateSnapshot; náhled závisí na aktuálním motivu stroje.
$snapshotPath = if ($UpdateSnapshot) { Join-Path $repo '.build/previews/queue-theme-system.png' } else { Join-Path $testDir 'queue-theme-system.png' }
if ($UpdateSnapshot) { New-Item -ItemType Directory -Path (Split-Path $snapshotPath) -Force | Out-Null }
$output = [IO.File]::Create($snapshotPath)
try { $encoder.Save($output) } finally { $output.Dispose() }
$window.Close()
$view = [Tercet.QueueView]::new($copy)
$editable = [Windows.Window]::new()
$editable.Content = $view
$grid = $view.FindName('QueueGrid')
$inputs = @($grid.Children | Where-Object { $_ -is [Windows.Controls.DockPanel] } | ForEach-Object { $_.Children } | Where-Object { $_ -is [Windows.Controls.TextBox] })
Assert ($inputs.Count -eq $original.Rows().Count) 'Missing editor rows'
$inputs[0].Text = 'Edited through UI'
Assert ($copy.QueueItems()[0]['title'].GetValue[string]() -eq 'Edited through UI') 'Editor did not update copy'
Assert ($inputs[0].ToolTip -eq $inputs[0].Text) 'Tooltip did not follow edited title'
Assert ([Tercet.QueueDocument]::Parse($bytes).HasSameData($original)) 'Editor modified original'
# Strukturální operace: přípustné vztahy, hloubka, pořadí a odstranění.
$tree = $original.Clone()
$items = $tree.QueueItems()
$workshop = $items[0]; $backlog = $items[1]; $task101 = $items[2]; $fence = $items[15]; $garden = $items[14]
Assert ($tree.Depth($task101) -eq 2) 'Depth of third level'
Assert ($null -eq $tree.ParentOf($workshop)) 'Root item has no parent'
Assert ([object]::ReferenceEquals($tree.ParentOf($task101), $backlog)) 'Parent lookup'
Assert ($tree.CanInsertInto($null, 'group')) 'Root accepts group'
Assert (-not $tree.CanInsertInto($task101, 'task')) 'Task must stay a leaf'
Assert ($tree.CanInsertInto($fence, 'task')) 'Composite accepts task'
Assert (-not $tree.CanInsertInto($fence, 'group')) 'Composite rejects group'
$fence['situation'] = [Text.Json.Nodes.JsonValue]::Create('done')
Assert (-not $tree.CanInsertInto($fence, 'task')) 'Done composite rejects new task'
$fence['situation'] = [Text.Json.Nodes.JsonValue]::Create('inProgress')
Assert ($tree.CanInsertInto($workshop, 'group') -and -not $tree.CanInsertInto($backlog, 'group')) 'Group only on first two levels'
Reject { $tree.AppendChild($backlog, [Tercet.QueueDocument]::NewGroup('Third level group')) } ([InvalidOperationException])
# Celek na třetí úrovni vzniknout smí, ale potomky už mít nemůže.
$deep = [Tercet.QueueDocument]::NewTask('Deep composite')
$deep['kind'] = [Text.Json.Nodes.JsonValue]::Create('compositeTask')
$deep['children'] = [Text.Json.Nodes.JsonArray]::new()
$tree.AppendChild($backlog, $deep)
Assert ($tree.Depth($deep) -eq 2) 'Appended composite depth'
Assert (-not $tree.CanInsertInto($deep, 'task')) 'Fourth level rejected'
Reject { $tree.AppendChild($deep, [Tercet.QueueDocument]::NewTask('Too deep')) } ([InvalidOperationException])
Assert ($tree.Remove($deep) -eq 1) 'Removed empty composite count'
$sibling = [Tercet.QueueDocument]::NewTask('After 271')
$tree.InsertAfter($task101, $sibling)
Assert ([object]::ReferenceEquals($tree.QueueItems()[3], $sibling)) 'Sibling inserted after anchor'
Assert ($null -eq $sibling['assignee'] -and $sibling['situation'].GetValue[string]() -eq 'inactive') 'New task defaults'
# Převody typů: rozdělit lze každý úkol včetně třetí úrovně, sloučit jen celek bez částí.
$web = $tree.QueueItems()[7]
Assert ($web['title'].GetValue[string]() -eq 'Create a website' -and $tree.CanSplit($web)) 'Task on second level can split'
Assert ($tree.CanSplit($task101)) 'Third level task can split'
Assert (-not $tree.CanSplit($fence)) 'Composite cannot split'
Reject { $tree.SplitIntoParts($fence) } ([InvalidOperationException])
Assert (-not $tree.CanMerge($fence)) 'Composite with parts must not merge'
Reject { $tree.MergeIntoTask($fence) } ([InvalidOperationException])
$webId = $web['id'].GetValue[string]()
$tree.SplitIntoParts($web)
Assert ($web['kind'].GetValue[string]() -eq 'compositeTask' -and $web['children'].Count -eq 0 -and $web['id'].GetValue[string]() -eq $webId) 'Split keeps identity'
Assert ($tree.CanInsertInto($web, 'task') -and $tree.CanMerge($web)) 'Split composite accepts parts'
$tree.Validate()
$tree.MergeIntoTask($web)
Assert ($web['kind'].GetValue[string]() -eq 'task' -and -not $web.ContainsKey('children')) 'Merge removes children'
$tree.Validate()
# Posun mezi sourozenci: podstrom se přesune celý, okraj seznamu nic nemění.
Assert (-not $tree.CanMove($workshop, -1) -and $tree.CanMove($workshop, 1)) 'Move bounds at first root item'
Assert ($tree.TryMove($workshop, 1)) 'Move root group down'
$moved = $tree.QueueItems()
Assert ($moved[0]['title'].GetValue[string]() -eq 'Tercet' -and [object]::ReferenceEquals($moved[3], $workshop) -and [object]::ReferenceEquals($moved[4], $backlog)) 'Subtree moved as a whole'
Assert ($tree.TryMove($workshop, -1) -and [object]::ReferenceEquals($tree.QueueItems()[0], $workshop)) 'Move back up'
Assert (-not $tree.TryMove($workshop, -1)) 'Move past start rejected'
# Přesun k jinému rodiči: cyklus, strop tří úrovní, typ, dokončený celek, efekt.
$astronomy = $tree.QueueItems()[11]; $tools = $tree.QueueItems()[13]
Assert ($astronomy['title'].GetValue[string]() -eq 'Astronomy' -and $tools['title'].GetValue[string]() -eq 'Telescope tools') 'Move fixtures'
Assert ($tree.SubtreeHeight($task101) -eq 0 -and $tree.SubtreeHeight($backlog) -eq 1 -and $tree.SubtreeHeight($workshop) -eq 2) 'Subtree height'
Assert (-not $tree.CanMoveTo($task101, $backlog)) 'Current parent is not a target'
Assert (-not $tree.CanMoveTo($workshop, $workshop) -and -not $tree.CanMoveTo($workshop, $backlog)) 'Cycle rejected'
Assert (-not $tree.CanMoveTo($workshop, $astronomy)) 'Subtree over the depth limit rejected'
Assert ($tree.CanMoveTo($backlog, $astronomy) -and -not $tree.CanMoveTo($backlog, $tools)) 'Group height fits only under a root group'
Assert (-not $tree.CanMoveTo($backlog, $fence)) 'Group under composite rejected'
Assert ($tree.CanMoveTo($task101, $null) -and $tree.CanMoveTo($task101, $fence) -and -not $tree.CanMoveTo($task101, $sibling)) 'Task targets: root and composite, never a task'
$fence['situation'] = [Text.Json.Nodes.JsonValue]::Create('done')
foreach ($part in $fence['children']) { $part['situation'] = [Text.Json.Nodes.JsonValue]::Create('done') }
Assert (-not $tree.CanMoveTo($task101, $fence)) 'Undone task under done composite rejected'
Reject { $tree.MoveTo($task101, $fence) } ([InvalidOperationException])
# Pod hotový celek nesmí nehotová práce: hotový úkol tam smí.
$report = @($tree.QueueItems() | Where-Object { $_['title'].GetValue[string]() -eq 'Meeting notes' })[0]
Assert ($tree.IsCompleted($report) -and $tree.CanMoveTo($report, $fence)) 'Done task may move under done composite'
$fence['situation'] = [Text.Json.Nodes.JsonValue]::Create('inProgress')
foreach ($part in $fence['children']) { $part['situation'] = [Text.Json.Nodes.JsonValue]::Create('inactive') }
$targets = $tree.MoveTargets($task101)
Assert ($null -eq $targets[0] -and [object]::ReferenceEquals($targets[1], $workshop) -and -not ($targets | Where-Object { $null -ne $_ -and [object]::ReferenceEquals($_, $backlog) })) 'Targets: root first, queue order, current parent excluded'
Assert ($tree.PathOf($backlog) -eq 'Workshop › Backlog' -and $tree.PathOf($workshop) -eq 'Workshop') 'Target path'
$task101Id = $task101['id'].GetValue[string]()
$tree.MoveTo($task101, $fence)
Assert ([object]::ReferenceEquals($tree.ParentOf($task101), $fence) -and [object]::ReferenceEquals($fence['children'][-1], $task101)) 'Moved to the end of target children'
Assert ($tree.Depth($task101) -eq 2 -and $task101['id'].GetValue[string]() -eq $task101Id) 'Moved task keeps depth limit and identity'
Assert (-not ($backlog['children'] | Where-Object { [object]::ReferenceEquals($_, $task101) })) 'Moved task left old parent'
$tree.Validate()
# Zpět pod Workshop, aby pozdější odstranění skupiny Garden mělo stále čtyři položky.
$tree.MoveTo($task101, $workshop)
Assert ([object]::ReferenceEquals($workshop['children'][-1], $task101) -and $tree.Depth($task101) -eq 1) 'Moved back under root group'
$tree.MoveTo($backlog, $null)
$lastRoot = @($tree.QueueItems() | Where-Object { $null -eq $tree.ParentOf($_) })[-1]
Assert ([object]::ReferenceEquals($lastRoot, $backlog) -and $tree.Depth($backlog['children'][0]) -eq 1) 'Group moved to root with its subtree'
$tree.Validate()
$tree.AppendChild($null, [Tercet.QueueDocument]::NewGroup('Root group'))
Assert ($tree.QueueItems()[-1]['title'].GetValue[string]() -eq 'Root group') 'Root append at end'
Assert ($tree.Remove($garden) -eq 4) 'Subtree count on removal'
$tree.Validate()
Assert ($tree.Rows().Count -eq $tree.QueueItems().Count -and $tree.Rows().Count -eq 19) 'Rows after structural edits'
$store.Save($tree)
Assert ([Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes($path)).HasSameData($tree)) 'Structural save mismatch'
Assert ([Tercet.QueueDocument]::Parse($bytes).HasSameData($original)) 'Structural edits touched original'
'PASS: insert rules, order, removal count, structural roundtrip'
# Archivace a obnova nad vlastní kopií, aby neměnila počty výše.
$vault = $original.Clone()
$vaultItems = $vault.QueueItems()
$vWorkshop = $vaultItems[0]; $vReport = $vaultItems[4]; $vGarden = $vaultItems[14]; $vFence = $vaultItems[15]
$vPost = $vaultItems[16]; $vPaint = $vaultItems[17]; $vClassBooking = $vaultItems[18]
Assert ($vReport['title'].GetValue[string]() -eq 'Meeting notes' -and $vClassBooking['title'].GetValue[string]() -eq 'Book a class') 'Archive fixtures'
$entries = $vault.ArchiveEntries()
Assert ($entries.Count -eq 1 -and [Tercet.QueueDocument]::ArchivedItem($entries[0])['title'].GetValue[string]() -eq 'Repair the gate') 'Demo archive entry'
# Pojmenované prvky C# tuple (Parent, Index) existují jen při překladu; za běhu jsou to Item1/Item2.
$placement = $vault.RestorePlacement($entries[0])
Assert ([object]::ReferenceEquals($placement.Item1, $vGarden) -and $placement.Item2 -eq 1) 'Demo entry restores under Garden at index 1'
Assert (-not $vault.CanArchive($vWorkshop) -and -not $vault.CanArchive($vFence) -and $vault.CanArchive($vReport)) 'Only completed work archives'
Reject { $vault.Archive($vFence) } ([InvalidOperationException])
$vFence['situation'] = [Text.Json.Nodes.JsonValue]::Create('done')
Assert (-not $vault.CanArchive($vFence) -and -not $vault.IsCompleted($vFence)) 'Composite with an unfinished part cannot archive'
$vPaint['situation'] = [Text.Json.Nodes.JsonValue]::Create('done')
Assert ($vault.CanArchive($vFence) -and $vault.IsCompleted($vFence)) 'Completed composite archives'
$record = $vault.Archive($vFence)
Assert ($record['originalParentId'].GetValue[string]() -eq $vGarden['id'].GetValue[string]() -and $record['originalIndex'].GetValue[int]() -eq 0) 'Archive record position'
Assert ([object]::ReferenceEquals([Tercet.QueueDocument]::ArchivedItem($record), $vFence) -and $vFence['children'].Count -eq 2) 'Archived subtree kept'
Assert ($vault.ArchiveEntries().Count -eq 2 -and $vGarden['children'].Count -eq 0 -and $vault.QueueItems().Count -eq 18) 'Queue lost the subtree'
$vault.Validate()
# Původní index branky (1) přesahuje prázdné potomky skupiny Garden: vloží se na konec, tedy na 0.
$gate = $vault.Restore($vault.ArchiveEntries()[0])
Assert ($gate['title'].GetValue[string]() -eq 'Repair the gate' -and [object]::ReferenceEquals($vault.ParentOf($gate), $vGarden) -and $vGarden['children'].Count -eq 1) 'Gate restored under Garden'
Assert ($vault.ArchiveEntries().Count -eq 1 -and $gate['situation'].GetValue[string]() -eq 'done' -and $gate['children'].Count -eq 2) 'Restore keeps completion and parts'
# Plot se vrací na původní index 0, tedy před později obnovenou branku.
$restoredFence = $vault.Restore($record)
Assert ([object]::ReferenceEquals($vGarden['children'][0], $restoredFence) -and [object]::ReferenceEquals($vGarden['children'][1], $gate)) 'Original index restored ahead of later sibling'
Assert ($vault.ArchiveEntries().Count -eq 0 -and $vault.QueueItems().Count -eq 24) 'Archive emptied'
$vault.Validate()
Reject { $vault.Restore($record) } ([InvalidOperationException])
# Náhradní obnova do kořene: rodič zmizel (odstraněn), nebo už není celkem (sloučen na úkol).
$null = $vault.Archive($vFence)
$null = $vault.Remove($vGarden)
$roots = { @($vault.QueueItems() | Where-Object { $null -eq $vault.ParentOf($_) }) }
$placement = $vault.RestorePlacement($vault.ArchiveEntries()[0])
Assert ($null -eq $placement.Item1 -and $placement.Item2 -eq (& $roots).Count) 'Missing parent falls back to root end'
$restoredFence = $vault.Restore($vault.ArchiveEntries()[0])
Assert ($null -eq $vault.ParentOf($restoredFence) -and [object]::ReferenceEquals($vault.QueueItems()[-1], $vPaint)) 'Fallback appends subtree at root end'
$postRecord = $vault.Archive($vPost)
$null = $vault.Archive($vPaint)
Assert ($vault.CanMerge($restoredFence)) 'Composite empty after archiving parts'
$vault.MergeIntoTask($restoredFence)
Assert ($null -eq $vault.RestorePlacement($postRecord).Item1) 'Parent turned into a task falls back to root'
$post = $vault.Restore($postRecord)
Assert ($null -eq $vault.ParentOf($post) -and [object]::ReferenceEquals((& $roots)[-1], $post)) 'Part restored at root end'
$vault.Validate()
# Původní umístění v kořeni: originalParentId null, obnova na stejný index i po změně sourozenců.
$vClassBooking['situation'] = [Text.Json.Nodes.JsonValue]::Create('done')
$classBookingIndex = [array]::IndexOf((& $roots), $vClassBooking)
$classBookingRecord = $vault.Archive($vClassBooking)
Assert ($null -eq $classBookingRecord['originalParentId'] -and $classBookingRecord['originalIndex'].GetValue[int]() -eq $classBookingIndex) 'Root archive record'
$vault.InsertAfter((& $roots)[0], [Tercet.QueueDocument]::NewTask('Shifts the root order'))
$null = $vault.Restore($classBookingRecord)
Assert ([array]::IndexOf((& $roots), $vClassBooking) -eq $classBookingIndex) 'Root item restored at its original index'
$vault.Validate()
$store.Save($vault)
Assert ([Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes($path)).HasSameData($vault)) 'Archive save mismatch'
Assert ([Tercet.QueueDocument]::Parse($bytes).HasSameData($original)) 'Archive edits touched original'
'PASS: archive rules, record, restore to original index, fallbacks to root, roundtrip'
# Překreslení editoru z pracovní kopie po strukturální změně.
$copy.AppendChild($null, [Tercet.QueueDocument]::NewTask('Added through model'))
$view.Rebuild()
$collectInputs = { @($grid.Children | Where-Object { $_ -is [Windows.Controls.DockPanel] } | ForEach-Object { $_.Children } | Where-Object { $_ -is [Windows.Controls.TextBox] }) }
$inputs = & $collectInputs
Assert ($inputs.Count -eq $copy.QueueItems().Count -and $inputs[-1].Text -eq 'Added through model') 'Rebuild did not reflect copy'
Assert ($null -ne $inputs[0].ContextMenu) 'Structure menu missing on title'
# První řádek je skupina se SemiBold názvem; menu nesmí váhu písma zdědit.
Assert ($inputs[0].ContextMenu.FontWeight -eq [Windows.FontWeights]::Normal) 'Structure menu inherited bold font'
if ($CheckFocus) {
    # Skutečný keyboard focus vyžaduje zobrazené HWND; samotný RaiseEvent nestačí.
    $editable.Width = 266
    $editable.Height = 400
    $editable.ShowActivated = $true
    $editable.Show()
    $editable.Activate() | Out-Null
    foreach ($mode in 'Light','Dark') {
        $app.ThemeMode = [Windows.ThemeMode].GetProperty($mode).GetValue($null)
        $editable.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $editable.Activate() | Out-Null
        [Windows.Input.Keyboard]::Focus($inputs[0]) | Out-Null
        Assert $inputs[0].IsKeyboardFocused 'Real keyboard focus missing'
        $expected = $app.FindResource('TextControlForegroundFocused').ToString()
        Assert ($inputs[0].Foreground.ToString() -eq $expected) "Wrong focused text: $mode"
        Assert ($inputs[0].CaretBrush.ToString() -eq $expected) "Wrong caret: $mode"
        $border = $inputs[0].Template.FindName('ContentBorder', $inputs[0])
        Assert ($border.Background.ToString() -eq $app.FindResource('TextControlBackgroundFocused').ToString()) "Wrong focused background: $mode"
        "PASS: $mode focused text=$expected background=$($border.Background)"
        # Enter ukončí editaci názvu: KeyDown musí odebrat klávesový focus.
        $enter = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, [Windows.PresentationSource]::FromVisual($inputs[0]), 0, [Windows.Input.Key]::Enter)
        $enter.RoutedEvent = [Windows.Input.Keyboard]::KeyDownEvent
        $inputs[0].RaiseEvent($enter)
        Assert (-not $inputs[0].IsKeyboardFocused) "Enter did not end editing: $mode"
        [Windows.Input.Keyboard]::Focus($inputs[0]) | Out-Null
        Assert $inputs[0].IsKeyboardFocused 'Refocus after Enter'
        # Escape vrátí text platný při vstupu do pole, i v kopii, a ukončí editaci.
        $keptTitle = $inputs[0].Text
        $inputs[0].Text = 'Escaped edit'
        Assert ($copy.QueueItems()[0]['title'].GetValue[string]() -eq 'Escaped edit') 'Typing did not reach the copy'
        $escape = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, [Windows.PresentationSource]::FromVisual($inputs[0]), 0, [Windows.Input.Key]::Escape)
        $escape.RoutedEvent = [Windows.Input.Keyboard]::KeyDownEvent
        $inputs[0].RaiseEvent($escape)
        Assert ($inputs[0].Text -eq $keptTitle -and $copy.QueueItems()[0]['title'].GetValue[string]() -eq $keptTitle) "Escape did not restore the title: $mode"
        Assert (-not $inputs[0].IsKeyboardFocused) "Escape did not end editing: $mode"
        Assert $editable.IsVisible 'Escape closed the editor window'
        [Windows.Input.Keyboard]::Focus($inputs[0]) | Out-Null
        Assert $inputs[0].IsKeyboardFocused 'Refocus after Escape'
        $inputs[1].Focus() | Out-Null
        $editable.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        if (-not $inputs[0].IsMouseOver) {
            Assert ($inputs[0].Foreground.ToString() -eq $app.FindResource('TextOnAccentFillColorPrimaryBrush').ToString()) "Accent text not restored: $mode"
        }
    }
}
$editable.Close()
. (Join-Path $PSScriptRoot 'Check-QueueRegressions.ps1') -Bytes $bytes -TestDirectory $testDir -Assembly $assembly
. (Join-Path $PSScriptRoot 'Check-DataLocation.ps1') -Bytes $bytes -TestDirectory $testDir -Assembly $assembly
. (Join-Path $PSScriptRoot 'Check-TrayIcon.ps1') -Application $app -Bytes $bytes -TestDirectory $testDir -Assembly $assembly
. (Join-Path $PSScriptRoot 'Check-Blink.ps1') -Application $app -Bytes $bytes -TestDirectory $testDir -Assembly $assembly
. (Join-Path $PSScriptRoot 'Check-Recovery.ps1') -Application $app -Bytes $bytes -TestDirectory $testDir -Assembly $assembly -Review:$ReviewRecovery
. (Join-Path $PSScriptRoot 'Check-Sync.ps1') -Application $app -Bytes $bytes -TestDirectory $testDir -Assembly $assembly
. (Join-Path $PSScriptRoot 'Check-Backup.ps1') -Application $app -Bytes $bytes -TestDirectory $testDir -Assembly $assembly
'PASS: startup theme, opaque background, render, editor working copy'
# Dočasná data a náhledy PNG zůstanou jen na vyžádání (-KeepArtifacts), stejně
# jako u Check-Web; po selhání zůstávají vždy, protože skript skončí dřív
# Neúspěšný běh je ponechá k diagnostice.
if ($KeepArtifacts) {
    "Rendered preview: $snapshotPath"
    "Temporary test data: $testDir"
} else {
    Remove-Item -LiteralPath $testDir -Recurse -Force
    if ($UpdateSnapshot) { "Rendered preview: $snapshotPath" }
}
