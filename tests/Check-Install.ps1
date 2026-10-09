param([Parameter(Mandatory = $true)][string]$SourceDirectory, [switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Install-Tercet.ps1'
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action,[string]$Pattern) {
    $rejected = $false
    try { & $Action | Out-Null } catch {
        Assert ($_.Exception.Message -like $Pattern) "Unexpected rejection: $($_.Exception.Message)"
        $rejected = $true
    }
    Assert $rejected 'Expected installer rejection'
}
# Snímek obsahuje celou sadu souborů balíčku, včetně nepřítomnosti PDB.
# Manifest instalátor vytváří znovu; jeho čas není součástí payloadu.
function Get-PayloadHashes([string]$Directory) {
    $hashes = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Force | Where-Object Name -ne '.tercet-install.json') {
        $hashes[$file.Name] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    return $hashes
}
function Assert-Payload([string]$Directory, [hashtable]$Expected) {
    $actual = Get-PayloadHashes $Directory
    Assert ($actual.Count -eq $Expected.Count) 'Installed file set differs'
    foreach ($name in $Expected.Keys) {
        Assert ($actual.ContainsKey($name) -and $actual[$name] -ceq $Expected[$name]) "Installed file differs: $name"
    }
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Tercet-install-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $testRoot 'package'
$target = Join-Path $testRoot 'Programs/Tercet'
$startup = Join-Path $testRoot 'Startup'
$data = Join-Path $testRoot 'data'
[IO.Directory]::CreateDirectory($package) | Out-Null
[IO.Directory]::CreateDirectory($data) | Out-Null
foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -File) { [IO.File]::Copy($file.FullName,(Join-Path $package $file.Name)) }
$originalHashes = Get-PayloadHashes $package
$queuePath = Join-Path $data 'queue.json'
[IO.File]::WriteAllText($queuePath,'User data must survive installation unchanged.')
$queueHash = (Get-FileHash -LiteralPath $queuePath).Hash
$parameters = @{ SourceDirectory = $package; InstallDirectory = $target; StartupDirectory = $startup; DataDirectory = $data }
& $installer @parameters
$shortcutPath = Join-Path $startup 'Tercet.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
Assert ($shortcut.TargetPath -eq (Join-Path $target 'Tercet.exe')) 'Wrong startup executable'
Assert ($shortcut.WorkingDirectory -eq $target -and $shortcut.Arguments -eq '') 'Wrong startup arguments or directory'
Assert-Payload $target $originalHashes
$firstMarker = [IO.File]::ReadAllText((Join-Path $target '.tercet-install.json'))

# Další verzi rozliší doplňkové PDB, nikoli zásah do spustitelného kódu.
[IO.File]::WriteAllText((Join-Path $package 'Tercet.pdb'),'Second version test marker')
& $installer @parameters
$backups = @(Get-ChildItem -LiteralPath (Split-Path $target -Parent) -Directory -Filter 'Tercet.backup-*')
Assert ($backups.Count -eq 1) 'Upgrade did not preserve exactly one previous version'
Assert ([IO.File]::ReadAllText((Join-Path $backups[0].FullName '.tercet-install.json')) -ceq $firstMarker) 'Backup changed old installation'
Assert ([IO.File]::ReadAllText((Join-Path $target 'Tercet.pdb')) -ceq 'Second version test marker') 'Upgrade not applied'
# Návrat ze zálohy používá stejný instalátor a zachová i opouštěnou verzi.
& $installer -SourceDirectory $backups[0].FullName -InstallDirectory $target -StartupDirectory $startup -DataDirectory $data
Assert-Payload $target $originalHashes

$lease = [IO.File]::Open((Join-Path $data '.instance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try { Reject { & $installer @parameters } '*using this data folder*' } finally { $lease.Dispose() }
Assert-Payload $target $originalHashes

# Chyba při zápisu zástupce nastane až po výměně adresářů. Ověříme návrat
# předchozích bajtů, nikoli pouze výjimku instalátoru.
$shortcutBytes = [IO.File]::ReadAllBytes($shortcutPath)
[IO.File]::SetAttributes($shortcutPath,[IO.FileAttributes]::ReadOnly)
$failedBefore = @(Get-ChildItem -LiteralPath (Split-Path $target -Parent) -Directory -Filter 'Tercet.failed-*').Count
try { Reject { & $installer @parameters } '*' } finally { [IO.File]::SetAttributes($shortcutPath,[IO.FileAttributes]::Normal) }
Assert (@(Get-ChildItem -LiteralPath (Split-Path $target -Parent) -Directory -Filter 'Tercet.failed-*').Count -eq $failedBefore + 1) 'Failure did not reach post-swap rollback'
Assert-Payload $target $originalHashes
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($shortcutPath)) -ceq [Convert]::ToBase64String($shortcutBytes)) 'Failed update changed shortcut'

$foreign = Join-Path $testRoot 'Foreign'
[IO.Directory]::CreateDirectory($foreign) | Out-Null
[IO.File]::WriteAllText((Join-Path $foreign 'keep.txt'),'keep')
Reject { & $installer -SourceDirectory $package -InstallDirectory $foreign -StartupDirectory $startup -DataDirectory $data } '*not a managed Tercet installation*'
Assert ([IO.File]::ReadAllText((Join-Path $foreign 'keep.txt')) -ceq 'keep') 'Foreign target changed'
Reject { & $installer -SourceDirectory $package -InstallDirectory $data -StartupDirectory $startup -DataDirectory $data } '*must not overlap*'
$incomplete = Join-Path $testRoot 'incomplete'
[IO.Directory]::CreateDirectory($incomplete) | Out-Null
[IO.File]::WriteAllText((Join-Path $incomplete 'Tercet.exe'),'incomplete')
Reject { & $installer -SourceDirectory $incomplete -InstallDirectory $target -StartupDirectory $startup -DataDirectory $data } '*Incomplete package*'
Assert ((Get-FileHash -LiteralPath $queuePath).Hash -eq $queueHash) 'Installation touched user data'
'PASS: install, shortcut, upgrade, backup restore, busy refusal, rollback after shortcut failure, foreign target, overlapping paths, incomplete package, user data unchanged'
# Po úspěchu úklid, po selhání zůstává vše k diagnostice (vzor Check-Web).
if ($KeepArtifacts) { "Temporary installation tests: $testRoot" } else { Remove-Item -LiteralPath $testRoot -Recurse -Force }
