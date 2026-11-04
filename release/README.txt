DebloatHub {{VERSION}} - Installation
====================================

DebloatHub is portable: there is nothing to install. Keep the files together
in one folder and start it from there.

QUICK START
-----------
Even quicker, without the zip: open PowerShell, paste this and press Enter:
    irm https://grappura.github.io/DebloatHub/install.ps1 | iex

With the zip:
1. Extract the WHOLE zip to a folder (for example C:\Tools\DebloatHub).
   Do not run it from inside the zip.
2. Double-click "Start DebloatHub.bat".
3. Click "Yes" when Windows asks for administrator rights.
4. Wait a few seconds for the first scan. The switches then show what is
   already ON on your PC.

"WINDOWS PROTECTED YOUR PC"?
----------------------------
Windows shows this for any downloaded script that is not code-signed.
Click "More info" and then "Run anyway".

To avoid it, before extracting: right-click DebloatHub.zip > Properties >
tick "Unblock" (bottom of the General tab) > OK, then extract.

To check the download, run this in PowerShell in the download folder and
compare the result with SHA256SUMS.txt on the release page:
    Get-FileHash DebloatHub.zip

FIRST USE
---------
- Hover a switch to see what it does, who needs it, its pros and cons and
  the exact changes.
- Start from a preset (Recommended, Maximum, Privacy, Gaming) or flip
  switches yourself.
  Nothing changes until you press Apply.
- Leave "Restore point first" ON. Turn on "Dry run" to preview without
  changing anything.
- Press Apply, then sign out or reboot when the log tells you to.
- To undo a tweak: switch it OFF and press Apply. DebloatHub restores the
  exact setting it found before changing it.

REQUIREMENTS
------------
- Windows 10 or Windows 11 (64-bit)
- Windows PowerShell 5.1 (built into Windows)
- An administrator account

UPDATING
--------
Download the new zip and replace the old files. Your undo records are kept
in the registry, so tweaks applied with an older version can still be undone.

UNINSTALLING
------------
Click "Remove DebloatHub" (Advanced view, or the link at the bottom of the
Simple view). It offers to undo DebloatHub's changes first, then deletes its
files, logs, settings and undo records, and this folder if it holds nothing
else.

COMMAND LINE (NO WINDOW)
------------------------
From an administrator PowerShell window in this folder:
    .\DebloatHub.ps1 -Preset Debloat      (or Maximum, or Undo)
    .\DebloatHub.ps1 -Selection my-selection.json
Add -DryRun to only list what would change.

TROUBLESHOOTING
---------------
- Nothing happens after clicking Yes: open PowerShell in this folder and run
    powershell -ExecutionPolicy Bypass -File .\DebloatHub.ps1 -ShowConsole
  The console stays open and shows the error.
- Startup errors are also saved to %TEMP%\DebloatHub-error.log
- Every session is logged to %ProgramData%\DebloatHub\Logs
- "No restore point could be created": turn on System Protection for C:
  (System Properties > System Protection), or switch off "Restore point
  first" to continue without one.
- Your antivirus flags it: debloat tools change system settings, which some
  antivirus programs report as suspicious. The full source is the
  DebloatHub.ps1 file in this folder and on GitHub.

Project page, full documentation and bug reports:
https://github.com/GrappurA/DebloatHub
