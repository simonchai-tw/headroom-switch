#requires -Version 5.1
# Build-Exe.ps1 — compile HeadroomSwitch.ps1 into a double-click .exe
# Double-click Build-Exe.bat (not this file) so Windows PowerShell 5.1 runs it.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Wait-Close {
    Write-Host ''
    Write-Host 'Press Enter to close.'
    try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 3 }
}

if ($PSVersionTable.PSEdition -eq 'Core') {
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $winPs)) {
        Write-Host 'Need Windows PowerShell 5.1 (powershell.exe), not pwsh.'
        Wait-Close
        exit 1
    }
    & $winPs -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$in = Join-Path $here 'HeadroomSwitch.ps1'
$out = Join-Path $here 'HeadroomSwitch.exe'
$icon = Join-Path $here 'HeadroomSwitch.ico'

if (-not (Test-Path -LiteralPath $in)) {
    Write-Host 'HeadroomSwitch.ps1 not found. Put this script in the same folder.'
    Wait-Close
    exit 1
}

Write-Host 'Preparing ps2exe (first run only)...'
if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
        $prevPolicy = 'Untrusted'
        try { $prevPolicy = (Get-PSRepository -Name PSGallery).InstallationPolicy } catch {}
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        try {
            Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
        } finally {
            try { Set-PSRepository -Name PSGallery -InstallationPolicy $prevPolicy } catch {}
        }
    } catch {
        Write-Host "Could not install ps2exe: $($_.Exception.Message)"
        Write-Host 'Use HeadroomSwitch.bat instead.'
        Wait-Close
        exit 1
    }
}

Import-Module ps2exe -Force
# FileVersion must be numeric; the public release name is 0.3.0.
$params = @{
    inputFile    = $in
    outputFile   = $out
    noConsole    = $true
    title        = 'Headroom Switch'
    description  = 'One-click Headroom for Codex / Claude'
    product      = 'Headroom Switch'
    version      = '0.3.0.0'
    requireAdmin = $false
}
if (Test-Path -LiteralPath $icon) { $params.iconFile = $icon }

Write-Host 'Compiling...'
try {
    Invoke-ps2exe @params
} catch {
    Write-Host "Compile error: $($_.Exception.Message)"
    Wait-Close
    exit 1
}

if (Test-Path -LiteralPath $out) {
    Write-Host ''
    Write-Host "Done: $out"
    Write-Host 'Double-click HeadroomSwitch.exe next time.'
} else {
    Write-Host 'Compile failed — no exe written.'
    Wait-Close
    exit 1
}
Wait-Close
