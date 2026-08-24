@echo off
REM Headroom Switch launcher — no console window
cd /d "%~dp0"
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0HeadroomSwitch.ps1"
