@echo off
rem Double-click to start DebloatHub (asks for administrator rights once).
rem The script path is passed in an environment variable, so folder names with apostrophes, spaces or brackets work.
cd /d "%~dp0"
set "DH_SCRIPT=%~dp0DebloatHub.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:DH_SCRIPT; Unblock-File -LiteralPath $p -ErrorAction SilentlyContinue; try { Start-Process powershell -Verb RunAs -WindowStyle Hidden -ErrorAction Stop -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File \"' + $p + '\" -Elevated') } catch { Add-Type -AssemblyName PresentationFramework; [void][Windows.MessageBox]::Show('DebloatHub needs administrator rights. Start it again and click Yes in the Windows prompt.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message, 'DebloatHub') }"
