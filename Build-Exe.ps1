#requires -Version 5.1
# Build-Exe.ps1 — compile HeadroomSwitch.ps1 into a double-click .exe
# Run with Windows PowerShell 5.1 (right-click → 使用 PowerShell 執行)

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
    Write-Host "找不到 HeadroomSwitch.ps1"
    pause
    exit 1
}

Write-Host "正在準備 ps2exe（只需第一次）..."
if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
    } catch {
        Write-Host "無法安裝 ps2exe：$($_.Exception.Message)"
        Write-Host "請改雙擊 HeadroomSwitch.bat 啟動。"
        pause
        exit 1
    }
}

Import-Module ps2exe -Force
$params = @{
    inputFile   = $in
    outputFile  = $out
    noConsole   = $true
    title       = 'Headroom Switch'
    description = 'Codex GUI 一鍵掛載 Headroom'
    product     = 'Headroom Switch'
    version     = '0.1.0'
    requireAdmin = $false
}
if (Test-Path $icon) { $params.iconFile = $icon }

Write-Host "編譯中..."
Invoke-ps2exe @params

if (Test-Path $out) {
    Write-Host ""
    Write-Host "完成：$out"
    Write-Host "以後雙擊 HeadroomSwitch.exe 即可。"
} else {
    Write-Host "編譯失敗。"
    exit 1
}
Write-Host ""
pause
