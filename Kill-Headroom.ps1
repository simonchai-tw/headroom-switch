#requires -Version 5.1
# Kill-Headroom.ps1 — stop Headroom Switch GUI + headroom proxy
# Optional:  powershell -File Kill-Headroom.ps1 -RevertClaude

param([switch]$RevertClaude)

$ErrorActionPreference = 'SilentlyContinue'
$self = $PID

function Stop-PidSafe([int]$ProcessId, [string]$Why) {
    if ($ProcessId -le 0 -or $ProcessId -eq $self) { return }
    Write-Host "kill $ProcessId  $Why"
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Test-BlobHeadroom([string]$Blob) {
    if ($Blob -match 'HeadroomSwitch') { return $true }
    if ($Blob -match '(?i)headroom\.exe') { return $true }
    if ($Blob -match '(?i)(["'']|\s|^)headroom(\.exe)?(["'']|\s|$)') { return $true }
    return $false
}

Write-Host '=== Headroom Switch / proxy ==='

Get-Process -Name 'HeadroomSwitch','headroom' -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-PidSafe $_.Id $_.Name
}

$procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
foreach ($p in $procs) {
    if ($p.ProcessId -eq $self) { continue }
    $blob = "$($p.Name) $($p.CommandLine)"
    if (Test-BlobHeadroom $blob) {
        if (($p.Name -eq 'powershell.exe' -or $p.Name -eq 'pwsh.exe') -and ($blob -notmatch 'HeadroomSwitch')) { continue }
        Stop-PidSafe $p.ProcessId $blob.Substring(0, [Math]::Min(120, $blob.Length))
    }
}

Start-Sleep -Milliseconds 400

$ports = @(8787)
$statePaths = @(
    (Join-Path $env:LOCALAPPDATA 'HeadroomSwitch\state.json'),
    (Join-Path $env:USERPROFILE '.codex\headroom-switch-state.json')
)
foreach ($statePath in $statePaths) {
    if (Test-Path $statePath) {
        try {
            $s = Get-Content -Raw $statePath | ConvertFrom-Json
            if ($s.port) { $ports += [int]$s.port }
        } catch {}
    }
}
$ports = $ports | Select-Object -Unique

foreach ($port in $ports) {
    $lines = netstat -ano -p tcp 2>$null | Select-String -Pattern ":$port\s+.*LISTENING"
    foreach ($line in $lines) {
        if ($line.Line -match '\s(\d+)\s*$') {
            $listenPid = [int]$Matches[1]
            $wp = Get-CimInstance Win32_Process -Filter "ProcessId=$listenPid" -ErrorAction SilentlyContinue
            $blob = "$($wp.Name) $($wp.CommandLine)"
            if (Test-BlobHeadroom $blob) {
                Stop-PidSafe $listenPid "LISTEN :$port $blob"
            } else {
                Write-Host "skip PID $listenPid on :$port (not headroom): $blob"
            }
        }
    }
}

if ($RevertClaude) {
    Write-Host '=== revert Claude env pointing at localhost ==='
    $settings = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (Test-Path $settings) {
        try {
            $obj = Get-Content -Raw $settings | ConvertFrom-Json
            if ($obj.env -and $obj.env.ANTHROPIC_BASE_URL -match '127\.0\.0\.1:') {
                $obj.env.PSObject.Properties.Remove('ANTHROPIC_BASE_URL')
                $json = $obj | ConvertTo-Json -Depth 20
                $utf8 = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($settings, $json, $utf8)
                Write-Host "cleared ANTHROPIC_BASE_URL in $settings"
            }
        } catch {
            Write-Host "could not edit $settings : $($_.Exception.Message)"
        }
    }
}

Write-Host '=== still alive? ==='
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessId -ne $self -and (Test-BlobHeadroom ("$($_.Name) $($_.CommandLine)"))
} | ForEach-Object {
    Write-Host "STILL RUNNING $($_.ProcessId) $($_.Name) $($_.CommandLine)"
}
Write-Host 'Done. Tray icon should be gone. If not, kill Headroom Switch from Task Manager (not X on the window).'
