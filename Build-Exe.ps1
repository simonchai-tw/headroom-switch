#requires -Version 5.1
# Build-Exe.ps1 — compile HeadroomSwitch.ps1 into a double-click .exe
# Run with Windows PowerShell 5.1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($PSVersionTable.PSEdition -eq 'Core') {
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $winPs -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$in = Join-Path $here 'HeadroomSwitch.ps1'
$out = Join-Path $here 'HeadroomSwitch.exe'
$icon = Join-Path $here 'HeadroomSwitch.ico'

if (-not (Test-Path $in)) {
    Write-Host 'HeadroomSwitch.ps1 not found.'
    pause
    exit 1
}

Write-Host 'Preparing ps2exe (first run only)...'
if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
    } catch {
        Write-Host "Could not install ps2exe: $($_.Exception.Message)"
        Write-Host 'Use HeadroomSwitch.bat instead.'
        pause
        exit 1
    }
}

Import-Module ps2exe -Force
$params = @{
    inputFile    = $in
    outputFile   = $out
    noConsole    = $true
    title        = 'Headroom Switch'
    description  = 'One-click Headroom for Codex / Claude'
    product      = 'Headroom Switch'
    version      = '0.2.0'
    requireAdmin = $false
}
if (Test-Path $icon) { $params.iconFile = $icon }

Write-Host 'Compiling...'
Invoke-ps2exe @params

if (Test-Path $out) {
    Write-Host ''
    Write-Host "Done: $out"
    Write-Host 'Double-click HeadroomSwitch.exe next time.'
} else {
    Write-Host 'Compile failed.'
    exit 1
}
Write-Host ''
pause
