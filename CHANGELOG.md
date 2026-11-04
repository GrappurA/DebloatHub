# Changelog

All notable changes to DebloatHub. Versions follow [Semantic Versioning](https://semver.org/).

## [1.2.2] - 2026-11-04

### Added
- **One-line install:** paste `irm https://grappura.github.io/DebloatHub/install.ps1 | iex` into PowerShell. The small installer downloads `DebloatHub.ps1` from the latest release, checks its SHA-256 against the release's `SHA256SUMS.txt`, keeps it in `%LOCALAPPDATA%\DebloatHub` and starts it. Running the line again updates. The same `install.ps1` is attached to every release (for networks that block github.io).
- **Download page** at https://grappura.github.io/DebloatHub/ with the one-liner (copy button) and the zip.
- The zip and the Releases page stay exactly as before; every release now also lists `install.ps1` in `SHA256SUMS.txt`. CI runs the installer on Windows against the latest release, and the Pages workflow checks the published one-liner end to end.

## [1.2.1] - 2026-11-03

### Added
- **Progress bar with time left.** While changes are applied, the Simple view and the loading indicator show "Step 12 of 70 - 35% done - about 1 min left" and a progress bar; the scan shows its progress too.

### Changed
- **Recommended goes further, as requested:** it now also removes Get Help, Quick Assist, Phone Link (and its helper), the Widgets package, Maps and Power Automate, so only Teams and the default Media Player and Movies & TV players are kept. It also sets the Xbox, Phone Link, Fax and Remote Registry services to start on demand (Manual mode: they still start when something asks for them).

### Fixed
- **Restore point failed with "the service cannot be started because it is disabled".** System Restore needs the Volume Shadow Copy service and the Microsoft Software Shadow Copy Provider, which other debloat tools often disable. DebloatHub now sets them to Manual just for the restore point and puts back what was there afterwards; if it still fails, the log says which services to check.

## [1.2.0] - 2026-11-03

### Added
- **Autoruns** (was *Startup Programs*): also lists third-party scheduled tasks and third-party auto-start services. Disable only, nothing is deleted:
  - Tasks are disabled.
  - Services go to Manual (Disabled in Strict mode).
  - Drivers, security, VPN and similar entries are marked Moderate/Advanced.
- **Hide taskbar search completely**, the alternative to icon-only (switching one on turns the other off).
- **Recommended is more drastic.** It now also:
  - hides the taskbar search;
  - removes promo apps and games, Microsoft consumer and legacy apps, Windows 11 extras, Xbox and Copilot apps (keeps Teams, Quick Assist, Phone Link, Media Player, Movies & TV and Get Help);
  - disables every non-essential startup app (keeps drivers, audio, touchpad, GPU, security, sync, VPN, password managers, remote access, G-Helper and Teams);
  - sets IP Helper and the diagnostics services to Manual.

  App removals are the only part of Recommended that can't be undone with one click.
- **Tests on real Windows** (`tests/Run-Tests.ps1`, workflow *Tests*): on Windows Server 2022 and 2025, in Manual and Strict mode, every detector is checked against the real system, and every revertible registry, service, task and startup switch is applied, verified, undone with the Simple view's *Undo* and compared with the original state.

- **More real tests:** the Windows tests also apply and undo every command with an undo (Cloudflare DNS, Ultimate Performance, hibernation, memory compression, classic right-click menu, windowed-game optimizations) and check that the exact state comes back, and run the one-time cleanups with a junction planted in Temp to prove they never delete what it points to.
- **Releases wait for the Windows tests:** a release is published only when both CI and the 4-machine Windows tests pass.

### Fixed
- **Cloudflare DNS** now picks the adapters that carry the internet connection (those with a default gateway), instead of every physical adapter. On PCs with a Hyper-V external switch the physical card has no IP of its own, so applying failed there and the adapter that really carries the traffic (vEthernet) was skipped. VPN adapters and adapters without a gateway (WSL, Default Switch) are still left alone.
- **Disable hibernation** is no longer offered on PCs and virtual machines that cannot hibernate: there it could be switched off but never back on ("The request is not supported"). Its undo now reports that clearly.
- Removed *Stop Windows reinstalling Teams*: Windows 11 protects the registry key it writes (owned by TrustedInstaller), so the switch always failed there; Windows 11 23H2 and later no longer reinstall Teams personal anyway.
- Undo no longer touches parts of a switch that DebloatHub never changed: when some parts were already in place before (e.g. AllowTelemetry = 0 set by another tool), only the parts with a recorded original are reverted.
- Restoring a service's start type keeps its *Automatic (Delayed Start)* flag.
- A failed apply no longer leaves its undo record behind.
- System check ignores implausible refresh rates (virtual machines report 1 Hz) and placeholder RAM part numbers.
- The loading indicator no longer covers the toolbar.

## [1.1.0] - 2026-11-02

### Fixed
- **Driver Store cleanup never worked.** The cleanup plan was wrapped into a single item, so every package name (including in-use ones) was passed to `pnputil` as one argument and the action failed. It now handles each package separately, and no longer uses `pnputil /force`: Windows itself refuses packages that an unplugged device still uses, and those are logged as kept instead of failed.
- **Cleanups can no longer delete files outside their folder.** Windows PowerShell 5.1's `Remove-Item -Recurse` follows directory junctions, so a junction in the Temp or a browser-cache folder could make the elevated cleanup delete files elsewhere. Temp, browser-cache, crash-dump and Windows Update cache cleanups now remove links without following them.
- **A failed restore point stops Apply.** Before, DebloatHub logged the failure and carried on. Now nothing is changed and a message explains how to continue without one. If System Protection was off for the Windows drive, the log says that DebloatHub turned it on.
- **Cloudflare DNS** is set only on physical adapters (Ethernet, Wi-Fi), not on VPN, Hyper-V, WSL or Tailscale adapters. Each adapter's previous DNS (automatic or typed in) is recorded and restored on undo, instead of resetting every adapter to automatic.
- **Ultimate Performance** undo returns to the power plan that was active before, not always Balanced.
- **32-bit PowerShell:** started from a 32-bit program, DebloatHub relaunches itself in 64-bit PowerShell. Before, machine-wide policies were written to `WOW6432Node`, where Windows ignores them, and the check read the same wrong place and reported success.
- **Launcher:** works in folders whose name contains an apostrophe (e.g. `C:\Users\D'Angelo\Downloads`), and shows a message when the administrator prompt is declined instead of closing silently.
- **Memory compression** now explains that it needs the SysMain service when SysMain is disabled, instead of failing with an MMAgent error.
- **Leftovers after upgrading Windows 10 to 11:** Windows 10-only tweaks DebloatHub applied (for example the Ndu driver or News and Interests) were greyed out on Windows 11 and could not be undone. They now show a purple *Left over* badge and can be switched off and undone, also with the Simple view's *Undo*.
- **"Applied" for things that are not installed:** a tweak whose services, tasks or optional keys do not exist on the PC (e.g. NVIDIA telemetry without NVIDIA drivers) showed as *Applied*. It now shows *Not on this PC* and is not counted.
- **Uninstall OneDrive** and **Empty Recycle Bin** act on the signed-in user even when UAC elevated DebloatHub to another administrator account. The OneDrive uninstall also removes the setup entry that would reinstall OneDrive for new accounts.
- **Privacy and Gaming presets** no longer pre-select Advanced items (e.g. turning off Memory Integrity) or anything that cannot be undone (e.g. removing Copilot apps). The log lists what was left for you to decide. On laptops, Gaming skips the Ultimate Performance plan.
- **Developer CLI telemetry variables** are offered only when a developer tool is installed (or the variables already exist), so Recommended no longer adds 14 environment variables to every PC.
- Only one copy of DebloatHub can run at a time, so two copies cannot overwrite each other's undo records.

### Added
- **Unattended mode:** `-Preset Debloat|Gaming|Undo` or `-Selection <file>`, with `-DryRun` and `-NoRestorePoint`, and meaningful exit codes.
- **Log file:** every session is logged to `%ProgramData%\DebloatHub\Logs` (kept 90 days).
- **Save/Load selection** ask where to save or load the file.
- **Startup apps** also include the startup tasks of Microsoft Store apps (new Teams, Spotify, WhatsApp...).
- New tweaks: *Start menu: no recommendations or account notifications* (Windows 11), *Disable OneDrive and sync-provider ads in Explorer*, *Classic right-click menu* (Windows 11), *Hide Copilot button on the taskbar*, *Do not install drivers through Windows Update*, *Stop Windows reinstalling Teams*, *Block OneDrive by policy* (part of Uninstall OneDrive), and the Widgets package in *Remove Windows 11 extra apps*.
- Existing tweaks cover more: telemetry tasks include MareBackup and Device Information; Start/Settings suggestions include Settings suggested content, the post-update welcome experience and the "finish setting up your device" screen; Game DVR is also turned off by machine policy.
- **Tests and CI:** `tests/Test-DebloatHub.ps1` (syntax, consistency, JSONC editing, driver selection, link-safe cleanup, leftover logic) runs on every push in Windows PowerShell 5.1 and PowerShell 7, with PSScriptAnalyzer and unattended dry runs of every preset on Windows. Releases are only published when CI passes.
- MIT license, security policy, contribution guide and issue templates.


### Added
- **Simple view (new start page).** On first start you choose **Simple** or **Advanced**, and can tick *Remember my choice*.
  - Simple shows three big buttons: **Debloat** (the Recommended preset), **Debloat + Gaming** (adds raw mouse input, no Game Bar or Sticky Keys pop-ups, faster sleeping tabs in Edge) and **Undo**.
  - **Undo** puts back only what DebloatHub itself changed: settings that have a recorded original or a command marker.
  - Each button shows how many changes it would make. *Show me exactly what changes* opens Advanced with the switches pre-set.
  - Restore point on by default; a "Restart now" button appears after applying.
  - You can switch between the views at any time ("Advanced options" / "Simple view").
- **System check (read-only)** at the top of *Performance & Gaming*, refreshed on every scan. It covers what matters more than most tweaks but can't be changed from Windows:
  - **GPU driver:** missing, or older than 6 months.
  - **Display:** running at 60 Hz when the screen reports more.
  - **RAM:** running at the default JEDEC speed (enable XMP/EXPO), below the module rating, under 8 GB, or a single module (single channel).
  - **Memory Integrity and GPU scheduling** status.
  - The Simple view lists the tips under its status line.
- **Gaming switches:** *Make sure Game Mode is on*, *Optimizations for windowed games* (Windows 11; other settings in the same registry value are kept), *Turn on hardware-accelerated GPU scheduling*, and *Turn off Memory Integrity (Core isolation)* (Advanced, with a warning in the confirmation).
- **Remove Windows 11 extra apps:** Outlook (new), Mail and Calendar (old), Dev Home, To Do, Family, Quick Assist, Bing Search, Journal, Phone Link. Each one is its own switch.
- **Xbox apps:** now include the current Xbox app (`Microsoft.GamingApp`).
- **Debloat + Gaming** (Simple view) now also turns on Game Mode and windowed-game optimizations.
- **Manual mode for Background Services (default).** Switched-on services are set to *Manual* instead of *Disabled*: they no longer start at boot, but Windows still starts them when an app or feature asks, so nothing crashes or silently breaks.
  - Services that already don't start at boot on your PC are not listed, and each group says which ones were left out.
  - **Strict mode** (a switch in the section) brings back *Disabled* for "never, even if asked".
- **Third-party updaters & helpers: start on demand.** Google/Chrome, Brave, Adobe, Dropbox updaters and HP, Dell, AMD, Killer telemetry helpers are set to Manual. Only installed services are shown, and the apps still update through their own tasks.
- **New browser tweaks** (sources: Microsoft Edge policy docs, Mozilla's official ADMX templates):
  - *Edge: no Microsoft Rewards or MSN news feed*: useful even if you never open Edge, because its new tab page and Rewards no longer phone home.
  - *Edge: put background tabs to sleep sooner*: sleeping tabs after 5 minutes, optional efficiency mode.
  - *Firefox: no sponsored shortcuts, stories, suggestions or feature ads*.
  - *Firefox: update only while Firefox is open*: no background update task while it's closed.
- **Recommended preset rebuilt** as an explicit, curated list with a *Recommended* badge on each included tweak.
  - It covers performance and privacy wins that keep common features working and are fully undoable: no app removals, no cleanups, and the Visual Effects *Recommended* set.
  - The log says how many switches the preset turned on.

### Changed
- **Browser and IDE tweaks only appear when that program is installed** (Edge, Chrome, Firefox, Visual Studio, VS Code). They also appear when their policy key already exists, so settings applied earlier can still be reverted. Before, Chrome/Firefox policies were offered and applied even without the browser, which later made a newly installed browser say "managed by your organization".
- "Disable Connected Devices Platform (breaks Night light)" always uses Disabled in both modes, so its warning stays accurate.

### Fixed
- Undo records for services are shared between Disabled and Manual, so switching mode never loses the original start type. Records from v1.0.x are still read.
- Re-applying a tweak can no longer overwrite its recorded original with an already-changed state.

## [1.0.2] - 2026-10-28

### Changed
- The download zip now contains a short `README.txt` with installation steps, instead of the full GitHub README.
- Release pages start with installation instructions, followed by the changes.
- No changes to the tweaks themselves.

## [1.0.1] - 2026-10-28

### Fixed
- **Night light / Settings crash:** the "Phone Link & cross-device services" group could disable the Connected Devices Platform service (CDPSvc). Night light depends on it, so it could no longer be turned on and Settings > Display could crash with SystemSettings.exe error 0x40000015.
  - CDPSvc is now a separate **Advanced** switch named "Disable Connected Devices Platform (breaks Night light)", with a warning in the Apply confirmation.
  - The Phone Link group now only contains the Phone Service.
  - **If you are affected:** switch "Connected Devices Platform" off in DebloatHub (Background Services), press Apply and reboot. Your original setting is restored exactly.

## [1.0.0] - 2026-10-27

First public release.

### Highlights
- **120+ tweaks in 11 sections:** Privacy & Telemetry, AI & Copilot, Apps & Bloatware, Browsers & Dev Tools, Start/Taskbar/Explorer, Performance & Gaming, Background Services, Memory (RAM), Visual Effects, Startup Programs, System/Security/Network, Maintenance & Repair.
- **Switches show the real system state** after a background scan. Multi-item tweaks (apps, services, tasks, features, browser policies) can be chosen item by item.
- **Real undo:** original values, start types, task and feature states are recorded before the first change and restored exactly.
- **Verified apply:** every change is re-checked on the system; failures are reported, not hidden.
- **Safety net:** restore point (on by default), Dry run, confirmation for one-time actions and risky items.
- **Pros and cons on screen** for every tweak, plus a detailed hover card (what it does, who needs it, what it affects, exact changes).
- **Presets:** Recommended, Privacy, Gaming, Reset, plus Visual Effects presets.
- **Background Services section:** feature groups (printing & scanning, Xbox, Phone Link, Bluetooth, Windows Hello, network sharing, Remote Desktop, IP Helper, diagnostics, ASUS services) with one switch per service, and an option for fewer svchost processes.
- **ASUS / G-Helper support:** stop NVIDIA services while the dGPU is off in Eco mode; ASUS services list matching G-Helper.
- **Memory tools:** Ndu driver fix, memory compression toggle, empty standby memory (native API, no RAMMap download).
- Save and load your selection; Windows 10/11 version awareness; per-user settings follow the signed-in user even when UAC elevates to another admin account.
