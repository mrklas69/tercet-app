param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][string]$PayloadDirectory,
    # Volající test (Check-InstallerVersions) dá pracovní adresář dovnitř svého,
    # aby i záměrně selhávající běh uklidil s sebou; jinak vlastní v TEMP.
    [string]$WorkDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('Tercet-msi-' + [guid]::NewGuid().ToString('N'))),
    [switch]$KeepArtifacts
)
$ErrorActionPreference = 'Stop'
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$msi = (Get-Item -LiteralPath $InstallerPath).FullName
$payload = (Get-Item -LiteralPath $PayloadDirectory).FullName.TrimEnd('\')
$testRoot = [IO.Path]::GetFullPath($WorkDirectory)
New-Item -ItemType Directory -Path $testRoot | Out-Null

# Čteme skutečné tabulky MSI. Kontrola zdrojového XML by neodhalila chybu
# při sestavení a netestovala by balíček, který dostane tester.
$engine = New-Object -ComObject WindowsInstaller.Installer
$database = $engine.OpenDatabase($msi, 0)
function Read-Rows([string]$Query, [int]$ColumnCount) {
    $view = $database.OpenView($Query)
    $null = $view.Execute()
    while ($record = $view.Fetch()) {
        $values = @()
        for ($column = 1; $column -le $ColumnCount; $column++) { $values += $record.StringData($column) }
        ,$values
    }
    $null = $view.Close()
}
$properties = @{}
foreach ($row in (Read-Rows 'SELECT `Property`, `Value` FROM `Property`' 2)) { $properties[$row[0]] = $row[1] }
Assert (-not $properties['ALLUSERS']) 'MSI is not per-user'
Assert ($properties['ProductName'] -ceq 'Tercet Preview') 'Wrong preview product name'
Assert ($properties['REBOOT'] -eq 'ReallySuppress') 'MSI can restart Windows'
Assert ($properties['MSIRESTARTMANAGERCONTROL'] -eq 'Disable') 'MSI can close the editor automatically'
$shortcuts = @(Read-Rows 'SELECT `Directory_`, `Target`, `WkDir`, `Name` FROM `Shortcut`' 4)
Assert ($shortcuts.Count -eq 2) 'Expected two shortcuts'
foreach ($row in $shortcuts) {
    Assert ($row[0] -in @('StartupFolder', 'TercetMenuFolder')) 'Unexpected shortcut location'
    # MSI ukládá krátké a dlouhé jméno jako short|long; kontrolujeme viditelný název.
    Assert ($row[3].Split('|')[-1] -ceq 'Tercet Preview') 'Wrong preview shortcut name'
    Assert ($row[1] -eq '[INSTALLFOLDER]Tercet.exe' -and $row[2] -eq 'INSTALLFOLDER') 'Wrong shortcut target'
}
foreach ($row in (Read-Rows 'SELECT `Root`, `Key` FROM `Registry`' 2)) {
    Assert ($row[0] -eq '1' -and $row[1] -like 'Software\Tercet\Installer*') 'MSI modifies unrelated registry data'
}
foreach ($row in (Read-Rows 'SELECT `FileName`, `DirProperty`, `InstallMode` FROM `RemoveFile`' 3)) {
    Assert ($row[0] -eq '' -and $row[2] -eq '2') 'Uninstall must only remove empty directories explicitly'
}
$tableFiles = @(Read-Rows 'SELECT `FileName` FROM `File`' 1)
foreach ($row in $tableFiles) { Assert ($row[0] -notmatch 'queue\.json|instance\.lock') 'User data is included in MSI' }
# Uvolnění COM objektů zavře handle MSI. Bez toho ho držel i volající skript
# (Check-InstallerVersions běží in-process) a úklid výstupu selhal na
# „používá jiný proces". GC posbírá i obaly View/Record.
foreach ($comObject in @($database, $engine)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject) }
$database = $null; $engine = $null
[GC]::Collect(); [GC]::WaitForPendingFinalizers()

# Administrativní rozbalení nezaregistruje aplikaci ani nevymění provozní
# instalaci. Ověříme každý rozbalený soubor proti vstupu přes SHA256.
$extract = Join-Path $testRoot 'extracted'
$log = Join-Path $testRoot 'extract.log'
$process = Start-Process msiexec.exe -ArgumentList @('/a', ('"' + $msi + '"'), '/qn', ('TARGETDIR="' + $extract + '"'), '/l*v', ('"' + $log + '"')) -WindowStyle Hidden -PassThru
if (-not $process.WaitForExit(60000)) { throw "MSI extraction timed out; log: $log" }
Assert ($process.ExitCode -eq 0) "MSI extraction failed ($($process.ExitCode)); log: $log"
$executables = @(Get-ChildItem -LiteralPath $extract -Filter Tercet.exe -Recurse -File)
Assert ($executables.Count -eq 1) 'Expected exactly one extracted Tercet.exe'
$application = $executables[0].DirectoryName
# Porovnáváme metadata opravdu rozbalené DLL s tabulkou hotového MSI.
# Kontrola vstupního parametru builderu by nezachytila cizí či starý balíček.
$applicationVersion = ([string][Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $application 'Tercet.dll')).ProductVersion).Split('+')[0]
Assert ($properties['ProductVersion'] -ceq $applicationVersion) "MSI version $($properties['ProductVersion']) differs from application version $applicationVersion"
$files = @(Get-ChildItem -LiteralPath $payload -Recurse -File | Where-Object Extension -ne '.pdb')
Assert ($files.Count -eq $tableFiles.Count) 'MSI file count differs from payload'
foreach ($file in $files) {
    $relative = $file.FullName.Substring($payload.Length + 1)
    $actual = Join-Path $application $relative
    Assert (Test-Path -LiteralPath $actual -PathType Leaf) "Missing extracted file: $relative"
    Assert ((Get-FileHash -LiteralPath $actual).Hash -eq (Get-FileHash -LiteralPath $file.FullName).Hash) "Extracted file differs: $relative"
}
$runtime = Get-Content -LiteralPath (Join-Path $application 'Tercet.runtimeconfig.json') -Raw | ConvertFrom-Json
Assert ($runtime.runtimeOptions.includedFrameworks.Count -eq 2) 'Desktop runtime is not bundled'
Assert (Test-Path -LiteralPath (Join-Path $application 'licenses/Tercet-LICENSE.txt') -PathType Leaf) 'Tercet license is not bundled'
Write-Output "PASS MSI version $applicationVersion, per-user, shortcuts, registry scope, empty-folder removal, $($files.Count) extracted file hashes, bundled runtime"
# Po úspěchu úklid rozbaleného balíčku, po selhání zůstává k diagnostice (vzor Check-Web).
if ($KeepArtifacts) {
    Write-Output "Extracted executable: $($executables[0].FullName)"
    Write-Output "Diagnostic files: $testRoot"
} else {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
