#requires -Version 5.1
# Kill-Headroom.ps1 — stop Headroom Switch GUI + headroom proxy
# Optional:  powershell -File Kill-Headroom.ps1 -Revert

param([switch]$Revert, [switch]$RevertClaude)

$ErrorActionPreference = 'SilentlyContinue'
$self = $PID

function Stop-PidSafe([int]$ProcessId, [string]$Why) {
    if ($ProcessId -le 0 -or $ProcessId -eq $self) { return }
    Write-Host "kill $ProcessId  $Why"
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Test-ExeIsHeadroom([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return [bool]($Path -match '(?i)[\\/]headroom(\.exe)?$')
}

function Test-ProcHeadroom($p) {
    if (-not $p) { return $false }
    if ($p.ProcessId -eq $self) { return $false }
    $name = [string]$p.Name
    $exe = [string]$p.ExecutablePath
    $cmd = [string]$p.CommandLine
    if ($name -match '(?i)^HeadroomSwitch') { return $true }
    if ($exe -match '(?i)HeadroomSwitch\.exe$') { return $true }
    if (Test-ExeIsHeadroom $exe) { return $true }
    if ($name -match '(?i)^headroom(\.exe)?$') { return $true }
    if ($cmd -match '(?i)(?:^|[\\/''"\s])headroom\.exe(?:[''"]|\s|$)' -and $cmd -match '(?i)(?:^|\s)proxy(?:\s|$)') { return $true }
    if ($name -match '(?i)powershell' -and $cmd -match '(?i)(-File|/File)\s+".*HeadroomSwitch\.ps1"') { return $true }
    if ($name -match '(?i)powershell' -and $cmd -match '(?i)(-File|/File)\s+\S*HeadroomSwitch\.ps1') { return $true }
    return $false
}

Write-Host '=== Headroom Switch / proxy ==='

Get-Process -Name 'HeadroomSwitch','headroom' -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-PidSafe $_.Id $_.Name
}

$procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
foreach ($p in $procs) {
    if (Test-ProcHeadroom $p) {
        Stop-PidSafe $p.ProcessId ("{0} {1}" -f $p.Name, $p.ExecutablePath)
    }
}

Start-Sleep -Milliseconds 400

$ports = @(8787)
$codexDir = if ($env:CODEX_HOME -and $env:CODEX_HOME.Trim()) { $env:CODEX_HOME.Trim() } else { Join-Path $env:USERPROFILE '.codex' }
$statePaths = @(
    (Join-Path $env:LOCALAPPDATA 'HeadroomSwitch\state.json'),
    (Join-Path $codexDir 'headroom-switch-state.json')
)
$state = $null
foreach ($statePath in $statePaths) {
    if (Test-Path -LiteralPath $statePath) {
        try {
            $s = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if (-not $state) { $state = $s }
            if ($s.port) { $ports += [int]$s.port }
        } catch {}
    }
}
$ports = $ports | Select-Object -Unique

foreach ($port in $ports) {
    $lines = netstat -ano 2>$null | Select-String -Pattern 'LISTENING'
    foreach ($line in $lines) {
        $t = [string]$line.Line
        if ($t -notmatch ":$port\s") { continue }
        if ($t -match '\s(\d+)\s*$') {
            $listenPid = [int]$Matches[1]
            $wp = Get-CimInstance Win32_Process -Filter "ProcessId=$listenPid" -ErrorAction SilentlyContinue
            if (Test-ProcHeadroom $wp) {
                Stop-PidSafe $listenPid "LISTEN :$port $($wp.Name)"
            } else {
                Write-Host "skip PID $listenPid on :$port (not headroom): $($wp.Name) $($wp.ExecutablePath)"
            }
        }
    }
}

if ($Revert -or $RevertClaude) {
    Write-Host '=== revert app config pointing at localhost ==='
    $settings = Join-Path $env:USERPROFILE '.claude\settings.json'
    if ($env:CLAUDE_CONFIG_DIR -and $env:CLAUDE_CONFIG_DIR.Trim()) {
        $settings = Join-Path $env:CLAUDE_CONFIG_DIR.Trim() 'settings.json'
    }
    if (Test-Path -LiteralPath $settings) {
        try {
            $obj = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
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
    $cfg = Join-Path $codexDir 'config.toml'
    if ($state -and (Test-Path -LiteralPath $cfg)) {
        Write-Host "Codex config is at $cfg — restore a .bak if Headroom keys were left behind."
    }
}

Write-Host '=== still alive? ==='
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    Test-ProcHeadroom $_
} | ForEach-Object {
    Write-Host "STILL RUNNING $($_.ProcessId) $($_.Name) $($_.ExecutablePath)"
}
Write-Host 'Done. Tray icon should be gone. If not, kill Headroom Switch from Task Manager (not X on the window).'
