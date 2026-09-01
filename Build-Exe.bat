@echo off
REM Compile HeadroomSwitch.exe with Windows PowerShell 5.1
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Exe.ps1"
if errorlevel 1 (
  echo.
  echo Build failed.
  pause
)
