# Changelog

All notable changes to DebloatHub. Versions follow [Semantic Versioning](https://semver.org/).

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
