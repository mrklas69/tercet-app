[CmdletBinding()]
param(
    # Adresář s hotovým self-contained publish výstupem (např. administrativně
    # rozbalené MSI). Bajty payloadu se nemění, verdikt SAC tedy zůstává stejný.
    [Parameter(Mandatory)][string]$PayloadDirectory,
    # Adresář s makeappx.exe a signtool.exe (bin\<verze>\x64 z NuGet balíčku
    # Microsoft.Windows.SDK.BuildTools; postup v installer/README.md).
    [Parameter(Mandatory)][string]$ToolsDirectory,
    # Otisk (thumbprint) podpisového certifikátu v Cert:\CurrentUser\My.
    # Jeho Subject se stane Publisher v manifestu; manifest a podpis musí sedět.
    [Parameter(Mandatory)][string]$CertificateThumbprint,
    # Výstup do ignorovaného .build/ v kořeni repa, ne do obj/.
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../.build/msix')
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$payload = (Get-Item -LiteralPath $PayloadDirectory).FullName.TrimEnd('\')
$tools = (Get-Item -LiteralPath $ToolsDirectory).FullName.TrimEnd('\')
$output = [IO.Path]::GetFullPath($OutputDirectory)

foreach ($tool in @('makeappx.exe', 'signtool.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $tools $tool) -PathType Leaf)) { throw "Missing tool: $tool in $tools" }
}
foreach ($name in @('Tercet.exe', 'Tercet.dll', 'Tercet.runtimeconfig.json', 'coreclr.dll', 'licenses/Tercet-LICENSE.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $payload $name) -PathType Leaf)) { throw "Missing payload file: $name" }
}
$runtime = Get-Content -LiteralPath (Join-Path $payload 'Tercet.runtimeconfig.json') -Raw | ConvertFrom-Json
if (-not $runtime.runtimeOptions.includedFrameworks) { throw 'Publish a self-contained payload first.' }

# Verze stejně jako u MSI: z metadat hotové DLL, bez části za + (hash commitu).
# MSIX chce čtyři složky; čtvrtá je u Store balíčků vyhrazená a má být 0.
$payloadVersion = ([string][Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $payload 'Tercet.dll')).ProductVersion).Split('+')[0]
if ($payloadVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'The payload must have a three-part release version.' }
$packageVersion = "$payloadVersion.0"

# Certifikát čteme z osobního úložiště uživatele; Publisher v manifestu MUSÍ
# být doslova jeho Subject, jinak signtool podpis odmítne (dokumentace MSIX).
$certificate = Get-ChildItem -LiteralPath 'Cert:\CurrentUser\My' | Where-Object Thumbprint -ceq $CertificateThumbprint
if (-not $certificate) { throw "Certificate $CertificateThumbprint not found in Cert:\CurrentUser\My." }
$publisher = $certificate.Subject

$work = Join-Path $repo ('src/Tercet/obj/msix-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    # -LiteralPath nerozbaluje zástupné znaky; položky payloadu kopírujeme výčtem.
    Get-ChildItem -LiteralPath $payload | Copy-Item -Destination $work -Recurse
    # Loga balíčku renderujeme ze stejné vektorové předlohy jako ICO aplikace
    # společnou funkcí z Render-ApplicationIcon.ps1; ICO má pevnou
    # sadu rozměrů, loga Store jiné, kód renderu je ale jeden.
    . (Join-Path $PSScriptRoot 'Render-ApplicationIcon.ps1')
    $assets = Join-Path $work 'Assets'
    New-Item -ItemType Directory -Path $assets -Force | Out-Null
    foreach ($logo in @(@{ Name = 'Square44x44Logo.png'; Size = 44 }, @{ Name = 'Square150x150Logo.png'; Size = 150 }, @{ Name = 'StoreLogo.png'; Size = 50 })) {
        [IO.File]::WriteAllBytes((Join-Path $assets $logo.Name), (ConvertTo-ApplicationIconPng $logo.Size))
    }

    $manifest = [IO.File]::ReadAllText((Join-Path $repo 'installer/msix/AppxManifest.xml'))
    $manifest = $manifest.Replace('__PUBLISHER__', [Security.SecurityElement]::Escape($publisher)).Replace('__VERSION__', $packageVersion)
    # UTF-8 bez BOM: makeappx XML s BOM přijme, ale držíme se obvyklého tvaru.
    [IO.File]::WriteAllText((Join-Path $work 'AppxManifest.xml'), $manifest, [Text.UTF8Encoding]::new($false))

    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $packagePath = Join-Path $output "Tercet-$payloadVersion-x64.msix"
    if (Test-Path -LiteralPath $packagePath) { Remove-Item -LiteralPath $packagePath }
    # makeappx validuje manifest proti schématu; chybějící runFullTrust nebo
    # špatný atribut ohlásí s řádkem a sloupcem. Vypisuje každý soubor,
    # proto výstup odkládáme do logu a ukážeme ho jen při chybě.
    $makeappxLog = Join-Path $output 'makeappx.log'
    & (Join-Path $tools 'makeappx.exe') pack /d $work /p $packagePath /o *> $makeappxLog
    if ($LASTEXITCODE -ne 0) { Get-Content -LiteralPath $makeappxLog -Tail 20; throw "makeappx failed with exit code $LASTEXITCODE (log: $makeappxLog)." }
    # /fd SHA256 je povinný algoritmus otisku souboru; /sha1 vybere certifikát
    # podle otisku v úložišti My aktuálního uživatele.
    & (Join-Path $tools 'signtool.exe') sign /fd SHA256 /s My /sha1 $CertificateThumbprint $packagePath
    if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE." }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$hash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
"Package: $packagePath"
"Version: $packageVersion  Publisher: $publisher"
"Size: $((Get-Item -LiteralPath $packagePath).Length) B  SHA256: $hash"
