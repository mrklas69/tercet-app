TERCET — preview for Windows 11 (Intel/AMD x64)

Tercet is a small desktop note for the tasks you want to keep in view.
It stays on the desktop beneath your application windows. Colored lights
show each task's situation; you control the list and its order.

INSTALL AND START
1. If Tercet is running, choose Exit from its system tray menu.
2. Run the included Tercet-...-win-x64.msi under your normal Windows account.
3. Launch Tercet Preview from the Start menu. It will start automatically when you
   next sign in to Windows.

The .NET Desktop Runtime is included. You do not need to install an SDK
or PowerShell. This package is for Intel/AMD x64, not ARM processors.
It installs for the current user only.

GETTING STARTED
On a new installation with no saved queue or backup, Tercet shows an English
example. Open the editor with Ctrl+Alt+T or Edit in the system tray menu.
Right-click an item name for its menu. Change the examples into your own
tasks, then choose Save. Cancel discards unsaved edits.
The application version appears at the top right of the editor.
The tray icon stays the same; task situations are shown on the desktop note.

Local use needs no account or internet connection. Leave the queue link
in Settings empty for local use. Synchronization is optional and requires
a queue link supplied to you. Treat that link as private: anyone with it
can access and change the shared queue.

FILES AND UPDATES
Application: %LOCALAPPDATA%\Programs\Tercet
Data folder: %LOCALAPPDATA%\Tercet
Queue: queue.json; previous saved version: queue.json.bak
Synchronization settings, if configured: settings.json

Updates preserve your saved queue, backup and settings. If the queue is
missing or damaged and a valid backup exists, Tercet offers to restore it.
The local backup is not a substitute for a separate backup of your data.

To update: choose Exit, back up the data folder, run an MSI with a higher
version number, then launch Tercet Preview from Start.
To uninstall: Windows Settings > Apps > Installed apps > Tercet Preview.
Uninstalling leaves your data folder in place.
Do not mix MSI installation with the developer's Install-Tercet.ps1 script.
To disable automatic startup, remove Tercet Preview.lnk from the folder opened by
Win+R > shell:startup.

MOVING TO THE MICROSOFT STORE VERSION (WHEN AVAILABLE)
The Store application is named Tercet. This MSI is Tercet Preview;
the separate developer MSIX is Tercet Prototype, not a Store release.
1. Choose Exit in the system tray, then copy the entire data folder listed
   above to a safe location outside that folder. Keep settings.json private:
   it contains your queue link if synchronization is configured.
2. Uninstall Tercet Preview in Windows Settings. This leaves its data folder
   in place and removes its Start and automatic startup shortcuts.
3. Install Tercet from the Microsoft Store and launch it from Start.
   On its first launch it imports the old queue, local backup and settings
   into its own data folder, provided it has no data there yet.
4. Check your tasks, archive and synchronization settings before continuing.
   Keep your external backup until you have checked the imported data.
Older MSI versions also called their Start shortcut Tercet. Uninstall the
MSI before installing the Store version to avoid two indistinguishable names.
Store uninstall removes the Store application's local data. Before uninstalling,
use Back Up Queue in its tray menu to save your queue and archive outside
the application's data folder. This backup excludes synchronization settings;
keep your queue link separately. Synchronization is not a backup.

WINDOWS SECURITY
This preview is not digitally signed. Smart App Control or SmartScreen
may block it. If that happens, send the exact message to the person who
provided the package. Disabling Windows protection is not part of setup.

QUICK CHECK ON YOUR COMPUTER
- Open the editor, change and save an item, and check the desktop note.
- Launching Tercet again must not create a second tray icon.
- After restarting Windows and signing in, Tercet should return with your
  saved tasks.
- On a first installation, check that the English example is displayed.

This is a preview for testing. Calendar integration is not included.
