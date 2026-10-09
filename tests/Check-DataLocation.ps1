param([byte[]]$Bytes, [string]$TestDirectory, [Reflection.Assembly]$Assembly)
# Dílčí sada z Check-Editor: volba datového adresáře a jednorázový import
# dosavadních dat do LocalState balíčku nad dočasnými adresáři.
# Identita hostitele rozhoduje, která větev se tu měří: pwsh ze Storu
# (například MSIX `Microsoft.PowerShell_8wekyb3d8bbwe`)
# ji má, pwsh z MSI ne. Chování Tercetu s vlastní identitou (LocalState,
# žádná virtualizovaná kopie, zámek dosavadní složky) měří Check-Msix.ps1
# v kroku Launch a přijímá uživatel s balíčkem.

$legacy = Join-Path $env:LOCALAPPDATA 'Tercet'
Assert ([Tercet.DataLocation]::LegacyDirectory -ceq $legacy) "Legacy directory: $([Tercet.DataLocation]::LegacyDirectory)"
$expectedState = Join-Path $env:LOCALAPPDATA 'Packages\Tercet.Prototype_abc\LocalState'
Assert ([Tercet.DataLocation]::PackageStateDirectory('Tercet.Prototype_abc') -ceq $expectedState) 'LocalState path convention'
Assert ((@([Tercet.DataLocation]::DataFiles) -join ',') -ceq 'settings.json,queue.json.bak,queue.json') 'Queue must be imported last'
$family = [Tercet.DataLocation]::PackageFamilyName
if ($null -eq $family) {
    Assert (-not [Tercet.DataLocation]::IsPackaged) 'IsPackaged must follow the family name'
    Assert ([Tercet.DataLocation]::Resolve() -ceq $legacy) 'Unpackaged process must resolve to the legacy directory'
    'PASS: data location without package identity (host pwsh is not packaged)'
} else {
    # Rodinné jméno má tvar <Name>_<hash vydavatele>; LocalState musí sedět na něj.
    Assert ([Tercet.DataLocation]::IsPackaged) 'IsPackaged must follow the family name'
    Assert ($family -cmatch '^[^_]+_[a-z0-9]{13}$') "Unexpected package family name: $family"
    Assert ([Tercet.DataLocation]::Resolve() -ceq [Tercet.DataLocation]::PackageStateDirectory($family)) 'Packaged process must resolve to its LocalState'
    "PASS: data location with the package identity of the host ($family)"
}

# Zdroj importu: trojice dat podle názvu, cizí soubory nesou svůj název jako obsah.
function New-LegacyFolder([string]$name, [string[]]$files) {
    $folder = Join-Path $TestDirectory ('legacy-' + $name)
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    foreach ($file in $files) {
        $content = switch ($file) {
            'queue.json' { $Bytes }
            'queue.json.bak' { [Text.Encoding]::UTF8.GetBytes('{"backup":true}') }
            'settings.json' { [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"queueLink":null,"lastSyncedETag":null}') }
            default { [Text.Encoding]::UTF8.GetBytes($file) }
        }
        [IO.File]::WriteAllBytes((Join-Path $folder $file), $content)
    }
    return $folder
}
function Get-FileBase64([string]$path) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) }
function Get-FolderContents([string]$folder) {
    @(Get-ChildItem -LiteralPath $folder -File | Sort-Object Name | ForEach-Object { $_.Name + '=' + (Get-FileBase64 $_.FullName) }) -join ';'
}

# Plný import: trojice se převezme bajtově shodně, zámek ani záchranné kopie ne,
# zdroj zůstane beze změny a druhé volání už nic nepřebírá.
$extras = @('.instance.lock', 'queue.json.corrupt-20261007T000000000Z-0.json')
$source = New-LegacyFolder 'full' (@('queue.json', 'queue.json.bak', 'settings.json') + $extras)
$target = Join-Path $TestDirectory 'state-full'
$sourceBefore = Get-FolderContents $source
$imported = @([Tercet.DataLocation]::ImportLegacy($source, $target))
Assert (($imported -join ',') -ceq 'settings.json,queue.json.bak,queue.json') "Imported: $($imported -join ',')"
foreach ($name in $imported) {
    Assert ((Get-FileBase64 (Join-Path $target $name)) -ceq (Get-FileBase64 (Join-Path $source $name))) "Imported bytes differ: $name"
}
Assert (@(Get-ChildItem -LiteralPath $target -File).Count -eq 3) 'Lock and rescue copies must not be imported'
Assert ((Get-FolderContents $source) -ceq $sourceBefore) 'Import changed the source folder'
Assert ([Tercet.QueueDocument]::Parse([IO.File]::ReadAllBytes((Join-Path $target 'queue.json'))).HasSameData([Tercet.QueueDocument]::Parse($Bytes))) 'Imported queue does not load'
[IO.File]::WriteAllBytes((Join-Path $source 'queue.json'), [Text.Encoding]::UTF8.GetBytes('changed later'))
$targetAfter = Get-FolderContents $target
Assert (@([Tercet.DataLocation]::ImportLegacy($source, $target)).Count -eq 0) 'Second import must not run'
Assert ((Get-FolderContents $target) -ceq $targetAfter) 'Second import changed the target'
'PASS: import of queue, backup and settings; source untouched; no second import'

# Cíl s vlastním nastavením, ale bez fronty: import neběží, nic se nepřepíše.
$source = New-LegacyFolder 'partial-target' @('queue.json', 'queue.json.bak', 'settings.json')
$target = Join-Path $TestDirectory 'state-partial'
[IO.Directory]::CreateDirectory($target) | Out-Null
[IO.File]::WriteAllBytes((Join-Path $target 'settings.json'), [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"queueLink":"https://example.test/q","lastSyncedETag":null}'))
$targetBefore = Get-FolderContents $target
Assert (@([Tercet.DataLocation]::ImportLegacy($source, $target)).Count -eq 0) 'Target with own settings must not import'
Assert ((Get-FolderContents $target) -ceq $targetBefore) 'Import touched a target that already had data'

# Chybějící zdroj, zdroj jen s nastavením: nic se nepřebírá ani nezakládá.
foreach ($case in @(@{ Name = 'missing'; Files = $null }, @{ Name = 'settings-only'; Files = @('settings.json') })) {
    $source = if ($null -eq $case.Files) { Join-Path $TestDirectory 'legacy-missing' } else { New-LegacyFolder $case.Name $case.Files }
    $target = Join-Path $TestDirectory ('state-' + $case.Name)
    Assert (@([Tercet.DataLocation]::ImportLegacy($source, $target)).Count -eq 0) "Import ran for $($case.Name)"
    Assert (-not (Test-Path -LiteralPath $target)) "Import created a target for $($case.Name)"
}

# Jen záloha: převezme se sama, obnovu pak nabídne běžný start.
$source = New-LegacyFolder 'backup-only' @('queue.json.bak')
$target = Join-Path $TestDirectory 'state-backup-only'
Assert ((@([Tercet.DataLocation]::ImportLegacy($source, $target)) -join ',') -ceq 'queue.json.bak') 'Backup-only import'
'PASS: no import for a target with data, a missing source or settings alone; backup alone is taken over'

# Chyba uprostřed: adresář jménem queue.json v cíli zablokuje poslední kopii;
# dříve zkopírované nastavení a záloha musí zmizet a chyba se předat dál.
$source = New-LegacyFolder 'blocked' @('queue.json', 'queue.json.bak', 'settings.json')
$target = Join-Path $TestDirectory 'state-blocked'
[IO.Directory]::CreateDirectory((Join-Path $target 'queue.json')) | Out-Null
$failure = $null
try { $null = [Tercet.DataLocation]::ImportLegacy($source, $target) } catch {
    $failure = $_.Exception
    while (($failure -is [Management.Automation.RuntimeException] -or $failure -is [Reflection.TargetInvocationException]) -and $null -ne $failure.InnerException) {
        $failure = $failure.InnerException
    }
}
Assert ($failure -is [IO.IOException] -or $failure -is [UnauthorizedAccessException]) "Expected an access error, got: $failure"
Assert (-not (Test-Path -LiteralPath (Join-Path $target 'settings.json')) -and -not (Test-Path -LiteralPath (Join-Path $target 'queue.json.bak'))) 'Failed import left partial copies'
Assert ((Get-FolderContents $source) -ceq (Get-FolderContents (New-LegacyFolder 'blocked-reference' @('queue.json', 'queue.json.bak', 'settings.json')))) 'Failed import changed the source'
'PASS: failed import removes partial copies and reports the error'
