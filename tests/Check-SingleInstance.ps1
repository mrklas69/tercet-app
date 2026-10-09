param([string]$Configuration = 'Release', [string]$ProbeDirectory, [string]$ResultPath, [switch]$Hold, [switch]$KeepArtifacts)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$null = [Reflection.Assembly]::LoadFrom((Join-Path $repo "src/Tercet/bin/$Configuration/net10.0-windows/Tercet.dll"))

# Tentýž skript slouží jako malý druhý proces. Nepouští App a nečte její
# provozní frontu; výsledek zaznamená souborem i návratovým kódem.
if ($ProbeDirectory) {
    $probe = [Tercet.SingleInstanceLock]::TryAcquire($ProbeDirectory)
    if ($null -eq $probe) { [IO.File]::WriteAllText($ResultPath,'blocked'); exit 10 }
    try {
        [IO.File]::WriteAllText($ResultPath,'acquired')
        if ($Hold) { Start-Sleep -Seconds 30 }
    } finally { $probe.Dispose() }
    exit 0
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Tercet-instance-' + [guid]::NewGuid().ToString('N'))
$lockDirectory = Join-Path $testRoot 'data'
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$pwshPath = (Get-Process -Id $PID).Path
function Start-Probe([string]$Name,[switch]$KeepAlive) {
    $resultFile = Join-Path $testRoot ($Name + '.txt')
    $arguments = @('-NoProfile','-File',('"{0}"' -f $PSCommandPath),'-Configuration',$Configuration,
        '-ProbeDirectory',('"{0}"' -f $lockDirectory),'-ResultPath',('"{0}"' -f $resultFile))
    if ($KeepAlive) { $arguments += '-Hold' }
    $process = Start-Process -FilePath $pwshPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
    return @{ Process = $process; Result = $resultFile }
}
function Complete-Probe($Probe,[int]$ExitCode,[string]$Expected) {
    try {
        Assert ($Probe.Process.WaitForExit(10000)) 'Probe timed out'
        Assert ($Probe.Process.ExitCode -eq $ExitCode) "Probe exit: $($Probe.Process.ExitCode)"
        Assert ([IO.File]::ReadAllText($Probe.Result) -ceq $Expected) 'Probe result differs from exit code'
    } finally {
        if (-not $Probe.Process.HasExited) { $Probe.Process.Kill(); $Probe.Process.WaitForExit() }
        $Probe.Process.Dispose()
    }
}
$owner = [Tercet.SingleInstanceLock]::TryAcquire($lockDirectory)
Assert ($null -ne $owner) 'First instance failed'
try { Complete-Probe (Start-Probe 'blocked') 10 'blocked' } finally { $owner.Dispose() }
Complete-Probe (Start-Probe 'released') 0 'acquired'

# Pád procesu nesmí nechat trvale obsazený zámek. Ukončujeme výhradně
# vlastní pomocný proces s uloženým PID, nikdy běžící Tercet uživatele.
$crashProbe = Start-Probe 'crashed' -KeepAlive
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $crashProbe.Result) -and [DateTime]::UtcNow -lt $deadline -and -not $crashProbe.Process.HasExited) { Start-Sleep -Milliseconds 50 }
    Assert (Test-Path -LiteralPath $crashProbe.Result) 'Holding probe did not start'
    Assert ([IO.File]::ReadAllText($crashProbe.Result) -ceq 'acquired') 'Holding probe failed to acquire'
    $contender = [Tercet.SingleInstanceLock]::TryAcquire($lockDirectory)
    if ($null -ne $contender) { $contender.Dispose(); throw 'Concurrent process did not block acquisition' }
    $crashProbe.Process.Kill()
    Assert ($crashProbe.Process.WaitForExit(10000)) 'Killed probe did not exit'
} finally {
    if (-not $crashProbe.Process.HasExited) { $crashProbe.Process.Kill(); $crashProbe.Process.WaitForExit() }
    $crashProbe.Process.Dispose()
}
Complete-Probe (Start-Probe 'after-crash') 0 'acquired'

# Jiná chyba souborového systému se nesmí vydávat za druhou instanci.
$invalidDirectory = Join-Path $testRoot 'file-not-directory'
[IO.File]::WriteAllText($invalidDirectory,'keep')
$rejected = $false
try { $null = [Tercet.SingleInstanceLock]::TryAcquire($invalidDirectory) } catch { $rejected = $true }
Assert $rejected 'Invalid data directory was silently accepted'
Assert ([IO.File]::ReadAllText($invalidDirectory) -ceq 'keep') 'Invalid directory input was changed'
'PASS: cross-process exclusion, release, crash recovery, unrelated IO error'
# Po úspěchu úklid, po selhání zůstává vše k diagnostice (vzor Check-Web).
if ($KeepArtifacts) { "Temporary lock tests: $testRoot" } else { Remove-Item -LiteralPath $testRoot -Recurse -Force }
