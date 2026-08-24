#requires -Version 5.1
# Headroom Switch — one-click Headroom proxy for Codex GUI
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
        "Headroom Switch 已經在執行。",
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
$script:IsOn = $false
$script:Busy = $false
$script:ProxyPid = 0
$script:CustomHeadroom = ''
$script:ShowProxyWindow = $false
$script:ReallyExit = $false
$script:PreviousProvider = $null
$script:HadProviderLine = $false
$script:PreviousOpenaiBaseUrl = $null

if ($env:CODEX_HOME -and $env:CODEX_HOME.Trim()) {
    $script:CodexDir = $env:CODEX_HOME.Trim()
} else {
    $script:CodexDir = Join-Path $env:USERPROFILE '.codex'
}
$script:ConfigPath = Join-Path $script:CodexDir 'config.toml'
$script:StatePath = Join-Path $script:CodexDir 'headroom-switch-state.json'

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

function Test-HeadroomEnabled([string]$Content, [int]$Port) {
    $base = Read-OpenaiBaseUrl $Content
    if ($base -and $base -match [regex]::Escape("127.0.0.1:$Port")) { return $true }
    return ((Read-ModelProvider $Content) -eq 'headroom')
}

function Enable-HeadroomConfig([string]$Content, [int]$Port, [string]$McpCommand) {
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

function Disable-HeadroomConfig([string]$Content, $PreviousProvider, $PreviousOpenaiBaseUrl) {
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

function Normalize-Profile([string]$Name) {
    $n = "$Name".Trim().ToLowerInvariant()
    if ($n -eq 'speed' -or $n -eq 'maximum' -or $n -eq 'balanced') { return $n }
    return 'balanced'
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
        'speed'    { return 'cache：衝快取，幾乎不壓' }
        'maximum'  { return 'token：最省，可能掉細節' }
        default    { return 'token：實際壓縮（預設）' }
    }
}

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
        if ($s.PSObject.Properties.Name -contains 'showProxyWindow') {
            $script:ShowProxyWindow = [bool]$s.showProxyWindow
        }
        if ($s.PSObject.Properties.Name -contains 'profile' -and $s.profile) {
            $script:Profile = Normalize-Profile ([string]$s.profile)
        }
        if ($s.PSObject.Properties.Name -contains 'previousOpenaiBaseUrl') {
            $script:PreviousOpenaiBaseUrl = $s.previousOpenaiBaseUrl
        }
    } catch {}
}

function Write-AppState {
    $obj = [ordered]@{
        port             = $script:Port
        previousProvider = $script:PreviousProvider
        hadProviderLine  = $script:HadProviderLine
        previousOpenaiBaseUrl = $script:PreviousOpenaiBaseUrl
        proxyPid         = $script:ProxyPid
        customHeadroom   = $script:CustomHeadroom
        showProxyWindow  = $script:ShowProxyWindow
        profile          = $script:Profile
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
    $style = if ($script:ShowProxyWindow) { 'Normal' } else { 'Hidden' }
    $p = Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle $style -PassThru
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
    Add-Log '重啟 proxy 讓 profile 生效（不必重開 Codex）'
    Stop-HeadroomProxy
    Start-Sleep -Milliseconds 300
    if (Start-HeadroomProxy) {
        Add-Log "proxy 已用 $($script:Profile) 重新啟動"
    } else {
        Add-Log 'proxy 重啟失敗'
    }
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

# --- UI -------------------------------------------------------------------------

$fontUi = New-Object System.Drawing.Font('Microsoft JhengHei UI', 9.5)
$fontSm = New-Object System.Drawing.Font('Microsoft JhengHei UI', 8.5)
$fontTitle = New-Object System.Drawing.Font('Microsoft JhengHei UI', 16, [System.Drawing.FontStyle]::Bold)
$fontMono = New-Object System.Drawing.Font('Consolas', 8)
$fontEyebrow = New-Object System.Drawing.Font('Microsoft JhengHei UI', 7.5)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Headroom Switch'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(400, 648)
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

$lblEyebrow = New-Lbl 'CODEX  ·  HEADROOM' 20 18 360 16 $fontEyebrow $Col.Subtle
$lblTitle = New-Lbl '省錢模式' 20 38 360 32 $fontTitle $Col.Fg
$lblSub = New-Lbl 'Codex 目前直連 OpenAI，沒有壓縮。' 20 74 360 36 $fontSm $Col.Muted

$track = New-Object System.Windows.Forms.Panel
$track.Location = New-Object System.Drawing.Point(20, 120)
$track.Size = New-Object System.Drawing.Size(360, 72)
$track.BackColor = $Col.Inset
$track.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$form.Controls.Add($track)

$thumb = New-Object System.Windows.Forms.Panel
$thumb.Size = New-Object System.Drawing.Size(56, 56)
$thumb.Location = New-Object System.Drawing.Point(8, 8)
$thumb.BackColor = $Col.Fg
$thumb.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$track.Controls.Add($thumb)

$lblModeL = New-Lbl '直連 OpenAI' 20 200 160 20 $fontSm $Col.Fg
$lblModeR = New-Lbl '省錢模式' 220 200 160 20 $fontSm $Col.Subtle
$lblModeR.TextAlign = 'MiddleRight'

$lblProf = New-Lbl 'Profile' 20 222 120 18 $fontSm $Col.Subtle
$lblProfHint = New-Lbl '預設，大多數情況' 140 222 240 18 $fontSm $Col.Muted
$lblProfHint.TextAlign = 'MiddleRight'

$seg = New-Object System.Windows.Forms.Panel
$seg.Location = New-Object System.Drawing.Point(20, 240)
$seg.Size = New-Object System.Drawing.Size(360, 36)
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
    $b.Location = New-Object System.Drawing.Point($X, 3)
    $b.Size = New-Object System.Drawing.Size(116, 30)
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
$status.Location = New-Object System.Drawing.Point(20, 286)
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

$rowCfg = New-StatusRow 8 'config.toml'
$rowPx = New-StatusRow 44 'Headroom proxy'
$rowBin = New-StatusRow 80 'Headroom 執行檔'

$lblLogH = New-Lbl '活動紀錄' 20 416 360 18 $fontSm $Col.Subtle
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BorderStyle = 'None'
$logBox.BackColor = $Col.Bg
$logBox.ForeColor = $Col.Muted
$logBox.Font = $fontMono
$logBox.Location = New-Object System.Drawing.Point(20, 434)
$logBox.Size = New-Object System.Drawing.Size(360, 80)
$logBox.TabStop = $false
[void]$form.Controls.Add($logBox)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = '開啟設定資料夾'
$btnFolder.FlatStyle = 'Flat'
$btnFolder.FlatAppearance.BorderColor = $Col.Subtle
$btnFolder.BackColor = $Col.Elevated
$btnFolder.ForeColor = $Col.Fg
$btnFolder.Font = $fontSm
$btnFolder.Location = New-Object System.Drawing.Point(20, 526)
$btnFolder.Size = New-Object System.Drawing.Size(174, 36)
$btnFolder.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$form.Controls.Add($btnFolder)

$btnSettings = New-Object System.Windows.Forms.Button
$btnSettings.Text = '設定'
$btnSettings.FlatStyle = 'Flat'
$btnSettings.FlatAppearance.BorderColor = $Col.Subtle
$btnSettings.BackColor = $Col.Elevated
$btnSettings.ForeColor = $Col.Fg
$btnSettings.Font = $fontSm
$btnSettings.Location = New-Object System.Drawing.Point(206, 526)
$btnSettings.Size = New-Object System.Drawing.Size(174, 36)
$btnSettings.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$form.Controls.Add($btnSettings)

$lblHint = New-Lbl '切完請從系統列完全退出 ChatGPT / Codex 再開。改 profile 只重啟 proxy。右上角 X 會縮到系統列。' 20 570 360 56 $fontSm $Col.Subtle

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

function Update-ToggleVisual {
    if ($script:IsOn) {
        $track.BackColor = $Col.Save
        $thumb.Location = New-Object System.Drawing.Point(296, 8)
        $lblModeL.ForeColor = $Col.Subtle
        $lblModeR.ForeColor = $Col.Save
        $lblModeR.Text = 'Headroom 壓縮中'
        $lblSub.Text = '請求會先經過本機壓縮，再送到模型。'
    } else {
        $track.BackColor = $Col.Inset
        $thumb.Location = New-Object System.Drawing.Point(8, 8)
        $lblModeL.ForeColor = $Col.Fg
        $lblModeR.ForeColor = $Col.Subtle
        $lblModeR.Text = '省錢模式'
        $lblSub.Text = 'Codex 目前直連 OpenAI，沒有壓縮。'
    }
}

function Refresh-Status {
    $content = Read-Utf8 $script:ConfigPath
    $cfgOn = Test-HeadroomEnabled $content $script:Port
    $script:IsOn = $cfgOn
    $px = Test-PortOpen $script:Port
    $bin = Find-HeadroomExe
    $base = Read-OpenaiBaseUrl $content
    Set-Lamp $rowCfg $cfgOn $(if ($cfgOn) {
        if ($base) { "openai_base_url → 127.0.0.1:$($script:Port)" } else { 'model_provider = "headroom"' }
    } else { '直連（未掛 Headroom）' })
    Set-Lamp $rowPx $px $(if ($px) { "127.0.0.1:$($script:Port) · $($script:Profile)" } else { '未啟動' })
    Set-Lamp $rowBin ([bool]$bin) $(if ($bin) { $bin } else { '找不到。到「設定」指定 headroom.exe 路徑。' })
    Update-ToggleVisual
}

function Invoke-TurnOn {
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
    $bin = Find-HeadroomExe
    Add-Log '寫入 openai_base_url（ChatGPT 桌面版走這條）'
    Add-Log '寫入 model_provider + websocket + MCP'
    $next = Enable-HeadroomConfig $content $script:Port $(if ($bin) { $bin } else { 'headroom' })
    Write-Utf8NoBom $script:ConfigPath $next
    Add-Log "[model_providers.headroom] supports_websockets=true"
    Add-Log '[mcp_servers.headroom] mcp serve'
    if (-not $bin) {
        Add-Log '找不到 headroom 執行檔。設定已寫入，但 proxy 沒啟動。'
        [void][System.Windows.Forms.MessageBox]::Show(
            "找不到 headroom 執行檔（多半是從檔案總管啟動時 PATH 沒帶進來）。`r`n`r`n請按「設定」指定 headroom.exe 路徑。`r`n常見位置：Python 的 Scripts 資料夾，或 uv tools。`r`n`r`nconfig.toml 已經改好了。",
            'Headroom Switch'
        )
        Write-AppState
        Refresh-Status
        return
    }
    Add-Log "啟動 $(Get-ProxyCmd)"
    $ok = Start-HeadroomProxy
    if ($ok) { Add-Log '埠已開。請完全退出 ChatGPT / Codex 再開一次。' }
    else { Add-Log 'proxy 啟動逾時。請確認 headroom 可執行。' }
    Write-AppState
    Refresh-Status
}

function Invoke-TurnOff {
    $content = Read-Utf8 $script:ConfigPath
    Add-Log $(if ($script:PreviousProvider) { "還原 model_provider = `"$($script:PreviousProvider)`"" } else { '移除 model_provider = "headroom"' })
    $next = Disable-HeadroomConfig $content $script:PreviousProvider $script:PreviousOpenaiBaseUrl
    Write-Utf8NoBom $script:ConfigPath $next
    Add-Log '移除 openai_base_url、websocket 區塊與 MCP'
    Add-Log '停止 proxy'
    Stop-HeadroomProxy
    Write-AppState
    Add-Log '已切回直連 OpenAI。請完全退出 ChatGPT / Codex 再開一次。'
    Refresh-Status
}

function Invoke-Toggle {
    if ($script:Busy) { return }
    $script:Busy = $true
    $track.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Refresh-Status
        if ($script:IsOn) { Invoke-TurnOff } else { Invoke-TurnOn }
    } catch {
        Add-Log ("錯誤：" + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Headroom Switch')
    } finally {
        $script:Busy = $false
        $track.Cursor = [System.Windows.Forms.Cursors]::Hand
    }
}

$handler = { Invoke-Toggle }
$track.Add_Click($handler)
$thumb.Add_Click($handler)

$btnFolder.Add_Click({
    if (-not (Test-Path $script:CodexDir)) {
        New-Item -ItemType Directory -Path $script:CodexDir -Force | Out-Null
    }
    Start-Process explorer.exe $script:CodexDir
})

function Show-Settings {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '設定'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(360, 220)
    $dlg.BackColor = $Col.Elevated
    $dlg.ForeColor = $Col.Fg
    $dlg.Font = $fontUi
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = 'Proxy 埠'
    $l1.Location = New-Object System.Drawing.Point(16, 16)
    $l1.Size = New-Object System.Drawing.Size(320, 20)
    $l1.ForeColor = $Col.Muted
    [void]$dlg.Controls.Add($l1)

    $tbPort = New-Object System.Windows.Forms.TextBox
    $tbPort.Text = "$($script:Port)"
    $tbPort.Location = New-Object System.Drawing.Point(16, 38)
    $tbPort.Size = New-Object System.Drawing.Size(328, 28)
    $tbPort.BackColor = $Col.Bg
    $tbPort.ForeColor = $Col.Fg
    $tbPort.BorderStyle = 'FixedSingle'
    [void]$dlg.Controls.Add($tbPort)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'headroom.exe 路徑（空白則自動尋找）'
    $l2.Location = New-Object System.Drawing.Point(16, 76)
    $l2.Size = New-Object System.Drawing.Size(320, 20)
    $l2.ForeColor = $Col.Muted
    [void]$dlg.Controls.Add($l2)

    $tbPath = New-Object System.Windows.Forms.TextBox
    $tbPath.Text = $script:CustomHeadroom
    $tbPath.Location = New-Object System.Drawing.Point(16, 98)
    $tbPath.Size = New-Object System.Drawing.Size(250, 28)
    $tbPath.BackColor = $Col.Bg
    $tbPath.ForeColor = $Col.Fg
    $tbPath.BorderStyle = 'FixedSingle'
    [void]$dlg.Controls.Add($tbPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = '瀏覽'
    $btnBrowse.Location = New-Object System.Drawing.Point(272, 96)
    $btnBrowse.Size = New-Object System.Drawing.Size(72, 30)
    $btnBrowse.FlatStyle = 'Flat'
    $btnBrowse.BackColor = $Col.Inset
    $btnBrowse.ForeColor = $Col.Fg
    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'Executable|*.exe|All|*.*'
        $ofd.Title = '選擇 headroom.exe'
        if ($ofd.ShowDialog() -eq 'OK') { $tbPath.Text = $ofd.FileName }
    })
    [void]$dlg.Controls.Add($btnBrowse)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = '顯示 proxy 主控台視窗'
    $chk.Checked = $script:ShowProxyWindow
    $chk.Location = New-Object System.Drawing.Point(16, 138)
    $chk.Size = New-Object System.Drawing.Size(320, 24)
    $chk.ForeColor = $Col.Fg
    [void]$dlg.Controls.Add($chk)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '儲存'
    $ok.Location = New-Object System.Drawing.Point(232, 174)
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
        $script:ShowProxyWindow = $chk.Checked
        Write-AppState
        Refresh-Status
        Add-Log "設定已儲存（埠 $($script:Port)）"
    }
}

$btnSettings.Add_Click({ Show-Settings })

# Tray
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
[void]$trayMenu.Items.Add('顯示視窗').add_Click({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
[void]$trayMenu.Items.Add('切換省錢模式').add_Click({ Invoke-Toggle })
[void]$trayMenu.Items.Add('-')
[void]$trayMenu.Items.Add('結束（保持現狀）').add_Click({
    $script:ReallyExit = $true
    $form.Close()
})
[void]$trayMenu.Items.Add('關閉省錢模式並結束').add_Click({
    try { if ($script:IsOn) { Invoke-TurnOff } } catch {}
    $script:ReallyExit = $true
    $form.Close()
})
$notify.ContextMenuStrip = $trayMenu
$notify.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

$form.Add_FormClosing({
    param($src, $e)
    if (-not $script:ReallyExit) {
        $e.Cancel = $true
        $form.Hide()
        $notify.ShowBalloonTip(1800, 'Headroom Switch', '程式在系統列。省錢模式若已開啟會繼續跑。', [System.Windows.Forms.ToolTipIcon]::Info)
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
Refresh-Status
if ($script:IsOn -and -not (Test-PortOpen $script:Port)) {
    Add-Log '設定檔已掛 Headroom，但 proxy 沒在跑。嘗試啟動…'
    try { [void](Start-HeadroomProxy); Write-AppState; Refresh-Status } catch { Add-Log $_.Exception.Message }
}
Add-Log '就緒。按中間開關即可切換。'
$timer.Start()

[void]$form.ShowDialog()
$timer.Stop()
$notify.Dispose()
