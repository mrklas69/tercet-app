[CmdletBinding()]
param(
    # Měření prototypu MSIX běží po krocích, protože mezi nimi jsou
    # ruční zásahy uživatele (Exit provozní instance, Save v balíčkové instanci,
    # UAC pro certifikát). Provozní kroky jen měří a vypisují. Package navíc
    # automaticky ověří názvy v hotovém balíčku, aniž by ho instaloval.
    [Parameter(Mandatory)][ValidateSet('Package', 'Install', 'Launch', 'Probe', 'Snapshot', 'Compare', 'Remove')][string]$Step,
    [string]$PackagePath,
    [string]$IdentityName = 'Tercet.Prototype',
    # Snapshot: jméno snímku (before/after); Compare porovná právě tato dvě.
    [string]$Label,
    [string]$StateDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'Tercet-msix-check')
)
$ErrorActionPreference = 'Stop'
# MSIX je ZIP; čteme skutečný manifest artefaktu, ne zdrojovou šablonu.
# Tento krok nevyžaduje důvěru certifikátu ani přístup k provozním datům.
if ($Step -eq 'Package') {
    if (-not $PackagePath) { throw 'PackagePath is required for Package.' }
    $zip = [IO.Compression.ZipFile]::OpenRead((Get-Item -LiteralPath $PackagePath).FullName)
    try {
        if (-not $zip.GetEntry('licenses/Tercet-LICENSE.txt')) { throw 'Tercet license is not bundled.' }
        $entry = $zip.GetEntry('AppxManifest.xml')
        if (-not $entry) { throw 'AppxManifest.xml is missing.' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $ns = [Xml.XmlNamespaceManager]::new($manifest.NameTable)
        $ns.AddNamespace('p', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
        $ns.AddNamespace('uap', 'http://schemas.microsoft.com/appx/manifest/uap/windows10')
        $ns.AddNamespace('desktop', 'http://schemas.microsoft.com/appx/manifest/desktop/windows10')
        if ($manifest.Package.Identity.Name -cne 'Tercet.Prototype') { throw 'Prototype identity changed.' }
        $names = @(
            $manifest.SelectSingleNode('/p:Package/p:Properties/p:DisplayName', $ns).InnerText
            $manifest.SelectSingleNode('//uap:VisualElements', $ns).DisplayName
            $manifest.SelectSingleNode('//desktop:StartupTask', $ns).DisplayName
        )
        foreach ($name in $names) {
            if ($name -cne 'Tercet Prototype') { throw "Unexpected prototype display name: $name" }
        }
        'PASS: MSIX identity Tercet.Prototype; package, Start and StartupTask names Tercet Prototype'
    } finally { $zip.Dispose() }
    return
}
$dataDirectory = Join-Path $env:LOCALAPPDATA 'Tercet'
New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null

# Bez -ReferencedAssemblies: výchozí sada pwsh 7 pokrývá kolekce i StringBuilder
# Delegát EnumProc předává .NET funkci Win32 enumerátoru.
if (-not ('MsixNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class MsixNative
{
    public delegate bool EnumProc(IntPtr handle, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr handle, StringBuilder text, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr handle, StringBuilder text, int capacity);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr handle);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(IntPtr handle, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr handle, int id);

    // Nativní obal lístečku je STATIC okno s textem Tercet.DesktopSurface
    // (DesktopHost.Attach). Hledáme ho mezi potomky všech top-level oken,
    // abychom nepředjímali, zda sedí v Progman nebo v samostatném WorkerW.
    public static List<IntPtr> FindSurfaces(uint processId)
    {
        var result = new List<IntPtr>();
        EnumProc visit = (handle, parameter) =>
        {
            uint owner;
            GetWindowThreadProcessId(handle, out owner);
            if (owner == processId)
            {
                var text = new StringBuilder(256);
                GetWindowText(handle, text, 256);
                if (text.ToString() == "Tercet.DesktopSurface") result.Add(handle);
            }
            return true;
        };
        EnumWindows((handle, parameter) => { EnumChildWindows(handle, visit, IntPtr.Zero); return true; }, IntPtr.Zero);
        return result;
    }

    public static string ClassOf(IntPtr handle)
    {
        var text = new StringBuilder(256);
        GetClassName(handle, text, 256);
        return text.ToString();
    }

    public static string Describe(IntPtr handle)
    {
        IntPtr parent = GetParent(handle);
        IntPtr grandparent = parent == IntPtr.Zero ? IntPtr.Zero : GetParent(parent);
        return string.Format("hwnd=0x{0:X} class={1}; parent=0x{2:X} {3}; grandparent=0x{4:X} {5}",
            handle.ToInt64(), ClassOf(handle), parent.ToInt64(), ClassOf(parent), grandparent.ToInt64(), ClassOf(grandparent));
    }
}
'@
}

function Get-Package {
    $package = Get-AppxPackage -Name $IdentityName
    if (-not $package) { throw "Package $IdentityName is not installed." }
    return $package
}

# Blokace SAC se projeví událostmi CodeIntegrity 3077/3033 s cestou souboru;
# bez nich je pád aplikace vada, ne zásada řízení aplikací.
function Get-CodeIntegrityEvents([datetime]$Since) {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3077, 3033; StartTime = $Since } -ErrorAction SilentlyContinue)
    "CodeIntegrity 3077/3033 since $($Since.ToString('HH:mm:ss')): $($events.Count)"
    foreach ($event in $events) { "  $($event.TimeCreated.ToString('HH:mm:ss')) $($event.Id): $(($event.Message -split "`n")[0])" }
}

function Get-PackageDataDirectories($package) {
    $root = Join-Path $env:LOCALAPPDATA ('Packages\' + $package.PackageFamilyName)
    return @((Join-Path $root 'LocalCache\Local\Tercet'), (Join-Path $root 'LocalState'))
}

# Hash každého souboru; zamčený soubor (FileShare.None u .lock) ohlásíme, ne spadneme.
function Get-FolderSnapshot([string]$Folder) {
    $entries = @{}
    if (Test-Path -LiteralPath $Folder) {
        foreach ($file in Get-ChildItem -LiteralPath $Folder -File -Recurse) {
            $relative = $file.FullName.Substring($Folder.Length).TrimStart('\')
            try { $entries[$relative] = "$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) ($($file.Length) B)" }
            catch { $entries[$relative] = "locked ($($file.Length) B)" }
        }
    }
    return $entries
}

switch ($Step) {
    'Install' {
        if (-not $PackagePath) { throw 'Install requires -PackagePath.' }
        $since = Get-Date
        # Sideload podepsaného balíčku: certifikát musí být důvěryhodný (TrustedPeople);
        # kde přesně, měříme — dokumentace uvádí LocalMachine, zkoušíme nejdřív CurrentUser.
        Add-AppxPackage -Path (Resolve-Path -LiteralPath $PackagePath).Path
        $package = Get-Package
        "Installed: $($package.PackageFullName)"
        "PackageFamilyName: $($package.PackageFamilyName)"
        "InstallLocation: $($package.InstallLocation)"
        Get-CodeIntegrityEvents $since
    }
    'Launch' {
        $package = Get-Package
        $since = Get-Date
        $before = @(Get-Process -Name Tercet -ErrorAction SilentlyContinue | ForEach-Object Id)
        "Tercet processes before launch: $(if ($before) { $before -join ', ' } else { 'none' })"
        # Aktivace přes shell:AppsFolder dá procesu identitu balíčku; přímé spuštění
        # exe z WindowsApps by ji nemuselo mít a měřilo by jiný stav.
        Start-Process ('shell:AppsFolder\' + $package.PackageFamilyName + '!Tercet')
        $process = $null
        $deadline = (Get-Date).AddSeconds(15)
        # Polling 40 ms: balíčková instance končící na cizím zámku žije jen stovky
        # milisekund a po 500 ms už nebyla vidět — krok hlásil „did not appear"
        # a tichý konec nešlo odlišit od nespuštění (změřeno 2026-10-08 S1).
        while (-not $process -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 40
            $process = Get-Process -Name Tercet -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $before -and $_.Path -like ($package.InstallLocation + '\*') } | Select-Object -First 1
        }
        if (-not $process) {
            'Packaged process did not appear within 15 s.'
            Get-CodeIntegrityEvents $since
            return
        }
        "Packaged process: PID $($process.Id), $($process.Path)"
        Start-Sleep -Seconds 5
        $process.Refresh()
        if ($process.HasExited) {
            # Druhá instance končí Shutdown() ještě před systray — očekávané, když běží
            # provozní Tercet a zámek .instance.lock je sdílený (nevirtualizovaný).
            'Packaged process exited within 5 s (existing instance lock, or failure — see CodeIntegrity below).'
            Get-CodeIntegrityEvents $since
            return
        }
        'Packaged process is running.'
        $surfaces = [MsixNative]::FindSurfaces([uint32]$process.Id)
        "Desktop surfaces owned by the process: $($surfaces.Count)"
        foreach ($surface in $surfaces) { '  ' + [MsixNative]::Describe($surface) }
        # Data balíčku musí ležet v LocalState, nikoli ve virtualizované
        # kopii LocalCache\Local\Tercet; převzetí dosavadních dat hlásí balónek.
        $packageDirectories = Get-PackageDataDirectories $package
        "LocalCache\Local\Tercet exists: $(Test-Path -LiteralPath $packageDirectories[0])  ($($packageDirectories[0]))"
        "LocalState: $($packageDirectories[1])"
        if (Test-Path -LiteralPath $packageDirectories[1]) {
            foreach ($file in Get-ChildItem -LiteralPath $packageDirectories[1] -File) { "  $($file.Name)  $($file.Length) B" }
        } else {
            '  (missing)'
        }
        # Ctrl+Alt+T (MOD_CONTROL|MOD_ALT|MOD_NOREPEAT = 0x4003, VK_T = 0x54):
        # chyba 1409 ERROR_HOTKEY_ALREADY_REGISTERED dokazuje, že ji aplikace drží.
        if ([MsixNative]::RegisterHotKey([IntPtr]::Zero, 0x5452, 0x4003, 0x54)) {
            [MsixNative]::UnregisterHotKey([IntPtr]::Zero, 0x5452) | Out-Null
            'Hotkey Ctrl+Alt+T: FREE — the packaged application did not register it.'
        } else {
            $error1 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            "Hotkey Ctrl+Alt+T: taken (Win32 error $error1; 1409 = held by another window)."
        }
        # Stav úlohy po spuštění drží Windows v HKCU pod identitou balíčku.
        $taskKey = Join-Path 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData' ($package.PackageFamilyName + '\TercetStartup')
        if (Test-Path -LiteralPath $taskKey) {
            $state = Get-ItemProperty -LiteralPath $taskKey
            "StartupTask registry: $taskKey"
            foreach ($property in $state.PSObject.Properties | Where-Object Name -notlike 'PS*') { "  $($property.Name) = $($property.Value)" }
        } else {
            "StartupTask registry key absent: $taskKey"
        }
        Get-CodeIntegrityEvents $since
    }
    'Probe' {
        $package = Get-Package
        # cmd v kontextu balíčku založí NOVÝ soubor v datové složce; kam fyzicky
        # dopadne, říká, zda virtualizace zápisu platí. Soubor po měření smažeme.
        $probeName = 'msix-probe.txt'
        $realProbe = Join-Path $dataDirectory $probeName
        $packageProbe = Join-Path (Get-PackageDataDirectories $package)[0] $probeName
        Invoke-CommandInDesktopPackage -PackageFamilyName $package.PackageFamilyName -AppId 'Tercet' -Command 'cmd.exe' -Args ('/c echo probe> "' + $realProbe + '"')
        Start-Sleep -Seconds 3
        "Real path exists:    $(Test-Path -LiteralPath $realProbe)  ($realProbe)"
        "Package path exists: $(Test-Path -LiteralPath $packageProbe)  ($packageProbe)"
        foreach ($path in @($realProbe, $packageProbe)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
    }
    'Snapshot' {
        if (-not $Label) { throw 'Snapshot requires -Label.' }
        $package = Get-Package
        $snapshot = [ordered]@{ Taken = (Get-Date).ToString('s'); Folders = [ordered]@{} }
        foreach ($folder in @($dataDirectory) + (Get-PackageDataDirectories $package)) {
            $snapshot.Folders[$folder] = Get-FolderSnapshot $folder
        }
        $file = Join-Path $StateDirectory "$Label.json"
        $snapshot | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding utf8
        "Snapshot '$Label' written: $file"
        foreach ($folder in $snapshot.Folders.Keys) {
            "  $folder : $($snapshot.Folders[$folder].Count) file(s)"
            foreach ($name in $snapshot.Folders[$folder].Keys) { "    $name  $($snapshot.Folders[$folder][$name])" }
        }
    }
    'Compare' {
        $before = Get-Content -LiteralPath (Join-Path $StateDirectory 'before.json') -Raw | ConvertFrom-Json
        $after = Get-Content -LiteralPath (Join-Path $StateDirectory 'after.json') -Raw | ConvertFrom-Json
        foreach ($folderProperty in $after.Folders.PSObject.Properties) {
            $folder = $folderProperty.Name
            "Folder: $folder"
            $beforeFiles = $before.Folders.$folder
            $afterFiles = $folderProperty.Value
            $names = @($beforeFiles.PSObject.Properties.Name) + @($afterFiles.PSObject.Properties.Name) | Sort-Object -Unique
            foreach ($name in $names) {
                $old = $beforeFiles.$name
                $new = $afterFiles.$name
                $status = if ($null -eq $old) { 'NEW' } elseif ($null -eq $new) { 'REMOVED' } elseif ($old -ceq $new) { 'same' } else { 'CHANGED' }
                "  $status  $name"
                if ($status -eq 'CHANGED') { "    before: $old"; "    after:  $new" }
            }
        }
    }
    'Remove' {
        $package = Get-Package
        $packageRoot = Join-Path $env:LOCALAPPDATA ('Packages\' + $package.PackageFamilyName)
        Remove-AppxPackage -Package $package.PackageFullName
        "Removed: $($package.PackageFullName)"
        # Odinstalace maže virtualizovaná data balíčku — přesně to měříme.
        "Package data root still exists: $(Test-Path -LiteralPath $packageRoot)  ($packageRoot)"
        "Real data directory exists:      $(Test-Path -LiteralPath $dataDirectory)  ($dataDirectory)"
    }
}
