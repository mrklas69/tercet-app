param([string]$Configuration = 'Release', [switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$project = Join-Path $PSScriptRoot 'DesktopProcess/DesktopDiagnostics.csproj'
# Vlastní EXE dědí skutečný manifest aplikace. PowerShell jako host má
# jiné DPI nastavení a původní obnovovací smyčku nedokázal reprodukovat.
dotnet build $project -c $Configuration
if ($LASTEXITCODE -ne 0) { throw 'Desktop process test build failed.' }
$directory = Join-Path ([IO.Path]::GetTempPath()) ('Tercet-desktop-process-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
$log = Join-Path $directory 'geometry.log'
$exe = Join-Path $PSScriptRoot "DesktopProcess/bin/$Configuration/net10.0-windows/DesktopDiagnostics.exe"
$probe = Start-Process -FilePath $exe -ArgumentList @(('"{0}"' -f $log),('"{0}"' -f $repo)) -WindowStyle Hidden -PassThru
try {
    if (-not $probe.WaitForExit(25000)) { throw 'Desktop process test timed out.' }
    if ($probe.ExitCode -ne 0) { throw "Desktop process test failed: exit $($probe.ExitCode), log $log" }
    $lines = @(Get-Content -LiteralPath $log)
    if (@($lines | Where-Object { $_ -match 'Before tick:' }).Count -ne 6 -or @($lines | Where-Object { $_ -match 'ERROR' }).Count -gt 0) {
        throw "Desktop process test incomplete: $log"
    }
    'PASS: real EXE manifest, six idle timer ticks, stable HWND and matching WPF/native geometry'
    # Po úspěchu úklid, po selhání log zůstává k diagnostice (vzor Check-Web).
    if ($KeepArtifacts) { "Geometry log: $log" } else { Remove-Item -LiteralPath $directory -Recurse -Force }
} finally {
    # Ukončujeme výhradně vlastní izolovanou sondu, nikdy provozní Tercet.
    if (-not $probe.HasExited) { $probe.Kill(); $probe.WaitForExit() }
    $probe.Dispose()
}
