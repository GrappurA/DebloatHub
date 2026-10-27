@echo off
rem Double-click to start DebloatHub (asks for administrator rights once).
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -Path '%~dp0DebloatHub.ps1' -ErrorAction SilentlyContinue; Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0DebloatHub.ps1\" -Elevated'"
