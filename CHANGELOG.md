# Release notes

## 2.0.4 — Tercet Preview

The first public MSI preview for Windows 11 on Intel/AMD x64. The installer
includes the .NET Desktop Runtime. No developer tools or account are needed.

Changes since the earlier 2.0.3 tester package:

- **Back Up Queue** exports your tasks and archive to a JSON file.
- **Restore Queue** opens a backup in the editor for review. Save accepts it;
  Cancel keeps your current queue. Connection settings are not in the backup.
- **Open Data Folder** opens the folder containing your queue and settings.
- Start, automatic startup, the tray tooltip and application windows consistently
  identify the MSI version as **Tercet Preview**.
- Synchronization reports a damaged settings file instead of silently stopping.
  Settings writes are flushed to disk before replacing the previous file.
- Preparation for a future Microsoft Store version includes separate packaged
  data, one-time import and a warning about data removal on MSIX uninstall.

### Install or update

Download `Tercet-2.0.4-win-x64.msi` from this release. Close an existing Tercet
using **Exit** in its tray menu, run the MSI, then open **Tercet Preview** from
Start. Press **Ctrl+Alt+T** to edit the example tasks and choose **Save**.
Tercet starts automatically when you next sign in.

Updates keep the queue, archive and settings. MSI uninstall leaves the data
folder in place. Back up important data before updating. If you used the
developer install script, follow the installation guide before switching to MSI.

### Preview limitations

The MSI and application are unsigned. Smart App Control or SmartScreen may
block them; disabling Windows protection is not part of setup. The package is
for x64 computers, not Windows on ARM. A Microsoft Store release is not yet
available. Local use works without a server; optional synchronization requires
a compatible service supplied separately.

See [installation instructions](installer/README.txt) for data locations,
backup, automatic startup and removal.
