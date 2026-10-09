param(
    [string]$WixPath = (Join-Path $PSScriptRoot '../.build/wix5-tools/wix.exe'),
    [switch]$KeepArtifacts
)
$ErrorActionPreference = 'Stop'
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Tercet-shortcuts-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$namespace = 'http://wixtoolset.org/schemas/v4/wxs'
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../installer/Package.wxs'))
$upgradeCode = [guid]::NewGuid().ToString('B')
$componentCode = [guid]::NewGuid().ToString('B')
$registryKey = 'Software\TercetTests\' + [guid]::NewGuid().ToString('N')
$products = @([guid]::NewGuid().ToString('B'), [guid]::NewGuid().ToString('B'))
$engine = New-Object -ComObject WindowsInstaller.Installer
$shell = New-Object -ComObject WScript.Shell

# Skutecny MSI lifecycle, ale s vlastni identitou, registrem a adresari.
# Zachovavame produkcni komponentu zastupcu, key path a poradi MajorUpgrade.
# Stary balicek se lisi jen verzi a dosavadnim jmenem Tercet.
function New-TestPackage([int]$Index) {
    [xml]$xml = $template
    $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('w', $namespace)
    $package = $xml.Wix.Package
    $package.SetAttribute('Name', 'Tercet isolated shortcut check')
    $package.SetAttribute('Version', "$($Index + 1).0.0")
    $package.SetAttribute('UpgradeCode', $upgradeCode)
    $package.SetAttribute('ProductCode', $products[$Index])
    $component = $xml.SelectSingleNode('//w:Component', $ns)
    $component.SetAttribute('Guid', $componentCode)
    $component.RegistryValue.SetAttribute('Key', $registryKey)
    foreach ($shortcut in $component.Shortcut) {
        Assert ($shortcut.Name -ceq 'Tercet Preview') 'Source must use the new shortcut name'
        if ($Index -eq 0) { $shortcut.SetAttribute('Name', 'Tercet') }
    }
    # Nahrazujeme standardni slozky Windows vlastnim stromem pod TEMP.
    # Zadny zastupce se nedostane do opravdoveho Startu ani Startup.
    $root = $xml.CreateElement('StandardDirectory', $namespace)
    $root.SetAttribute('Id', 'TARGETDIR')
    $sandbox = $xml.CreateElement('Directory', $namespace)
    $sandbox.SetAttribute('Id', 'TESTROOT')
    $sandbox.SetAttribute('Name', 'Sandbox')
    $null = $root.AppendChild($sandbox)
    foreach ($original in @($package.SelectNodes('w:StandardDirectory', $ns))) {
        $directory = $xml.CreateElement('Directory', $namespace)
        $directory.SetAttribute('Id', $original.Id)
        $directory.SetAttribute('Name', $original.Id)
        foreach ($child in @($original.ChildNodes)) { $null = $directory.AppendChild($child.CloneNode($true)) }
        $null = $sandbox.AppendChild($directory)
        $null = $package.RemoveChild($original)
    }
    $null = $package.AppendChild($root)
    # Standardni Id by Windows dosadil skutecnou cestou z profilu a WiX
    # by navic pripojil vlastni symbol. Prejmenujeme i vsechny reference.
    foreach ($attribute in $xml.SelectNodes('//@*')) {
        if ($attribute.Value -in @('LocalAppDataFolder', 'ProgramMenuFolder', 'StartupFolder') -and $attribute.Name -ne 'Name') {
            $attribute.Value = 'Test' + $attribute.Value
        }
    }
    $property = $xml.CreateElement('Property', $namespace)
    $property.SetAttribute('Id', 'TESTROOT')
    $property.SetAttribute('Value', (Join-Path $testRoot 'installed'))
    $null = $package.AppendChild($property)
    # Prazdny payload: kontrolujeme instalator, zadny Tercet se nespousti.
    $ref = $xml.SelectSingleNode('//w:ComponentGroupRef', $ns)
    $null = $ref.ParentNode.RemoveChild($ref)
    $source = Join-Path $testRoot "$Index.wxs"
    $xml.Save($source)
    $msi = Join-Path $testRoot "$Index.msi"
    & $WixPath build $source -arch x64 -o $msi -pdbtype none | Out-Host
    Assert ($LASTEXITCODE -eq 0) 'Test MSI build failed'
    return $msi
}

# Return code nestaci: volajici vzdy kontroluje skutecne zmeny souboru
# i ProductState. Logy zustavaji pri selhani pro diagnostiku.
function Invoke-Msi([string]$Operation, [string]$Target, [string]$Label) {
    $log = Join-Path $testRoot "$Label.log"
    $process = Start-Process msiexec.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        $Operation, ('"' + $Target + '"'), '/qn', 'REBOOT=ReallySuppress', '/l*v', ('"' + $log + '"'))
    if (-not $process.WaitForExit(60000)) { throw "MSI timed out: $log" }
    Assert ($process.ExitCode -eq 0) "MSI failed ($($process.ExitCode)): $log"
}
function Assert-Shortcuts([string]$Name) {
    $links = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'installed') -Filter '*.lnk' -Recurse)
    Assert ($links.Count -eq 2) "Expected two shortcuts, found $($links.Count)"
    foreach ($link in $links) {
        Assert ($link.BaseName -ceq $Name) "Unexpected remaining shortcut: $($link.FullName)"
        $shortcut = $shell.CreateShortcut($link.FullName)
        $expected = Join-Path $testRoot 'installed/LocalAppDataFolder/Programs/Tercet/Tercet.exe'
        Assert ($shortcut.TargetPath -ieq $expected) 'Shortcut points outside the isolated installation'
    }
}

$passed = $false
try {
    $old = New-TestPackage 0
    $current = New-TestPackage 1
    # Data mimo instalacni strom modeluji oddelenou frontu. Hash musi prezit
    # instalaci, upgrade i uninstall, jako skutecna nespravovana data Tercetu.
    $data = Join-Path $testRoot 'queue.json'
    [IO.File]::WriteAllText($data, '{"sentinel":"keep"}')
    $hash = (Get-FileHash -LiteralPath $data).Hash
    Invoke-Msi '/i' $old 'install-old'
    Assert ($engine.ProductState($products[0]) -eq 5) 'Old product was not installed'
    Assert-Shortcuts 'Tercet'
    Invoke-Msi '/i' $current 'upgrade'
    Assert ($engine.ProductState($products[0]) -eq -1) 'Old product remains registered'
    Assert ($engine.ProductState($products[1]) -eq 5) 'New product was not installed'
    Assert-Shortcuts 'Tercet Preview'
    Assert ((Get-FileHash -LiteralPath $data).Hash -ceq $hash) 'Upgrade changed separate data'
    Invoke-Msi '/x' $products[1] 'uninstall'
    Assert ($engine.ProductState($products[1]) -eq -1) 'New product remains registered after uninstall'
    $remaining = @(Get-ChildItem -LiteralPath $testRoot -Filter '*.lnk' -Recurse)
    Assert ($remaining.Count -eq 0) 'Uninstall left a shortcut'
    Assert (-not (Test-Path -LiteralPath "HKCU:\$registryKey")) 'Uninstall left the test registry key'
    Assert ((Get-FileHash -LiteralPath $data).Hash -ceq $hash) 'Uninstall changed separate data'
    $passed = $true
    'PASS: real MSI upgrade Tercet -> Tercet Preview; old registration/links removed, new targets correct, uninstall cleans links and registry, separate data preserved'
} finally {
    # I pri selhani uklizime jen sve dve presne zname identity.
    foreach ($product in $products) {
        if ($engine.ProductState($product) -ne -1) { Invoke-Msi '/x' $product ('cleanup-' + $product.Trim('{}')) }
    }
    foreach ($com in @($shell, $engine)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) }
    if ($passed -and -not $KeepArtifacts) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        Assert ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) 'Cleanup path is outside TEMP'
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else { "Shortcut check artifacts: $testRoot" }
}
