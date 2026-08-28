# verify-fix.ps1 — 需要 Windows PowerShell 5.1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1  = Join-Path $here 'HeadroomSwitch.ps1'

# --- 切出純函式層（第一個 function C( 到 # --- UI 之前）-------------------
$all = Get-Content -LiteralPath $ps1 -Encoding UTF8
$start = -1; $ui = $all.Count
for ($i = 0; $i -lt $all.Count; $i++) {
    if ($start -lt 0 -and $all[$i] -like 'function C(*') { $start = $i }
    if ($all[$i] -like '# --- UI*') { $ui = $i; break }
}
if ($start -lt 0) { throw 'cannot find function C(' }
$pure = @('Add-Type -AssemblyName System.Drawing', '$ErrorActionPreference = ''Stop''') +
        $all[$start..($ui - 1)]
$purePath = Join-Path $env:TEMP ('hs-pure-' + [guid]::NewGuid().ToString('n') + '.ps1')
Set-Content -LiteralPath $purePath -Value ($pure -join "`r`n") -Encoding UTF8
. $purePath

$results = @()
function Check([string]$Name, [bool]$Pass, [string]$Detail) {
    $script:results += ("{0}  {1}  {2}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name, $Detail)
}

$tmp = Join-Path $env:TEMP ('hs-v-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# --- 1. 壞 JSON 必須拒絕寫入 ------------------------------------------------
$bad = Join-Path $tmp 'settings.json'
Set-Content -LiteralPath $bad -Value '{ this is not json' -Encoding UTF8
$before = Get-Content -LiteralPath $bad -Raw
$threw = $false
try { $null = Read-JsonObject $bad } catch { $threw = $true }
Check '1a corrupt JSON throws' $threw 'Read-JsonObject raised'
Check '1b file untouched' ((Get-Content -LiteralPath $bad -Raw) -eq $before) 'content preserved'

# --- 2. 備份時戳碰撞（這輪的重點）------------------------------------------
$b1 = Join-Path $tmp 'collide.json'
Set-Content -LiteralPath $b1 -Value '{"CLEAN":"original"}' -Encoding UTF8
Write-Utf8NoBom $b1 '{"step":1}'
Write-Utf8NoBom $b1 '{"step":2}'
$baks = @(Get-ChildItem -LiteralPath $tmp -File | Where-Object { $_.Name -like 'collide.json.*.bak' })
$clean = @($baks | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'CLEAN' })
Check '2a two rapid writes -> 2 backups' ($baks.Count -eq 2) "found $($baks.Count)"
Check '2b clean data still in a backup' ($clean.Count -ge 1) "backups with CLEAN: $($clean.Count)"

# --- 3. 備份輪替上限 5 ------------------------------------------------------
$b2 = Join-Path $tmp 'rot.json'
Set-Content -LiteralPath $b2 -Value '{"n":0}' -Encoding UTF8
1..9 | ForEach-Object { Write-Utf8NoBom $b2 ('{"n":' + $_ + '}'); Start-Sleep -Milliseconds 60 }
$rot = @(Get-ChildItem -LiteralPath $tmp -File | Where-Object { $_.Name -like 'rot.json.*.bak' })
Check '3a rotation caps at 5' ($rot.Count -eq 5) "found $($rot.Count)"

# --- 4. 無暫存檔殘留 --------------------------------------------------------
$leftover = @(Get-ChildItem -LiteralPath $tmp -File |
    Where-Object { $_.Name -like '*.tmp' -or $_.Name -like '*.replace.bak' })
Check '4a no temp leftovers' ($leftover.Count -eq 0) "found $($leftover.Count)"

# --- 5. TOML 整表移除（含未知 key）-----------------------------------------
$toml = "model = ""gpt-5""`r`nmodel_provider = ""openai""`r`n`r`n" +
        "[model_providers.headroom]`r`nname = ""x""`r`n" +
        "env_http_headers = { X-Foo = ""BAR"" }`r`n`r`n[profiles.deep]`r`nmodel = ""other""`r`n"
$stripped = Remove-TomlTable $toml 'model_providers.headroom'
Check '5a unknown keys removed' (-not ($stripped -match 'env_http_headers')) 'no orphan keys'
Check '5b header removed'       (-not ($stripped -match '\[model_providers\.headroom\]')) 'header gone'
Check '5c other tables survive' ($stripped -match '\[profiles\.deep\]' -and $stripped -match 'gpt-5') 'rest intact'

# --- 6. port 比對 -----------------------------------------------------------
Check '6a 87870 not matched' (-not (Test-CodexEnabled 'openai_base_url = "http://127.0.0.1:87870/v1"' 8787)) 'no false positive'
Check '6b 8787 matched'      (Test-CodexEnabled 'openai_base_url = "http://127.0.0.1:8787/v1"' 8787) 'true positive'
Check '6c bare port matched' (Test-CodexEnabled 'openai_base_url = "http://127.0.0.1:8787"' 8787) 'end-of-string case'

# --- 7. 語法解析 ------------------------------------------------------------
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$null, [ref]$errs)
Check '7a PS1 parses' ($errs.Count -eq 0) "parse errors: $($errs.Count)"

Remove-Item -LiteralPath $tmp, $purePath -Recurse -Force -ErrorAction SilentlyContinue
$results -join "`r`n" | Set-Content -Path (Join-Path $here 'verify-output.txt') -Encoding UTF8
$results | ForEach-Object { Write-Host $_ }
