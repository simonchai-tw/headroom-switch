#requires -Version 5.1
# Headroom Switch — one-click Headroom proxy for Codex / Claude on Windows
# Encoding: UTF-8 with BOM (Windows PowerShell 5.1)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 6) {
    $sta = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($sta -ne 'STA') {
        $exe = Join-Path $PSHOME 'powershell.exe'
        Start-Process $exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
        exit
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [void][System.Windows.Forms.Application]::SetHighDpiMode('PerMonitorV2') } catch {}

if (-not ('HeadroomHidden' -as [type])) {
    Add-Type -IgnoreWarnings -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class HeadroomHidden {
    const int CreateNoWindowFlag = 0x08000000;

    static void TryCreateNoWindow(ProcessStartInfo psi) {
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.UseShellExecute = false;
        try {
            var flags = BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Public;
            var p = typeof(ProcessStartInfo).GetProperty("CreationFlags", flags);
            if (p != null && p.CanWrite) p.SetValue(psi, CreateNoWindowFlag, null);
            var f = typeof(ProcessStartInfo).GetField("creationFlags", flags);
            if (f != null) f.SetValue(psi, CreateNoWindowFlag);
        } catch {}
    }

    static void AnswerYes(Process p) {
        try {
            p.StandardInput.WriteLine("Y");
            p.StandardInput.Flush();
            p.StandardInput.Close();
        } catch {}
    }

    public static string PypiVersion() {
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
        var req = (HttpWebRequest)WebRequest.Create("https://pypi.org/pypi/headroom-ai/json");
        req.UserAgent = "HeadroomSwitch";
        req.Timeout = 12000;
        using (var resp = req.GetResponse())
        using (var stream = resp.GetResponseStream())
        using (var sr = new StreamReader(stream)) {
            var json = sr.ReadToEnd();
            var m = Regex.Match(json, "\"version\"\\s*:\\s*\"([0-9]+(?:\\.[0-9]+)*)\"");
            return m.Success ? m.Groups[1].Value : "";
        }
    }

    public static string Run(string file, string args, int timeoutMs, out int code) {
        code = -1;
        var psi = new ProcessStartInfo();
        psi.FileName = file;
        psi.Arguments = args;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.RedirectStandardInput = true;
        TryCreateNoWindow(psi);
        try {
            psi.EnvironmentVariables["PYTHONUNBUFFERED"] = "1";
            psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
            psi.EnvironmentVariables["PIP_NO_INPUT"] = "1";
            psi.EnvironmentVariables["CI"] = "1";
            psi.EnvironmentVariables["UV_NO_PROGRESS"] = "1";
        } catch {}
        using (var p = new Process()) {
            p.StartInfo = psi;
            p.Start();
            AnswerYes(p);
            var outT = p.StandardOutput.ReadToEndAsync();
            var errT = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(timeoutMs)) {
                try { p.Kill(); } catch {}
                try { p.WaitForExit(2000); } catch {}
                try { outT.Wait(500); } catch {}
                try { errT.Wait(500); } catch {}
                throw new TimeoutException("Timed out.");
            }
            code = p.ExitCode;
            var o = outT.Result ?? "";
            var er = errT.Result ?? "";
            return (o + "\n" + er).Trim();
        }
    }

    public static void QueueCheck(string file, string verArgs, SendOrPostCallback onDone) {
        var ctx = SynchronizationContext.Current;
        ThreadPool.QueueUserWorkItem(_ => {
            string ver = "";
            string latest = "";
            string error = null;
            try {
                int code;
                ver = Run(file, verArgs, 15000, out code);
            } catch (Exception ex) { error = ex.Message; }
            try { latest = PypiVersion(); } catch (Exception ex) {
                if (error == null) error = ex.Message;
            }
            object payload = new object[] { ver, latest, error };
            if (ctx != null) ctx.Post(onDone, payload);
            else onDone(payload);
        });
    }

    public static void Queue(string file, string args, int timeoutMs, SendOrPostCallback onLine, SendOrPostCallback onDone) {
        var ctx = SynchronizationContext.Current;
        ThreadPool.QueueUserWorkItem(_ => {
            int code = -1;
            string text = "";
            string error = null;
            try {
                var psi = new ProcessStartInfo();
                psi.FileName = file;
                psi.Arguments = args;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.RedirectStandardInput = true;
                psi.StandardOutputEncoding = Encoding.UTF8;
                psi.StandardErrorEncoding = Encoding.UTF8;
                TryCreateNoWindow(psi);
                try {
                    psi.EnvironmentVariables["PYTHONUNBUFFERED"] = "1";
                    psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
                    psi.EnvironmentVariables["PIP_NO_INPUT"] = "1";
                    psi.EnvironmentVariables["CI"] = "1";
                    psi.EnvironmentVariables["UV_NO_PROGRESS"] = "1";
                } catch {}
                var sb = new StringBuilder();
                using (var p = new Process()) {
                    p.StartInfo = psi;
                    p.EnableRaisingEvents = false;
                    DataReceivedEventHandler h = (s, e) => {
                        if (string.IsNullOrEmpty(e.Data)) return;
                        lock (sb) { sb.AppendLine(e.Data); }
                        if (onLine != null && ctx != null) ctx.Post(onLine, e.Data);
                    };
                    p.OutputDataReceived += h;
                    p.ErrorDataReceived += h;
                    p.Start();
                    AnswerYes(p);
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();
                    if (!p.WaitForExit(timeoutMs)) {
                        try { p.Kill(); } catch {}
                        try { p.WaitForExit(2000); } catch {}
                        error = "Timed out.";
                    }
                    code = p.HasExited ? p.ExitCode : -1;
                    lock (sb) { text = sb.ToString().Trim(); }
                }
            }
            catch (Exception ex) { error = ex.Message; }
            object payload = new object[] { code, text, error };
            if (ctx != null) ctx.Post(onDone, payload);
            else onDone(payload);
        });
    }
}
'@
}

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

$script:AppVersion = '0.3.0'
$script:Port = 8787
$script:Profile = 'balanced'
$script:SegButtons = @{}
$script:AppButtons = @{}
$script:TargetApp = 'codex'
$script:IsOn = $false
$script:Busy = $false
$script:ProxyPid = 0
$script:ProxyReadyTimeoutSec = 90
$script:ProxyWaitPending = $false
$script:ProxyWaitStarted = $null
$script:ProxyWaitWriteConfig = $false
$script:ProxyWait = $null
$script:CustomHeadroom = ''
$script:CloseToTray = $false
$script:LastLampOn = $null
$script:ReallyExit = $false
$script:PreviousProvider = $null
$script:PreviousOpenaiBaseUrl = $null
$script:ClaudePrevBaseUrl = $null
$script:ClaudeHadBaseUrl = $false
$script:OwnsCodex = $false
$script:OwnsClaude = $false
$script:ProxyStartTime = $null
$script:ProxyExePath = $null
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

function Write-Utf8NoBom([string]$Path, [string]$Text, [switch]$NoBackup) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not $NoBackup) { Backup-ConfigFile $Path }
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
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
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
    return (Read-TomlRootQuoted $Content 'model_provider')
}

function Test-ProviderLine([string]$Content) {
    $root = (Split-TomlRoot $Content).Root
    $hits = @((Find-TomlRootKeys $root) | Where-Object { $_.Name -eq 'model_provider' })
    return ($hits.Count -eq 1)
}

function Get-TomlCharRun([string]$Content, [int]$Index, [char]$Ch) {
    $n = $Content.Length
    $run = 0
    while (($Index + $run) -lt $n -and $Content[$Index + $run] -eq $Ch) { $run++ }
    return $run
}

function Find-TomlTableHeaders([string]$Content) {
    $headers = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Content)) { return @() }
    $n = $Content.Length
    $i = 0
    $state = 'code'
    $arr = 0
    $escape = $false
    $bol = $true
    $dq = [char]'"'
    $sq = [char]"'"
    $bs = [char]0x5C
    while ($i -lt $n) {
        if ($state -eq 'mlbasic') {
            if ($escape) { $escape = $false; $i++; continue }
            $ch = $Content[$i]
            if ($ch -eq $bs) { $escape = $true; $i++; continue }
            if ($ch -eq $dq) {
                $run = Get-TomlCharRun $Content $i $dq
                if ($run -ge 3) { $state = 'code'; $i += $run; $bol = $false; continue }
                $i += $run
                continue
            }
            if ($ch -eq [char]"`n") { $bol = $true }
            $i++; continue
        }
        if ($state -eq 'mlliteral') {
            if ($Content[$i] -eq $sq) {
                $run = Get-TomlCharRun $Content $i $sq
                if ($run -ge 3) { $state = 'code'; $i += $run; $bol = $false; continue }
                $i += $run
                continue
            }
            if ($Content[$i] -eq [char]"`n") { $bol = $true }
            $i++; continue
        }
        if ($state -eq 'basic') {
            if ($escape) { $escape = $false; $i++; continue }
            $ch = $Content[$i]
            if ($ch -eq $bs) { $escape = $true; $i++; continue }
            if ($ch -eq $dq) { $state = 'code'; $i++; $bol = $false; continue }
            $i++; continue
        }
        if ($state -eq 'literal') {
            if ($Content[$i] -eq $sq) { $state = 'code'; $i++; $bol = $false; continue }
            $i++; continue
        }
        $c = $Content[$i]
        if ($c -eq [char]'#') {
            while ($i -lt $n -and $Content[$i] -ne [char]"`n") { $i++ }
            continue
        }
        if ($c -eq $dq) {
            $run = Get-TomlCharRun $Content $i $dq
            if ($run -ge 3) { $state = 'mlbasic'; $i += 3; $bol = $false; continue }
            $state = 'basic'; $i++; $bol = $false; continue
        }
        if ($c -eq $sq) {
            $run = Get-TomlCharRun $Content $i $sq
            if ($run -ge 3) { $state = 'mlliteral'; $i += 3; $bol = $false; continue }
            $state = 'literal'; $i++; $bol = $false; continue
        }
        if ($c -eq [char]'[') {
            if ($bol -and $arr -eq 0) {
                $aot = (($i + 1) -lt $n -and $Content[$i + 1] -eq [char]'[')
                $nameStart = $i + $(if ($aot) { 2 } else { 1 })
                $j = $nameStart
                while ($j -lt $n -and $Content[$j] -ne [char]']') { $j++ }
                $name = ''
                if ($j -le $n) { $name = $Content.Substring($nameStart, [Math]::Max(0, $j - $nameStart)).Trim() }
                $headers.Add(@{ Index = $i; Name = $name; Aot = [bool]$aot })
                if ($j -lt $n) { $j++ }
                if ($aot -and $j -lt $n -and $Content[$j] -eq [char]']') { $j++ }
                $i = $j
                $bol = $false
                continue
            }
            $arr++
            $bol = $false
            $i++
            continue
        }
        if ($c -eq [char]']') {
            if ($arr -gt 0) { $arr-- }
            $bol = $false
            $i++
            continue
        }
        if ($c -eq [char]"`n") { $bol = $true; $i++; continue }
        if ($c -eq [char]"`r") { $i++; continue }
        if ($c -eq [char]' ' -or $c -eq [char]"`t") { $i++; continue }
        $bol = $false
        $i++
    }
    if ($headers.Count -eq 0) { return [object[]]@() }
    return $headers.ToArray()
}

function Split-TomlRoot([string]$Content) {
    if ([string]::IsNullOrEmpty($Content)) { return @{ Root = $Content; Rest = '' } }
    $headers = @(Find-TomlTableHeaders $Content)
    if ($headers.Count -eq 0) { return @{ Root = $Content; Rest = '' } }
    $i = [int]$headers[0].Index
    return @{ Root = $Content.Substring(0, $i); Rest = $Content.Substring($i) }
}

function Get-TomlTableText([string]$Content, [string]$TableName) {
    $headers = @(Find-TomlTableHeaders $Content)
    for ($k = 0; $k -lt $headers.Count; $k++) {
        if ($headers[$k].Aot) { continue }
        if ($headers[$k].Name -ne $TableName) { continue }
        $start = [int]$headers[$k].Index
        $end = if (($k + 1) -lt $headers.Count) { [int]$headers[$k + 1].Index } else { $Content.Length }
        return $Content.Substring($start, $end - $start)
    }
    return $null
}

function Get-TomlUnquotedKey([string]$Raw) {
    $t = "$Raw".Trim()
    if ($t.Length -ge 2) {
        $a = $t[0]
        $b = $t[$t.Length - 1]
        if (($a -eq [char]'"' -and $b -eq [char]'"') -or ($a -eq [char]"'" -and $b -eq [char]"'")) {
            return $t.Substring(1, $t.Length - 2)
        }
    }
    return $t
}

function Find-TomlRootKeys([string]$Root) {
    $list = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Root)) { return [object[]]@() }
    $n = $Root.Length
    $i = 0
    $state = 'code'
    $arr = 0
    $escape = $false
    $lineStart = 0
    $dq = [char]'"'
    $sq = [char]"'"
    $bs = [char]0x5C
    $phase = 'key'
    $keyStart = -1
    $keyEnd = -1
    $eqAt = -1
    $valOpen = -1
    $valClose = -1
    $valKind = ''
    function Flush-RootKey {
        param($End)
        if ($keyStart -lt 0 -or $eqAt -lt 0) { return }
        $name = Get-TomlUnquotedKey $Root.Substring($keyStart, [Math]::Max(0, $keyEnd - $keyStart))
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $list.Add(@{
            Name = $name
            LineStart = $lineStart
            LineEnd = $End
            KeyStart = $keyStart
            KeyEnd = $keyEnd
            Eq = $eqAt
            ValOpen = $valOpen
            ValClose = $valClose
            ValKind = $valKind
        })
    }
    while ($i -lt $n) {
        if ($state -eq 'mlbasic') {
            if ($escape) { $escape = $false; $i++; continue }
            $ch = $Root[$i]
            if ($ch -eq $bs) { $escape = $true; $i++; continue }
            if ($ch -eq $dq) {
                $run = Get-TomlCharRun $Root $i $dq
                if ($run -ge 3) {
                    $state = 'code'
                    $i += $run
                    if ($phase -eq 'value' -and $arr -eq 0) { $valClose = $i; $phase = 'postval' }
                    continue
                }
                $i += $run
                continue
            }
            $i++; continue
        }
        if ($state -eq 'mlliteral') {
            if ($Root[$i] -eq $sq) {
                $run = Get-TomlCharRun $Root $i $sq
                if ($run -ge 3) {
                    $state = 'code'
                    $i += $run
                    if ($phase -eq 'value' -and $arr -eq 0) { $valClose = $i; $phase = 'postval' }
                    continue
                }
                $i += $run
                continue
            }
            $i++; continue
        }
        if ($state -eq 'basic') {
            if ($escape) { $escape = $false; $i++; continue }
            $ch = $Root[$i]
            if ($ch -eq $bs) { $escape = $true; $i++; continue }
            if ($ch -eq $dq) {
                $state = 'code'
                $i++
                if ($phase -eq 'value' -and $arr -eq 0) { $valClose = $i; $phase = 'postval' }
                elseif ($phase -eq 'qkey') { $keyEnd = $i; $phase = 'postkey' }
                continue
            }
            $i++; continue
        }
        if ($state -eq 'literal') {
            if ($Root[$i] -eq $sq) {
                $state = 'code'
                $i++
                if ($phase -eq 'value' -and $arr -eq 0) { $valClose = $i; $phase = 'postval' }
                elseif ($phase -eq 'qkey') { $keyEnd = $i; $phase = 'postkey' }
                continue
            }
            $i++; continue
        }
        $c = $Root[$i]
        if ($c -eq [char]'#') {
            while ($i -lt $n -and $Root[$i] -ne [char]"`n") { $i++ }
            continue
        }
        if ($c -eq [char]"`r") { $i++; continue }
        if ($c -eq [char]"`n") {
            if ($phase -eq 'postval' -or ($phase -eq 'value' -and $arr -eq 0 -and $valOpen -ge 0)) {
                if ($valClose -lt 0) { $valClose = $i }
                Flush-RootKey ($i + 1)
            }
            $phase = 'key'
            $keyStart = -1; $keyEnd = -1; $eqAt = -1
            $valOpen = -1; $valClose = -1; $valKind = ''
            $lineStart = $i + 1
            $i++
            continue
        }
        if ($arr -gt 0) {
            if ($c -eq $dq) {
                $run = Get-TomlCharRun $Root $i $dq
                if ($run -ge 3) { $state = 'mlbasic'; $i += 3; continue }
                $state = 'basic'; $i++; continue
            }
            if ($c -eq $sq) {
                $run = Get-TomlCharRun $Root $i $sq
                if ($run -ge 3) { $state = 'mlliteral'; $i += 3; continue }
                $state = 'literal'; $i++; continue
            }
            if ($c -eq [char]'[') { $arr++; $i++; continue }
            if ($c -eq [char]']') {
                $arr--
                $i++
                if ($arr -eq 0 -and $phase -eq 'value') { $valClose = $i; $phase = 'postval' }
                continue
            }
            $i++; continue
        }
        if ($phase -eq 'key') {
            if ($c -eq [char]' ' -or $c -eq [char]"`t") { $i++; continue }
            $keyStart = $i
            if ($c -eq $dq -or $c -eq $sq) {
                $phase = 'qkey'
                $state = $(if ($c -eq $dq) { 'basic' } else { 'literal' })
                $i++
                continue
            }
            while ($i -lt $n) {
                $ch = $Root[$i]
                if ($ch -eq [char]'=' -or $ch -eq [char]' ' -or $ch -eq [char]"`t" -or $ch -eq [char]"`n" -or $ch -eq [char]"`r" -or $ch -eq [char]'#') { break }
                $i++
            }
            $keyEnd = $i
            $phase = 'postkey'
            continue
        }
        if ($phase -eq 'postkey') {
            if ($c -eq [char]' ' -or $c -eq [char]"`t") { $i++; continue }
            if ($c -eq [char]'=') { $eqAt = $i; $phase = 'value'; $i++; continue }
            $phase = 'skip'
            $i++
            continue
        }
        if ($phase -eq 'value') {
            if ($valOpen -lt 0 -and ($c -eq [char]' ' -or $c -eq [char]"`t")) { $i++; continue }
            if ($valOpen -lt 0) { $valOpen = $i }
            $run = 0
            if ($c -eq $dq) { $run = Get-TomlCharRun $Root $i $dq }
            if ($c -eq $sq) { $run = Get-TomlCharRun $Root $i $sq }
            if ($c -eq $dq -and $run -ge 3) { $valKind = 'multi'; $state = 'mlbasic'; $i += 3; continue }
            if ($c -eq $sq -and $run -ge 3) { $valKind = 'multi'; $state = 'mlliteral'; $i += 3; continue }
            if ($c -eq $dq) { $valKind = 'basic'; $state = 'basic'; $i++; continue }
            if ($c -eq $sq) { $valKind = 'literal'; $state = 'literal'; $i++; continue }
            if ($c -eq [char]'[') { $valKind = 'array'; $arr = 1; $i++; continue }
            $valKind = 'bare'
            while ($i -lt $n) {
                $ch = $Root[$i]
                if ($ch -eq [char]'#' -or $ch -eq [char]"`n" -or $ch -eq [char]"`r") { break }
                $i++
            }
            $valClose = $i
            $phase = 'postval'
            continue
        }
        $i++
    }
    if ($phase -eq 'postval' -or ($phase -eq 'value' -and $valOpen -ge 0)) {
        if ($valClose -lt 0) { $valClose = $n }
        Flush-RootKey $n
    }
    if ($list.Count -eq 0) { return [object[]]@() }
    return $list.ToArray()
}

function Read-TomlRootQuoted([string]$Content, [string]$Key) {
    $root = (Split-TomlRoot $Content).Root
    $hits = @((Find-TomlRootKeys $root) | Where-Object { $_.Name -eq $Key })
    if ($hits.Count -ne 1) { return $null }
    $h = $hits[0]
    if ($h.ValKind -ne 'basic' -and $h.ValKind -ne 'literal') { return $null }
    if ([int]$h.ValOpen -lt 0 -or [int]$h.ValClose -le [int]$h.ValOpen) { return $null }
    return (Get-TomlUnquotedKey $root.Substring([int]$h.ValOpen, [int]$h.ValClose - [int]$h.ValOpen))
}

function Set-TomlRootQuoted([string]$Content, [string]$Key, [string]$Value, [string]$Nl) {
    $parts = Split-TomlRoot $Content
    $hits = @((Find-TomlRootKeys $parts.Root) | Where-Object { $_.Name -eq $Key })
    if ($hits.Count -gt 1) { throw "Refusing to write config — duplicate root key $Key." }
    $quoted = '"' + (Escape-TomlString $Value) + '"'
    if ($hits.Count -eq 1) {
        $h = $hits[0]
        if ($h.ValKind -ne 'basic' -and $h.ValKind -ne 'literal') {
            throw "Refusing to write config — $Key is not a quoted string."
        }
        $root = $parts.Root.Substring(0, [int]$h.ValOpen) + $quoted + $parts.Root.Substring([int]$h.ValClose)
        return Join-TomlRoot $parts $root
    }
    $line = $Key + ' = ' + $quoted
    if ([string]::IsNullOrWhiteSpace($parts.Root)) { return Join-TomlRoot $parts ($line + $Nl) }
    return Join-TomlRoot $parts ($parts.Root.TrimEnd() + $Nl + $line + $Nl)
}

function Remove-TomlRootKey([string]$Content, [string]$Key) {
    $parts = Split-TomlRoot $Content
    $hits = @((Find-TomlRootKeys $parts.Root) | Where-Object { $_.Name -eq $Key })
    if ($hits.Count -ne 1) { return $Content }
    $h = $hits[0]
    $root = $parts.Root.Substring(0, [int]$h.LineStart) + $parts.Root.Substring([int]$h.LineEnd)
    return Join-TomlRoot $parts $root
}

function Join-TomlRoot($Parts, [string]$Root) {
    return $Root + $Parts.Rest
}

function Set-ProviderLine([string]$Content, [string]$Provider, [string]$Nl) {
    return (Set-TomlRootQuoted $Content 'model_provider' $Provider $Nl)
}

function Remove-ProviderLine([string]$Content) {
    return (Remove-TomlRootKey $Content 'model_provider')
}

function Remove-TomlTable([string]$Content, [string]$TableName) {
    if ([string]::IsNullOrEmpty($Content) -or [string]::IsNullOrEmpty($TableName)) { return $Content }
    $headers = @(Find-TomlTableHeaders $Content)
    if ($headers.Count -eq 0) { return $Content }
    $sb = New-Object System.Text.StringBuilder
    $prev = 0
    for ($k = 0; $k -lt $headers.Count; $k++) {
        $h = $headers[$k]
        $end = if (($k + 1) -lt $headers.Count) { [int]$headers[$k + 1].Index } else { $Content.Length }
        if ($h.Name -eq $TableName) {
            $idx = [int]$h.Index
            if ($idx -gt $prev) { [void]$sb.Append($Content.Substring($prev, $idx - $prev)) }
            $prev = $end
        }
    }
    if ($prev -lt $Content.Length) { [void]$sb.Append($Content.Substring($prev)) }
    return $sb.ToString()
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

function Get-HeadroomCompatBlock([string]$Nl) {
    return (
        '[model_providers.headroom]' + $Nl +
        'name = "OpenAI via Headroom proxy"' + $Nl +
        'wire_api = "responses"' + $Nl +
        'requires_openai_auth = true'
    )
}

function Test-HeadroomProviderIsCompat([string]$Content) {
    $t = Get-TomlTableText $Content 'model_providers.headroom'
    if ([string]::IsNullOrEmpty($t)) { return $false }
    $nl = $t.IndexOf("`n")
    $b = if ($nl -ge 0) { $t.Substring($nl + 1) } else { '' }
    if ($b -match '(?i)base_url') { return $false }
    if ($b -match '(?i)127\.0\.0\.1') { return $false }
    if ($b -match '(?i)api\.openai\.com') { return $false }
    if ($b -notmatch '(?m)^wire_api\s*=\s*"responses"') { return $false }
    if ($b -notmatch '(?m)^requires_openai_auth\s*=\s*true') { return $false }
    return $true
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
    return (Read-TomlRootQuoted $Content 'openai_base_url')
}

function Set-OpenaiBaseLine([string]$Content, [string]$Url, [string]$Nl) {
    return (Set-TomlRootQuoted $Content 'openai_base_url' $Url $Nl)
}

function Remove-OpenaiBaseLine([string]$Content) {
    return (Remove-TomlRootKey $Content 'openai_base_url')
}

function Test-CodexManagedBySwitch([string]$Content) {
    $v = Read-TomlTableValue $Content 'headroom_switch' 'managed_by'
    return ($v -eq 'headroom-switch')
}

function Escape-TomlString([string]$Value) {
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('\', '\\').Replace('"', '\"')
}

function Read-TomlTableValue([string]$Content, [string]$Table, [string]$Key) {
    $t = Get-TomlTableText $Content $Table
    if ([string]::IsNullOrEmpty($t)) { return $null }
    $escK = [regex]::Escape($Key)
    $km = [regex]::Match($t, "(?m)^[ \t]*$escK\s*=\s*""([^""]*)""")
    if ($km.Success) { return $km.Groups[1].Value }
    return $null
}

function Read-SwitchPrevious([string]$Content) {
    $p = Read-TomlTableValue $Content 'headroom_switch' 'previous_provider'
    $b = Read-TomlTableValue $Content 'headroom_switch' 'previous_openai_base_url'
    if ($p -eq '') { $p = $null }
    if ($b -eq '') { $b = $null }
    return @{ Provider = $p; BaseUrl = $b }
}

function Get-SwitchBlock($PreviousProvider, $PreviousOpenaiBaseUrl, [string]$Nl) {
    $pp = Escape-TomlString $(if ($PreviousProvider -and $PreviousProvider -ne 'headroom') { $PreviousProvider } else { '' })
    $pb = Escape-TomlString $(if ($PreviousOpenaiBaseUrl -and "$PreviousOpenaiBaseUrl" -notmatch '127\.0\.0\.1:') { $PreviousOpenaiBaseUrl } else { '' })
    return (
        '[headroom_switch]' + $Nl +
        'managed_by = "headroom-switch"' + $Nl +
        ('previous_provider = "' + $pp + '"') + $Nl +
        ('previous_openai_base_url = "' + $pb + '"')
    )
}

function Test-CodexEnabled([string]$Content, [int]$Port) {
    $base = Read-OpenaiBaseUrl $Content
    if ($base -and $base -match "127\.0\.0\.1:$Port(/|$)") { return $true }
    return ((Read-ModelProvider $Content) -eq 'headroom')
}

function Enable-CodexConfig([string]$Content, [int]$Port, [string]$McpCommand) {
    $nl = Get-Newline $Content
    if ([string]::IsNullOrWhiteSpace($Content)) { $nl = "`r`n"; $Content = '' }
    $sw = Read-SwitchPrevious $Content
    $cur = Read-ModelProvider $Content
    $prevP = $sw.Provider
    if (-not $prevP -and $cur -and $cur -ne 'headroom') { $prevP = $cur }
    $curB = Read-OpenaiBaseUrl $Content
    $prevB = $sw.BaseUrl
    if (-not $prevB -and $curB -and "$curB" -notmatch '127\.0\.0\.1:') { $prevB = $curB }
    $Content = Remove-TomlTable $Content 'headroom_switch'
    $Content = Remove-HeadroomBlock $Content
    $Content = Remove-McpBlock $Content
    $Content = Set-ProviderLine $Content 'headroom' $nl
    $Content = Set-OpenaiBaseLine $Content "http://127.0.0.1:$Port/v1" $nl
    $block = Get-HeadroomBlock $Port $nl
    $cmd = if ($McpCommand) { $McpCommand } else { 'headroom' }
    $mcp = Get-McpBlock $cmd $nl
    $owned = Get-SwitchBlock $prevP $prevB $nl
    $Content = $Content.TrimEnd() + $nl + $nl + $block + $nl + $nl + $mcp + $nl + $nl + $owned + $nl
    if (-not $Content.EndsWith("`n")) { $Content += $nl }
    return $Content
}

function Disable-CodexConfig([string]$Content, $PreviousProvider, $PreviousOpenaiBaseUrl) {
    $nl = Get-Newline $Content
    $sw = Read-SwitchPrevious $Content
    if (-not $PreviousProvider) { $PreviousProvider = $sw.Provider }
    if (-not $PreviousOpenaiBaseUrl) { $PreviousOpenaiBaseUrl = $sw.BaseUrl }
    $Content = Remove-TomlTable $Content 'headroom_switch'
    $Content = Remove-HeadroomBlock $Content
    $Content = Remove-McpBlock $Content
    if ($PreviousProvider -and $PreviousProvider -ne 'headroom') {
        $Content = Set-ProviderLine $Content $PreviousProvider $nl
    } else {
        $Content = Remove-ProviderLine $Content
    }
    if ($PreviousOpenaiBaseUrl -and "$PreviousOpenaiBaseUrl" -notmatch '127\.0\.0\.1:') {
        $Content = Set-OpenaiBaseLine $Content $PreviousOpenaiBaseUrl $nl
    } else {
        $Content = Remove-OpenaiBaseLine $Content
    }
    $compat = Get-HeadroomCompatBlock $nl
    $Content = $Content.TrimEnd() + $nl + $nl + $compat + $nl
    if (-not $Content.EndsWith("`n")) { $Content += $nl }
    return $Content
}

function Get-AnthropicBaseUrl([int]$Port) { return "http://127.0.0.1:$Port" }

function ConvertTo-PrettyJson($Obj) {
    return ($Obj | ConvertTo-Json -Depth 20)
}

function Test-JsonDuplicateKeys([string]$Json) {
    if ([string]::IsNullOrWhiteSpace($Json)) { return $false }
    $inStr = $false
    $esc = $false
    $depth = 0
    $arr = New-Object 'System.Collections.Generic.List[bool]'
    $sets = New-Object 'System.Collections.Generic.List[object]'
    [void]$arr.Add($false)
    [void]$sets.Add($null)
    $expectKey = $false
    $readingKey = $false
    $buf = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Json.Length; $i++) {
        $c = $Json[$i]
        if ($inStr) {
            if ($esc) { $esc = $false; if ($readingKey) { [void]$buf.Append($c) }; continue }
            if ($c -eq [char]92) { $esc = $true; continue }
            if ($c -eq '"') {
                $inStr = $false
                if ($readingKey) {
                    $k = $buf.ToString()
                    $readingKey = $false
                    $set = $sets[$depth]
                    if ($set -and -not $set.Add($k)) { return $true }
                }
                continue
            }
            if ($readingKey) { [void]$buf.Append($c) }
            continue
        }
        if ($c -eq '"') {
            $inStr = $true
            if ($depth -gt 0 -and -not $arr[$depth] -and $expectKey) {
                $readingKey = $true
                $buf.Length = 0
            }
            continue
        }
        if ([char]::IsWhiteSpace($c)) { continue }
        if ($c -eq '{') {
            $depth++
            while ($arr.Count -le $depth) { [void]$arr.Add($false); [void]$sets.Add($null) }
            $arr[$depth] = $false
            $sets[$depth] = New-Object 'System.Collections.Generic.HashSet[string]'
            $expectKey = $true
            continue
        }
        if ($c -eq '}') { $depth--; $expectKey = $false; continue }
        if ($c -eq '[') {
            $depth++
            while ($arr.Count -le $depth) { [void]$arr.Add($false); [void]$sets.Add($null) }
            $arr[$depth] = $true
            $expectKey = $false
            continue
        }
        if ($c -eq ']') { $depth--; $expectKey = $false; continue }
        if ($c -eq ':') { $expectKey = $false; continue }
        if ($c -eq ',') {
            if ($depth -gt 0 -and -not $arr[$depth]) { $expectKey = $true }
            continue
        }
    }
    return $false
}

function Read-JsonObject([string]$Path) {
    $raw = Read-Utf8 $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return New-Object PSObject
    }
    if (Test-JsonDuplicateKeys $raw) {
        throw "Refusing to write $Path — the file has duplicate JSON keys. Restore a backup, then try again."
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
    if (Test-Path -LiteralPath $pkgRoot) {
        $pkgs = @(Get-ChildItem -LiteralPath $pkgRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Claude_*' })
        foreach ($p in $pkgs) {
            $c = Join-Path $p.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json'
            [void]$list.Add($c)
        }
    }
    return @($list | Select-Object -Unique)
}

function New-FileSnapshot([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (Test-Path -LiteralPath $Path) {
        return @{ Path = $Path; Exists = $true; Bytes = [System.IO.File]::ReadAllBytes($Path) }
    }
    return @{ Path = $Path; Exists = $false; Bytes = $null }
}

function Restore-FileSnapshot($Snap) {
    if ($null -eq $Snap -or [string]::IsNullOrWhiteSpace($Snap.Path)) { return }
    $p = [string]$Snap.Path
    $dir = Split-Path -Parent $p
    if ($Snap.Exists) {
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $tmp = $p + '.' + [guid]::NewGuid().ToString('n') + '.tmp'
        [System.IO.File]::WriteAllBytes($tmp, [byte[]]$Snap.Bytes)
        if (Test-Path -LiteralPath $p) {
            $swap = $p + '.replace.bak'
            [System.IO.File]::Replace($tmp, $p, $swap)
            Remove-Item -LiteralPath $swap -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::Move($tmp, $p)
        }
    } else {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WithFileSnapshots([string[]]$Paths, [scriptblock]$Action, [object[]]$ActionArgs) {
    $snaps = @()
    foreach ($p in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $snaps += ,(New-FileSnapshot $p)
    }
    try {
        if ($null -eq $ActionArgs -or $ActionArgs.Count -eq 0) { & $Action }
        else { & $Action @ActionArgs }
    } catch {
        $restoreErr = $null
        foreach ($s in $snaps) {
            try { Restore-FileSnapshot $s } catch {
                Add-Log ('Restore failed: ' + $_.Exception.Message)
                if (-not $restoreErr) { $restoreErr = $_ }
            }
        }
        if ($restoreErr) { throw $restoreErr }
        throw
    }
}

function Get-ClaudeConfigPaths {
    $list = New-Object System.Collections.Generic.List[string]
    if ($script:ClaudeSettingsPath) { [void]$list.Add($script:ClaudeSettingsPath) }
    foreach ($p in @(Get-ClaudeDesktopPaths)) { [void]$list.Add($p) }
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
    $mark = Get-Note $obj '_headroom_switch'
    if ($prev -and ("$prev" -notmatch '127\.0\.0\.1:')) {
        $script:ClaudePrevBaseUrl = "$prev"
        $script:ClaudeHadBaseUrl = $true
    } elseif (-not $prev) {
        if (-not $mark) { $script:ClaudeHadBaseUrl = $false }
    }
    if (-not $mark) {
        $mark = New-Object PSObject
        Ensure-Note $obj '_headroom_switch' $mark
    }
    if ($script:ClaudeHadBaseUrl -and $script:ClaudePrevBaseUrl) {
        Ensure-Note $mark 'previous' $script:ClaudePrevBaseUrl
        Ensure-Note $mark 'had' $true
    } else {
        Ensure-Note $mark 'had' $false
    }
    Ensure-Note $envObj 'ANTHROPIC_BASE_URL' (Get-AnthropicBaseUrl $Port)
    $dir = Split-Path $script:ClaudeSettingsPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Utf8NoBom $script:ClaudeSettingsPath (ConvertTo-PrettyJson $obj)
}

function Disable-ClaudeSettings {
    if (-not (Test-Path -LiteralPath $script:ClaudeSettingsPath)) { return }
    $obj = Read-JsonObject $script:ClaudeSettingsPath
    $envObj = Get-Note $obj 'env'
    $mark = Get-Note $obj '_headroom_switch'
    $prev = $script:ClaudePrevBaseUrl
    $had = $script:ClaudeHadBaseUrl
    if ($mark) {
        $mp = Get-Note $mark 'previous'
        $mh = Get-Note $mark 'had'
        if ($mp) { $prev = "$mp" }
        if ($null -ne $mh) { $had = [bool]$mh }
    }
    if ($null -eq $envObj) {
        $envObj = New-Object PSObject
        Ensure-Note $obj 'env' $envObj
    }
    if ($had -and $prev -and ($prev -notmatch '127\.0\.0\.1:')) {
        Ensure-Note $envObj 'ANTHROPIC_BASE_URL' $prev
    } else {
        if (Test-HasProp $envObj 'ANTHROPIC_BASE_URL') {
            $envObj.PSObject.Properties.Remove('ANTHROPIC_BASE_URL')
        }
    }
    $envNames = @(Get-PropNames $envObj)
    if ($envNames.Count -eq 0 -and (Test-HasProp $obj 'env')) {
        $obj.PSObject.Properties.Remove('env')
    }
    if (Test-HasProp $obj '_headroom_switch') {
        $obj.PSObject.Properties.Remove('_headroom_switch')
    }
    Write-Utf8NoBom $script:ClaudeSettingsPath (ConvertTo-PrettyJson $obj)
}

function Enable-ClaudeDesktop([string]$Command, [string[]]$Paths) {
    $cmd = if ($Command) { $Command } else { 'headroom' }
    $explicit = $true
    if ($null -eq $Paths) { $Paths = @(Get-ClaudeDesktopPaths); $explicit = $false }
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $dir = Split-Path $path
        $exists = Test-Path -LiteralPath $path
        if (-not $explicit) {
            if (-not $exists -and -not (Test-Path -LiteralPath $dir)) {
                if ($path -notmatch [regex]::Escape((Join-Path $env:APPDATA 'Claude'))) { continue }
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            if (-not $exists -and $path -notmatch [regex]::Escape((Join-Path $env:APPDATA 'Claude'))) { continue }
        }
        $obj = Read-JsonObject $path
        $mcp = Get-Note $obj 'mcpServers'
        $owned = $false
        try { $owned = [bool](Get-Note $obj '_headroom_switch_mcp') } catch { $owned = $false }
        if ($mcp -and (Test-HasProp $mcp 'headroom') -and -not $owned) {
            throw "Claude already has mcpServers.headroom. Not overwriting."
        }
        if ($null -eq $mcp) {
            $mcp = New-Object PSObject
            Ensure-Note $obj 'mcpServers' $mcp
        }
        $server = New-Object PSObject
        Ensure-Note $server 'command' $cmd
        Ensure-Note $server 'args' @('mcp', 'serve')
        Ensure-Note $mcp 'headroom' $server
        Ensure-Note $obj '_headroom_switch_mcp' $true
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Write-Utf8NoBom $path (ConvertTo-PrettyJson $obj)
        try { Add-Log "MCP → $path" } catch {}
    }
}

function Disable-ClaudeDesktop([string[]]$Paths) {
    if ($null -eq $Paths) { $Paths = @(Get-ClaudeDesktopPaths) }
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $obj = Read-JsonObject $path
        $owned = $false
        try { $owned = [bool](Get-Note $obj '_headroom_switch_mcp') } catch { $owned = $false }
        if (-not $owned) { continue }
        $mcp = Get-Note $obj 'mcpServers'
        if ($mcp -and (Test-HasProp $mcp 'headroom')) {
            $mcp.PSObject.Properties.Remove('headroom')
        }
        $left = @(Get-PropNames $mcp)
        if ($left.Count -eq 0 -and (Test-HasProp $obj 'mcpServers')) {
            $obj.PSObject.Properties.Remove('mcpServers')
        }
        if (Test-HasProp $obj '_headroom_switch_mcp') {
            $obj.PSObject.Properties.Remove('_headroom_switch_mcp')
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
        if (Test-HasProp $s 'ownsCodex') {
            $script:OwnsCodex = [bool]$s.ownsCodex
        } elseif ($script:PreviousProvider -or $script:PreviousOpenaiBaseUrl) {
            $script:OwnsCodex = $true
        }
        if (Test-HasProp $s 'ownsClaude') {
            $script:OwnsClaude = [bool]$s.ownsClaude
        } elseif ($script:ClaudePrevBaseUrl) {
            $script:OwnsClaude = $true
        }
        if ((Test-HasProp $s 'proxyStartTime') -and $s.proxyStartTime) {
            $script:ProxyStartTime = [string]$s.proxyStartTime
        }
        if ((Test-HasProp $s 'proxyExePath') -and $s.proxyExePath) {
            $script:ProxyExePath = [string]$s.proxyExePath
        }
    } catch {}
}

function Write-AppState {
    $obj = [ordered]@{
        port                  = $script:Port
        previousProvider      = $script:PreviousProvider
        previousOpenaiBaseUrl = $script:PreviousOpenaiBaseUrl
        proxyPid              = $script:ProxyPid
        proxyStartTime        = $script:ProxyStartTime
        proxyExePath          = $script:ProxyExePath
        customHeadroom        = $script:CustomHeadroom
        closeToTray           = $script:CloseToTray
        settingsVersion       = 4
        profile               = $script:Profile
        targetApp             = $script:TargetApp
        claudePrevBaseUrl     = $script:ClaudePrevBaseUrl
        claudeHadBaseUrl      = $script:ClaudeHadBaseUrl
        ownsCodex             = $script:OwnsCodex
        ownsClaude            = $script:OwnsClaude
    }
    Write-Utf8NoBom $script:StatePath ($obj | ConvertTo-Json) -NoBackup
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
                $cmdPy = Get-Command $py -ErrorAction SilentlyContinue
                if (-not $cmdPy -or -not $cmdPy.Source) { continue }
                $code = 0
                $which = [HeadroomHidden]::Run($cmdPy.Source, '-c "import shutil; print(shutil.which(''headroom'') or '''')"', 4000, [ref]$code)
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
        $lines = @(netstat -ano 2>$null | Select-String -Pattern 'LISTENING')
        foreach ($line in $lines) {
            $t = [string]$line.Line
            if ($t -notmatch ":$Port\s") { continue }
            if ($t -match '\s(\d+)\s*$') { return [int]$Matches[1] }
        }
    } catch {}
    return $null
}

function Merge-SwitchOwnership([string]$Content, $PrevP, $PrevB) {
    if (Test-CodexManagedBySwitch $Content) { return $Content }
    $nl = Get-Newline $Content
    if ([string]::IsNullOrWhiteSpace($Content)) { $nl = "`r`n" }
    $block = Get-SwitchBlock $PrevP $PrevB $nl
    return ($Content.TrimEnd() + $nl + $nl + $block + $nl)
}

function Test-ExeIsHeadroom([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return [bool]($Path -match '(?i)[\\/]headroom(\.exe)?$')
}

function Test-HeadroomIdentity([string]$Name, [string]$ExePath) {
    if (Test-ExeIsHeadroom $ExePath) { return $true }
    if ($Name -match '(?i)^headroom(\.exe)?$') { return $true }
    return $false
}

function Test-CmdIsHeadroomProxy([string]$Cmd) {
    if ([string]::IsNullOrWhiteSpace($Cmd)) { return $false }
    if ($Cmd -notmatch '(?i)(?:^|[\\/''"\s])headroom\.exe(?:[''"]|\s|$)') { return $false }
    if ($Cmd -notmatch '(?i)(?:^|\s)proxy(?:\s|$)') { return $false }
    return $true
}

function Test-CmdHasMcpServe([string]$Cmd) {
    if ([string]::IsNullOrWhiteSpace($Cmd)) { return $false }
    if ($Cmd -notmatch '(?i)(?:^|\s)mcp(?:\s|$)') { return $false }
    if ($Cmd -notmatch '(?i)(?:^|\s)serve(?:\s|$)') { return $false }
    return $true
}

function Test-IsPortProxyWorker([string]$Cmd) {
    return (Test-CmdIsHeadroomProxy $Cmd)
}

function Test-IsShimProxy([string]$Name, [string]$ExePath, [string]$Cmd) {
    if (-not (Test-HeadroomIdentity $Name $ExePath)) { return $false }
    return [bool]($Cmd -match '(?i)(?:^|\s)proxy(?:\s|$)')
}

function Test-ParentLooksAlive([int]$ParentId) {
    if ($ParentId -le 0) { return $false }
    try {
        $proc = Get-Process -Id $ParentId -ErrorAction SilentlyContinue
        return [bool]$proc
    } catch {
        return $false
    }
}

function Test-IsOrphanMcpServe([string]$Name, [string]$ExePath, [string]$Cmd, [int]$ParentId) {
    if (-not (Test-HeadroomIdentity $Name $ExePath)) { return $false }
    if (-not (Test-CmdHasMcpServe $Cmd)) { return $false }
    if (Test-ParentLooksAlive $ParentId) { return $false }
    return $true
}

function Test-CreationTimeAllowsKill($Recorded, $CreationDate) {
    if (-not $Recorded) { return $true }
    if ($null -eq $CreationDate -or "$CreationDate" -eq '') { return $false }
    try {
        $created = [datetime]$CreationDate
        $want = [datetime]$Recorded
        return ([math]::Abs(($created - $want).TotalSeconds) -le 3)
    } catch {
        return $false
    }
}

function Test-ProcessLooksLikeHeadroom([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    if ($ProcessId -eq $PID) { return $false }
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if (-not $p) { return $false }
        return (Test-HeadroomIdentity ([string]$p.Name) ([string]$p.ExecutablePath))
    } catch { return $false }
}

function Test-StoredProxyPid([int]$ProcessId) {
    if (-not (Test-ProcessLooksLikeHeadroom $ProcessId)) { return $false }
    if (-not $script:ProxyExePath -and -not $script:ProxyStartTime) { return $true }
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if (-not $p) { return $false }
        $exe = [string]$p.ExecutablePath
        if ($script:ProxyExePath) {
            if (-not $exe -or ($exe -ne $script:ProxyExePath)) { return $false }
        }
        if ($script:ProxyStartTime) {
            if (-not (Test-CreationTimeAllowsKill $script:ProxyStartTime $p.CreationDate)) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Test-ListenIsOurProxy([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if (-not $p) { return $false }
        return (Test-IsPortProxyWorker ([string]$p.CommandLine))
    } catch { return $false }
}

function Stop-OrphanMcpServe {
    try {
        $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            if ([int]$p.ProcessId -eq $PID) { continue }
            $ppid = 0
            try { $ppid = [int]$p.ParentProcessId } catch {}
            if (Test-IsOrphanMcpServe ([string]$p.Name) ([string]$p.ExecutablePath) ([string]$p.CommandLine) $ppid) {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}

function Stop-HeadroomProxy {
    if ($script:ProxyPid -gt 0) {
        if (Test-StoredProxyPid $script:ProxyPid) {
            Stop-Process -Id $script:ProxyPid -Force -ErrorAction SilentlyContinue
        }
        $script:ProxyPid = 0
        $script:ProxyStartTime = $null
        $script:ProxyExePath = $null
    }
    $listen = Get-ListeningPid $script:Port
    if ($listen -and (Test-ListenIsOurProxy $listen)) {
        Stop-Process -Id $listen -Force -ErrorAction SilentlyContinue
    }
    Stop-OrphanMcpServe
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

function Get-ExistingDirectory([string]$Path) {
    try {
        if ($Path -and (Test-Path -LiteralPath $Path -PathType Container)) { return $Path }
    } catch {}
    $p = $Path
    for ($n = 0; $n -lt 8; $n++) {
        if ([string]::IsNullOrWhiteSpace($p)) { break }
        try { $p = Split-Path $p } catch { break }
        try {
            if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { return $p }
        } catch {}
    }
    foreach ($c in @($env:TEMP, $env:USERPROFILE, $env:WINDIR, $env:SystemRoot)) {
        try {
            if ($c -and (Test-Path -LiteralPath $c -PathType Container)) { return $c }
        } catch {}
    }
    return [string]$pwd
}

function Resolve-ProxyStartKind([bool]$ProcAlive, $ExitCode, [bool]$PortReady, [bool]$Ours, [int]$ElapsedSec, [int]$LimitSec, [bool]$ForeignListen) {
    if ($PortReady -and $Ours) { return 'ready' }
    if ($PortReady -and -not $Ours) { return 'identity' }
    if (-not $ProcAlive) { return 'exited' }
    if ($ElapsedSec -ge $LimitSec) { return 'timeout' }
    if ($ForeignListen) { return 'port-busy' }
    return 'wait'
}

function Protect-DiagText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = "$Text"
    if ($env:USERPROFILE) { $t = $t.Replace($env:USERPROFILE, '%USERPROFILE%') }
    if ($t.Length -gt 1200) { $t = $t.Substring($t.Length - 1200) }
    return $t
}

function Test-OwnedProxyReady {
    param(
        [int]$Port = 0,
        [int]$ExpectedProcessId = 0,
        [string]$ExpectedExePath = '',
        $ExpectedStartTime = $null
    )
    if ($Port -le 0) { $Port = [int]$script:Port }
    if ($Port -le 0) { return $false }
    if (-not (Test-PortOpen $Port)) { return $false }
    $listen = Get-ListeningPid $Port
    if (-not $listen) { return $false }
    if (-not (Test-ListenIsOurProxy $listen)) { return $false }
    if ($ExpectedProcessId -gt 0 -and $listen -eq $ExpectedProcessId -and
        ($ExpectedExePath -or $ExpectedStartTime)) {
        try {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$listen" -ErrorAction SilentlyContinue
            if (-not $p) { return $false }
            if ($ExpectedExePath -and ([string]$p.ExecutablePath -ne $ExpectedExePath)) { return $false }
            if ($ExpectedStartTime -and
                -not (Test-CreationTimeAllowsKill $ExpectedStartTime $p.CreationDate)) { return $false }
        } catch {
            return $false
        }
    }
    return $true
}

function Start-HeadroomProxy {
    $port = [int]$script:Port
    if (Test-PortOpen $port) {
        $listen = Get-ListeningPid $port
        if ($listen -and (Test-ProxyMatchesProfile $listen) -and (Test-ListenIsOurProxy $listen)) {
            $script:ProxyPid = $listen
            return $true
        }
        if ($listen -and (Test-ListenIsOurProxy $listen)) {
            Stop-Process -Id $listen -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 250
        } elseif ($listen) {
            return $false
        } else {
            return $false
        }
    }
    $exe = Find-HeadroomExe
    if (-not $exe) { return $false }
    $wd = Get-ExistingDirectory (Split-Path $exe)
    $argList = @('proxy', '--port', "$port") + @(Get-ModeArgs)
    $p = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $wd -WindowStyle Hidden -PassThru
    $script:ProxyPid = $p.Id
    try {
        $wp = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
        if ($wp) {
            $script:ProxyExePath = [string]$wp.ExecutablePath
            if ($wp.CreationDate) {
                $script:ProxyStartTime = [datetime]$wp.CreationDate
            }
        }
    } catch {}
    return $true
}

function Test-SwitchBusy {
    return [bool]($script:Busy -or $script:ProxyWaitPending)
}

function Test-SettingsAllowed {
    return -not (Test-SwitchBusy)
}

function Test-CurrentAppConfigOwned([string]$Target = '') {
    $app = if ($Target) { Normalize-App $Target } else { Normalize-App $script:TargetApp }
    try {
        if ($app -eq 'claude') {
            $obj = Read-JsonObject $script:ClaudeSettingsPath
            return [bool](Test-HasProp $obj '_headroom_switch')
        }
        return [bool](Test-CodexManagedBySwitch (Read-Utf8 $script:ConfigPath))
    } catch {
        return $false
    }
}

function New-ProxyWaitContext {
    param(
        [Parameter(Mandatory)][string]$Purpose,
        [bool]$WriteConfig,
        [bool]$ConfigWasOn,
        [bool]$ConfigOwned,
        [int]$Port = 0,
        [string]$Bin = '',
        [int]$ProcessId = 0
    )
    if ($Port -le 0) { $Port = [int]$script:Port }
    if ([string]::IsNullOrWhiteSpace($Bin)) {
        try { $Bin = Find-HeadroomExe } catch { $Bin = '' }
    }
    if ($ProcessId -le 0) { $ProcessId = [int]$script:ProxyPid }
    return [ordered]@{
        Purpose      = "$Purpose"
        Port         = [int]$Port
        Bin          = [string]$Bin
        WriteConfig  = [bool]$WriteConfig
        ConfigWasOn  = [bool]$ConfigWasOn
        ConfigOwned  = [bool]$ConfigOwned
        ProcessId    = [int]$ProcessId
        Started      = Get-Date
        Target       = [string]$script:TargetApp
        Profile      = [string]$script:Profile
        ExePath      = [string]$script:ProxyExePath
        StartTime    = $script:ProxyStartTime
    }
}

function Get-ProxyWaitCompensation([string]$Kind, $ctx) {
    $ready = ($Kind -eq 'ready')
    return [ordered]@{
        Kind          = $Kind
        StopProxy     = (-not $ready)
        DisableConfig = ((-not $ready) -and [bool]$ctx.ConfigOwned)
        WriteConfig   = ($ready -and [bool]$ctx.WriteConfig)
        KeepDirect    = ((-not $ready) -and -not [bool]$ctx.ConfigWasOn)
    }
}

function Get-ProxyWaitLog([string]$Kind, $ctx, [int]$Elapsed, $ExitCode, [string]$RollbackState = '') {
    $was = [bool]$ctx.ConfigWasOn
    $owned = [bool]$ctx.ConfigOwned
    $suffix = if ($owned) {
        switch ($RollbackState) {
            'restored' { 'Restored direct routing.' }
            'failed' { 'Rollback failed; config may still point to localhost.' }
            default { 'Owned config rollback not confirmed.' }
        }
    } elseif ($was) {
        'Foreign config left as-is.'
    } else {
        'Config not written.'
    }
    switch ($Kind) {
        'ready' {
            if ($ctx.WriteConfig) { return "Port open (${Elapsed}s)." }
            return "Proxy ready (${Elapsed}s)."
        }
        'exited' {
            $c = if ($null -ne $ExitCode -and "$ExitCode" -ne '') { $ExitCode } else { '?' }
            return "Proxy exited (code $c). $suffix"
        }
        'timeout' {
            return "Proxy timed out after ${Elapsed}s. $suffix"
        }
        'port-busy' {
            return "Port busy. $suffix"
        }
        'identity' {
            return "Listener identity failed. $suffix"
        }
        default {
            return "Proxy start failed ($Kind). $suffix"
        }
    }
}

function Set-PendingUi([bool]$Pending) {
    try {
        if ($btnSettings) { $btnSettings.Enabled = -not $Pending }
    } catch {}
    try {
        if ($lamp -and $Pending) { $lamp.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
        elseif ($lamp) { $lamp.Cursor = [System.Windows.Forms.Cursors]::Hand }
    } catch {}
}

function Clear-ProxyWait {
    $script:ProxyWaitPending = $false
    $script:ProxyWait = $null
    $script:ProxyWaitWriteConfig = $false
    try { if ($script:ProxyWaitTimer) { $script:ProxyWaitTimer.Stop() } } catch {}
    Set-PendingUi $false
}

function Complete-ProxyWait([string]$Kind, $ctx, [int]$Elapsed, $ExitCode) {
    Clear-ProxyWait
    if ($null -eq $ctx) { $script:Busy = $false; return }
    $plan = Get-ProxyWaitCompensation $Kind $ctx
    if ($plan.WriteConfig) {
        try {
            Enable-CurrentAppConfig -Bin $ctx.Bin -Target $ctx.Target -Port $ctx.Port
            $who = if ($ctx.Target -eq 'claude') { 'Claude Desktop / Cowork' } else { 'ChatGPT / Codex' }
            try { Add-Log (Get-ProxyWaitLog $Kind $ctx $Elapsed $ExitCode) } catch {}
            try { Add-Log "Fully quit $who, then reopen." } catch {}
        } catch {
            try { Add-Log 'Config write failed. Stopping proxy.' } catch {}
            try { Stop-HeadroomProxy } catch {}
        }
    } elseif ($Kind -eq 'ready') {
        try { Add-Log (Get-ProxyWaitLog $Kind $ctx $Elapsed $ExitCode) } catch {}
    } else {
        $rollbackState = 'not-needed'
        if ($plan.DisableConfig) {
            try {
                if (Disable-CurrentAppConfig -Target $ctx.Target) {
                    $rollbackState = 'restored'
                } else {
                    $rollbackState = 'failed'
                }
            } catch {
                $rollbackState = 'failed'
                try { Add-Log ('Config rollback failed: ' + $_.Exception.Message) } catch {}
            }
        }
        try { Stop-HeadroomProxy } catch {}
        try { Add-Log (Get-ProxyWaitLog $Kind $ctx $Elapsed $ExitCode $rollbackState) } catch {}
    }
    $script:Busy = $false
    Set-PendingUi $false
    try { Write-AppState } catch {}
    try { Refresh-Status } catch {}
}

function Complete-ProxyWaitTick {
    $ctx = $script:ProxyWait
    if (-not $script:ProxyWaitPending -or $null -eq $ctx) {
        try { if ($script:ProxyWaitTimer) { $script:ProxyWaitTimer.Stop() } } catch {}
        return
    }
    $limit = [int]$script:ProxyReadyTimeoutSec
    if ($limit -le 0) { $limit = 90 }
    $elapsed = 0
    if ($ctx.Started) {
        try { $elapsed = [int]((Get-Date) - [datetime]$ctx.Started).TotalSeconds } catch { $elapsed = 0 }
    }
    $alive = $false
    $code = $null
    $workerPid = [int]$ctx.ProcessId
    if ($workerPid -gt 0) {
        try {
            $proc = Get-Process -Id $workerPid -ErrorAction SilentlyContinue
            if ($proc) {
                $alive = $true
                try { if ($proc.HasExited) { $alive = $false; $code = [int]$proc.ExitCode } } catch {}
                if ($alive -and ($ctx.ExePath -or $ctx.StartTime)) {
                    $wp = Get-CimInstance Win32_Process -Filter "ProcessId=$workerPid" -ErrorAction SilentlyContinue
                    if (-not $wp) {
                        $alive = $false
                    } elseif ($ctx.ExePath -and ([string]$wp.ExecutablePath -ne [string]$ctx.ExePath)) {
                        $alive = $false
                    } elseif ($ctx.StartTime -and
                        -not (Test-CreationTimeAllowsKill $ctx.StartTime $wp.CreationDate)) {
                        $alive = $false
                    }
                }
            }
        } catch { $alive = $false }
    }
    $port = [int]$ctx.Port
    $portOpen = $false
    try { $portOpen = [bool](Test-PortOpen $port) } catch {}
    $ours = $false
    $foreign = $false
    if ($portOpen) {
        $ours = [bool](Test-OwnedProxyReady -Port $port -ExpectedProcessId $workerPid `
            -ExpectedExePath ([string]$ctx.ExePath) -ExpectedStartTime $ctx.StartTime)
        $foreign = -not $ours
    }
    $kind = Resolve-ProxyStartKind $alive $code $portOpen $ours $elapsed $limit $foreign
    if ($kind -eq 'wait') { return }
    Complete-ProxyWait $kind $ctx $elapsed $code
}

function Begin-ProxyReadyWait {
    param(
        [string]$Purpose,
        [bool]$WriteConfig,
        [bool]$ConfigWasOn,
        [bool]$ConfigOwned
    )
    $script:ProxyWait = New-ProxyWaitContext -Purpose $Purpose -WriteConfig $WriteConfig `
        -ConfigWasOn $ConfigWasOn -ConfigOwned $ConfigOwned
    $script:ProxyWaitWriteConfig = [bool]$WriteConfig
    $script:ProxyWaitPending = $true
    $script:Busy = $true
    Set-PendingUi $true
    if ($script:ProxyWaitTimer) { $script:ProxyWaitTimer.Start() }
}

function Start-OwnedProxyWait {
    param(
        [string]$Purpose,
        [bool]$WriteConfig,
        [bool]$ConfigWasOn,
        [bool]$ConfigOwned
    )
    $bin = ''
    try { $bin = Find-HeadroomExe } catch { $bin = '' }
    if (-not $bin) {
        $ctx = New-ProxyWaitContext -Purpose $Purpose -WriteConfig $WriteConfig `
            -ConfigWasOn $ConfigWasOn -ConfigOwned $ConfigOwned -Bin $bin
        Complete-ProxyWait 'missing-bin' $ctx 0 $null
        return $false
    }
    $ok = $false
    try { $ok = Start-HeadroomProxy } catch { $ok = $false }
    if (-not $ok) {
        $ctx = New-ProxyWaitContext -Purpose $Purpose -WriteConfig $WriteConfig `
            -ConfigWasOn $ConfigWasOn -ConfigOwned $ConfigOwned -Bin $bin
        Complete-ProxyWait 'port-busy' $ctx 0 $null
        return $false
    }
    $port = [int]$script:Port
    if (Test-OwnedProxyReady -Port $port) {
        $ctx = New-ProxyWaitContext -Purpose $Purpose -WriteConfig $WriteConfig `
            -ConfigWasOn $ConfigWasOn -ConfigOwned $ConfigOwned -Bin $bin
        Complete-ProxyWait 'ready' $ctx 0 $null
        return $true
    }
    Begin-ProxyReadyWait -Purpose $Purpose -WriteConfig $WriteConfig `
        -ConfigWasOn $ConfigWasOn -ConfigOwned $ConfigOwned
    return $true
}

function Apply-OwnedPortChange([int]$NewPort) {
    $wasOn = [bool]$script:IsOn
    $oldPort = [int]$script:Port
    if ($NewPort -le 0 -or $NewPort -ge 65536) { return $false }
    if ($NewPort -eq $oldPort) { return $false }
    if ($wasOn) {
        if (-not (Test-CurrentAppConfigOwned)) {
            try { Add-Log 'Port not changed: active Headroom config is not owned by Switch.' } catch {}
            return $false
        }
        try {
            if (-not (Disable-CurrentAppConfig)) {
                Add-Log 'Port not changed: direct routing could not be confirmed.'
                return $false
            }
        } catch {
            try { Add-Log ('Port not changed: config restore failed: ' + $_.Exception.Message) } catch {}
            return $false
        }
        try { Stop-HeadroomProxy } catch {}
    } elseif (Test-PortOpen $oldPort) {
        try { Stop-HeadroomProxy } catch {}
    }
    $script:Port = $NewPort
    if ($wasOn) {
        try { Add-Log "Port $oldPort → $NewPort. Starting proxy, then writing config." } catch {}
        [void](Start-OwnedProxyWait -Purpose 'port' -WriteConfig $true `
            -ConfigWasOn $false -ConfigOwned $false)
    }
    return $true
}

function Restart-ProxyForProfile {
    if (-not (Test-PortOpen $script:Port) -and $script:ProxyPid -le 0) { return }
    try { Add-Log 'Restarting proxy so the profile applies (no app restart needed)' } catch {}
    $configWasOn = [bool]$script:IsOn
    $configOwned = $false
    if ($configWasOn) {
        $configOwned = Test-CurrentAppConfigOwned
        if (-not $configOwned) {
            try { Add-Log 'Profile saved, but foreign Headroom config/proxy was not restarted.' } catch {}
            return
        }
    }
    try { Stop-HeadroomProxy } catch {}
    Start-Sleep -Milliseconds 300
    [void](Start-OwnedProxyWait -Purpose 'profile' -WriteConfig $false `
        -ConfigWasOn $configWasOn -ConfigOwned $configOwned)
}

function Start-BootstrapRecovery {
    if (-not $script:IsOn) { return }
    if (Test-PortOpen $script:Port) { return }
    try { Add-Log 'Config is on Headroom but the proxy is down. Starting…' } catch {}
    $owned = Test-CurrentAppConfigOwned
    [void](Start-OwnedProxyWait -Purpose 'bootstrap' -WriteConfig $false `
        -ConfigWasOn $true -ConfigOwned $owned)
}

function Get-HarnessProcessName([string]$App) {
    if ((Normalize-App $App) -eq 'claude') { return 'Claude' }
    return 'ChatGPT'
}

function Get-HarnessLabel([string]$App) {
    if ((Normalize-App $App) -eq 'claude') { return 'Claude' }
    return 'ChatGPT'
}

function Test-HarnessRunning([string]$App) {
    $n = Get-HarnessProcessName $App
    $p = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
    return ($p.Count -gt 0)
}

function Test-AnyHarnessRunning {
    return (Test-HarnessRunning 'codex') -or (Test-HarnessRunning 'claude')
}

function Get-SilentHeadroom([string]$ArgString) {
    $hr = Find-HeadroomExe
    if (-not $hr) { return $null }
    $dir = Split-Path -Parent $hr
    $parent = Split-Path -Parent $dir
    foreach ($c in @((Join-Path $dir 'pythonw.exe'), (Join-Path $parent 'pythonw.exe'))) {
        if (Test-Path -LiteralPath $c) {
            return @{ File = $c; Args = "-m headroom $ArgString" }
        }
    }
    return @{ File = $hr; Args = $ArgString }
}

function Find-UvExe {
    $hr = Find-HeadroomExe
    if ($hr) {
        $c = Join-Path (Split-Path -Parent $hr) 'uv.exe'
        if (Test-Path -LiteralPath $c) { return $c }
    }
    foreach ($name in @('uv', 'uv.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }
    return $null
}

function Test-FileInUseText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    if ($Text -match '(?i)being used by another process') { return $true }
    if ($Text -match '(?i)Failed to install entrypoint') { return $true }
    if ($Text -match '程序無法存取檔案') { return $true }
    return $false
}

function Stop-HeadroomShims {
    try { Stop-HeadroomProxy } catch {}
    try {
        $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            if ([int]$p.ProcessId -eq $PID) { continue }
            $name = [string]$p.Name
            $exe = [string]$p.ExecutablePath
            $cmd = [string]$p.CommandLine
            $ppid = 0
            try { $ppid = [int]$p.ParentProcessId } catch {}
            if ((Test-IsShimProxy $name $exe $cmd) -or (Test-IsOrphanMcpServe $name $exe $cmd $ppid)) {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
    Start-Sleep -Milliseconds 500
}

function Get-HeadroomVersionFromText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    if ($Text -match '(?im)headroom(?:-ai)?[^\d]{0,32}([0-9]+\.[0-9]+(?:\.[0-9]+)?)') {
        return $Matches[1]
    }
    foreach ($ln in ($Text -split '\r?\n')) {
        if ($ln -match '(?i)python') { continue }
        if ($ln.Trim() -match '^v?([0-9]+\.[0-9]+(?:\.[0-9]+)?)') { return $Matches[1] }
    }
    return ''
}

function Test-NewerVersion([string]$Local, [string]$Latest) {
    if (-not $Local -or -not $Latest) { return $false }
    try { return ([version]$Latest -gt [version]$Local) } catch { return ($Latest -ne $Local) }
}

function Read-UpdateCheck([string]$Text) {
    $r = [pscustomobject]@{ Available = $false; Local = ''; Latest = ''; Raw = $Text }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $r }
    if ($Text -match '(?i)you have\s+([0-9]+(?:\.[0-9]+)*)') { $r.Local = $Matches[1] }
    if ($Text -match '(?i)Headroom\s+([0-9]+(?:\.[0-9]+)*)\s+available') {
        $r.Latest = $Matches[1]
        $r.Available = $true
    }
    if ($Text -match '(?i)(?:already\s+)?up to date') {
        $r.Available = $false
        if ($Text -match '([0-9]+(?:\.[0-9]+)*)' -and -not $r.Local) {
            $r.Local = $Matches[1]
            $r.Latest = $Matches[1]
        }
    }
    if (-not $r.Available -and $r.Local -and $r.Latest) {
        try { $r.Available = ([version]$r.Latest -gt [version]$r.Local) } catch {}
    }
    return $r
}

function Get-PypiHeadroomVersion {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $resp = Invoke-WebRequest -Uri 'https://pypi.org/pypi/headroom-ai/json' -UseBasicParsing -TimeoutSec 12
    $j = $resp.Content | ConvertFrom-Json
    return [string]$j.info.version
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

$script:ProxyWaitTimer = New-Object System.Windows.Forms.Timer
$script:ProxyWaitTimer.Interval = 250
$script:ProxyWaitTimer.Add_Tick({ Complete-ProxyWaitTick })

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
$lblTitle = New-Lbl 'Headroom Switch' $m 34 ($cw - 108) 34 $fontTitle $Ui.Fg
$lblTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblSub = New-Lbl 'Direct to the model. Proxy is off.' $m 72 $cw 22 $fontSm $Ui.Muted

$script:UpdState = 'checking'
$script:UpdAngle = 0
$script:UpdLocal = ''
$script:UpdLatest = ''
$script:UpdCheckFailed = $false
$script:UpdWorker = $null

$updW = 92
$updH = 28
$updChip = New-Object System.Windows.Forms.Panel
$updY = $lblTitle.Top + [int](($lblTitle.Height - $updH) / 2)
$updChip.Location = New-Object System.Drawing.Point(($m + $cw - $updW), $updY)
$updChip.Size = New-Object System.Drawing.Size($updW, $updH)
$updChip.BackColor = $Ui.Bg
$updChip.Cursor = [System.Windows.Forms.Cursors]::Hand
Enable-DoubleBuffer $updChip
[void]$form.Controls.Add($updChip)

$updCaption = New-Object System.Windows.Forms.Label
$updCaption.Text = 'Checking'
$updCaption.Dock = 'Fill'
$updCaption.TextAlign = 'MiddleCenter'
$updCaption.Font = $fontSm
$updCaption.ForeColor = $Ui.Muted
$updCaption.BackColor = [System.Drawing.Color]::Transparent
$updCaption.Cursor = [System.Windows.Forms.Cursors]::Hand
[void]$updChip.Controls.Add($updCaption)

function Add-RoundRectPath($path, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$R) {
    $d = [Math]::Max(2, $R * 2)
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $path.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $path.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $path.CloseFigure()
}

function Blend-Color($A, $B, [double]$T) {
    if ($T -lt 0) { $T = 0 }
    if ($T -gt 1) { $T = 1 }
    $r = [int]($A.R + ($B.R - $A.R) * $T)
    $g = [int]($A.G + ($B.G - $A.G) * $T)
    $b = [int]($A.B + ($B.B - $A.B) * $T)
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

function Paint-UpdateChip {
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $w = $updChip.Width
    $h = $updChip.Height
    $state = $script:UpdState
    $fill = $Ui.Elevated
    if ($state -eq 'available') { $fill = $Ui.Save }
    $br = New-Object System.Drawing.SolidBrush $fill
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    Add-RoundRectPath $path 1 1 ($w - 3) ($h - 3) 10
    $g.FillPath($br, $path)
    $br.Dispose()
    if ($state -eq 'checking' -or $state -eq 'updating') {
        $flat = [System.Drawing.Drawing2D.GraphicsPath]$path.Clone()
        $flat.Flatten()
        $pts = $flat.PathPoints
        $n = $pts.Count
        if ($n -gt 1) {
            $pen = New-Object System.Drawing.Pen $Ui.Save, 2
            $pen.StartCap = 'Round'
            $pen.EndCap = 'Round'
            for ($i = 0; $i -lt $n; $i++) {
                $u = (($i / [double]$n) + ($script:UpdAngle / 360.0)) % 1.0
                $heat = [math]::Exp(-18.0 * $u * $u)
                if ($heat -lt 0.08) { continue }
                $pen.Color = Blend-Color $Ui.Line $Ui.Save $heat
                $j = ($i + 1) % $n
                $g.DrawLine($pen, $pts[$i], $pts[$j])
            }
            $pen.Dispose()
        }
        $flat.Dispose()
    } elseif ($state -eq 'available') {
        $pen = New-Object System.Drawing.Pen $Ui.Save, 1
        $g.DrawPath($pen, $path)
        $pen.Dispose()
    } else {
        $pen = New-Object System.Drawing.Pen $Ui.Line, 1
        $g.DrawPath($pen, $path)
        $pen.Dispose()
    }
    $path.Dispose()
}

$updChip.Add_Paint({ param($s, $e) Paint-UpdateChip $s $e })

$updSpin = New-Object System.Windows.Forms.Timer
$updSpin.Interval = 40
$updSpin.Add_Tick({
    if ($script:UpdState -ne 'checking' -and $script:UpdState -ne 'updating') {
        $updSpin.Stop()
        return
    }
    $script:UpdAngle = ($script:UpdAngle + 10) % 360
    $updChip.Invalidate()
})

function Set-UpdateChip([string]$State, [string]$Caption) {
    $script:UpdState = $State
    if ($updCaption.Text -ne $Caption) { $updCaption.Text = $Caption }
    if ($State -eq 'available') {
        $updCaption.ForeColor = $Ui.SaveFg
    } else {
        $updCaption.ForeColor = $Ui.Muted
    }
    if ($State -eq 'checking' -or $State -eq 'updating') {
        if (-not $updSpin.Enabled) { $updSpin.Start() }
    } else {
        $updSpin.Stop()
    }
    $updChip.Invalidate()
}

function Start-UpdateCheck {
    if ($script:UpdState -eq 'updating') { return }
    $script:UpdCheckFailed = $false
    Set-UpdateChip 'checking' 'Checking'
    $inv = Get-SilentHeadroom '--version'
    if (-not $inv) {
        $script:UpdCheckFailed = $true
        Set-UpdateChip 'failed' 'Retry'
        Add-Log 'Update check skipped (no headroom.exe).'
        return
    }
    $cb = [System.Threading.SendOrPostCallback]{
        param($state)
        if ($script:UpdState -eq 'updating') { return }
        $verText = [string]$state[0]
        $latest = [string]$state[1]
        $errMsg = $state[2]
        $local = Get-HeadroomVersionFromText $verText
        $script:UpdLocal = $local
        $script:UpdLatest = $latest
        if ($errMsg -or -not $local) {
            $script:UpdCheckFailed = $true
            Add-Log 'Update check failed.'
            Set-UpdateChip 'failed' 'Retry'
            return
        }
        $avail = Test-NewerVersion $local $latest
        $script:UpdCheckFailed = $false
        if ($avail) {
            Set-UpdateChip 'available' 'Update'
            Add-Log "Headroom $latest available"
        } else {
            Set-UpdateChip 'current' 'Updated'
        }
    }
    [HeadroomHidden]::QueueCheck($inv.File, $inv.Args, $cb)
}

function Test-UpdateBlocked {
    if (Test-AnyHarnessRunning) { return 'Quit ChatGPT and Claude from the tray first.' }
    if ($script:IsOn -or (Test-PortOpen $script:Port)) { return 'Turn the lamp off first.' }
    return $null
}

function Add-UpdateLog([string]$Line) {
    $t = $Line.Trim()
    if (-not $t) { return }
    if ($t -match '^[\-\|=#\s]+$') { return }
    if ($t.Length -gt 180) { $t = $t.Substring(0, 180) }
    Add-Log $t
}

function Invoke-UpdateChipClick {
    if ($script:UpdState -eq 'checking' -or $script:UpdState -eq 'updating') { return }
    if (Test-SwitchBusy) { return }
    $block = Test-UpdateBlocked
    if ($block) {
        Show-HarnessBlock $block
        return
    }
    if ($script:UpdCheckFailed -or $script:UpdState -eq 'failed') {
        Start-UpdateCheck
        return
    }
    if ($script:UpdState -ne 'available') {
        $v = if ($script:UpdLocal) { " (Headroom $($script:UpdLocal))" } else { '' }
        Show-HarnessBlock "Already on the latest Headroom.$v"
        return
    }
    $uv = Find-UvExe
    if ($uv) {
        $script:UpdFile = $uv
        $script:UpdArgs = 'tool upgrade headroom-ai'
        Add-Log 'Updating Headroom via uv…'
    } else {
        $inv = Get-SilentHeadroom 'update'
        if (-not $inv) {
            Show-HarnessBlock 'headroom.exe was not found. Set it in Settings.'
            return
        }
        $script:UpdFile = $inv.File
        $script:UpdArgs = $inv.Args
        Add-Log 'Updating Headroom (this can take a few minutes)…'
    }
    $script:UpdRetry = 0
    Start-HeadroomUpgradeJob
}

function Start-HeadroomUpgradeJob {
    $script:Busy = $true
    Set-UpdateChip 'updating' 'Updating'
    try { Stop-HeadroomShims } catch {}
    $onLine = [System.Threading.SendOrPostCallback]{
        param($line)
        try { Add-UpdateLog ([string]$line) } catch {}
    }
    $cb = [System.Threading.SendOrPostCallback]{
        param($state)
        $script:HeadroomExeCacheAt = [datetime]::MinValue
        $code = [int]$state[0]
        $text = [string]$state[1]
        $errMsg = $state[2]
        $busyFile = (Test-FileInUseText $text) -or (Test-FileInUseText ([string]$errMsg))
        if (($errMsg -or $code -ne 0) -and $busyFile -and ($script:UpdRetry -lt 1)) {
            $script:UpdRetry = 1
            Add-Log 'headroom.exe was in use. Stopping it and retrying…'
            Start-HeadroomUpgradeJob
            return
        }
        $script:Busy = $false
        if ($errMsg) {
            Add-Log 'Update timed out or failed. You can try again.'
            Set-UpdateChip 'available' 'Update'
            return
        }
        if ($code -ne 0) {
            Add-Log 'Update failed.'
            Set-UpdateChip 'available' 'Update'
            return
        }
        Add-Log 'Headroom updated.'
        Set-UpdateChip 'current' 'Updated'
        $script:UpdLocal = $script:UpdLatest
        $script:UpdCheckFailed = $false
    }
    [HeadroomHidden]::Queue($script:UpdFile, $script:UpdArgs, 900000, $onLine, $cb)
}

$updChip.Add_Click({ Invoke-UpdateChipClick })
$updCaption.Add_Click({ Invoke-UpdateChipClick })

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
    $p.Add_Paint({
        param($s, $ev)
        $id2 = [string]$s.Tag
        $on = ($id2 -eq $script:Profile)
        $g = $ev.Graphics
        $r = $s.ClientRectangle
        if ($on) {
            $br = New-Object System.Drawing.SolidBrush $Ui.Save
            $g.FillRectangle($br, $r)
            $br.Dispose()
        } else {
            $dim = [System.Drawing.Color]::FromArgb(36, 40, 36)
            $h = New-Object System.Drawing.Drawing2D.HatchBrush(
                [System.Drawing.Drawing2D.HatchStyle]::ForwardDiagonal,
                $dim,
                $Ui.Inset
            )
            $g.FillRectangle($h, $r)
            $h.Dispose()
        }
    })
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

$lblHint = New-Lbl 'Model API only. Config we did not write is never edited.' $m 492 $cw 20 $fontSm $Ui.Subtle

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
        $fg = if ($on) { $Ui.SaveFg } else { $Ui.Muted }
        $b.Invalidate()
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
    if (Test-HarnessRunning $script:TargetApp) {
        $who = Get-HarnessLabel $script:TargetApp
        $hint = "Quit $who from the tray first."
        if ($lblHint.Text -ne $hint) { $lblHint.Text = $hint }
    } else {
        $idle = 'Model API only. Config we did not write is never edited.'
        if ($lblHint.Text -ne $idle) { $lblHint.Text = $idle }
    }
    Update-ToggleVisual
    Update-AppVisual
}

function Apply-Profile([string]$Name) {
    $next = Normalize-Profile $Name
    if ($next -eq $script:Profile) { return }
    if (Test-SwitchBusy) { return }
    if ($script:UpdState -eq 'updating') { return }
    $script:Busy = $true
    try {
        if (Test-HarnessRunning $script:TargetApp) {
            Show-HarnessBlock ("Quit $(Get-HarnessLabel $script:TargetApp) from the tray first.")
            return
        }
        $script:Profile = $next
        Write-AppState
        Update-SegVisual
        Add-Log "Profile $next → $(Get-ProxyCmd)"
        if ($script:IsOn -or (Test-PortOpen $script:Port)) {
            Restart-ProxyForProfile
            Write-AppState
            Refresh-Status
        }
    } finally {
        if (-not $script:ProxyWaitPending) {
            $script:Busy = $false
        }
    }
}

function Disable-CurrentAppConfig([string]$Target = '') {
    $app = if ($Target) { Normalize-App $Target } else { Normalize-App $script:TargetApp }
    if ($app -eq 'claude') {
        $managed = $false
        try {
            $peek = Read-JsonObject $script:ClaudeSettingsPath
            $managed = Test-HasProp $peek '_headroom_switch'
        } catch {}
        if (-not $managed) {
            Add-Log 'Claude Headroom env was not written by Switch. Settings left as-is.'
            return $false
        }
        Add-Log 'Restoring Claude ANTHROPIC_BASE_URL / MCP'
        $script:ClaudeTxPaths = @(Get-ClaudeConfigPaths)
        $script:ClaudeTxDesk = @($script:ClaudeTxPaths | Where-Object { $_ -ne $script:ClaudeSettingsPath })
        Invoke-WithFileSnapshots -Paths $script:ClaudeTxPaths -Action {
            Disable-ClaudeSettings
            Disable-ClaudeDesktop $script:ClaudeTxDesk
        }
        $script:OwnsClaude = $false
        return $true
    } else {
        $content = Read-Utf8 $script:ConfigPath
        if (-not (Test-CodexManagedBySwitch $content)) {
            Add-Log 'Codex Headroom config was not written by Switch. config.toml left as-is.'
            return $false
        }
        $sw = Read-SwitchPrevious $content
        $prevP = $script:PreviousProvider
        if (-not $prevP) { $prevP = $sw.Provider }
        Add-Log $(if ($prevP) { "Restore model_provider = `"$prevP`"" } else { 'Remove model_provider = "headroom"' })
        $next = Disable-CodexConfig $content $prevP $script:PreviousOpenaiBaseUrl
        Write-Utf8NoBom $script:ConfigPath $next
        $script:OwnsCodex = $false
        Add-Log 'Direct routing restored. Headroom provider kept for old threads.'
        return $true
    }
}

function Enable-CurrentAppConfig([string]$Bin, [string]$Target = '', [int]$Port = 0) {
    $app = if ($Target) { Normalize-App $Target } else { Normalize-App $script:TargetApp }
    $effectivePort = if ($Port -gt 0) { [int]$Port } else { [int]$script:Port }
    if ($app -eq 'claude') {
        Add-Log 'Experimental: ANTHROPIC_BASE_URL → local proxy (no /v1)'
        $cmd = if ($Bin) { $Bin } else { 'headroom' }
        $script:ClaudeTxPaths = @(Get-ClaudeConfigPaths)
        $script:ClaudeTxDesk = @($script:ClaudeTxPaths | Where-Object { $_ -ne $script:ClaudeSettingsPath })
        $script:ClaudeTxCmd = $cmd
        Invoke-WithFileSnapshots -Paths $script:ClaudeTxPaths -Action {
            Enable-ClaudeSettings $effectivePort
            Enable-ClaudeDesktop $script:ClaudeTxCmd $script:ClaudeTxDesk
        }
        $script:OwnsClaude = $true
        Add-Log 'Experimental: Headroom MCP in claude_desktop_config.json'
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
        $next = Enable-CodexConfig $content $effectivePort $(if ($Bin) { $Bin } else { 'headroom' })
        Write-Utf8NoBom $script:ConfigPath $next
        $script:OwnsCodex = $true
        Add-Log '[model_providers.headroom] supports_websockets=true'
        Add-Log '[mcp_servers.headroom] mcp serve'
    }
}

function Invoke-TurnOn {
    $bin = Find-HeadroomExe
    if (-not $bin) {
        Add-Log 'headroom.exe not found. Config not written.'
        [void][System.Windows.Forms.MessageBox]::Show(
            "headroom.exe was not found (Explorer launches often miss PATH).`r`n`r`nOpen Settings and pick the binary.`r`nTypical locations: Python Scripts, or uv tools.",
            'Headroom Switch'
        )
        Write-AppState
        Refresh-Status
        return
    }
    Add-Log "Start $(Get-ProxyCmd)"
    [void](Start-OwnedProxyWait -Purpose 'on' -WriteConfig $true `
        -ConfigWasOn $false -ConfigOwned $false)
}

function Invoke-TurnOff {
    Clear-ProxyWait
    $restored = $false
    try {
        $restored = [bool](Disable-CurrentAppConfig)
    } catch {
        Add-Log ('Config restore error: ' + $_.Exception.Message)
        Add-Log 'Turn off aborted. Proxy kept running because config may still point localhost.'
        Refresh-Status
        return $false
    }
    if (-not $restored) {
        Add-Log 'Turn off aborted. Foreign config left as-is; proxy kept running.'
        Refresh-Status
        return $false
    }
    Stop-HeadroomProxy
    Add-Log 'Proxy stopped.'
    Write-AppState
    $who = if ($script:TargetApp -eq 'claude') { 'Claude' } else { 'Codex' }
    Add-Log "Back to direct $who. Fully quit the app, then reopen."
    Refresh-Status
    return $true
}

function Show-HarnessBlock([string]$Message) {
    Add-Log $Message
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'Headroom Switch')
}

function Invoke-Toggle {
    if (Test-SwitchBusy) { return }
    $script:Busy = $true
    $lamp.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Refresh-Status
        if (Test-HarnessRunning $script:TargetApp) {
            Show-HarnessBlock ("Quit $(Get-HarnessLabel $script:TargetApp) from the tray first.")
            return
        }
        if ($script:IsOn) { Invoke-TurnOff } else { Invoke-TurnOn }
    } catch {
        Add-Log ('Error: ' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Headroom Switch')
    } finally {
        if (-not $script:ProxyWaitPending) {
            $script:Busy = $false
            $lamp.Cursor = [System.Windows.Forms.Cursors]::Hand
        }
    }
}

function Apply-App([string]$Name) {
    $next = Normalize-App $Name
    if ($next -eq $script:TargetApp) { return }
    if (Test-SwitchBusy) { return }
    $script:Busy = $true
    try {
        Refresh-Status
        if ($script:IsOn) {
            Show-HarnessBlock 'Turn the lamp off first.'
            return
        }
        if (Test-AnyHarnessRunning) {
            $who = if (Test-HarnessRunning 'codex') { 'ChatGPT' } else { 'Claude' }
            Show-HarnessBlock "Quit $who from the tray first."
            return
        }
        $script:TargetApp = $next
        Write-AppState
        Update-AppVisual
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
    try { Refresh-Status } catch { try { Add-Log ('Exit: ' + $_.Exception.Message) } catch {} }
    if ($script:IsOn -and (Test-HarnessRunning $script:TargetApp)) {
        Show-HarnessBlock ("Quit $(Get-HarnessLabel $script:TargetApp) from the tray first.")
        return
    }
    try {
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
    if (-not (Test-SettingsAllowed)) {
        Add-Log 'Wait for the proxy to finish starting.'
        return
    }
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
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
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
        if (-not (Test-SettingsAllowed)) {
            Add-Log 'Wait for the proxy to finish starting.'
            return
        }
        $script:CustomHeadroom = $tbPath.Text.Trim()
        $script:HeadroomExeCache = $null
        $script:CloseToTray = [bool]$rbTray.Checked
        $p = 0
        if ([int]::TryParse($tbPort.Text.Trim(), [ref]$p) -and $p -gt 0 -and $p -lt 65536) {
            [void](Apply-OwnedPortChange $p)
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(
                'Port must be a number from 1 to 65535.',
                'Headroom Switch'
            )
        }
        Write-AppState
        Refresh-Status
        Add-Log "Settings saved. Port $($script:Port)."
    }
}

$btnSettings.Add_Click({
    if (-not (Test-SettingsAllowed)) { return }
    Show-Settings
})

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
    $live = $false
    try { $live = $script:IsOn -and (Test-HarnessRunning $script:TargetApp) } catch {}
    if ($live) {
        $e.Cancel = $true
        $src.Visible = $false
        $who = Get-HarnessLabel $script:TargetApp
        Show-HarnessBlock "$who is still using Headroom. Staying in the tray. Quit $who first."
        return
    }
    try {
        if ($script:IsOn) { Invoke-TurnOff }
        else { Stop-HeadroomProxy }
    } catch {
        try { Add-Log ('Close: ' + $_.Exception.Message) } catch {}
    }
    $script:ReallyExit = $true
    $notify.Visible = $false
})

$form.Add_FormClosed({
    $updSpin.Stop()
    try { $script:ProxyWaitTimer.Stop() } catch {}
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
    Start-BootstrapRecovery
}
Add-Log 'Model API only. Config we did not write is never edited.'
$timer.Start()
Start-UpdateCheck

[void][System.Windows.Forms.Application]::Run($form)
$timer.Stop()
$updSpin.Stop()
$notify.Visible = $false
$notify.Dispose()
