# Contributing to DebloatHub

Thanks for helping. Bug reports, tweak ideas and pull requests are all welcome.

## Reporting a bug

Open an issue with the **Bug report** form. The most useful details:
- Windows version and build (shown at the top left of the window) and edition (Home, Pro...);
- what you switched, what you expected and what happened;
- the log: `%ProgramData%\DebloatHub\Logs\DebloatHub-<date>.log` (remove anything private).

Security problems: see [SECURITY.md](SECURITY.md) instead.

## Suggesting a tweak

Use the **Tweak request** form. Please include the exact registry value, service, task or command, a source (Microsoft documentation, ADMX template, or a well-known tool), and what it breaks.

## Pull requests

1. Tweaks are data: add an `fTw` line (see *Adding your own tweaks* in the README) and a `$more['Name']=@(need it?, pros, cons)` entry. Be honest in the cons.
2. Every change must be undoable unless it is a clearly labelled one-time action. Prefer `fReg`, `fSvc`/`fSvm`, `fTask`: their originals are recorded automatically.
3. Never use `Remove-Item -Recurse` on folders a user can write to; use `Clear-Folder` (Windows PowerShell 5.1 follows junctions).
4. Keep `DebloatHub.ps1` pure ASCII with CRLF line endings (Windows PowerShell 5.1 reads BOM-less files as ANSI).
5. Run the tests: `powershell -NoProfile -File tests\Test-DebloatHub.ps1`. CI runs them on every push, plus PSScriptAnalyzer and unattended dry runs on Windows.
6. Add a line to the `Unreleased` (or next version) section of `CHANGELOG.md`.
7. Test real changes in a virtual machine, not on your main PC.

## Releasing (maintainer)

1. Set `$AppVersion` in `DebloatHub.ps1` and add a `## [x.y.z] - date` section to `CHANGELOG.md`.
2. `git tag vx.y.z && git push origin vx.y.z`. The release workflow runs CI first and publishes only if it passes.
