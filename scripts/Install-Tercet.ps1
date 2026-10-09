param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\Tercet'),
    [string]$StartupDirectory = [Environment]::GetFolderPath('Startup'),
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'Tercet')
)
$ErrorActionPreference = 'Stop'

# Oddělené cíle dovolují ověřit celý instalátor v dočasném adresáři.
# Skript sestavení nevyrábí a aplikaci nespouští: nasazuje hotový publish.
function Get-FullDirectory([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\','/')) { throw 'A drive root cannot be an installation directory.' }
    return $full
}
function Test-InDirectory([string]$Path, [string]$Directory) {
    return $Path.Equals($Directory,[StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Directory + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
# Reparse point by mohl přesměrovat přesun jinam. Kontrolujeme i předky,
# ne pouze jméno cíle; adresáře balíčku se níže vůbec nepovolují.
function Assert-NoRedirect([string]$Path) {
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Redirected path is not supported: $cursor"
            }
        }
        $cursor = Split-Path -Path $cursor -Parent
    }
}
$source = Get-FullDirectory $SourceDirectory
$target = Get-FullDirectory $InstallDirectory
$startup = Get-FullDirectory $StartupDirectory
$data = Get-FullDirectory $DataDirectory
foreach ($path in @($source,$target,$startup,$data)) { Assert-NoRedirect $path }
foreach ($other in @($source,$startup,$data)) {
    if ((Test-InDirectory $target $other) -or (Test-InDirectory $other $target)) {
        throw 'Installation must not overlap source, startup or data directories.'
    }
}

# Dnešní aplikace má právě čtyři povinné soubory a volitelné PDB. Nová
# závislost musí rozšířit tento kontrakt; tiše neúplný balíček nepřijmeme.
$required = @('Tercet.exe','Tercet.dll','Tercet.deps.json','Tercet.runtimeconfig.json')
$allowed = $required + @('Tercet.pdb')
$files = @(Get-ChildItem -LiteralPath $source -Force)
foreach ($file in $files) {
    if ($file.PSIsContainer -or $file.Name -notin ($allowed + '.tercet-install.json') -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Unexpected package entry: $($file.FullName)"
    }
}
# Záloha instalace je také platný zdroj pro návrat; její starý manifest
# nekopírujeme, protože nové nasazení dostane vlastní čas a ověřené hashe.
$sourceMarker = Join-Path $source '.tercet-install.json'
if (Test-Path -LiteralPath $sourceMarker -PathType Leaf) {
    $sourceManifest = Get-Content -LiteralPath $sourceMarker -Raw | ConvertFrom-Json
    if ($sourceManifest.application -cne 'Tercet' -or $sourceManifest.formatVersion -ne 1) { throw 'Unknown source installation marker.' }
}
$files = @($files | Where-Object { $_.Name -in $allowed })
foreach ($name in $required) {
    if ($name -notin $files.Name) { throw "Incomplete package: $name is missing." }
}
$parent = Split-Path -Path $target -Parent
$leaf = Split-Path -Path $target -Leaf
$suffix = [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
$stage = Join-Path $parent ($leaf + '.staging-' + $suffix)
$backup = Join-Path $parent ($leaf + '.backup-' + $suffix)
$failed = Join-Path $parent ($leaf + '.failed-' + $suffix)
$shortcutPath = Join-Path $startup 'Tercet.lnk'
$exePath = Join-Path $target 'Tercet.exe'

# Cesty případných přesunů jsou ověřené ještě před první mutací. Všechny
# přesouvané adresáře jsou přímí sourozenci konkrétního instalačního cíle.
foreach ($path in @($target,$stage,$backup,$failed)) {
    if ((Split-Path -Path $path -Parent) -ne $parent) { throw "Unsafe move target: $path" }
}
[IO.Directory]::CreateDirectory($data) | Out-Null
$lease = $null
try {
    try { $lease = [IO.File]::Open((Join-Path $data '.instance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch {
        $failure = $_.Exception
        while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
        if (($failure.HResult -band 0xffff) -in @(32,33)) {
            throw 'Tercet or another installer is using this data folder. Close Tercet with Exit before installing.'
        }
        throw
    }

    # Starší instalace bez zámku může stále držet exe. Novější verze chrání
    # i start během výměny sdíleným .instance.lock; procesy nikdy nezabíjíme.
    $running = @(Get-Process Tercet -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exePath })
    if ($running.Count -gt 0) { throw 'The installed Tercet is running. Close it with Exit before installing.' }
    $hadTarget = Test-Path -LiteralPath $target
    if ($hadTarget) {
        $markerPath = Join-Path $target '.tercet-install.json'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw 'Existing directory is not a managed Tercet installation; left unchanged.' }
        Assert-NoRedirect $markerPath
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($marker.application -cne 'Tercet' -or $marker.formatVersion -ne 1) { throw 'Unknown installation marker; left unchanged.' }
        foreach ($entry in Get-ChildItem -LiteralPath $target -Force) {
            if ($entry.PSIsContainer -or $entry.Name -notin ($allowed + '.tercet-install.json') -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Unexpected installed entry; left unchanged: $($entry.FullName)"
            }
        }
    }
    Assert-NoRedirect $shortcutPath
    $oldShortcut = $null
    $shell = New-Object -ComObject WScript.Shell
    if (Test-Path -LiteralPath $shortcutPath) {
        $existing = $shell.CreateShortcut($shortcutPath)
        if ($existing.TargetPath -ne $exePath) { throw 'Existing Tercet shortcut points elsewhere; left unchanged.' }
        $oldShortcut = [IO.File]::ReadAllBytes($shortcutPath)
    }

    [IO.Directory]::CreateDirectory($stage) | Out-Null
    $hashes = [ordered]@{}
    foreach ($file in $files) {
        $destination = Join-Path $stage $file.Name
        [IO.File]::Copy($file.FullName,$destination,$false)
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hash) { throw 'Package copy verification failed.' }
        $hashes[$file.Name] = $hash
    }
    $manifest = [ordered]@{ application = 'Tercet'; formatVersion = 1; installedAt = [DateTimeOffset]::Now.ToString('o'); files = $hashes }
    [IO.File]::WriteAllText((Join-Path $stage '.tercet-install.json'),($manifest | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    [IO.Directory]::CreateDirectory($startup) | Out-Null

    # Přesun předchozího adresáře zachová jeho úplný obsah. Při chybě po
    # výměně se vrací adresář i původní zástupce; neúspěšný balíček zůstane
    # jako .failed pro diagnostiku, žádná rekurzivní destrukce není potřeba.
    $oldMoved = $false
    $newMoved = $false
    $shortcutTouched = $false
    try {
        if ($hadTarget) { [IO.Directory]::Move($target,$backup); $oldMoved = $true }
        [IO.Directory]::Move($stage,$target)
        $newMoved = $true
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $exePath
        $shortcut.WorkingDirectory = $target
        $shortcut.Description = 'Start Tercet after signing in to Windows'
        $shortcut.Arguments = ''
        $shortcutTouched = $true
        $shortcut.Save()
        $verified = $shell.CreateShortcut($shortcutPath)
        if ($verified.TargetPath -ne $exePath -or $verified.WorkingDirectory -ne $target -or $verified.Arguments -ne '') {
            throw 'Startup shortcut verification failed.'
        }
    } catch {
        if ($newMoved) { [IO.Directory]::Move($target,$failed) }
        if ($oldMoved) { [IO.Directory]::Move($backup,$target) }
        if ($shortcutTouched) {
            if ($null -ne $oldShortcut) {
                # Selhání Save může ponechat zástupce beze změny (např.
                # read-only soubor). V takovém případě jej znovu nepíšeme.
                $unchanged = (Test-Path -LiteralPath $shortcutPath -PathType Leaf) -and
                    ([Convert]::ToBase64String([IO.File]::ReadAllBytes($shortcutPath)) -ceq [Convert]::ToBase64String($oldShortcut))
                if (-not $unchanged) { [IO.File]::WriteAllBytes($shortcutPath,$oldShortcut) }
            }
            elseif (Test-Path -LiteralPath $shortcutPath -PathType Leaf) { [IO.File]::Delete($shortcutPath) }
        }
        throw
    }
    "Installed: $exePath"
    "Startup shortcut: $shortcutPath"
    if ($hadTarget) { "Previous version: $backup" }
} finally {
    if ($null -ne $lease) { $lease.Dispose() }
}
