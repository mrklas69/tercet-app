# Building packages

These recipes build **Windows 11 x64** development packages, not Store submissions.
Use PowerShell 7 in the repository root, .NET 10 SDK and an interactive desktop.
Release builds and package builds are separate artifacts and need separate checks.

## MSI Preview

```powershell
dotnet tool install wix --version 5.0.2 --tool-path .build/wix5-tools --allow-roll-forward
dotnet publish src/Tercet/Tercet.csproj -c Release -r win-x64 --self-contained true -p:PublishTrimmed=false -o .build/payload
pwsh -NoProfile -File scripts/Build-Installer.ps1 -PayloadDirectory .build/payload -OutputDirectory publish
$dll = (Get-Item .build/payload/Tercet.dll).FullName
$version = ([Diagnostics.FileVersionInfo]::GetVersionInfo($dll).ProductVersion).Split('+')[0]
pwsh -NoProfile -File tests/Check-Installer.ps1 -InstallerPath "publish/Tercet-$version-win-x64.msi" -PayloadDirectory .build/payload
pwsh -NoProfile -File tests/Check-InstallerVersions.ps1 -PayloadDirectory .build/payload
```

The builder adds Tercet and runtime licenses to the input payload, then packages
it. Runtime licenses come from the exact NuGet versions recorded in the payload.
It derives the three-part version from Tercet.dll and rejects a conflicting explicit
`-PackageVersion`. An existing MSI output is rejected. Increase the application
version for an actual upgrade release; rebuilding is not itself a new release.
The checks inspect MSI metadata and compare extracted files by SHA256.
Check-InstallerVersions uses a temporary payload copy.

The MSI installs per user, with Start and Startup shortcuts named Tercet Preview.
It includes the runtime (roughly 60 MB compressed, depending on the SDK/runtime).
Launch from Start after installation; no SDK is needed on the tester's machine.
It leaves `%LOCALAPPDATA%\Tercet` untouched on uninstall. See [user instructions](README.txt).

`tests/Check-ShortcutUpgrade.ps1 -WixPath .build/wix5-tools/wix.exe` performs an
isolated miniature MSI upgrade to verify shortcut renaming and preservation of
a test data file. It installs its own test product, not Tercet.

## MSIX Prototype

First prepare the licensed `.build/payload` through the MSI recipe above.
Acquire the Windows SDK packaging tools independently:

```powershell
New-Item -ItemType Directory -Path .build -Force | Out-Null
Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools/10.0.28000.2705' -OutFile .build/sdk-buildtools.zip
Expand-Archive .build/sdk-buildtools.zip .build/sdk-buildtools
$tools = (Get-Item .build/sdk-buildtools/bin/10.0.28000.0/x64).FullName
$certificate = New-SelfSignedCertificate -Type Custom -KeyUsage DigitalSignature -CertStoreLocation Cert:\CurrentUser\My -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') -Subject 'CN=Tercet Prototype'
pwsh -NoProfile -STA -File scripts/Build-Msix.ps1 -PayloadDirectory .build/payload -ToolsDirectory $tools -CertificateThumbprint $certificate.Thumbprint
pwsh -NoProfile -File tests/Check-Msix.ps1 -Step Package -PackagePath ".build/msix/Tercet-$version-x64.msix"
```

The manifest uses `runFullTrust`, package identity `Tercet.Prototype`, and a
StartupTask. Publisher comes from the signing certificate. The Package check
inspects the resulting archive without installation or trust changes. The private
key stays in your certificate store; never commit or distribute it.

Installing a self-signed prototype requires a separate trust decision. The above
recipe does not install it or change TrustedPeople. The other Check-Msix steps
are manual acceptance helpers: read the script before running Install, Launch,
Probe, Snapshot, Compare or Remove. Exit the existing app before replacement.
Acceptance must cover desktop hosting, hotkey, systray, startup, import, backup,
restore and removal of packaged data. A prototype signature neither predicts
Store review nor establishes the Smart App Control verdict for a Store release.

## Check the actual binary before handing it over

Compilation and package integrity do not prove that Windows will run the payload.
Check both the **published DLL and apphost EXE** with Smart App Control enabled,
in a disposable environment or against isolated data, then inspect CodeIntegrity
events for blocks. A test hosted in PowerShell alone does not test the apphost.
Do not replace a user's running instance or use their queue for this check.

When distributing an artifact, include its version, x64 architecture, bundled
runtime version, size, SHA256, first-start instructions and remaining manual
acceptance steps. Recheck the binary after rebuilding from a different commit.
The Store identity and listing must be supplied through the actual publisher
account; the prototype manifest is not a production Store manifest.
