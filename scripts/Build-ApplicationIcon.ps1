param([string]$PreviewDirectory)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$destination = Join-Path $repo 'src/Tercet/Assets/Tercet.ico'

# Render jednotlivých rozměrů sdílí s Build-Msix.ps1 (dot-source definuje
# ConvertTo-ApplicationIconPng a načte vektorovou předlohu).
. (Join-Path $PSScriptRoot 'Render-ApplicationIcon.ps1')
$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$frames = [Collections.Generic.List[byte[]]]::new()
if ($PreviewDirectory) { [IO.Directory]::CreateDirectory($PreviewDirectory) | Out-Null }
foreach ($size in $sizes) {
    $png = ConvertTo-ApplicationIconPng $size
    $frames.Add($png)
    if ($PreviewDirectory) { [IO.File]::WriteAllBytes((Join-Path $PreviewDirectory "icon-$size.png"), $png) }
}

# ICO: šestibajtová hlavička, 16 bajtů na záznam adresáře a pak PNG snímky.
# BinaryWriter zapisuje čísla little-endian; velikost 256 se v bajtu značí 0.
# Nejdřív sestavíme celý obsah v paměti, aby chyba renderu nezničila hotové ICO.
$output = [IO.MemoryStream]::new()
$writer = [IO.BinaryWriter]::new($output)
try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($index = 0; $index -lt $sizes.Count; $index++) {
        $dimension = if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$frames[$index].Length)
        $writer.Write([uint32]$offset)
        $offset += $frames[$index].Length
    }
    foreach ($frame in $frames) { $writer.Write($frame) }
    $writer.Flush()
    [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
    [IO.File]::WriteAllBytes($destination, $output.ToArray())
} finally { $writer.Dispose(); $output.Dispose() }
"Generated: $destination ($($sizes -join ', ') px)"
