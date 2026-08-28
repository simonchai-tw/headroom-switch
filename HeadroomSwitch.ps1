#requires -Version 5.1
# Headroom Switch — one-click Headroom proxy for Codex / Claude on Windows
# Encoding: UTF-8 with BOM (Windows PowerShell 5.1)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 6) {
    $sta = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($sta -ne 'STA') {
        $exe = Join-Path $PSHOME 'powershell.exe'
        Start-Process $exe -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath
        )
        exit
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [void][System.Windows.Forms.Application]::SetHighDpiMode('PerMonitorV2') } catch {}

$mutex = New-Object System.Threading.Mutex($false, 'Local\HeadroomSwitchSingleton')
$script:HasMutex = $false
try {
    $script:HasMutex = [bool]$mutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $script:HasMutex = $true
}
if (-not $script:HasMutex) {
    [void][System.Windows.Forms.MessageBox]::Show(
        'Headroom Switch is already running.',
        'Headroom Switch'
    )
    exit
}

function C([int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }
$Ui = @{
    Bg       = C 12 13 12
    Elevated = C 20 22 20
    Inset    = C 16 18 16
    Fg       = C 236 238 233
    Muted    = C 141 146 138
    Subtle   = C 107 112 104
    Save     = C 127 154 134
    SaveFg   = C 12 13 12
    Accent   = C 197 205 192
    LampOff  = C 58 61 58
    Danger   = C 181 106 94
    Line     = C 48 52 48
}

$script:AppVersion = '0.2.2'
$script:Port = 8787
$script:Profile = 'balanced'
$script:SegButtons = @{}
$script:AppButtons = @{}
$script:TargetApp = 'codex'
$script:IsOn = $false
$script:Busy = $false
$script:ProxyPid = 0
$script:CustomHeadroom = ''
$script:CloseToTray = $false
$script:LastLampOn = $null
$script:ReallyExit = $false
$script:PreviousProvider = $null
$script:PreviousOpenaiBaseUrl = $null
$script:ClaudePrevBaseUrl = $null
$script:ClaudeHadBaseUrl = $false
$script:HeadroomExeCache = $null
$script:HeadroomExeCacheAt = [datetime]::MinValue

if ($env:CODEX_HOME -and $env:CODEX_HOME.Trim()) {
    $script:CodexDir = $env:CODEX_HOME.Trim()
} else {
    $script:CodexDir = Join-Path $env:USERPROFILE '.codex'
}
$script:ConfigPath = Join-Path $script:CodexDir 'config.toml'
$script:AppDataDir = Join-Path $env:LOCALAPPDATA 'HeadroomSwitch'
if (-not $script:AppDataDir) { $script:AppDataDir = Join-Path $env:USERPROFILE 'AppData\Local\HeadroomSwitch' }
$script:StatePath = Join-Path $script:AppDataDir 'state.json'
$script:LegacyStatePath = Join-Path $script:CodexDir 'headroom-switch-state.json'

if ($env:CLAUDE_CONFIG_DIR -and $env:CLAUDE_CONFIG_DIR.Trim()) {
    $script:ClaudeDir = $env:CLAUDE_CONFIG_DIR.Trim()
} else {
    $script:ClaudeDir = Join-Path $env:USERPROFILE '.claude'
}
$script:ClaudeSettingsPath = Join-Path $script:ClaudeDir 'settings.json'

function Backup-ConfigFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $name = Split-Path -Leaf $Path
    if ($name -eq 'state.json' -or $name -eq 'headroom-switch-state.json') { return }
    $dir = Split-Path -Parent $Path
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $bak = Join-Path $dir ($name + '.' + $stamp + '.bak')
    if (Test-Path -LiteralPath $bak) {
        $bak = Join-Path $dir ($name + '.' + $stamp + '.' + [guid]::NewGuid().ToString('n').Substring(0, 6) + '.bak')
    }
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    $old = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ($name + '.*.bak') } |
        Sort-Object LastWriteTime -Descending)
    if ($old.Count -gt 5) {
        $old | Select-Object -Skip 5 | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Backup-ConfigFile $Path
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('n') + '.tmp'
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $Text, $enc)
    if (Test-Path -LiteralPath $Path) {
        $swapBak = $Path + '.replace.bak'
        [System.IO.File]::Replace($tmp, $Path, $swapBak)
        Remove-Item -LiteralPath $swapBak -Force -ErrorAction SilentlyContinue
    } else {
        [System.IO.File]::Move($tmp, $Path)
    }
}

function Read-Utf8([string]$Path) {
    if (-not (Test-Path $Path)) { return '' }
    $enc = New-Object System.Text.UTF8Encoding $false
    return [System.IO.File]::ReadAllText($Path, $enc)
}

function Get-Newline([string]$Text) {
    if ($Text -match "`r`n") { return "`r`n" }
    return "`n"
}

function Collapse-Blank([string]$Text, [string]$Nl) {
    $dbl = $Nl + $Nl
    $Text = [regex]::Replace($Text, '(\r?\n){3,}', [System.Text.RegularExpressions.MatchEvaluator] { param($m) $dbl })
    $Text = $Text.TrimStart([char]13, [char]10)
    if (-not $Text.EndsWith("`n")) { $Text += $Nl }
    return $Text
}

function Read-ModelProvider([string]$Content) {
    $m = [regex]::Match($Content, '(?m)^model_provider\s*=\s*"([^"]*)"\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Test-ProviderLine([string]$Content) {
    return [regex]::IsMatch($Content, '(?m)^model_provider\s*=')
}

function Set-ProviderLine([string]$Content, [string]$Provider, [string]$Nl) {
    $line = "model_provider = `"$Provider`""
    if (Test-ProviderLine $Content) {
        return [regex]::Replace($Content, '(?m)^model_provider\s*=.*$', $line, 1)
    }
    if ([string]::IsNullOrWhiteSpace($Content)) { return $line + $Nl }
    return $line + $Nl + $Nl + $Content
}

function Remove-ProviderLine([string]$Content) {
    return [regex]::Replace($Content, '(?m)^model_provider\s*=.*\r?\n?', '')
}

function Remove-TomlTable([string]$Content, [string]$TableName) {
    $esc = [regex]::Escape($TableName)
    return [regex]::Replace(
        $Content,
        "(?m)^\[$esc\][ \t]*\r?\n(?:(?!\[).*\r?\n?)*",
        ''
    )
}

function Remove-HeadroomBlock([string]$Content) {
    return Remove-TomlTable $Content 'model_providers.headroom'
}

function Remove-McpBlock([string]$Content) {
    return Remove-TomlTable $Content 'mcp_servers.headroom'
}

function Get-HeadroomBlock([int]$Port, [string]$Nl) {
    return (
        '[model_providers.headroom]' + $Nl +
        'name = "OpenAI via Headroom proxy"' + $Nl +
        "base_url = `"http://127.0.0.1:$Port/v1`"" + $Nl +
        'wire_api = "responses"' + $Nl +
        'supports_websockets = true' + $Nl +
        'requires_openai_auth = true'
    )
}

function Get-McpBlock([string]$Command, [string]$Nl) {
    $escaped = $Command.Replace('\', '\\').Replace('"', '\"')
    return (
        '[mcp_servers.headroom]' + $Nl +
        "command = `"$escaped`"" + $Nl +
        'args = ["mcp", "serve"]'
    )
}

function Read-OpenaiBaseUrl([string]$Content) {
    $m = [regex]::Match($Content, '(?m)^openai_base_url\s*=\s*"([^"]*)"\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Set-OpenaiBaseLine([string]$Content, [string]$Url, [string]$Nl) {
    $line = "openai_base_url = `"$Url`""
    if ([regex]::IsMatch($Content, '(?m)^openai_base_url\s*=')) {
        return [regex]::Replace($Content, '(?m)^openai_base_url\s*=.*$', $line, 1)
    }
    if ([string]::IsNullOrWhiteSpace($Content)) { return $line + $Nl }
    return $line + $Nl + $Nl + $Content
}

function Remove-OpenaiBaseLine([string]$Content) {
    return [regex]::Replace($Content, '(?m)^openai_base_url\s*=.*\r?\n?', '')
}

function Test-CodexEnabled([string]$Content, [int]$Port) {
    $base = Read-OpenaiBaseUrl $Content
    if ($base -and $base -match "127\.0\.0\.1:$Port(/|$)") { return $true }
    return ((Read-ModelProvider $Content) -eq 'headroom')
}

function Enable-CodexConfig([string]$Content, [int]$Port, [string]$McpCommand) {
    $nl = Get-Newline $Content
    if ([string]::IsNullOrWhiteSpace($Content)) { $nl = "`r`n"; $Content = '' }
    $Content = Remove-HeadroomBlock $Content
    $Content = Remove-McpBlock $Content
    $Content = Set-ProviderLine $Content 'headroom' $nl
    $Content = Set-OpenaiBaseLine $Content "http://127.0.0.1:$Port/v1" $nl
    $Content = Collapse-Blank $Content $nl
    $block = Get-HeadroomBlock $Port $nl
    $cmd = if ($McpCommand) { $McpCommand } else { 'headroom' }
    $mcp = Get-McpBlock $cmd $nl
    $Content = $Content.TrimEnd() + $nl + $nl + $block + $nl + $nl + $mcp + $nl
    return Collapse-Blank $Content $nl
}

function Disable-CodexConfig([string]$Content, $PreviousProvider, $PreviousOpenaiBaseUrl) {
    $nl = Get-Newline $Content
    $Content = Remove-HeadroomBlock $Content
    $Content = Remove-McpBlock $Content
    if ($PreviousProvider -and $PreviousProvider -ne 'headroom') {
        $Content = Set-ProviderLine $Content $PreviousProvider $nl
    } else {
        $Content = Remove-ProviderLine $Content
    }
    if ($PreviousOpenaiBaseUrl -and $PreviousOpenaiBaseUrl -notmatch '127\.0\.0\.1:') {
        $Content = Set-OpenaiBaseLine $Content $PreviousOpenaiBaseUrl $nl
    } else {
        $Content = Remove-OpenaiBaseLine $Content
    }
    return Collapse-Blank $Content $nl
}

function Get-AnthropicBaseUrl([int]$Port) { return "http://127.0.0.1:$Port" }

function ConvertTo-PrettyJson($Obj) {
    return ($Obj | ConvertTo-Json -Depth 20)
}

function Read-JsonObject([string]$Path) {
    $raw = Read-Utf8 $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return New-Object PSObject
    }
    try {
        return $raw | ConvertFrom-Json
    } catch {
        throw "Refusing to write $Path — the file is not valid JSON. Restore a backup, then try again."
    }
}

function Test-HasProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $false }
    return $null -ne $Obj.PSObject.Properties[$Name]
}

function Get-PropNames($Obj) {
    if ($null -eq $Obj) { return @() }
    return @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
}

function Ensure-Note($Obj, [string]$Name, $Value) {
    if (Test-HasProp $Obj $Name) {
        $Obj.$Name = $Value
    } else {
        $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-Note($Obj, [string]$Name) {
    if (-not (Test-HasProp $Obj $Name)) { return $null }
    return $Obj.$Name
}


function Test-ClaudeEnabled([int]$Port) {
    try {
        $obj = Read-JsonObject $script:ClaudeSettingsPath
    } catch {
        return $false
    }
    $envObj = Get-Note $obj 'env'
    $url = Get-Note $envObj 'ANTHROPIC_BASE_URL'
    if ($url -and ("$url" -match "127\.0\.0\.1:$Port(/|$)")) { return $true }
    return $false
}

function Get-ClaudeDesktopPaths {
    $list = New-Object System.Collections.Generic.List[string]
    $classic = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
    [void]$list.Add($classic)
    $pkgRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path $pkgRoot) {
        $pkgs = @(Get-ChildItem -Path $pkgRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Claude_*' })
        foreach ($p in $pkgs) {
            $c = Join-Path $p.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json'
            [void]$list.Add($c)
        }
    }
    return @($list | Select-Object -Unique)
}

function Enable-ClaudeSettings([int]$Port) {
    $obj = Read-JsonObject $script:ClaudeSettingsPath
    $envObj = Get-Note $obj 'env'
    if ($null -eq $envObj) {
        $envObj = New-Object PSObject
        Ensure-Note $obj 'env' $envObj
    }
    $prev = Get-Note $envObj 'ANTHROPIC_BASE_URL'
    if ($prev -and ("$prev" -notmatch '127\.0\.0\.1:')) {
        $script:ClaudePrevBaseUrl = "$prev"
        $script:ClaudeHadBaseUrl = $true
    } elseif (-not $prev) {
        $script:ClaudeHadBaseUrl = $false
    }
    Ensure-Note $envObj 'ANTHROPIC_BASE_URL' (Get-AnthropicBaseUrl $Port)
    $dir = Split-Path $script:ClaudeSettingsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Utf8NoBom $script:ClaudeSettingsPath (ConvertTo-PrettyJson $obj)
}

function Disable-ClaudeSettings {
    if (-not (Test-Path $script:ClaudeSettingsPath)) { return }
    $obj = Read-JsonObject $script:ClaudeSettingsPath
    $envObj = Get-Note $obj 'env'
    if ($null -eq $envObj) { return }
    if ($script:ClaudeHadBaseUrl -and $script:ClaudePrevBaseUrl -and ($script:ClaudePrevBaseUrl -notmatch '127\.0\.0\.1:')) {
        Ensure-Note $envObj 'ANTHROPIC_BASE_URL' $script:ClaudePrevBaseUrl
    } else {
        if (Test-HasProp $envObj 'ANTHROPIC_BASE_URL') {
            $envObj.PSObject.Properties.Remove('ANTHROPIC_BASE_URL')
        }
    }
    $envNames = @(Get-PropNames $envObj)
    if ($envNames.Count -eq 0 -and (Test-HasProp $obj 'env')) {
        $obj.PSObject.Properties.Remove('env')
    }
    Write-Utf8NoBom $script:ClaudeSettingsPath (ConvertTo-PrettyJson $obj)
}

function Enable-ClaudeDesktop([string]$Command) {
    $cmd = if ($Command) { $Command } else { 'headroom' }
    foreach ($path in (Get-ClaudeDesktopPaths)) {
        $dir = Split-Path $path
        $exists = Test-Path $path
        if (-not $exists -and -not (Test-Path $dir)) {
            if ($path -notmatch [regex]::Escape((Join-Path $env:APPDATA 'Claude'))) { continue }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if (-not $exists -and $path -notmatch [regex]::Escape((Join-Path $env:APPDATA 'Claude'))) { continue }
        $obj = Read-JsonObject $path
        $mcp = Get-Note $obj 'mcpServers'
        if ($null -eq $mcp) {
            $mcp = New-Object PSObject
            Ensure-Note $obj 'mcpServers' $mcp
        }
        $server = New-Object PSObject
        Ensure-Note $server 'command' $cmd
        Ensure-Note $server 'args' @('mcp', 'serve')
        Ensure-Note $mcp 'headroom' $server
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Write-Utf8NoBom $path (ConvertTo-PrettyJson $obj)
        Add-Log "MCP → $path"
    }
}

function Disable-ClaudeDesktop {
    foreach ($path in (Get-ClaudeDesktopPaths)) {
        if (-not (Test-Path $path)) { continue }
        $obj = Read-JsonObject $path
        $mcp = Get-Note $obj 'mcpServers'
        if ($null -eq $mcp) { continue }
        if (Test-HasProp $mcp 'headroom') {
            $mcp.PSObject.Properties.Remove('headroom')
        }
        $left = @(Get-PropNames $mcp)
        if ($left.Count -eq 0 -and (Test-HasProp $obj 'mcpServers')) {
            $obj.PSObject.Properties.Remove('mcpServers')
        }
        Write-Utf8NoBom $path (ConvertTo-PrettyJson $obj)
    }
}

function Normalize-Profile([string]$Name) {
    $n = "$Name".Trim().ToLowerInvariant()
    if ($n -eq 'speed' -or $n -eq 'maximum' -or $n -eq 'balanced') { return $n }
    return 'balanced'
}

function Normalize-App([string]$Name) {
    $n = "$Name".Trim().ToLowerInvariant()
    if ($n -eq 'claude') { return 'claude' }
    return 'codex'
}

function Get-ModeArgs {
    switch (Normalize-Profile $script:Profile) {
        'speed'   { @('--mode', 'cache') }
        'maximum' { @('--mode', 'token', '--no-ccr') }
        default   { @('--mode', 'token') }
    }
}

function Get-ProxyCmd {
    $parts = @('proxy', '--port', "$($script:Port)") + @(Get-ModeArgs)
    return ($parts -join ' ')
}

function Get-ProfileHint([string]$Name) {
    switch (Normalize-Profile $Name) {
        'speed'    { return 'Fast. Cache first, almost no squeeze.' }
        'maximum'  { return 'Maximum squeeze. May drop detail.' }
        default    { return 'Default compression.' }
    }
}

function Get-DashboardUrl { return "http://127.0.0.1:$($script:Port)/dashboard" }

function Read-AppState {
    $path = $script:StatePath
    if (-not (Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $script:LegacyStatePath)) {
        $path = $script:LegacyStatePath
    }
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $s = Read-Utf8 $path | ConvertFrom-Json
        if ((Test-HasProp $s 'port') -and $s.port) {
            $script:Port = [int]$s.port
        }
        if (Test-HasProp $s 'previousProvider') {
            $script:PreviousProvider = $s.previousProvider
        }
        if ((Test-HasProp $s 'proxyPid') -and $s.proxyPid) {
            $script:ProxyPid = [int]$s.proxyPid
        }
        if ((Test-HasProp $s 'customHeadroom') -and $s.customHeadroom) {
            $script:CustomHeadroom = [string]$s.customHeadroom
        }
        if ((Test-HasProp $s 'settingsVersion') -and ([int]$s.settingsVersion -ge 3) -and (Test-HasProp $s 'closeToTray')) {
            $script:CloseToTray = [bool]$s.closeToTray
        }
        if ((Test-HasProp $s 'profile') -and $s.profile) {
            $script:Profile = Normalize-Profile ([string]$s.profile)
        }
        if ((Test-HasProp $s 'targetApp') -and $s.targetApp) {
            $script:TargetApp = Normalize-App ([string]$s.targetApp)
        }
        if (Test-HasProp $s 'previousOpenaiBaseUrl') {
            $script:PreviousOpenaiBaseUrl = $s.previousOpenaiBaseUrl
        }
        if (Test-HasProp $s 'claudePrevBaseUrl') {
            $script:ClaudePrevBaseUrl = $s.claudePrevBaseUrl
        }
        if (Test-HasProp $s 'claudeHadBaseUrl') {
            $script:ClaudeHadBaseUrl = [bool]$s.claudeHadBaseUrl
        }
    } catch {}
}

function Write-AppState {
    $obj = [ordered]@{
        port                  = $script:Port
        previousProvider      = $script:PreviousProvider
        previousOpenaiBaseUrl = $script:PreviousOpenaiBaseUrl
        proxyPid              = $script:ProxyPid
        customHeadroom        = $script:CustomHeadroom
        closeToTray           = $script:CloseToTray
        settingsVersion       = 3
        profile               = $script:Profile
        targetApp             = $script:TargetApp
        claudePrevBaseUrl     = $script:ClaudePrevBaseUrl
        claudeHadBaseUrl      = $script:ClaudeHadBaseUrl
    }
    Write-Utf8NoBom $script:StatePath ($obj | ConvertTo-Json)
}

function Find-HeadroomExe {
    if ($script:CustomHeadroom -and (Test-Path -LiteralPath $script:CustomHeadroom)) {
        return $script:CustomHeadroom
    }
    if ($script:HeadroomExeCache -and ((Get-Date) - $script:HeadroomExeCacheAt).TotalSeconds -lt 60) {
        return $script:HeadroomExeCache
    }
    $found = $null
    $cmd = Get-Command headroom -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $found = $cmd.Source }
    if (-not $found) {
        $globs = @(
            (Join-Path $env:USERPROFILE '.local\bin\headroom.exe'),
            (Join-Path $env:USERPROFILE '.local\bin\headroom'),
            (Join-Path $env:APPDATA 'Python\Python*\Scripts\headroom.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python*\Scripts\headroom.exe'),
            (Join-Path $env:USERPROFILE '.local\share\uv\tools\*\*\headroom.exe'),
            (Join-Path $env:LOCALAPPDATA 'uv\tools\*\*\headroom.exe'),
            (Join-Path $env:USERPROFILE 'AppData\Roaming\uv\tools\*\*\headroom.exe')
        )
        foreach ($g in $globs) {
            $hits = @(Get-Item -Path $g -ErrorAction SilentlyContinue)
            if ($hits.Count -gt 0) { $found = $hits[0].FullName; break }
        }
    }
    if (-not $found) {
        foreach ($py in @('py', 'python', 'python3')) {
            try {
                $which = & $py -c "import shutil; print(shutil.which('headroom') or '')" 2>$null
                if ($which -and "$which".Trim()) { $found = "$which".Trim(); break }
            } catch {}
        }
    }
    $script:HeadroomExeCache = $found
    $script:HeadroomExeCacheAt = Get-Date
    return $found
}

function Test-PortOpen([int]$Port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(180, $false)
        $connected = $ok -and $c.Connected
        try { $c.Close() } catch {}
        return $connected
    } catch { return $false }
}

function Get-ListeningPid([int]$Port) {
    try {
        $lines = netstat -ano -p tcp 2>$null | Select-String -Pattern ":$Port\s+.*LISTENING"
        foreach ($line in $lines) {
            if ($line.Line -match '\s(\d+)\s*$') { return [int]$Matches[1] }
        }
    } catch {}
    return $null
}

function Test-ProcessLooksLikeHeadroom([int]$ProcessId) {
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if (-not $p) { return $false }
        $blob = "$($p.Name) $($p.CommandLine)"
        if ($blob -match '(?i)HeadroomSwitch') { return $true }
        if ($blob -match '(?i)headroom\.exe') { return $true }
        if ($blob -match '(?i)(["'']|\s|^)headroom(\.exe)?(["'']|\s|$)') { return $true }
        return $false
    } catch { return $false }
}

function Stop-HeadroomProxy {
    if ($script:ProxyPid -gt 0) {
        if (Test-ProcessLooksLikeHeadroom $script:ProxyPid) {
            Stop-Process -Id $script:ProxyPid -Force -ErrorAction SilentlyContinue
        }
        $script:ProxyPid = 0
    }
    $listen = Get-ListeningPid $script:Port
    if ($listen -and (Test-ProcessLooksLikeHeadroom $listen)) {
        Stop-Process -Id $listen -Force -ErrorAction SilentlyContinue
    }
}

function Test-ProxyMatchesProfile([int]$ProcessId) {
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if (-not $p) { return $false }
        $cmd = "$($p.CommandLine)"
        $want = @(Get-ModeArgs)
        $mode = 'token'
        if ($want -contains 'cache') { $mode = 'cache' }
        if ($cmd -notmatch "--mode\s+$mode") { return $false }
        if ($script:Profile -eq 'maximum') {
            return ($cmd -match '--no-ccr')
        }
        return ($cmd -notmatch '--no-ccr')
    } catch { return $false }
}

function Start-HeadroomProxy {
    if (Test-PortOpen $script:Port) {
        $listen = Get-ListeningPid $script:Port
        if ($listen -and (Test-ProxyMatchesProfile $listen)) {
            $script:ProxyPid = $listen
            return $true
        }
        if ($listen -and (Test-ProcessLooksLikeHeadroom $listen)) {
            Stop-Process -Id $listen -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 250
        }
    }
    $exe = Find-HeadroomExe
    if (-not $exe) { return $false }
    $argList = @('proxy', '--port', "$($script:Port)") + @(Get-ModeArgs)
    $p = Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden -PassThru
    $script:ProxyPid = $p.Id
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortOpen $script:Port) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return (Test-PortOpen $script:Port)
}

function Restart-ProxyForProfile {
    if (-not (Test-PortOpen $script:Port) -and $script:ProxyPid -le 0) { return }
    Add-Log 'Restarting proxy so the profile applies (no app restart needed)'
    Stop-HeadroomProxy
    Start-Sleep -Milliseconds 300
    if (Start-HeadroomProxy) {
        Add-Log "Proxy restarted with $($script:Profile)"
    } else {
        Add-Log 'Proxy restart failed'
    }
}

# --- UI -------------------------------------------------------------------------

$fontUi = New-Object System.Drawing.Font('Segoe UI', 9.5)
$fontSm = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fontTitle = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
$fontMono = New-Object System.Drawing.Font('Consolas', 8)
$fontEyebrow = New-Object System.Drawing.Font('Segoe UI', 7.5)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Headroom Switch'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(400, 520)
$form.BackColor = $Ui.Bg
$form.ForeColor = $Ui.Fg
$form.Font = $fontUi

$m = 24
$cw = 352
$gap = 8
$half = [int](($cw - $gap) / 2)
$gridPad = 4
$gridGap = 4
$colW = [int](($cw - 2 * $gridPad - 2 * $gridGap) / 3)
$gx0 = $gridPad
$gx1 = $gx0 + $colW + $gridGap
$gx2 = $gx1 + $colW + $gridGap

function Enable-DoubleBuffer($ctrl) {
    try {
        $flags = [System.Reflection.BindingFlags]'NonPublic,Instance'
        $setStyle = [System.Windows.Forms.Control].GetMethod('SetStyle', $flags)
        $styles = [System.Windows.Forms.ControlStyles]
        $combo = $styles::OptimizedDoubleBuffer -bor $styles::AllPaintingInWmPaint -bor $styles::UserPaint -bor $styles::ResizeRedraw
        if ($setStyle) { [void]$setStyle.Invoke($ctrl, @($combo, $true)) }
        $prop = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', $flags)
        if ($prop) { $prop.SetValue($ctrl, $true, $null) }
    } catch {}
}
Enable-DoubleBuffer $form

function New-Card([int]$X, [int]$Y, [int]$W, [int]$H) {
    $shell = New-Object System.Windows.Forms.Panel
    $shell.Location = New-Object System.Drawing.Point($X, $Y)
    $shell.Size = New-Object System.Drawing.Size($W, $H)
    $shell.BackColor = $Ui.Line
    Enable-DoubleBuffer $shell
    $inner = New-Object System.Windows.Forms.Panel
    $inner.Location = New-Object System.Drawing.Point(1, 1)
    $inner.Size = New-Object System.Drawing.Size(($W - 2), ($H - 2))
    $inner.BackColor = $Ui.Elevated
    Enable-DoubleBuffer $inner
    [void]$shell.Controls.Add($inner)
    [void]$form.Controls.Add($shell)
    return $inner
}

function New-Lbl([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Font, $Ink) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.Font = $Font
    $l.ForeColor = $Ink
    $l.BackColor = [System.Drawing.Color]::Transparent
    [void]$form.Controls.Add($l)
    return $l
}

function New-GhostBtn([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = $Ui.Line
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.MouseOverBackColor = $Ui.Elevated
    $b.FlatAppearance.MouseDownBackColor = $Ui.Elevated
    $b.UseVisualStyleBackColor = $false
    $b.BackColor = $Ui.Elevated
    $b.ForeColor = $Ui.Fg
    $b.Font = $fontSm
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    [void]$form.Controls.Add($b)
    return $b
}

$lblEyebrow = New-Lbl 'CODEX' $m 18 $cw 14 $fontEyebrow $Ui.Subtle
$lblTitle = New-Lbl 'Headroom Switch' $m 34 $cw 34 $fontTitle $Ui.Fg
$lblSub = New-Lbl 'Direct to the model. Proxy is off.' $m 72 $cw 22 $fontSm $Ui.Muted

$rowY = 106
$lamp = New-Object System.Windows.Forms.Panel
$lampSz = 48
$lamp.Location = New-Object System.Drawing.Point(($m + 1 + $gx0 + [int](($colW - $lampSz) / 2)), $rowY)
$lamp.Size = New-Object System.Drawing.Size($lampSz, $lampSz)
$lamp.BackColor = $Ui.Bg
$lamp.Cursor = [System.Windows.Forms.Cursors]::Hand
Enable-DoubleBuffer $lamp
[void]$form.Controls.Add($lamp)

function Write-LampImage {
    $sz = $lamp.Width
    if ($sz -le 0) { return }
    $bmp = New-Object System.Drawing.Bitmap $sz, $sz
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear($Ui.Bg)
    $on = [bool]$script:IsOn
    $fill = if ($on) { $Ui.Save } else { $Ui.LampOff }
    $ring = if ($on) { $Ui.Save } else { $Ui.Line }
    $brush = New-Object System.Drawing.SolidBrush $fill
    $pen = New-Object System.Drawing.Pen $ring, 1
    $g.FillEllipse($brush, 0, 0, ($sz - 1), ($sz - 1))
    $g.DrawEllipse($pen, 0, 0, ($sz - 1), ($sz - 1))
    $core = New-Object System.Drawing.SolidBrush $(if ($on) { $Ui.Fg } else { $Ui.Inset })
    $c = [int]($sz / 2)
    $r = 6
    $g.FillEllipse($core, ($c - $r), ($c - $r), (2 * $r), (2 * $r))
    $brush.Dispose(); $pen.Dispose(); $core.Dispose(); $g.Dispose()
    $old = $lamp.BackgroundImage
    $lamp.BackgroundImage = $bmp
    $lamp.BackgroundImageLayout = 'Stretch'
    if ($old) { $old.Dispose() }
}

$script:AppButtons = @{}
$script:AppLabels = @{}
$chipHost = New-Card ($m + $gx1) ($rowY - 1) (2 * $colW + $gridGap + 2) 50
function New-AppBtn([string]$Id, [string]$Title, [int]$X, [string]$Sub = '') {
    $p = New-Object System.Windows.Forms.Panel
    $p.Tag = $Id
    $p.Location = New-Object System.Drawing.Point($X, 0)
    $p.Size = New-Object System.Drawing.Size($colW, 48)
    $p.Cursor = [System.Windows.Forms.Cursors]::Hand
    $p.BackColor = $Ui.Inset
    $click = {
        param($sender, $e)
        $id2 = $sender.Tag
        if (-not $id2) { $id2 = $sender.Parent.Tag }
        Apply-App ([string]$id2)
    }
    $p.Add_Click($click)
    if ($Sub) {
        $t = New-Object System.Windows.Forms.Label
        $t.Text = $Title
        $t.Tag = $Id
        $t.Font = $fontSm
        $t.TextAlign = 'BottomCenter'
        $t.Location = New-Object System.Drawing.Point(0, 4)
        $t.Size = New-Object System.Drawing.Size($colW, 24)
        $t.BackColor = [System.Drawing.Color]::Transparent
        $t.Cursor = [System.Windows.Forms.Cursors]::Hand
        $t.Add_Click($click)
        [void]$p.Controls.Add($t)
        $s = New-Object System.Windows.Forms.Label
        $s.Text = $Sub
        $s.Tag = $Id
        $s.Font = $fontEyebrow
        $s.TextAlign = 'TopCenter'
        $s.Location = New-Object System.Drawing.Point(0, 28)
        $s.Size = New-Object System.Drawing.Size($colW, 16)
        $s.BackColor = [System.Drawing.Color]::Transparent
        $s.Cursor = [System.Windows.Forms.Cursors]::Hand
        $s.Add_Click($click)
        [void]$p.Controls.Add($s)
        $script:AppLabels[$Id] = @($t, $s)
    } else {
        $t = New-Object System.Windows.Forms.Label
        $t.Text = $Title
        $t.Tag = $Id
        $t.Font = $fontUi
        $t.TextAlign = 'MiddleCenter'
        $t.Dock = 'Fill'
        $t.BackColor = [System.Drawing.Color]::Transparent
        $t.Cursor = [System.Windows.Forms.Cursors]::Hand
        $t.Add_Click($click)
        [void]$p.Controls.Add($t)
        $script:AppLabels[$Id] = @($t)
    }
    Enable-DoubleBuffer $p
    [void]$chipHost.Controls.Add($p)
    $script:AppButtons[$Id] = $p
    return $p
}
New-AppBtn 'codex' 'Codex' 0 | Out-Null
New-AppBtn 'claude' 'Claude' ($colW + $gridGap) '(exp.)' | Out-Null

$lblProf = New-Lbl 'Profile' $m 168 80 16 $fontSm $Ui.Subtle
$lblProfHint = New-Lbl 'Default compression' ($m + 80) 168 ($cw - 80) 16 $fontSm $Ui.Muted
$lblProfHint.TextAlign = 'MiddleRight'

$seg = New-Card $m 188 $cw 40

$script:SegButtons = @{}
$script:SegLabels = @{}
function New-SegBtn([string]$Id, [int]$X) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Tag = $Id
    $p.Location = New-Object System.Drawing.Point($X, 4)
    $p.Size = New-Object System.Drawing.Size($colW, 30)
    $p.Cursor = [System.Windows.Forms.Cursors]::Hand
    $p.BackColor = $Ui.Inset
    Enable-DoubleBuffer $p
    $click = {
        param($sender, $e)
        $id2 = $sender.Tag
        if (-not $id2) { $id2 = $sender.Parent.Tag }
        Apply-Profile ([string]$id2)
    }
    $p.Add_Click($click)
    $t = New-Object System.Windows.Forms.Label
    $t.Text = $Id
    $t.Tag = $Id
    $t.Font = $fontSm
    $t.TextAlign = 'MiddleCenter'
    $t.Dock = 'Fill'
    $t.BackColor = [System.Drawing.Color]::Transparent
    $t.Cursor = [System.Windows.Forms.Cursors]::Hand
    $t.Add_Click($click)
    [void]$p.Controls.Add($t)
    [void]$seg.Controls.Add($p)
    $script:SegButtons[$Id] = $p
    $script:SegLabels[$Id] = $t
    return $p
}
New-SegBtn 'speed' $gx0 | Out-Null
New-SegBtn 'balanced' $gx1 | Out-Null
New-SegBtn 'maximum' $gx2 | Out-Null

$status = New-Card $m 240 $cw 112

function New-StatusRow([int]$Y, [string]$Label) {
    $dot = New-Object System.Windows.Forms.Panel
    $dot.Size = New-Object System.Drawing.Size(7, 7)
    $dot.Location = New-Object System.Drawing.Point(14, ($Y + 8))
    $dot.BackColor = $Ui.LampOff
    [void]$status.Controls.Add($dot)
    $tt = New-Object System.Windows.Forms.Label
    $tt.Location = New-Object System.Drawing.Point(30, $Y)
    $tt.Size = New-Object System.Drawing.Size(306, 16)
    $tt.Font = $fontSm
    $tt.ForeColor = $Ui.Fg
    $tt.Text = $Label
    $tt.BackColor = [System.Drawing.Color]::Transparent
    [void]$status.Controls.Add($tt)
    $d = New-Object System.Windows.Forms.Label
    $d.Location = New-Object System.Drawing.Point(30, ($Y + 16))
    $d.Size = New-Object System.Drawing.Size(306, 15)
    $d.Font = $fontMono
    $d.ForeColor = $Ui.Muted
    $d.Text = ''
    $d.BackColor = [System.Drawing.Color]::Transparent
    [void]$status.Controls.Add($d)
    return @{ Dot = $dot; Title = $tt; Detail = $d }
}

$rowCfg = New-StatusRow 8 'App'
$rowPx = New-StatusRow 40 'Proxy'
$rowBin = New-StatusRow 72 'Binary'

$lblLogH = New-Lbl 'Log' $m 364 $cw 14 $fontSm $Ui.Subtle
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BorderStyle = 'FixedSingle'
$logBox.BackColor = $Ui.Elevated
$logBox.ForeColor = $Ui.Muted
$logBox.Font = $fontMono
$logBox.Location = New-Object System.Drawing.Point($m, 380)
$logBox.Size = New-Object System.Drawing.Size($cw, 56)
$logBox.TabStop = $false
[void]$form.Controls.Add($logBox)

$btnDash = New-GhostBtn 'Dashboard' $m 448 $half 36
$btnSettings = New-GhostBtn 'Settings' ($m + $half + $gap) 448 $half 36

$lblHint = New-Lbl 'Quit Codex or Claude from the tray, then reopen.' $m 492 $cw 20 $fontSm $Ui.Subtle

function Add-Log([string]$Msg) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $line = "$stamp  $Msg"
    if ([string]::IsNullOrEmpty($logBox.Text)) { $logBox.Text = $line }
    else { $logBox.AppendText("`r`n$line") }
}

function Set-Lamp($Row, [bool]$On, [string]$Detail) {
    $c = if ($On) { $Ui.Save } else { $Ui.LampOff }
    if ($Row.Dot.BackColor.ToArgb() -ne $c.ToArgb()) { $Row.Dot.BackColor = $c }
    if ($Row.Detail.Text -ne $Detail) { $Row.Detail.Text = $Detail }
}

function Update-SegVisual {
    foreach ($id in @('speed', 'balanced', 'maximum')) {
        if (-not $script:SegButtons.ContainsKey($id)) { continue }
        $b = $script:SegButtons[$id]
        $on = ($id -eq $script:Profile)
        $bg = if ($on) { $Ui.Save } else { $Ui.Inset }
        $fg = if ($on) { $Ui.SaveFg } else { $Ui.Muted }
        if ($b.BackColor.ToArgb() -ne $bg.ToArgb()) { $b.BackColor = $bg }
        if ($script:SegLabels.ContainsKey($id)) {
            $lb = $script:SegLabels[$id]
            if ($lb.ForeColor.ToArgb() -ne $fg.ToArgb()) { $lb.ForeColor = $fg }
        }
    }
    $hint = Get-ProfileHint $script:Profile
    if ($lblProfHint.Text -ne $hint) { $lblProfHint.Text = $hint }
}

function Update-AppVisual {
    foreach ($id in @('codex', 'claude')) {
        if (-not $script:AppButtons.ContainsKey($id)) { continue }
        $b = $script:AppButtons[$id]
        $on = ($id -eq $script:TargetApp)
        $bg = if ($on) { $Ui.Save } else { $Ui.Inset }
        $fg = if ($on) { $Ui.SaveFg } else { $Ui.Muted }
        if ($b.BackColor.ToArgb() -ne $bg.ToArgb()) { $b.BackColor = $bg }
        if ($script:AppLabels.ContainsKey($id)) {
            foreach ($lb in @($script:AppLabels[$id])) {
                if ($lb.ForeColor.ToArgb() -ne $fg.ToArgb()) { $lb.ForeColor = $fg }
            }
        }
    }
}

function Update-ToggleVisual {
    if ($script:LastLampOn -ne $script:IsOn) {
        $script:LastLampOn = $script:IsOn
        Write-LampImage
    }
    if ($lblTitle.Text -ne 'Headroom Switch') { $lblTitle.Text = 'Headroom Switch' }
    if ($script:TargetApp -eq 'claude') {
        $eye = 'CLAUDE  ·  EXPERIMENTAL'
        $sub = if ($script:IsOn) {
            'Proxy is up. Quit Claude from the tray, then reopen.'
        } else {
            'Direct path. Confirm in Dashboard after a turn.'
        }
    } else {
        $eye = 'CODEX'
        $sub = if ($script:IsOn) {
            'Context is compressed locally, then sent to the model.'
        } else {
            'Direct to the model. Proxy is off.'
        }
    }
    if ($lblEyebrow.Text -ne $eye) { $lblEyebrow.Text = $eye }
    if ($lblSub.Text -ne $sub) { $lblSub.Text = $sub }
}

function Refresh-Status {
    $px = Test-PortOpen $script:Port
    $bin = Find-HeadroomExe
    if ($script:TargetApp -eq 'claude') {
        $cfgOn = Test-ClaudeEnabled $script:Port
        $script:IsOn = $cfgOn
        $cfgTitle = 'Claude settings'
        if ($rowCfg.Title.Text -ne $cfgTitle) { $rowCfg.Title.Text = $cfgTitle }
        Set-Lamp $rowCfg $cfgOn $(if ($cfgOn) {
            "ANTHROPIC_BASE_URL → 127.0.0.1:$($script:Port)"
        } else { 'Direct (no Headroom env)' })
    } else {
        $content = Read-Utf8 $script:ConfigPath
        $cfgOn = Test-CodexEnabled $content $script:Port
        $script:IsOn = $cfgOn
        $base = Read-OpenaiBaseUrl $content
        $cfgTitle = 'Codex config.toml'
        if ($rowCfg.Title.Text -ne $cfgTitle) { $rowCfg.Title.Text = $cfgTitle }
        Set-Lamp $rowCfg $cfgOn $(if ($cfgOn) {
            if ($base) { "openai_base_url → 127.0.0.1:$($script:Port)" } else { 'model_provider = "headroom"' }
        } else { 'Direct (Headroom not mounted)' })
    }
    Set-Lamp $rowPx $px $(if ($px) { "127.0.0.1:$($script:Port) · $($script:Profile)" } else { 'Not running' })
    Set-Lamp $rowBin ([bool]$bin) $(if ($bin) { $bin } else { 'Not found. Set headroom.exe in Settings.' })
    Update-ToggleVisual
    Update-AppVisual
}

function Apply-Profile([string]$Name) {
    $next = Normalize-Profile $Name
    if ($next -eq $script:Profile) { return }
    $script:Profile = $next
    Write-AppState
    Update-SegVisual
    Add-Log "Profile $next → $(Get-ProxyCmd)"
    if ($script:IsOn -or (Test-PortOpen $script:Port)) {
        Restart-ProxyForProfile
        Write-AppState
        Refresh-Status
    }
}

function Disable-CurrentAppConfig {
    if ($script:TargetApp -eq 'claude') {
        Add-Log 'Restoring Claude ANTHROPIC_BASE_URL / MCP'
        Disable-ClaudeSettings
        Disable-ClaudeDesktop
    } else {
        $content = Read-Utf8 $script:ConfigPath
        Add-Log $(if ($script:PreviousProvider) { "Restore model_provider = `"$($script:PreviousProvider)`"" } else { 'Remove model_provider = "headroom"' })
        $next = Disable-CodexConfig $content $script:PreviousProvider $script:PreviousOpenaiBaseUrl
        Write-Utf8NoBom $script:ConfigPath $next
        Add-Log 'Removed openai_base_url, websocket block, MCP'
    }
}

function Enable-CurrentAppConfig([string]$Bin) {
    if ($script:TargetApp -eq 'claude') {
        Add-Log 'Experimental: ANTHROPIC_BASE_URL → local proxy (no /v1)'
        Enable-ClaudeSettings $script:Port
        Add-Log 'Experimental: Headroom MCP in claude_desktop_config.json'
        Enable-ClaudeDesktop $(if ($Bin) { $Bin } else { 'headroom' })
        Add-Log 'Cowork GUI may ignore env. Check Dashboard after a turn.'
    } else {
        $content = Read-Utf8 $script:ConfigPath
        $current = Read-ModelProvider $content
        if ($current -and $current -ne 'headroom') {
            $script:PreviousProvider = $current
        } elseif ($current -eq 'headroom') {
            # already on in file
        } else {
            if (-not $script:PreviousProvider) { $script:PreviousProvider = $null }
        }
        $existingBase = Read-OpenaiBaseUrl $content
        if ($existingBase -and $existingBase -notmatch '127\.0\.0\.1:') {
            $script:PreviousOpenaiBaseUrl = $existingBase
        }
        Add-Log 'Write openai_base_url (ChatGPT desktop uses this)'
        Add-Log 'Write model_provider + websocket + MCP'
        $next = Enable-CodexConfig $content $script:Port $(if ($Bin) { $Bin } else { 'headroom' })
        Write-Utf8NoBom $script:ConfigPath $next
        Add-Log '[model_providers.headroom] supports_websockets=true'
        Add-Log '[mcp_servers.headroom] mcp serve'
    }
}

function Invoke-TurnOn {
    $bin = Find-HeadroomExe
    Enable-CurrentAppConfig $bin
    if (-not $bin) {
        Add-Log 'headroom.exe not found. Config written, proxy not started.'
        [void][System.Windows.Forms.MessageBox]::Show(
            "headroom.exe was not found (Explorer launches often miss PATH).`r`n`r`nOpen Settings and pick the binary.`r`nTypical locations: Python Scripts, or uv tools.`r`n`r`nApp config was still written.",
            'Headroom Switch'
        )
        Write-AppState
        Refresh-Status
        return
    }
    Add-Log "Start $(Get-ProxyCmd)"
    $ok = Start-HeadroomProxy
    if ($ok) {
        $who = if ($script:TargetApp -eq 'claude') { 'Claude Desktop / Cowork' } else { 'ChatGPT / Codex' }
        Add-Log "Port open. Fully quit $who, then reopen."
    } else {
        Add-Log 'Proxy start timed out. Confirm headroom runs.'
    }
    Write-AppState
    Refresh-Status
}

function Invoke-TurnOff {
    Disable-CurrentAppConfig
    Add-Log 'Stop proxy'
    Stop-HeadroomProxy
    Write-AppState
    $who = if ($script:TargetApp -eq 'claude') { 'Claude' } else { 'Codex' }
    Add-Log "Back to direct $who. Fully quit the app, then reopen."
    Refresh-Status
}

function Invoke-Toggle {
    if ($script:Busy) { return }
    $script:Busy = $true
    $lamp.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Refresh-Status
        if ($script:IsOn) { Invoke-TurnOff } else { Invoke-TurnOn }
    } catch {
        Add-Log ('Error: ' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Headroom Switch')
    } finally {
        $script:Busy = $false
        $lamp.Cursor = [System.Windows.Forms.Cursors]::Hand
    }
}

function Apply-App([string]$Name) {
    $next = Normalize-App $Name
    if ($next -eq $script:TargetApp) { return }
    $wasOn = $false
    Refresh-Status
    $wasOn = [bool]$script:IsOn
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        if ($wasOn) {
            Add-Log "Switching app $($script:TargetApp) → $next (keep proxy if possible)"
            Disable-CurrentAppConfig
        }
        $script:TargetApp = $next
        Write-AppState
        Update-AppVisual
        if ($wasOn) {
            $bin = Find-HeadroomExe
            Enable-CurrentAppConfig $bin
            if (-not (Test-PortOpen $script:Port)) {
                [void](Start-HeadroomProxy)
            }
            Write-AppState
        }
        Refresh-Status
        Add-Log "Target app: $next"
    } catch {
        Add-Log ('Error: ' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Headroom Switch')
    } finally {
        $script:Busy = $false
    }
}

function Invoke-ExitStopAll {
    try {
        Refresh-Status
        if ($script:IsOn) { Invoke-TurnOff }
        else { Stop-HeadroomProxy }
    } catch {}
    $script:ReallyExit = $true
    $form.Close()
}

$lamp.Add_Click({ Invoke-Toggle })

$btnDash.Add_Click({
    if (-not (Test-PortOpen $script:Port)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Proxy is not running. Turn the lamp on first, then open Dashboard.',
            'Headroom Switch'
        )
        return
    }
    Start-Process (Get-DashboardUrl)
})

function Show-Settings {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Settings  $($script:AppVersion)"
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(360, 280)
    $dlg.BackColor = $Ui.Elevated
    $dlg.ForeColor = $Ui.Fg
    $dlg.Font = $fontUi
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = 'Proxy port'
    $l1.Location = New-Object System.Drawing.Point(16, 14)
    $l1.Size = New-Object System.Drawing.Size(320, 18)
    $l1.ForeColor = $Ui.Muted
    [void]$dlg.Controls.Add($l1)

    $tbPort = New-Object System.Windows.Forms.TextBox
    $tbPort.Text = "$($script:Port)"
    $tbPort.Location = New-Object System.Drawing.Point(16, 34)
    $tbPort.Size = New-Object System.Drawing.Size(328, 26)
    $tbPort.BackColor = $Ui.Bg
    $tbPort.ForeColor = $Ui.Fg
    $tbPort.BorderStyle = 'FixedSingle'
    [void]$dlg.Controls.Add($tbPort)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'headroom.exe (blank = auto-detect)'
    $l2.Location = New-Object System.Drawing.Point(16, 68)
    $l2.Size = New-Object System.Drawing.Size(320, 18)
    $l2.ForeColor = $Ui.Muted
    [void]$dlg.Controls.Add($l2)

    $tbPath = New-Object System.Windows.Forms.TextBox
    $tbPath.Text = $script:CustomHeadroom
    $tbPath.Location = New-Object System.Drawing.Point(16, 88)
    $tbPath.Size = New-Object System.Drawing.Size(250, 26)
    $tbPath.BackColor = $Ui.Bg
    $tbPath.ForeColor = $Ui.Fg
    $tbPath.BorderStyle = 'FixedSingle'
    [void]$dlg.Controls.Add($tbPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse'
    $btnBrowse.Location = New-Object System.Drawing.Point(272, 86)
    $btnBrowse.Size = New-Object System.Drawing.Size(72, 28)
    $btnBrowse.FlatStyle = 'Flat'
    $btnBrowse.BackColor = $Ui.Inset
    $btnBrowse.ForeColor = $Ui.Fg
    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'Executable|*.exe|All|*.*'
        $ofd.Title = 'Choose headroom.exe'
        if ($ofd.ShowDialog() -eq 'OK') { $tbPath.Text = $ofd.FileName }
    })
    [void]$dlg.Controls.Add($btnBrowse)

    $l3 = New-Object System.Windows.Forms.Label
    $l3.Text = 'Close button'
    $l3.Location = New-Object System.Drawing.Point(16, 126)
    $l3.Size = New-Object System.Drawing.Size(320, 18)
    $l3.ForeColor = $Ui.Muted
    [void]$dlg.Controls.Add($l3)

    $rbTray = New-Object System.Windows.Forms.RadioButton
    $rbTray.Text = 'Minimize to tray'
    $rbTray.Checked = [bool]$script:CloseToTray
    $rbTray.Location = New-Object System.Drawing.Point(16, 146)
    $rbTray.Size = New-Object System.Drawing.Size(320, 22)
    $rbTray.ForeColor = $Ui.Fg
    [void]$dlg.Controls.Add($rbTray)

    $rbQuit = New-Object System.Windows.Forms.RadioButton
    $rbQuit.Text = 'Quit'
    $rbQuit.Checked = -not [bool]$script:CloseToTray
    $rbQuit.Location = New-Object System.Drawing.Point(16, 168)
    $rbQuit.Size = New-Object System.Drawing.Size(320, 22)
    $rbQuit.ForeColor = $Ui.Fg
    [void]$dlg.Controls.Add($rbQuit)

    $btnFolder = New-Object System.Windows.Forms.Button
    $btnFolder.Text = 'Config folder'
    $btnFolder.Location = New-Object System.Drawing.Point(16, 232)
    $btnFolder.Size = New-Object System.Drawing.Size(120, 32)
    $btnFolder.FlatStyle = 'Flat'
    $btnFolder.BackColor = $Ui.Inset
    $btnFolder.ForeColor = $Ui.Muted
    $btnFolder.Add_Click({
        $dir = if ($script:TargetApp -eq 'claude') { $script:ClaudeDir } else { $script:CodexDir }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Start-Process explorer.exe $dir
    })
    [void]$dlg.Controls.Add($btnFolder)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Save'
    $ok.Location = New-Object System.Drawing.Point(232, 232)
    $ok.Size = New-Object System.Drawing.Size(112, 32)
    $ok.FlatStyle = 'Flat'
    $ok.BackColor = $Ui.Accent
    $ok.ForeColor = $Ui.SaveFg
    $ok.DialogResult = 'OK'
    [void]$dlg.Controls.Add($ok)
    $dlg.AcceptButton = $ok

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $oldPort = [int]$script:Port
        $p = 0
        if ([int]::TryParse($tbPort.Text.Trim(), [ref]$p) -and $p -gt 0 -and $p -lt 65536) {
            if ($p -ne $oldPort) {
                $script:Port = $oldPort
                if (Test-PortOpen $oldPort) { Stop-HeadroomProxy }
                $script:Port = $p
                if ($script:IsOn) {
                    Add-Log "Port $oldPort → $p. Restarting proxy."
                    [void](Start-HeadroomProxy)
                }
            }
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(
                'Port must be a number from 1 to 65535.',
                'Headroom Switch'
            )
        }
        $script:CustomHeadroom = $tbPath.Text.Trim()
        $script:HeadroomExeCache = $null
        $script:CloseToTray = [bool]$rbTray.Checked
        Write-AppState
        Refresh-Status
        Add-Log "Settings saved. Port $($script:Port)."
    }
}

$btnSettings.Add_Click({ Show-Settings })

$notify = New-Object System.Windows.Forms.NotifyIcon
$bmp = New-Object System.Drawing.Bitmap 16, 16
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear($Ui.Bg)
$g.SmoothingMode = 'AntiAlias'
$brush = New-Object System.Drawing.SolidBrush $Ui.Save
$g.FillEllipse($brush, 2, 4, 12, 8)
$g.FillEllipse((New-Object System.Drawing.SolidBrush $Ui.Fg), 8, 4, 8, 8)
$g.Dispose()
$notify.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
$notify.Text = "Headroom Switch $($script:AppVersion)"
$notify.Visible = $true
$form.Icon = $notify.Icon

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$trayMenu.Items.Add('Show').add_Click({ $form.Visible = $true; $form.WindowState = 'Normal'; $form.Activate() })
[void]$trayMenu.Items.Add('-')
[void]$trayMenu.Items.Add('Exit').add_Click({ Invoke-ExitStopAll })
$notify.ContextMenuStrip = $trayMenu
$notify.Add_DoubleClick({ $form.Visible = $true; $form.WindowState = 'Normal'; $form.Activate() })

function Test-ShouldStayInTray {
    return [bool]$script:CloseToTray
}

$form.Add_FormClosing({
    param($src, $e)
    if ($script:ReallyExit) { return }
    if ($script:CloseToTray) {
        $e.Cancel = $true
        $src.Visible = $false
        return
    }
    try { Stop-HeadroomProxy } catch {}
    $script:ReallyExit = $true
    $notify.Visible = $false
})

$form.Add_FormClosed({
    $notify.Visible = $false
    $notify.Dispose()
    try { $mutex.ReleaseMutex() } catch {}
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({
    if ($script:Busy) { return }
    try { Refresh-Status } catch {}
})

Read-AppState
Update-SegVisual
Update-AppVisual
Refresh-Status
if ($script:IsOn -and -not (Test-PortOpen $script:Port)) {
    Add-Log 'Config is on Headroom but the proxy is down. Starting…'
    try { [void](Start-HeadroomProxy); Write-AppState; Refresh-Status } catch { Add-Log $_.Exception.Message }
}
Add-Log 'Ready. Lamp turns Headroom on. Pick Codex or Claude first.'
$timer.Start()

[void][System.Windows.Forms.Application]::Run($form)
$timer.Stop()
$notify.Visible = $false
$notify.Dispose()
