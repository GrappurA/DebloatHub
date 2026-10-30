# Changelog

All notable changes to DebloatHub. Versions follow [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-10-29

### Added
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
