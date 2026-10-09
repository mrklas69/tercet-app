[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PayloadDirectory,
    [string]$PackageVersion,
    # Nástroje a payloady leží v ignorovaném .build/ v kořeni repa, ne v obj/
    # (výstup buildu, který se maže).
    [string]$WixPath = (Join-Path $PSScriptRoot '../.build/wix5-tools/wix.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../publish/testers')
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$payload = (Get-Item -LiteralPath $PayloadDirectory).FullName.TrimEnd('\')
$output = [IO.Path]::GetFullPath($OutputDirectory)
# Verzi bereme z hotového payloadu, ne z csproj, který už mohl mezitím
# změnit někdo jiný. ProductVersion odpovídá InformationalVersion v editoru;
# část za + je metadata sestavení (hash commitu), nikoli číslo vydání.
$payloadVersion = ([string][Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $payload 'Tercet.dll')).ProductVersion).Split('+')[0]
if ($payloadVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'The payload must have a three-part release version.' }
# Volitelný parametr je jen kontrola očekávání. Nesoulad odmítneme ještě
# před kopírováním licencí, vytvářením výstupu nebo spuštěním WiX.
if ($PSBoundParameters.ContainsKey('PackageVersion') -and $PackageVersion -cne $payloadVersion) {
    throw "Package version $PackageVersion does not match payload version $payloadVersion."
}
$PackageVersion = $payloadVersion
$version = [version]$PackageVersion
if ($version.Major -gt 255 -or $version.Minor -gt 255 -or $version.Build -gt 65535) { throw 'Version exceeds MSI limits.' }
$runtime = Get-Content -LiteralPath (Join-Path $payload 'Tercet.runtimeconfig.json') -Raw | ConvertFrom-Json
if (-not $runtime.runtimeOptions.includedFrameworks) { throw 'Publish a self-contained package first.' }
# Publish licenční texty runtime nekopíruje. Přidáme originály z přesně té
# verze NuGet balíčků, kterou zaznamenal runtimeconfig, nikoli z jiné instalace.
# Pozor, kopírují se DO VSTUPNÍHO payloadu (vedlejší účinek na vstup): MSI
# a Check-Installer pak porovnávají payload včetně `licenses/`, proto
# Check-InstallerVersions pracuje nad vlastní kopií.
$nugetRoot = $env:NUGET_PACKAGES
if (-not $nugetRoot) { $nugetRoot = Join-Path $env:USERPROFILE '.nuget/packages' }
$licenseDirectory = Join-Path $payload 'licenses'
New-Item -ItemType Directory -Path $licenseDirectory -Force | Out-Null
# Veřejný strom má licenci v kořeni; vývojový strom drží tutéž předlohu
# v distribution/public. Export ji kopíruje beze změny jako LICENSE.
$applicationLicense = Join-Path $repo 'LICENSE'
if (-not (Test-Path -LiteralPath $applicationLicense)) { $applicationLicense = Join-Path $repo 'distribution/public/LICENSE' }
Copy-Item -LiteralPath $applicationLicense -Destination (Join-Path $licenseDirectory 'Tercet-LICENSE.txt')
foreach ($framework in $runtime.runtimeOptions.includedFrameworks) {
    $package = Join-Path $nugetRoot ($framework.name.ToLowerInvariant() + '.runtime.win-x64/' + $framework.version)
    $licenseFiles = @(Get-ChildItem -LiteralPath $package -File | Where-Object { $_.Name -in @('LICENSE', 'LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT') })
    if (-not $licenseFiles) { throw "Runtime license not found: $package" }
    foreach ($licenseFile in $licenseFiles) {
        Copy-Item -LiteralPath $licenseFile.FullName -Destination (Join-Path $licenseDirectory ($framework.name + '-' + $licenseFile.Name))
    }
}
foreach ($name in @('Tercet.exe', 'Tercet.dll', 'coreclr.dll', 'PresentationFramework.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $payload $name) -PathType Leaf)) { throw "Missing payload file: $name" }
}
$wixVersion = & $WixPath --version
if ($LASTEXITCODE -ne 0 -or $wixVersion -notlike '5.0.2+*') { throw 'This build requires WiX 5.0.2.' }
New-Item -ItemType Directory -Path $output -Force | Out-Null
$msiPath = Join-Path $output "Tercet-$PackageVersion-win-x64.msi"
if (Test-Path -LiteralPath $msiPath) { throw "Output already exists: $msiPath" }
$work = Join-Path $repo ('src/Tercet/obj/msi-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
# Pracovní adresář (generované WXS, mezivýstupy WiX, ~56 MB) se po sestavení
# vždy odstraní, stejně jako u Build-Msix.ps1.
try {

# Každý soubor má stabilní component ID. HKCU key path je nutná pro správnou
# opravu instalace v uživatelském profilu (Windows Installer ICE38).
$xml = [xml]'<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs"><Fragment /></Wix>'
function Add-Element($Parent, [string]$Name, [hashtable]$Attributes) {
    $element = $xml.CreateElement($Name, $xml.DocumentElement.NamespaceURI)
    foreach ($key in $Attributes.Keys) { $element.SetAttribute($key, [string]$Attributes[$key]) }
    [void]$Parent.AppendChild($element)
    return $element
}
function Get-StableId([string]$Prefix, [string]$RelativePath) {
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($RelativePath.ToLowerInvariant()))
    return $Prefix + [Convert]::ToHexString($hash).Substring(0, 24)
}
# WiX neumí automatické GUID pro kombinaci souboru a registry key path.
# Vlastní jmenný prostor a relativní cesta drží GUID stejné napříč upgrady.
function Get-ComponentGuid([string]$RelativePath) {
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('Tercet.PerUser.x64/' + $RelativePath.ToLowerInvariant()))
    $bytes = [byte[]]$hash[0..15]
    $bytes[7] = ($bytes[7] -band 15) -bor 128
    $bytes[8] = ($bytes[8] -band 63) -bor 128
    return [guid]::new($bytes).ToString()
}
$fragment = $xml.DocumentElement.FirstChild
$root = Add-Element $fragment 'DirectoryRef' @{ Id = 'INSTALLFOLDER' }
$group = Add-Element $fragment 'ComponentGroup' @{ Id = 'AppPayload' }
$directories = @{ '' = $root }
function Get-PayloadDirectory([string]$RelativePath) {
    if ($directories.ContainsKey($RelativePath)) { return $directories[$RelativePath] }
    $parentPath = [IO.Path]::GetDirectoryName($RelativePath)
    if ($null -eq $parentPath) { $parentPath = '' }
    $parent = Get-PayloadDirectory $parentPath
    $directory = Add-Element $parent 'Directory' @{ Id = (Get-StableId 'D' $RelativePath); Name = [IO.Path]::GetFileName($RelativePath) }
    $directories[$RelativePath] = $directory
    return $directory
}
$removedDirectories = @{}
$entries = @(Get-ChildItem -LiteralPath $payload -Recurse)
if ($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Payload must not contain reparse points.' }
$files = @($entries | Where-Object { -not $_.PSIsContainer -and $_.Extension -ne '.pdb' } | Sort-Object FullName)
foreach ($file in $files) {
    $relative = $file.FullName.Substring($payload.Length + 1)
    $directoryPath = [IO.Path]::GetDirectoryName($relative)
    if ($null -eq $directoryPath) { $directoryPath = '' }
    $directory = Get-PayloadDirectory $directoryPath
    $id = Get-StableId 'C' $relative
    $component = Add-Element $directory 'Component' @{ Id = $id; Guid = (Get-ComponentGuid $relative) }
    $null = Add-Element $component 'RegistryValue' @{ Root = 'HKCU'; Key = 'Software\Tercet\Installer\Files'; Name = $id; Type = 'integer'; Value = '1'; KeyPath = 'yes' }
    $null = Add-Element $component 'File' @{ Id = (Get-StableId 'F' $relative); Source = $file.FullName }
    if (-not $removedDirectories.ContainsKey($directoryPath)) {
        $null = Add-Element $component 'RemoveFolder' @{ Id = (Get-StableId 'R' $directoryPath); On = 'uninstall' }
        $removedDirectories[$directoryPath] = $true
    }
    $null = Add-Element $group 'ComponentRef' @{ Id = $id }
}
$generated = Join-Path $work 'Payload.wxs'
$xml.Save($generated)
& $WixPath build (Join-Path $repo 'installer/Package.wxs') $generated -arch x64 -d "PackageVersion=$PackageVersion" -o $msiPath -pdbtype none -intermediatefolder $work
if ($LASTEXITCODE -ne 0) { throw "WiX build failed: $LASTEXITCODE" }

} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
$hash = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash
[IO.File]::WriteAllText($msiPath + '.sha256', "$hash  $([IO.Path]::GetFileName($msiPath))`n")
Copy-Item -LiteralPath (Join-Path $repo 'installer/README.txt') -Destination (Join-Path $output 'README.txt')
Write-Output "Installer: $msiPath"
Write-Output "Payload files: $($files.Count)"
Write-Output "SHA256: $hash"
