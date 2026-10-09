param(
    [Parameter(Mandatory)][string]$PayloadDirectory,
    [string]$WixPath = (Join-Path $PSScriptRoot '../.build/wix5-tools/wix.exe'),
    [switch]$KeepArtifacts
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$builder = Join-Path $repo 'scripts/Build-Installer.ps1'
$checker = Join-Path $PSScriptRoot 'Check-Installer.ps1'
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Pattern) {
    $rejected = $false
    try { & $Action | Out-Null } catch {
        Assert ($_.Exception.Message -like $Pattern) "Unexpected failure: $($_.Exception.Message)"
        $rejected = $true
    }
    Assert $rejected 'Expected version rejection'
}

# Builder přidává licence: i vstup proto musí být naše kopie. Test nic
# neinstaluje, nový MSI jen administrativně rozbalí do další složky TEMP.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Tercet-version-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$payload = Join-Path $testRoot 'payload'
Copy-Item -LiteralPath (Get-Item -LiteralPath $PayloadDirectory).FullName -Destination $payload -Recurse
$expectedVersion = ([string][Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $payload 'Tercet.dll')).ProductVersion).Split('+')[0]
$output = Join-Path $testRoot 'output'
$wrongVersions = @(@('0.0.0', '255.255.65535') | Where-Object { $_ -cne $expectedVersion })
foreach ($wrongVersion in $wrongVersions) {
    # Neexistující WiX odhalí pokus pokračovat po nesouladu. Nevznikne ani
    # výstupní adresář; správná chyba musí přijít ještě před sestavováním.
    Reject { & $builder -PayloadDirectory $payload -PackageVersion $wrongVersion -WixPath (Join-Path $testRoot 'missing-wix.exe') -OutputDirectory $output } '*does not match payload version*'
    Assert (-not (Test-Path -LiteralPath $output)) 'Version mismatch created output'
}
& $builder -PayloadDirectory $payload -WixPath $WixPath -OutputDirectory $output
$msi = Join-Path $output "Tercet-$expectedVersion-win-x64.msi"
Assert (Test-Path -LiteralPath $msi -PathType Leaf) 'Automatic version produced the wrong filename'
& $checker -InstallerPath $msi -PayloadDirectory $payload -WorkDirectory (Join-Path $testRoot 'check-good') -KeepArtifacts:$KeepArtifacts
# Explicitní správná verze projde kontrolou shody až k ochraně před
# přepsáním téhož výstupu; kvůli tomu nesestavujeme druhou totožnou MSI.
Reject { & $builder -PayloadDirectory $payload -PackageVersion $expectedVersion -WixPath $WixPath -OutputDirectory $output } '*Output already exists*'

# Změníme Property ve vlastní kopii hotového MSI, nikoli v produkčním
# balíčku. Tím ověříme, že kontrola odhalí i balíček vytvořený mimo builder.
$badMsi = Join-Path $testRoot 'mismatched.msi'
Copy-Item -LiteralPath $msi -Destination $badMsi
$engine = New-Object -ComObject WindowsInstaller.Installer
$database = $engine.OpenDatabase($badMsi, 1)
$query = 'UPDATE `Property` SET `Value` = ? WHERE `Property` = ''ProductVersion'''
$view = $database.OpenView($query)
$record = $engine.CreateRecord(1)
$record.StringData(1) = $wrongVersions[0]
try { $null = $view.Execute($record); $null = $view.Close(); $null = $database.Commit() }
finally {
    # Uvolnění COM objektů zavře zápisový handle před administrativním čtením.
    foreach ($comObject in @($record, $view, $database, $engine)) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
    }
}
# Záměrné selhání: Check-Installer svůj adresář po chybě nemaže, proto leží
# uvnitř $testRoot a uklidí se s ním.
Reject { & $checker -InstallerPath $badMsi -PayloadDirectory $payload -WorkDirectory (Join-Path $testRoot 'check-bad') -KeepArtifacts:$KeepArtifacts } '*differs from application version*'
'PASS: automatic MSI version, explicit match, mismatches rejected before build and in a completed MSI'
# Po úspěchu úklid, po selhání zůstává vše k diagnostice (vzor Check-Web).
if ($KeepArtifacts) { "Temporary version tests: $testRoot" } else { Remove-Item -LiteralPath $testRoot -Recurse -Force }
