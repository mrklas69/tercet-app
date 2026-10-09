# Tercet

Tercet is a small Windows desktop note for keeping your current tasks in view.
You edit a tree with up to three levels and mark each task's situation with a
colored light. Your queue is stored locally; no account is required for local use.

The note stays on the desktop beneath application windows. Open its editor with
**Ctrl+Alt+T** or **Edit** in the system tray menu. Right-click an item for actions,
then choose **Save** or **Cancel**. Completed tasks can be moved to the archive
and restored later. Tercet does not automate your workflow or integrate with calendars.

## Distribution and data

Target platform: **Windows 11, Intel/AMD x64**. The MSI is **Tercet Preview**;
the developer MSIX is **Tercet Prototype**. A Microsoft Store release is planned,
but this repository does not provide a Store listing or claim Store approval.
Source changes can precede a packaged release; check the release notes of any
binary you download. See the [installation guide](installer/README.txt).

The MSI includes the .NET Desktop Runtime and installs for the current user.
MSI and source builds use `%LOCALAPPDATA%\Tercet` for data. MSI uninstall leaves
that folder in place. MSIX uses its package's `LocalState` folder; uninstalling
the package deletes its local queue, archive and settings. On first packaged
launch, existing non-packaged data is imported if the package has no data yet.

Use **Back Up Queue…** to save your queue and archive outside the app's data
folder. **Restore Queue…** opens the backup for review; choose Save to accept it.
Keep your optional queue link separately: exported backups omit connection
settings. The automatic `queue.json.bak` is only the previous saved version.
Synchronization is not a backup. [More about packaged data](installer/store-data-notice.txt).

## Build and test

Install the **.NET 10 SDK**, **PowerShell 7** and **Git** on Windows.
Run these commands in PowerShell from the repository root:

```powershell
dotnet --version
dotnet build Tercet.slnx -c Release
pwsh -NoProfile -STA -File tests/Check-Editor.ps1 -Configuration Release
pwsh -NoProfile -File tests/Check-Web.ps1
```

The SDK resolver in `global.json` also supports an optional local `.dotnet`
junction; a normal machine-wide SDK installation does not need one. The editor
suite covers the model, persistence, archive, recovery, backup, data locations,
tray icon, blinking lights and synchronization against a loopback fake server.
The web suite requires **Microsoft Edge** and checks the mobile reader headlessly.
Fixtures contain fictional data. Test windows and recovery dialogs briefly open;
run tests in an interactive desktop session. They use temporary data, not your queue.

For actual keyboard-focus checks add `-CheckFocus` to Check-Editor and avoid typing
in other windows during the run. `-KeepArtifacts` retains diagnostic files;
`-UpdateSnapshot` saves a preview under `.build/previews`.

Desktop hosting and DPI checks:

```powershell
pwsh -NoProfile -STA -File tests/Check-DesktopRefresh.ps1 -Configuration Release
pwsh -NoProfile -File tests/Check-DesktopProcess.ps1 -Configuration Release
```

The process test uses the application's DPI manifest; tests hosted in PowerShell
cannot establish that behavior. Visibility on the composed desktop, RDP transitions,
startup after sign-in and usability still require manual acceptance. Smart App
Control can block an unsigned build even when compilation passes. Do not disable
Windows protection as part of setup. See [packaging and verification](installer/README.md).

To run your build, exit any existing Tercet instance and launch
`src/Tercet/bin/Release/net10.0-windows/Tercet.exe`. A source build uses your regular
local queue. Never rebuild a configuration whose executable is still running.
The [vector icon](resources/application-icon.xaml) can be regenerated with
`pwsh -NoProfile -STA -File scripts/Build-ApplicationIcon.ps1`.

## Optional synchronization and web reader

Local use is the default. Settings accepts a link supplied by a compatible queue
service, for example `https://example.com/Tercet/tercet.html#token`.
This repository provides **no hosted service or backend implementation**.
The link is a bearer credential: anyone with it can read and replace the queue.
Keep it out of screenshots, commits and issue reports.

The [web reader](web/tercet.html) expects `/api/tercet` on the same origin.
It reads with GET and a token header; without a token it can request a new queue
with POST. The desktop client also uses PUT with ETag concurrency checks.
Opening the HTML file locally or hosting it on GitHub Pages does not supply this API.
An optional host script at `/js/app-usage.js` counts page openings; absence of that
script does not stop the reader. There is no automatic connection to an author's server.

## License

Tercet is available under the [MIT License](LICENSE).
Bundled runtimes retain their own licenses and third-party notices in `licenses/`.
The source comments are mostly in Czech.
