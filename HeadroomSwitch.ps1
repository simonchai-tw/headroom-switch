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
if (-not $mutex.WaitOne(0, $false)) {
    [void][System.Windows.Forms.MessageBox]::Show(
        'Headroom Switch is already running.',
        'Headroom Switch'
    )
    exit
}

function C([int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }
$Col = @{
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
}

$script:Port = 8787
$script:Profile = 'balanced'
$script:SegButtons = @{}
$script:AppButtons = @{}
$script:TargetApp = 'codex'
$script:IsOn = $false
$script:Busy = $false
$script:ProxyPid = 0
$script:CustomHeadroom = ''
$script:CloseToTray = $true
$script:ReallyExit = $false
$script:PreviousProvider = $null
$script:HadProviderLine = $false
$script:PreviousOpenaiBaseUrl = $null
$script:ClaudePrevBaseUrl = $null
$script:ClaudeHadBaseUrl = $false

if ($env:CODEX_HOME -and $env:CODEX_HOME.Trim()) {
    $script:CodexDir = $env:CODEX_HOME.Trim()
} else {
    $script:CodexDir = Join-Path $env:USERPROFILE '.codex'
}
$script:ConfigPath = Join-Path $script:CodexDir 'config.toml'
$script:StatePath = Join-Path $script:CodexDir 'headroom-switch-state.json'

if ($env:CLAUDE_CONFIG_DIR -and $env:CLAUDE_CONFIG_DIR.Trim()) {
    $script:ClaudeDir = $env:CLAUDE_CONFIG_DIR.Trim()
} else {
    $script:ClaudeDir = Join-Path $env:USERPROFILE '.claude'
}
$script:ClaudeSettingsPath = Join-Path $script:ClaudeDir 'settings.json'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $dir = Split-Path $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
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

function Remove-HeadroomBlock([string]$Content) {
    return [regex]::Replace(
        $Content,
        '(?m)^\[model_providers\.headroom\][ \t]*\r?\n(?:[ \t]*(?:name|base_url|wire_api|supports_websockets|requires_openai_auth)[ \t]*=.*\r?\n)*',
        ''
    )
}

function Remove-McpBlock([string]$Content) {
    return [regex]::Replace(
        $Content,
        '(?m)^\[mcp_servers\.headroom\][ \t]*\r?\n(?:[ \t]*(?:command|args)[ \t]*=.*\r?\n)*',
        ''
    )
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
    if ($base -and $base -match [regex]::Escape("127.0.0.1:$Port")) { return $true }
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
    try { return $raw | ConvertFrom-Json } catch { return New-Object PSObject }
}

function Ensure-Note($Obj, [string]$Name, $Value) {
    if ($Obj.PSObject.Properties.Name -contains $Name) {
        $Obj.$Name = $Value
    } else {
        $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-Note($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj.PSObject.Properties.Name -contains $Name) { return $Obj.$Name }
    return $null
}

function Test-ClaudeEnabled([int]$Port) {
    $obj = Read-JsonObject $script:ClaudeSettingsPath
    $envObj = Get-Note $obj 'env'
    $url = Get-Note $envObj 'ANTHROPIC_BASE_URL'
    if ($url -and ("$url" -match [regex]::Escape("127.0.0.1:$Port"))) { return $true }
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
        if ($envObj.PSObject.Properties.Name -contains 'ANTHROPIC_BASE_URL') {
            $envObj.PSObject.Properties.Remove('ANTHROPIC_BASE_URL')
        }
    }
    $envNames = @($envObj.PSObject.Properties.Name)
    if ($envNames.Count -eq 0 -and $obj.PSObject.Properties.Name -contains 'env') {
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
        if ($mcp.PSObject.Properties.Name -contains 'headroom') {
            $mcp.PSObject.Properties.Remove('headroom')
        }
        $left = @($mcp.PSObject.Properties.Name)
        if ($left.Count -eq 0 -and $obj.PSObject.Properties.Name -contains 'mcpServers') {
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

function Get-ProfileHint([string]$UiName) {
    switch (Normalize-Profile $UiName) {
        'speed'    { return 'cache — fast, almost no compression' }
        'maximum'  { return 'token + no CCR — max savings' }
        default    { return 'token — actual compression (default)' }
    }
}

function Get-DashboardUrl { return "http://127.0.0.1:$($script:Port)/dashboard" }

function Read-AppState {
    if (-not (Test-Path $script:StatePath)) { return }
    try {
        $s = Read-Utf8 $script:StatePath | ConvertFrom-Json
        if ($s.PSObject.Properties.Name -contains 'port' -and $s.port) {
            $script:Port = [int]$s.port
        }
        if ($s.PSObject.Properties.Name -contains 'previousProvider') {
            $script:PreviousProvider = $s.previousProvider
        }
        if ($s.PSObject.Properties.Name -contains 'hadProviderLine') {
            $script:HadProviderLine = [bool]$s.hadProviderLine
        }
        if ($s.PSObject.Properties.Name -contains 'proxyPid' -and $s.proxyPid) {
            $script:ProxyPid = [int]$s.proxyPid
        }
        if ($s.PSObject.Properties.Name -contains 'customHeadroom' -and $s.customHeadroom) {
            $script:CustomHeadroom = [string]$s.customHeadroom
        }
        if ($s.PSObject.Properties.Name -contains 'closeToTray') {
            $script:CloseToTray = [bool]$s.closeToTray
        }
        if ($s.PSObject.Properties.Name -contains 'profile' -and $s.profile) {
            $script:Profile = Normalize-Profile ([string]$s.profile)
        }
        if ($s.PSObject.Properties.Name -contains 'targetApp' -and $s.targetApp) {
            $script:TargetApp = Normalize-App ([string]$s.targetApp)
        }
        if ($s.PSObject.Properties.Name -contains 'previousOpenaiBaseUrl') {
            $script:PreviousOpenaiBaseUrl = $s.previousOpenaiBaseUrl
        }
        if ($s.PSObject.Properties.Name -contains 'claudePrevBaseUrl') {
            $script:ClaudePrevBaseUrl = $s.claudePrevBaseUrl
        }
        if ($s.PSObject.Properties.Name -contains 'claudeHadBaseUrl') {
            $script:ClaudeHadBaseUrl = [bool]$s.claudeHadBaseUrl
        }
    } catch {}
}

function Write-AppState {
    $obj = [ordered]@{
        port                  = $script:Port
        previousProvider      = $script:PreviousProvider
        hadProviderLine       = $script:HadProviderLine
        previousOpenaiBaseUrl = $script:PreviousOpenaiBaseUrl
        proxyPid              = $script:ProxyPid
        customHeadroom        = $script:CustomHeadroom
        closeToTray           = $script:CloseToTray
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
    $cmd = Get-Command headroom -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
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
        if ($hits.Count -gt 0) { return $hits[0].FullName }
    }
    foreach ($py in @('py', 'python', 'python3')) {
        try {
            $which = & $py -c "import shutil; print(shutil.which('headroom') or '')" 2>$null
            if ($which -and "$which".Trim()) { return "$which".Trim() }
        } catch {}
    }
    return $null
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
        return ($blob -match 'headroom')
    } catch { return $false }
}

function Stop-HeadroomProxy {
    if ($script:ProxyPid -gt 0) {
        Stop-Process -Id $script:ProxyPid -Force -ErrorAction SilentlyContinue
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
$fontTitle = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$fontMono = New-Object System.Drawing.Font('Consolas', 8)
$fontEyebrow = New-Object System.Drawing.Font('Segoe UI', 7.5)
$fontLamp = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Headroom Switch'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(400, 560)
$form.BackColor = $Col.Elevated
$form.ForeColor = $Col.Fg
$form.Font = $fontUi

function New-Lbl([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Font, $Color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.Font = $Font
    $l.ForeColor = $Color
    $l.BackColor = [System.Drawing.Color]::Transparent
    [void]$form.Controls.Add($l)
    return $l
}

$lblEyebrow = New-Lbl 'HEADROOM' 20 16 360 16 $fontEyebrow $Col.Subtle
$lblTitle = New-Lbl 'Saving mode' 20 34 360 30 $fontTitle $Col.Fg
$lblSub = New-Lbl 'Codex is talking to OpenAI directly.' 20 66 360 36 $fontSm $Col.Muted

$lamp = New-Object System.Windows.Forms.Panel
$lamp.Location = New-Object System.Drawing.Point(20, 108)
$lamp.Size = New-Object System.Drawing.Size(64, 64)
$lamp.BackColor = $Col.Elevated
$lamp.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$form.Controls.Add($lamp)

$lamp.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear($Col.Elevated)
    $on = [bool]$script:IsOn
    $fill = if ($on) { $Col.Save } else { $Col.LampOff }
    $ring = if ($on) { $Col.Save } else { $Col.Subtle }
    $brush = New-Object System.Drawing.SolidBrush $fill
    $pen = New-Object System.Drawing.Pen $ring, 2
    $g.FillEllipse($brush, 6, 6, 50, 50)
    $g.DrawEllipse($pen, 6, 6, 50, 50)
    $core = New-Object System.Drawing.SolidBrush $(if ($on) { $Col.Fg } else { $Col.Inset })
    $g.FillEllipse($core, 24, 24, 14, 14)
    $brush.Dispose(); $pen.Dispose(); $core.Dispose()
})

$appHost = New-Object System.Windows.Forms.Panel
$appHost.Location = New-Object System.Drawing.Point(96, 108)
$appHost.Size = New-Object System.Drawing.Size(284, 64)
$appHost.BackColor = $Col.Inset
[void]$form.Controls.Add($appHost)

$script:AppButtons = @{}
function New-AppBtn([string]$Id, [string]$Label, [int]$X, [int]$W) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Label
    $b.Tag = $Id
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Font = $fontUi
    $b.Location = New-Object System.Drawing.Point($X, 8)
    $b.Size = New-Object System.Drawing.Size($W, 48)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Add_Click({
        param($sender, $e)
        Apply-App ([string]$sender.Tag)
    })
    [void]$appHost.Controls.Add($b)
    $script:AppButtons[$Id] = $b
    return $b
}
New-AppBtn 'codex' 'Codex' 8 128 | Out-Null
New-AppBtn 'claude' 'Claude  EXP' 144 132 | Out-Null

$lblProf = New-Lbl 'Profile' 20 184 80 18 $fontSm $Col.Subtle
$lblProfHint = New-Lbl 'token — actual compression (default)' 100 184 280 18 $fontSm $Col.Muted
$lblProfHint.TextAlign = 'MiddleRight'

$seg = New-Object System.Windows.Forms.Panel
$seg.Location = New-Object System.Drawing.Point(20, 204)
$seg.Size = New-Object System.Drawing.Size(360, 32)
$seg.BackColor = $Col.Inset
[void]$form.Controls.Add($seg)

$script:SegButtons = @{}
function New-SegBtn([string]$Id, [int]$X) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Id
    $b.Tag = $Id
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Font = $fontMono
    $b.Location = New-Object System.Drawing.Point($X, 2)
    $b.Size = New-Object System.Drawing.Size(116, 28)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Add_Click({
        param($sender, $e)
        Apply-Profile ([string]$sender.Tag)
    })
    [void]$seg.Controls.Add($b)
    $script:SegButtons[$Id] = $b
    return $b
}
New-SegBtn 'speed' 4 | Out-Null
New-SegBtn 'balanced' 122 | Out-Null
New-SegBtn 'maximum' 240 | Out-Null

$status = New-Object System.Windows.Forms.Panel
$status.Location = New-Object System.Drawing.Point(20, 248)
$status.Size = New-Object System.Drawing.Size(360, 118)
$status.BackColor = $Col.Inset
[void]$form.Controls.Add($status)

function New-StatusRow([int]$Y, [string]$Label) {
    $dot = New-Object System.Windows.Forms.Panel
    $dot.Size = New-Object System.Drawing.Size(8, 8)
    $dot.Location = New-Object System.Drawing.Point(16, ($Y + 8))
    $dot.BackColor = $Col.LampOff
    [void]$status.Controls.Add($dot)
    $t = New-Object System.Windows.Forms.Label
    $t.Location = New-Object System.Drawing.Point(34, $Y)
    $t.Size = New-Object System.Drawing.Size(310, 18)
    $t.Font = $fontSm
    $t.ForeColor = $Col.Fg
    $t.Text = $Label
    [void]$status.Controls.Add($t)
    $d = New-Object System.Windows.Forms.Label
    $d.Location = New-Object System.Drawing.Point(34, ($Y + 16))
    $d.Size = New-Object System.Drawing.Size(310, 16)
    $d.Font = $fontMono
    $d.ForeColor = $Col.Muted
    $d.Text = ''
    [void]$status.Controls.Add($d)
    return @{ Dot = $dot; Title = $t; Detail = $d }
}

$rowCfg = New-StatusRow 8 'App config'
$rowPx = New-StatusRow 44 'Headroom proxy'
$rowBin = New-StatusRow 80 'Headroom binary'

$lblLogH = New-Lbl 'Activity' 20 376 360 16 $fontSm $Col.Subtle
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BorderStyle = 'None'
$logBox.BackColor = $Col.Bg
$logBox.ForeColor = $Col.Muted
$logBox.Font = $fontMono
$logBox.Location = New-Object System.Drawing.Point(20, 394)
$logBox.Size = New-Object System.Drawing.Size(360, 64)
$logBox.TabStop = $false
[void]$form.Controls.Add($logBox)

$btnDash = New-Object System.Windows.Forms.Button
$btnDash.Text = 'Savings'
$btnDash.FlatStyle = 'Flat'
$btnDash.FlatAppearance.BorderColor = $Col.Subtle
$btnDash.BackColor = $Col.Elevated
$btnDash.ForeColor = $Col.Fg
$btnDash.Font = $fontSm
$btnDash.Location = New-Object System.Drawing.Point(20, 470)
$btnDash.Size = New-Object System.Drawing.Size(174, 36)
$btnDash.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$form.Controls.Add($btnDash)

$btnSettings = New-Object System.Windows.Forms.Button
$btnSettings.Text = 'Settings'
$btnSettings.FlatStyle = 'Flat'
$btnSettings.FlatAppearance.BorderColor = $Col.Subtle
$btnSettings.BackColor = $Col.Elevated
$btnSettings.ForeColor = $Col.Fg
$btnSettings.Font = $fontSm
$btnSettings.Location = New-Object System.Drawing.Point(206, 470)
$btnSettings.Size = New-Object System.Drawing.Size(174, 36)
$btnSettings.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$form.Controls.Add($btnSettings)

$lblHint = New-Lbl 'Lamp on = compress. Fully quit Codex / Claude from the tray, then reopen. X hides to tray.' 20 512 360 40 $fontSm $Col.Subtle

function Add-Log([string]$Msg) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $line = "$stamp  $Msg"
    if ([string]::IsNullOrEmpty($logBox.Text)) { $logBox.Text = $line }
    else { $logBox.AppendText("`r`n$line") }
}

function Set-Lamp($Row, [bool]$On, [string]$Detail) {
    $Row.Dot.BackColor = $(if ($On) { $Col.Save } else { $Col.LampOff })
    $Row.Detail.Text = $Detail
}

function Update-SegVisual {
    foreach ($id in @('speed', 'balanced', 'maximum')) {
        if (-not $script:SegButtons.ContainsKey($id)) { continue }
        $b = $script:SegButtons[$id]
        if ($id -eq $script:Profile) {
            $b.BackColor = $Col.Save
            $b.ForeColor = $Col.SaveFg
        } else {
            $b.BackColor = $Col.Inset
            $b.ForeColor = $Col.Muted
        }
    }
    $lblProfHint.Text = Get-ProfileHint $script:Profile
}

function Update-AppVisual {
    foreach ($id in @('codex', 'claude')) {
        if (-not $script:AppButtons.ContainsKey($id)) { continue }
        $b = $script:AppButtons[$id]
        if ($id -eq $script:TargetApp) {
            $b.BackColor = $Col.Save
            $b.ForeColor = $Col.SaveFg
        } else {
            $b.BackColor = $Col.Inset
            $b.ForeColor = $Col.Muted
        }
    }
}

function Update-ToggleVisual {
    $lamp.Invalidate()
    if ($script:TargetApp -eq 'claude') {
        $lblEyebrow.Text = 'CLAUDE  ·  EXPERIMENTAL'
        if ($script:IsOn) {
            $lblTitle.Text = 'Saving mode'
            $lblSub.Text = 'Claude env + MCP point at the proxy. Fully quit Desktop / Cowork and reopen.'
        } else {
            $lblTitle.Text = 'Saving mode'
            $lblSub.Text = 'Claude is direct. This path is experimental — watch the dashboard.'
        }
    } else {
        $lblEyebrow.Text = 'CODEX  ·  HEADROOM'
        if ($script:IsOn) {
            $lblTitle.Text = 'Saving mode'
            $lblSub.Text = 'Requests go through the local compressor, then to the model.'
        } else {
            $lblTitle.Text = 'Saving mode'
            $lblSub.Text = 'Codex is talking to OpenAI directly.'
        }
    }
}

function Refresh-Status {
    $px = Test-PortOpen $script:Port
    $bin = Find-HeadroomExe
    if ($script:TargetApp -eq 'claude') {
        $cfgOn = Test-ClaudeEnabled $script:Port
        $script:IsOn = $cfgOn
        $rowCfg.Title.Text = 'Claude settings'
        Set-Lamp $rowCfg $cfgOn $(if ($cfgOn) {
            "ANTHROPIC_BASE_URL → 127.0.0.1:$($script:Port)"
        } else { 'Direct (no Headroom env)' })
    } else {
        $content = Read-Utf8 $script:ConfigPath
        $cfgOn = Test-CodexEnabled $content $script:Port
        $script:IsOn = $cfgOn
        $base = Read-OpenaiBaseUrl $content
        $rowCfg.Title.Text = 'Codex config.toml'
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
        Add-Log 'Cowork GUI may ignore env. Check Savings after a turn.'
    } else {
        $content = Read-Utf8 $script:ConfigPath
        $current = Read-ModelProvider $content
        if ($current -and $current -ne 'headroom') {
            $script:PreviousProvider = $current
            $script:HadProviderLine = $true
        } elseif ($current -eq 'headroom') {
            # already on in file
        } else {
            $script:HadProviderLine = $false
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
            'Proxy is not running. Turn the lamp on first, then open Savings.',
            'Headroom Switch'
        )
        return
    }
    Start-Process (Get-DashboardUrl)
})

function Show-Settings {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Settings'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(360, 280)
    $dlg.BackColor = $Col.Elevated
    $dlg.ForeColor = $Col.Fg
    $dlg.Font = $fontUi
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = 'Proxy port'
    $l1.Location = New-Object System.Drawing.Point(16, 14)
    $l1.Size = New-Object System.Drawing.Size(320, 18)
    $l1.ForeColor = $Col.Muted
    [void]$dlg.Controls.Add($l1)

    $tbPort = New-Object System.Windows.Forms.TextBox
    $tbPort.Text = "$($script:Port)"
    $tbPort.Location = New-Object System.Drawing.Point(16, 34)
    $tbPort.Size = New-Object System.Drawing.Size(328, 26)
    $tbPort.BackColor = $Col.Bg
    $tbPort.ForeColor = $Col.Fg
    $tbPort.BorderStyle = 'FixedSingle'
    [void]$dlg.Controls.Add($tbPort)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'headroom.exe (blank = auto-detect)'
    $l2.Location = New-Object System.Drawing.Point(16, 68)
    $l2.Size = New-Object System.Drawing.Size(320, 18)
    $l2.ForeColor = $Col.Muted
    [void]$dlg.Controls.Add($l2)

    $tbPath = New-Object System.Windows.Forms.TextBox
    $tbPath.Text = $script:CustomHeadroom
    $tbPath.Location = New-Object System.Drawing.Point(16, 88)
    $tbPath.Size = New-Object System.Drawing.Size(250, 26)
    $tbPath.BackColor = $Col.Bg
    $tbPath.ForeColor = $Col.Fg
    $tbPath.BorderStyle = 'FixedSingle'
    [void]$dlg.Controls.Add($tbPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse'
    $btnBrowse.Location = New-Object System.Drawing.Point(272, 86)
    $btnBrowse.Size = New-Object System.Drawing.Size(72, 28)
    $btnBrowse.FlatStyle = 'Flat'
    $btnBrowse.BackColor = $Col.Inset
    $btnBrowse.ForeColor = $Col.Fg
    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'Executable|*.exe|All|*.*'
        $ofd.Title = 'Choose headroom.exe'
        if ($ofd.ShowDialog() -eq 'OK') { $tbPath.Text = $ofd.FileName }
    })
    [void]$dlg.Controls.Add($btnBrowse)

    $l3 = New-Object System.Windows.Forms.Label
    $l3.Text = 'Close button (X)'
    $l3.Location = New-Object System.Drawing.Point(16, 126)
    $l3.Size = New-Object System.Drawing.Size(320, 18)
    $l3.ForeColor = $Col.Muted
    [void]$dlg.Controls.Add($l3)

    $rbTray = New-Object System.Windows.Forms.RadioButton
    $rbTray.Text = 'Minimize to tray'
    $rbTray.Checked = [bool]$script:CloseToTray
    $rbTray.Location = New-Object System.Drawing.Point(16, 146)
    $rbTray.Size = New-Object System.Drawing.Size(320, 22)
    $rbTray.ForeColor = $Col.Fg
    [void]$dlg.Controls.Add($rbTray)

    $rbQuit = New-Object System.Windows.Forms.RadioButton
    $rbQuit.Text = 'Quit and stop proxy'
    $rbQuit.Checked = -not [bool]$script:CloseToTray
    $rbQuit.Location = New-Object System.Drawing.Point(16, 168)
    $rbQuit.Size = New-Object System.Drawing.Size(320, 22)
    $rbQuit.ForeColor = $Col.Fg
    [void]$dlg.Controls.Add($rbQuit)

    $btnFolder = New-Object System.Windows.Forms.Button
    $btnFolder.Text = 'Config folder'
    $btnFolder.Location = New-Object System.Drawing.Point(16, 232)
    $btnFolder.Size = New-Object System.Drawing.Size(120, 32)
    $btnFolder.FlatStyle = 'Flat'
    $btnFolder.BackColor = $Col.Inset
    $btnFolder.ForeColor = $Col.Muted
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
    $ok.BackColor = $Col.Accent
    $ok.ForeColor = $Col.SaveFg
    $ok.DialogResult = 'OK'
    [void]$dlg.Controls.Add($ok)
    $dlg.AcceptButton = $ok

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $p = 0
        if ([int]::TryParse($tbPort.Text.Trim(), [ref]$p) -and $p -gt 0 -and $p -lt 65536) {
            $script:Port = $p
        }
        $script:CustomHeadroom = $tbPath.Text.Trim()
        $script:CloseToTray = [bool]$rbTray.Checked
        Write-AppState
        Refresh-Status
        Add-Log "Settings saved (port $($script:Port); X=$(if ($script:CloseToTray) { 'tray' } else { 'quit' }))"
    }
}

$btnSettings.Add_Click({ Show-Settings })

$notify = New-Object System.Windows.Forms.NotifyIcon
$bmp = New-Object System.Drawing.Bitmap 16, 16
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear($Col.Bg)
$g.SmoothingMode = 'AntiAlias'
$brush = New-Object System.Drawing.SolidBrush $Col.Save
$g.FillEllipse($brush, 2, 4, 12, 8)
$g.FillEllipse((New-Object System.Drawing.SolidBrush $Col.Fg), 8, 4, 8, 8)
$g.Dispose()
$notify.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
$notify.Text = 'Headroom Switch'
$notify.Visible = $true
$form.Icon = $notify.Icon

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$trayMenu.Items.Add('Show').add_Click({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
[void]$trayMenu.Items.Add('-')
[void]$trayMenu.Items.Add('Exit (stop proxy)').add_Click({ Invoke-ExitStopAll })
$notify.ContextMenuStrip = $trayMenu
$notify.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

$form.Add_FormClosing({
    param($src, $e)
    if ($script:ReallyExit) { return }
    if ($script:CloseToTray) {
        $e.Cancel = $true
        $form.Hide()
        $notify.ShowBalloonTip(1600, 'Headroom Switch', 'Still in the tray. Saving mode keeps running if the lamp is on.', [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        try {
            Refresh-Status
            if ($script:IsOn) { Invoke-TurnOff } else { Stop-HeadroomProxy }
        } catch {}
        $script:ReallyExit = $true
    }
})

$form.Add_FormClosed({
    $notify.Visible = $false
    $notify.Dispose()
    try { $mutex.ReleaseMutex() } catch {}
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2500
$timer.Add_Tick({
    if (-not $script:Busy) { Refresh-Status }
})

Read-AppState
Update-SegVisual
Update-AppVisual
Refresh-Status
if ($script:IsOn -and -not (Test-PortOpen $script:Port)) {
    Add-Log 'Config is on Headroom but the proxy is down. Starting…'
    try { [void](Start-HeadroomProxy); Write-AppState; Refresh-Status } catch { Add-Log $_.Exception.Message }
}
Add-Log 'Ready. Lamp toggles saving mode. Pick Codex or Claude first.'
$timer.Start()

[void]$form.ShowDialog()
$timer.Stop()
$notify.Dispose()
