#requires -Version 5.1
# Kill-Headroom.ps1 — stop Headroom Switch GUI + proxy, free port 8787
# Optional:  powershell -File Kill-Headroom.ps1 -RevertClaude

param([switch]$RevertClaude)

$ErrorActionPreference = 'SilentlyContinue'
$self = $PID

function Stop-PidSafe([int]$ProcessId, [string]$Why) {
    if ($ProcessId -le 0 -or $ProcessId -eq $self) { return }
    Write-Host "kill $ProcessId  $Why"
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

Write-Host '=== Headroom Switch / proxy ==='

Get-Process -Name 'HeadroomSwitch','headroom' -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-PidSafe $_.Id $_.Name
}

$procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
foreach ($p in $procs) {
    if ($p.ProcessId -eq $self) { continue }
    $blob = "$($p.Name) $($p.CommandLine)"
    if ($blob -match 'HeadroomSwitch(\.ps1|\.exe|\.bat|\.vbs)?' -or $blob -match '(?i)headroom(\.exe)?(\s|$).*proxy' -or $blob -match '(?i)[\\/]headroom(\.exe)?') {
        if ($p.Name -eq 'powershell.exe' -or $p.Name -eq 'pwsh.exe') {
            if ($blob -notmatch 'HeadroomSwitch') { continue }
        }
        Stop-PidSafe $p.ProcessId $blob.Substring(0, [Math]::Min(120, $blob.Length))
    }
}

Start-Sleep -Milliseconds 400

$ports = @(8787)
$statePath = Join-Path $env:USERPROFILE '.codex\headroom-switch-state.json'
if (Test-Path $statePath) {
    try {
        $s = Get-Content -Raw $statePath | ConvertFrom-Json
        if ($s.port) { $ports += [int]$s.port }
    } catch {}
}
$ports = $ports | Select-Object -Unique

foreach ($port in $ports) {
    $lines = netstat -ano -p tcp 2>$null | Select-String -Pattern ":$port\s+.*LISTENING"
    foreach ($line in $lines) {
        if ($line.Line -match '\s(\d+)\s*$') {
            $listenPid = [int]$Matches[1]
            $wp = Get-CimInstance Win32_Process -Filter "ProcessId=$listenPid" -ErrorAction SilentlyContinue
            $blob = "$($wp.Name) $($wp.CommandLine)"
            if ($blob -match '(?i)headroom|python|HeadroomSwitch') {
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
    $_.ProcessId -ne $self -and ("$($_.Name) $($_.CommandLine)" -match '(?i)HeadroomSwitch|headroom')
} | ForEach-Object {
    Write-Host "STILL RUNNING $($_.ProcessId) $($_.Name) $($_.CommandLine)"
}
Write-Host 'Done. Tray icon should be gone. If not, kill Headroom Switch from Task Manager (not X on the window).'
