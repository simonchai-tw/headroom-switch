# verify-fix.ps1 — Windows PowerShell 5.1
$ErrorActionPreference = 'Stop'
if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath() }
if (-not $env:TMP) { $env:TMP = $env:TEMP }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1  = Join-Path $here 'HeadroomSwitch.ps1'

$tmp = $null
$purePath = $null
try {
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

    $bad = Join-Path $tmp 'settings.json'
    Set-Content -LiteralPath $bad -Value '{ this is not json' -Encoding UTF8
    $before = Get-Content -LiteralPath $bad -Raw
    $threw = $false
    try { $null = Read-JsonObject $bad } catch { $threw = $true }
    Check '1a corrupt JSON throws' $threw 'Read-JsonObject raised'
    Check '1b file untouched' ((Get-Content -LiteralPath $bad -Raw) -eq $before) 'content preserved'

    $b1 = Join-Path $tmp 'collide.json'
    Set-Content -LiteralPath $b1 -Value '{"CLEAN":"original"}' -Encoding UTF8
    Write-Utf8NoBom $b1 '{"step":1}'
    Write-Utf8NoBom $b1 '{"step":2}'
    $baks = @(Get-ChildItem -LiteralPath $tmp -File | Where-Object { $_.Name -like 'collide.json.*.bak' })
    $clean = @($baks | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'CLEAN' })
    Check '2a two rapid writes -> 2 backups' ($baks.Count -eq 2) "found $($baks.Count)"
    Check '2b clean data still in a backup' ($clean.Count -ge 1) "backups with CLEAN: $($clean.Count)"

    $b2 = Join-Path $tmp 'rot.json'
    Set-Content -LiteralPath $b2 -Value '{"n":0}' -Encoding UTF8
    1..9 | ForEach-Object { Write-Utf8NoBom $b2 ('{"n":' + $_ + '}'); Start-Sleep -Milliseconds 60 }
    $rot = @(Get-ChildItem -LiteralPath $tmp -File | Where-Object { $_.Name -like 'rot.json.*.bak' })
    Check '3a rotation caps at 5' ($rot.Count -eq 5) "found $($rot.Count)"

    $leftover = @(Get-ChildItem -LiteralPath $tmp -File |
        Where-Object { $_.Name -like '*.tmp' -or $_.Name -like '*.replace.bak' })
    Check '4a no temp leftovers' ($leftover.Count -eq 0) "found $($leftover.Count)"

    $toml = "model = ""gpt-5""`r`nmodel_provider = ""openai""`r`n`r`n" +
            "[model_providers.headroom]`r`nname = ""x""`r`n" +
            "env_http_headers = { X-Foo = ""BAR"" }`r`n`r`n[profiles.deep]`r`nmodel = ""other""`r`n"
    $stripped = Remove-TomlTable $toml 'model_providers.headroom'
    Check '5a unknown keys removed' (-not ($stripped -match 'env_http_headers')) 'no orphan keys'
    Check '5b header removed'       (-not ($stripped -match '\[model_providers\.headroom\]')) 'header gone'
    Check '5c other tables survive' ($stripped -match '\[profiles\.deep\]' -and $stripped -match 'gpt-5') 'rest intact'

    $indented = "model = ""x""`r`n  [model_providers.headroom]`r`nname = ""x""`r`n[other]`r`nk = 1`r`n"
    $si = Remove-TomlTable $indented 'model_providers.headroom'
    Check '5d indented table removed' ((-not ($si -match 'model_providers\.headroom')) -and ($si -match '\[other\]')) 'indent + other'

    $commented = "[model_providers.headroom] # note`r`nname = ""x""`r`n[ok]`r`n"
    $sc = Remove-TomlTable $commented 'model_providers.headroom'
    Check '5e comment on header' ((-not ($sc -match 'name = ""x""')) -and ($sc -match '\[ok\]')) 'comment header'

    Check '6a 87870 not matched' (-not (Test-CodexEnabled 'openai_base_url = "http://127.0.0.1:87870/v1"' 8787)) 'no false positive'
    Check '6b 8787 matched'      (Test-CodexEnabled 'openai_base_url = "http://127.0.0.1:8787/v1"' 8787) 'true positive'
    Check '6c bare port matched' (Test-CodexEnabled 'openai_base_url = "http://127.0.0.1:8787"' 8787) 'end-of-string case'

    $sample = "model = ""gpt-5""`r`nmodel_provider = ""openai""`r`npersonality = ""pragmatic""`r`n"
    $on = Enable-CodexConfig $sample 8787 'headroom'
    Check '8a enable sets provider' ($on -match 'model_provider = "headroom"') 'provider=headroom'
    Check '8b enable sets base url' ($on -match '127\.0\.0\.1:8787/v1') 'openai_base_url'
    Check '8c enable keeps other keys' ($on -match 'personality = "pragmatic"') 'personality kept'
    $off = Disable-CodexConfig $on 'openai' $null
    Check '8d disable restores provider' ($off -match 'model_provider = "openai"') 'provider restored'
    Check '8e disable keeps compat table' (Test-HeadroomProviderIsCompat $off) 'no localhost/base_url'

    $corp = "model_provider = ""openai""`r`n`r`n[profiles.corp]`r`nopenai_base_url = ""https://corp/v1""`r`n"
    $corpOff = Disable-CodexConfig $corp $null $null
    Check '8f nested openai_base_url kept' ($corpOff -match 'https://corp/v1') 'profiles.corp survives'
    $dollar = Set-ProviderLine "model_provider = ""openai""`n" 'a$&b' "`n"
    Check '8g provider not regex' ($dollar -match 'model_provider = "a\$&b"' -or $dollar -match 'a\$&b') 'no replace inject'

    $p1 = Read-UpdateCheck 'Headroom 0.37.0 available (you have 0.36.5).'
    Check '9a available' ([bool]$p1.Available) "latest=$($p1.Latest)"
    Check '9b local parsed' ($p1.Local -eq '0.36.5') $p1.Local
    $p2 = Read-UpdateCheck 'Already up to date (0.37.0).'
    Check '9c current' (-not $p2.Available) 'not available'
    Check '9d empty is current' (-not (Read-UpdateCheck '').Available) 'empty'

    Check '11a skip python line' ((Get-HeadroomVersionFromText "Python 3.11.9`r`nheadroom 0.37.0") -eq '0.37.0') 'not 3.11.9'
    Check '11b newer' (Test-NewerVersion '0.36.5' '0.37.0') '0.37 > 0.36'
    Check '11c not newer' (-not (Test-NewerVersion '0.37.0' '0.37.0')) 'equal'
    Check '11d missing local' (-not (Test-NewerVersion '' '0.37.0')) 'no local'

    Check '12a official name is not marker' (-not (Test-CodexManagedBySwitch "[model_providers.headroom]`nname = `"OpenAI via Headroom proxy`"`n")) 'docs string ignored'
    Check '12b managed_by is marker' (Test-CodexManagedBySwitch "[headroom_switch]`nmanaged_by = `"headroom-switch`"`n") 'own table'
    Check '12c enable writes marker' ($on -match 'managed_by = "headroom-switch"') 'enable owns'
    $hand = "model_provider = `"headroom`"`r`nopenai_base_url = `"http://127.0.0.1:8787/v1`"`r`n`r`n[model_providers.headroom]`r`nname = `"OpenAI via Headroom proxy`"`r`n`r`n[features]`r`nunified_exec = true`r`n"
    Check '12d handwritten not owned' (-not (Test-CodexManagedBySwitch $hand)) 'no rewrite without marker'
    $fromTable = Enable-CodexConfig "model_provider = `"openai`"`r`n" 8787 'headroom'
    $cold = Disable-CodexConfig $fromTable $null $null
    Check '12e disable restores from table' ($cold -match 'model_provider = "openai"') 'previous in config'
    Check '12f switch table removed' (-not ($cold -match 'headroom_switch')) 'own table gone'

    $arrT = "[[model_providers.headroom]]`r`nname = `"x`"`r`n[ok]`r`n"
    $arrOff = Remove-TomlTable $arrT 'model_providers.headroom'
    Check '5f array-of-tables removed' ((-not ($arrOff -match 'model_providers\.headroom')) -and ($arrOff -match '\[ok\]')) 'double brackets'

    $dup = Join-Path $tmp 'dup.json'
    Set-Content -LiteralPath $dup -Value '{"env":{"A":"1"},"env":{"B":"2"}}' -Encoding UTF8
    $dupThrew = $false
    try { $null = Read-JsonObject $dup } catch { $dupThrew = $true }
    Check '1c duplicate JSON keys throw' $dupThrew 'refused'

    Check '13a ps identity not headroom' (-not (Test-HeadroomIdentity 'powershell.exe' 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe')) 'ps skipped'
    Check '13b exe path is headroom' (Test-HeadroomIdentity 'foo' 'C:\Users\x\.local\bin\headroom.exe') 'path match'
    Check '13c process name headroom' (Test-HeadroomIdentity 'headroom' '') 'name match'
    $now = Get-Date
    Check '13d same datetime allows kill' (Test-CreationTimeAllowsKill $now $now) 'datetime cast'
    Check '13e 3h drift blocks kill' (-not (Test-CreationTimeAllowsKill $now ($now.AddHours(-3)))) 'stale pid'
    Check '13f bad date blocks kill' (-not (Test-CreationTimeAllowsKill $now 'not-a-date')) 'fail closed'

    $adopt = Merge-SwitchOwnership $hand 'openai' $null
    Check '12g adopt writes marker only' ((Test-CodexManagedBySwitch $adopt) -and ($adopt -match 'model_provider = "headroom"') -and ($adopt -match '\[features\]')) 'legacy adopt'
    $adopt2 = Merge-SwitchOwnership $adopt 'other' $null
    Check '12h adopt is idempotent' ((Read-SwitchPrevious $adopt2).Provider -eq 'openai') 'no overwrite'

    $text = [System.IO.File]::ReadAllText($ps1)
    Check '13g no DMTF converter' ($text -notmatch 'ManagementDateTimeConverter') 'source'
    $looks = [regex]::Match($text, '(?s)function Test-ProcessLooksLikeHeadroom.*?function Test-StoredProxyPid').Value
    Check '13h proxy match has no powershell rule' ($looks.Length -gt 40 -and $looks -notmatch 'powershell' -and $looks -notmatch 'HeadroomSwitch') 'identity only'

    $realListen = '"C:\Program Files\Python313\python.exe" "C:\Users\simon\.local\bin\headroom.exe" proxy --port 8787 --mode token'
    $shimCmd = '"C:\Users\simon\.local\bin\headroom.exe" proxy --port 8787 --mode token'
    $mcpCmd = '"C:\Users\simon\.local\bin\headroom.exe" mcp serve'
    $hr = 'C:\Users\simon\.local\bin\headroom.exe'
    Check '14a python listener is port worker' (Test-IsPortProxyWorker $realListen) 'headroom.exe + proxy'
    Check '14b bare token is not proxy' (-not (Test-CmdIsHeadroomProxy 'cmd.exe /k dir headroom')) 'no bare token'
    Check '14c pip show is not proxy' (-not (Test-CmdIsHeadroomProxy 'python.exe -m pip show headroom')) 'no pip'
    Check '14d HeadroomSwitch.ps1 is not proxy' (-not (Test-CmdIsHeadroomProxy 'powershell -File C:\src\HeadroomSwitch.ps1')) 'no script'
    Check '14e shim proxy' (Test-IsShimProxy 'headroom' $hr $shimCmd) 'own shim'
    Check '14f live mcp not orphan' (-not (Test-IsOrphanMcpServe 'headroom' $hr $mcpCmd $PID)) 'parent alive'
    Check '14g dead parent mcp is orphan' (Test-IsOrphanMcpServe 'headroom' $hr $mcpCmd 0) 'parent gone'
    Check '14h mcp without identity skipped' (-not (Test-IsOrphanMcpServe 'python' 'C:\Python\python.exe' $mcpCmd 0)) 'need headroom.exe'

    $cmdFn = [regex]::Match($text, '(?s)function Test-CmdIsHeadroomProxy\(.*?function Test-CmdHasMcpServe').Value
    Check '14i cmd match requires headroom.exe' ($cmdFn -match 'headroom\\\.exe') 'exe required'
    Check '14j cmd match is not bare headroom' ($cmdFn -notmatch "match '\(\?i\)headroom'") 'no token scan'
    $orphFn = [regex]::Match($text, '(?s)function Test-IsOrphanMcpServe\(.*?function Test-CreationTimeAllowsKill').Value
    Check '14k orphan predicate calls parent check' ($orphFn -match 'Test-ParentLooksAlive') 'liveness in predicate'
    $dis = [regex]::Match($text, '(?s)function Disable-CurrentAppConfig \{.*?function Enable-CurrentAppConfig').Value
    Check '14l disable does not claim proxy stopped' ($dis -notmatch 'Proxy stopped') 'log split'
    $toff = [regex]::Match($text, '(?s)function Invoke-TurnOff \{.*?function Show-HarnessBlock').Value
    Check '14m stop then log' ($toff -match '(?s)Stop-HeadroomProxy.*Proxy stopped') 'order'

    $nested = "model = `"gpt-5`"" + "`r`n" + 'matrix = [' + "`r`n" + '  [1, 2],' + "`r`n" + '  [3, 4]' + "`r`n" + ']' + "`r`n" + '[profiles.x]' + "`r`n" + 'model = "gpt-5"' + "`r`n"
    $nparts = Split-TomlRoot $nested
    Check '16a nested array stays in root' ($nparts.Root -match 'matrix' -and $nparts.Root -match '\[1, 2\]' -and $nparts.Rest -match '\[profiles\.x\]') 'array not table'
    $non = Enable-CodexConfig $nested 8787 'headroom'
    Check '16b enable keeps nested array' ($non -match '\[1, 2\]' -and $non -match '\[3, 4\]' -and $non -match '\[profiles\.x\]') 'intact'
    $ml = "model = `"x`"" + "`r`n" + 'developer_instructions = """' + "`r`n" + '[Section]' + "`r`n" + 'hello' + "`r`n" + '"""' + "`r`n" + '[features]' + "`r`n" + 'unified_exec = true' + "`r`n"
    $mlparts = Split-TomlRoot $ml
    Check '16d multiline bracket not table' ($mlparts.Root -match '\[Section\]' -and $mlparts.Rest -match '\[features\]') 'string'
    $mlon = Enable-CodexConfig $ml 8787 'headroom'
    Check '16e enable keeps multiline section' ($mlon -match '\[Section\]' -and $mlon -match 'hello' -and $mlon -match '\[features\]') 'body'
    $aot = "model = `"x`"" + "`n" + '[[plugins]]' + "`n" + 'name = "a"' + "`n"
    $ap = Split-TomlRoot $aot
    Check '16f array-of-table is rest' ($ap.Rest -match '\[\[plugins\]\]' -and $ap.Root -match 'model') 'aot'
    $lf = "model = `"x`"" + "`n" + 'matrix = [' + "`n" + '  [1, 2]' + "`n" + ']' + "`n" + '[ok]' + "`n"
    $lfp = Split-TomlRoot $lf
    Check '16g lf nested array' ($lfp.Root -match 'matrix' -and $lfp.Rest -match '\[ok\]') 'lf'
    $crlf = "model = `"x`"" + "`r`n" + 'matrix = [' + "`r`n" + '  [1, 2]' + "`r`n" + ']' + "`r`n" + '[ok]' + "`r`n"
    $cp = Split-TomlRoot $crlf
    Check '16h crlf nested array' ($cp.Root -match 'matrix' -and $cp.Rest -match '\[ok\]') 'crlf'

    $q4 = "model = `"gpt-5`"" + "`n" + 'note = """ends in quote""""' + "`n" + '[profiles.x]' + "`n" + 'model = "other"' + "`n"
    $qp = Split-TomlRoot $q4
    Check '16i quote-run4 rest is profiles' ($qp.Rest -match '\[profiles\.x\]' -and $qp.Root -notmatch '\[profiles\.x\]') 'close run'
    $qon = Enable-CodexConfig $q4 8787 'headroom'
    Check '16j enable writes root provider' ((Read-ModelProvider $qon) -eq 'headroom') 'root'
    $px = Get-TomlTableText $qon 'profiles.x'
    Check '16k nested profile not hijacked' ($px -and ($px -notmatch '127\.0\.0\.1') -and ($px -notmatch 'model_provider')) 'nested intact'
    $q5 = "model = `"x`"" + "`n" + 'note = """ends in two quotes"""""' + "`n" + '[ok]' + "`n" + 'k = 1' + "`n"
    $q5p = Split-TomlRoot $q5
    Check '16l quote-run5' ($q5p.Rest -match '\[ok\]' -and $q5p.Root -notmatch '\[ok\]') 'five quotes'
    $lit = "model = `"x`"" + "`n" + "note = '''ends in apos''''" + "`n" + '[ok]' + "`n" + 'k = 1' + "`n"
    $lp = Split-TomlRoot $lit
    Check '16m literal-run4' ($lp.Rest -match '\[ok\]' -and $lp.Root -notmatch '\[ok\]') 'apos'
    $tgt = "[model_providers.headroom]`nname = `"x`"`nmatrix = [`n  [1, 2],`n  [3, 4]`n]`n[after]`nok = true`n"
    $rm = Remove-TomlTable $tgt 'model_providers.headroom'
    Check '16n remove keeps after' ($rm -match '\[after\]' -and $rm -match 'ok = true') 'after lives'
    Check '16o remove no array fragment' ((-not ($rm -match 'model_providers\.headroom')) -and (-not ($rm -match '\[1, 2\]'))) 'no debris'
    $rmFn = [regex]::Match($text, '(?s)function Remove-TomlTable\(.*?function Remove-HeadroomBlock').Value
    Check '16p remove uses scanner' ($rmFn -match 'Find-TomlTableHeaders' -and $rmFn -notmatch '\(\?\!') 'no body regex'

    $tx = Join-Path $tmp 'snap'
    New-Item -ItemType Directory -Path $tx -Force | Out-Null
    $fa = Join-Path $tx 'a.json'
    $fb = Join-Path $tx 'b.json'
    Set-Content -LiteralPath $fa -Value '{"keep":"orig"}' -Encoding UTF8
    $threw = $false
    try {
        Invoke-WithFileSnapshots -Paths @($fa, $fb) -Action {
            param($A, $B)
            [System.IO.File]::WriteAllText($A, '{"keep":"dirty"}')
            [System.IO.File]::WriteAllText($B, '{"new":true}')
            throw 'second failed'
        } -ActionArgs @($fa, $fb)
    } catch { $threw = $true }
    Check '17a snapshot tx throws' $threw 'threw'
    Check '17b first file restored' ([bool]((Get-Content -LiteralPath $fa -Raw) -match 'orig')) 'orig'
    Check '17c created file removed' (-not (Test-Path -LiteralPath $fb)) 'gone'
    Check '17d claude uses snapshots' ($text -match 'Invoke-WithFileSnapshots -Paths \$script:ClaudeTxPaths') 'tx'

    Check '10a off keeps headroom id' ($off -match '\[model_providers\.headroom\]') 'table'
    Check '10b off has no localhost' ($off -notmatch '127\.0\.0\.1') 'no loopback'
    Check '10c off has no api.openai.com' ($off -notmatch 'api\.openai\.com') 'no hardcode'
    Check '10d off is compat shape' (Test-HeadroomProviderIsCompat $off) 'compat'
    Check '10e off lamp is dark' (-not (Test-CodexEnabled $off 8787)) 'not enabled'
    $fromEmpty = Enable-CodexConfig "model = `"gpt-5`"`r`n" 8787 'headroom'
    $offEmpty = Disable-CodexConfig $fromEmpty $null $null
    Check '10g no previous drops root provider' ($null -eq (Read-ModelProvider $offEmpty)) 'built-in openai'
    Check '10h empty-off still compat' (Test-HeadroomProviderIsCompat $offEmpty) 'compat'
    Check '10i resume id survives off' (((Read-ModelProvider $on) -eq 'headroom') -and (Test-HeadroomProviderIsCompat $off)) 'id kept'
    Check '10j no session rewrite' ($text -notmatch 'rollout' -and $text -notmatch '(?i)sqlite' -and $text -notmatch '\.jsonl') 'config only'

    $ton = [regex]::Match($text, '(?s)function Invoke-TurnOn \{.*?function Invoke-TurnOff').Value
    Check '1d spawn before wait' ($ton -match 'Start-OwnedProxyWait' -and $ton -match "Purpose 'on'") 'shared wait'
    Check '1e no write without bin' ($ton -match 'Config not written' -and $ton -notmatch 'Config written, proxy not started') 'fail closed'
    $cw = [regex]::Match($text, '(?s)function Complete-ProxyWait\[string\].*?function Complete-ProxyWaitTick').Value
    if (-not $cw) { $cw = [regex]::Match($text, '(?s)function Complete-ProxyWait \{.*?function Complete-ProxyWaitTick').Value }
    Check '1f tick writes after ready' ($text -match '(?s)function Complete-ProxyWait.*?WriteConfig.*?Enable-CurrentAppConfig') 'ready then write'

    $fake = "developer_instructions = `"`"`"" + "`n" + 'Keep this exact:' + "`n" + 'model_provider = "text-only"' + "`n" + 'openai_base_url = "https://text.invalid/v1"' + "`n" + '"""' + "`n`n" + '[profiles.x]' + "`n" + 'model = "other"' + "`n"
    Check '18a string assignment not root' ($null -eq (Read-ModelProvider $fake) -and $null -eq (Read-OpenaiBaseUrl $fake)) 'ignored'
    $fakeOn = Enable-CodexConfig $fake 8787 'headroom'
    Check '18b string body kept' ($fakeOn -match 'text-only' -and $fakeOn -match 'text\.invalid') 'intact'
    Check '18c real root provider' ((Read-ModelProvider $fakeOn) -eq 'headroom') 'root'
    $ind = "  model_provider = `"corp`" # keep" + "`n" + 'model = "x"' + "`n"
    Check '18d indented comment read' ((Read-ModelProvider $ind) -eq 'corp') 'corp'
    $indOn = Enable-CodexConfig $ind 8787 'headroom'
    $indOff = Disable-CodexConfig $indOn 'corp' $null
    Check '18e comment survives off' ((Read-ModelProvider $indOff) -eq 'corp' -and $indOff -match '# keep') 'comment'
    $nl3 = "note = `"`"`"" + "`n`n`n`n" + 'keep' + "`n" + '"""' + "`n" + '[ok]' + "`n" + 'k = 1' + "`n"
    $nl3on = Enable-CodexConfig $nl3 8787 'headroom'
    Check '18f three newlines kept' ($nl3on -match "`n`n`n`nkeep") 'bytes'

    $desk = Join-Path $tmp 'claude_desktop_config.json'
    Set-Content -LiteralPath $desk -Value '{"mcpServers":{"headroom":{"command":"custom-headroom","args":["custom"]}}}' -Encoding UTF8
    $collide = $false
    try { Enable-ClaudeDesktop 'headroom' @($desk) } catch { $collide = $true }
    Check '19a user mcp not overwritten' $collide 'threw'
    Check '19b custom command kept' ((Get-Content -LiteralPath $desk -Raw) -match 'custom-headroom') 'kept'
    Disable-ClaudeDesktop @($desk)
    Check '19c disable skips foreign mcp' ((Get-Content -LiteralPath $desk -Raw) -match 'custom-headroom') 'still there'
    $desk2 = Join-Path $tmp 'owned_desktop.json'
    Enable-ClaudeDesktop 'headroom' @($desk2)
    Check '19d owned marker' ((Get-Content -LiteralPath $desk2 -Raw) -match '_headroom_switch_mcp') 'marker'
    Disable-ClaudeDesktop @($desk2)
    Check '19e owned mcp removed' ((Get-Content -LiteralPath $desk2 -Raw) -notmatch 'custom-headroom' -and ((Get-Content -LiteralPath $desk2 -Raw) -notmatch '"headroom"')) 'gone'

    $offFa = Join-Path $tmp 'off-a.json'
    $offFb = Join-Path $tmp 'off-b.json'
    Set-Content -LiteralPath $offFa -Value '{"keep":"origA"}' -Encoding UTF8
    Set-Content -LiteralPath $offFb -Value '{"keep":"origB"}' -Encoding UTF8
    $offThrew = $false
    try {
        Invoke-WithFileSnapshots -Paths @($offFa, $offFb) -Action {
            param($A, $B)
            [System.IO.File]::WriteAllText($A, '{"keep":"dirtyA"}')
            throw 'second json failed'
        } -ActionArgs @($offFa, $offFb)
    } catch { $offThrew = $true }
    Check '19f off tx throws' $offThrew 'threw'
    Check '19g off first restored' ([bool]((Get-Content -LiteralPath $offFa -Raw) -match 'origA')) 'A'
    Check '19h off second untouched' ([bool]((Get-Content -LiteralPath $offFb -Raw) -match 'origB')) 'B'

    Check '20a ready at 20s' ((Resolve-ProxyStartKind $true $null $true $true 20 90 $false) -eq 'ready') '20s'
    Check '20b ready at 45s' ((Resolve-ProxyStartKind $true $null $true $true 45 90 $false) -eq 'ready') '45s'
    Check '20c early exit' ((Resolve-ProxyStartKind $false 1 $false $false 2 90 $false) -eq 'exited') 'exit'
    Check '20d timeout' ((Resolve-ProxyStartKind $true $null $false $false 90 90 $false) -eq 'timeout') '90s'
    Check '20e identity' ((Resolve-ProxyStartKind $true $null $true $false 5 90 $true) -eq 'identity') 'foreign listen'
    Check '20f wait still' ((Resolve-ProxyStartKind $true $null $false $false 20 90 $false) -eq 'wait') 'wait'
    $wd = Get-ExistingDirectory (Join-Path $tmp 'no-such-dir\deeper')
    Check '20g cwd fallback' ([bool]($wd -and (Test-Path -LiteralPath $wd -PathType Container))) 'exists'
    Check '20h no old timeout string' ($text -notmatch "AddSeconds\(10\)") 'no 10s'
    Check '20i spawn uses working dir' ($text -match 'WorkingDirectory') 'wd'
    Check '20j toggle respects pending' ($text -match 'ProxyWaitPending') 'busy'

    $portCtx = New-ProxyWaitContext -Purpose 'port' -WriteConfig $true -ConfigWasOn $false -Port 9999 -Bin 'headroom' -ProcessId 1
    $portPlan = Get-ProxyWaitCompensation 'timeout' $portCtx
    $sampleOn = Enable-CodexConfig "model_provider = `"openai`"`n" 8787 'headroom'
    $portAfter = Disable-CodexConfig $sampleOn 'openai' $null
    Check '21a port-change timeout stays direct' (
        $portPlan.DisableConfig -eq $false -and $portPlan.WriteConfig -eq $false -and $portPlan.StopProxy -eq $true -and
        $portAfter -notmatch '127\.0\.0\.1' -and (Get-ProxyWaitLog 'timeout' $portCtx 91 $null) -match 'Config not written'
    ) 'no prewrite'

    $profCtx = New-ProxyWaitContext -Purpose 'profile' -WriteConfig $false -ConfigWasOn $true -ConfigOwned $true -Port 8787 -Bin 'headroom' -ProcessId 1
    $profPlan = Get-ProxyWaitCompensation 'exited' $profCtx
    $profOff = $null
    if ($profPlan.DisableConfig) { $profOff = Disable-CodexConfig $sampleOn 'openai' $null }
    Check '21b profile restart exit rolls back' (
        $profPlan.DisableConfig -eq $true -and $profPlan.WriteConfig -eq $false -and
        $profOff -and $profOff -notmatch '127\.0\.0\.1' -and
        (Get-ProxyWaitLog 'exited' $profCtx 3 1 'restored') -match 'Restored direct routing'
    ) 'owned rollback'

    $bootCtx = New-ProxyWaitContext -Purpose 'bootstrap' -WriteConfig $false -ConfigWasOn $true -ConfigOwned $true -Port 8787 -Bin 'headroom' -ProcessId 1
    $bootReady = Get-ProxyWaitCompensation 'ready' $bootCtx
    $bootTo = Get-ProxyWaitCompensation 'timeout' $bootCtx
    Check '21c bootstrap 45s ready keeps config' (
        $bootReady.WriteConfig -eq $false -and $bootReady.DisableConfig -eq $false -and $bootReady.StopProxy -eq $false -and
        ((Resolve-ProxyStartKind $true $null $true $true 45 90 $false) -eq 'ready')
    ) 'already on'
    Check '21d bootstrap timeout restores direct' (
        $bootTo.DisableConfig -eq $true -and $bootTo.WriteConfig -eq $false -and
        (Get-ProxyWaitLog 'timeout' $bootCtx 90 $null 'restored') -match 'Restored direct routing'
    ) 'owned rollback'

    $script:Busy = $false
    $script:ProxyWaitPending = $true
    Check '21e pending settings blocked' (-not (Test-SettingsAllowed)) 'blocked'
    $script:ProxyWaitPending = $false
    Check '21e2 settings allowed when idle' (Test-SettingsAllowed) 'idle'

    $setFn = [regex]::Match($text, '(?s)function Show-Settings \{.*?function Test-ShouldStayInTray').Value
    if (-not $setFn) { $setFn = [regex]::Match($text, '(?s)function Show-Settings \{.*?\$btnSettings\.Add_Click').Value }
    Check '21f binary before port change' ($text -match '(?s)CustomHeadroom = \$tbPath\.Text\.Trim\(\).*Apply-OwnedPortChange') 'path first'
    Check '21g settings never prewrites config' ($setFn -notmatch 'Enable-CurrentAppConfig') 'no enable'
    Check '21h bootstrap uses shared wait' ($text -match 'Start-BootstrapRecovery' -and $text -match "Purpose 'bootstrap'") 'bootstrap'
    Check '21i timer uses snapshot port' ($text -match 'Test-OwnedProxyReady -Port \$port' -and $text -match '\$ctx\.Port') 'ctx.port'
    Check '21j profile keeps busy while pending' ([regex]::Match($text, '(?s)function Apply-Profile.*?function Disable-CurrentAppConfig').Value -match 'ProxyWaitPending') 'busy'
    Check '21k port change disables before wait' ($text -match '(?s)function Apply-OwnedPortChange.*?Disable-CurrentAppConfig.*?Start-OwnedProxyWait') 'order'
    Check '21l wait success uses frozen bin' ($text -match 'Enable-CurrentAppConfig\s+-Bin\s+\$ctx\.Bin') 'frozen bin'
    Check '21m failure disable only if Switch-owned' ($text -match '(?s)Get-ProxyWaitCompensation.*?DisableConfig.*?ConfigOwned') 'owned only'

    # Production state-machine fault injection. Mocks keep all writes and process
    # actions inside this test process while invoking the real callers and Tick.
    function Reset-ProductionMocks {
        $script:MockLogs = [System.Collections.Generic.List[string]]::new()
        $script:MockStops = 0
        $script:MockDisables = 0
        $script:MockEnables = 0
        $script:MockDisableMode = 'success'
        $script:MockOwned = $true
        $script:MockPortOpen = $false
        $script:MockReady = $false
        $script:MockProcMode = 'alive'
        $script:MockBin = 'C:\mock\headroom.exe'
        $script:MockStartTime = Get-Date
        $script:MockEnableArgs = $null
        $script:MockReadyArgs = $null
        $script:Busy = $false
        $script:ProxyWaitPending = $false
        $script:ProxyWait = $null
        $script:ProxyWaitTimer = $null
        $script:ProxyReadyTimeoutSec = 90
        $script:ProxyPid = 0
        $script:ProxyExePath = ''
        $script:ProxyStartTime = $null
        $script:IsOn = $true
        $script:Port = 8787
        $script:TargetApp = 'codex'
        $script:Profile = 'token'
    }
    function script:Add-Log([string]$Message) { $script:MockLogs.Add($Message) }
    function script:Set-PendingUi([bool]$Pending) {}
    function script:Write-AppState {}
    function script:Refresh-Status {}
    function script:Find-HeadroomExe { return [string]$script:MockBin }
    function script:Test-CurrentAppConfigOwned { return [bool]$script:MockOwned }
    function script:Test-PortOpen([int]$Port) { return [bool]$script:MockPortOpen }
    function script:Start-Sleep { param([int]$Milliseconds) }
    function script:Stop-HeadroomProxy { $script:MockStops++ }
    function script:Disable-CurrentAppConfig {
        param([string]$Target = '')
        $script:MockDisables++
        if ($script:MockDisableMode -eq 'throw') { throw 'injected disable failure' }
        return ($script:MockDisableMode -eq 'success')
    }
    function script:Enable-CurrentAppConfig {
        param([string]$Bin, [string]$Target, [int]$Port)
        $script:MockEnables++
        $script:MockEnableArgs = [ordered]@{ Bin = $Bin; Target = $Target; Port = $Port }
    }
    function script:Start-HeadroomProxy {
        $script:ProxyPid = 4242
        $script:ProxyExePath = 'C:\mock\worker.exe'
        $script:ProxyStartTime = $script:MockStartTime
        return $true
    }
    function script:Get-Process {
        param([int]$Id, $ErrorAction)
        if ($script:MockProcMode -eq 'missing') { return $null }
        if ($script:MockProcMode -eq 'exited') {
            return [pscustomobject]@{ HasExited = $true; ExitCode = 7 }
        }
        return [pscustomobject]@{ HasExited = $false; ExitCode = $null }
    }
    function script:Get-CimInstance {
        param([string]$ClassName, [string]$Filter, $ErrorAction)
        return [pscustomobject]@{
            ExecutablePath = 'C:\mock\worker.exe'
            CreationDate = $script:MockStartTime
        }
    }
    function script:Test-OwnedProxyReady {
        param(
            [int]$Port,
            [int]$ExpectedProcessId = 0,
            [string]$ExpectedExePath = '',
            $ExpectedStartTime = $null
        )
        $script:MockReadyArgs = [ordered]@{
            Port = $Port
            ProcessId = $ExpectedProcessId
            ExePath = $ExpectedExePath
            StartTime = $ExpectedStartTime
        }
        return [bool]$script:MockReady
    }

    # Ready Tick: execute on WinPS 5.1 and write only the frozen snapshot.
    Reset-ProductionMocks
    [void](Start-OwnedProxyWait -Purpose 'on' -WriteConfig $true -ConfigWasOn $false -ConfigOwned $false)
    $frozen = $script:ProxyWait
    $script:TargetApp = 'claude'
    $script:Port = 9999
    $script:MockBin = 'C:\changed\headroom.exe'
    $script:MockPortOpen = $true
    $script:MockReady = $true
    $frozen.Started = (Get-Date).AddSeconds(-45)
    $readyTickError = $null
    try { Complete-ProxyWaitTick } catch { $readyTickError = $_.Exception.Message }
    Check '22a production ready Tick executes' (-not $readyTickError -and -not $script:ProxyWaitPending) $(if ($readyTickError) { $readyTickError } else { 'completed' })
    Check '22b ready writes frozen Target Port Bin' (
        $script:MockEnables -eq 1 -and
        $script:MockEnableArgs.Target -eq 'codex' -and
        $script:MockEnableArgs.Port -eq 8787 -and
        $script:MockEnableArgs.Bin -eq 'C:\mock\headroom.exe'
    ) "target=$($script:MockEnableArgs.Target) port=$($script:MockEnableArgs.Port) bin=$($script:MockEnableArgs.Bin)"
    Check '22c ready validates frozen process identity' (
        $script:MockReadyArgs.ProcessId -eq 4242 -and
        $script:MockReadyArgs.ExePath -eq 'C:\mock\worker.exe' -and
        $null -ne $script:MockReadyArgs.StartTime
    ) "pid=$($script:MockReadyArgs.ProcessId) exe=$($script:MockReadyArgs.ExePath)"

    # Foreign bootstrap timeout: stop attempted worker, never edit foreign config.
    Reset-ProductionMocks
    $script:MockOwned = $false
    Start-BootstrapRecovery
    $script:ProxyWait.Started = (Get-Date).AddSeconds(-91)
    $timeoutTickError = $null
    try { Complete-ProxyWaitTick } catch { $timeoutTickError = $_.Exception.Message }
    Check '22d production timeout Tick executes' (-not $timeoutTickError -and -not $script:ProxyWaitPending) $(if ($timeoutTickError) { $timeoutTickError } else { 'completed' })
    Check '22e foreign bootstrap leaves config and logs truth' (
        $script:MockDisables -eq 0 -and
        $script:MockStops -eq 1 -and
        (($script:MockLogs -join "`n") -match 'Foreign config left as-is')
    ) "disable=$script:MockDisables stop=$script:MockStops log=$($script:MockLogs -join ' | ')"

    # Foreign and rollback-failed port changes stop before changing port or proxy.
    Reset-ProductionMocks
    $script:MockOwned = $false
    $script:MockPortOpen = $true
    $foreignPort = Apply-OwnedPortChange 9999
    Check '22f foreign port change refused no stop' (
        -not $foreignPort -and $script:Port -eq 8787 -and
        $script:MockDisables -eq 0 -and $script:MockStops -eq 0 -and
        -not $script:ProxyWaitPending
    ) "port=$script:Port disable=$script:MockDisables stop=$script:MockStops"

    Reset-ProductionMocks
    $script:MockDisableMode = 'failure'
    $restoreFalse = Apply-OwnedPortChange 9999
    Check '22g owned port restore false preserves old state' (
        -not $restoreFalse -and $script:IsOn -and $script:Port -eq 8787 -and
        $script:MockStops -eq 0 -and -not $script:ProxyWaitPending
    ) "port=$script:Port stop=$script:MockStops"

    Reset-ProductionMocks
    $script:MockDisableMode = 'throw'
    $restoreThrow = Apply-OwnedPortChange 9999
    Check '22h owned port Disable throw preserves old state' (
        -not $restoreThrow -and $script:IsOn -and $script:Port -eq 8787 -and
        $script:MockStops -eq 0 -and -not $script:ProxyWaitPending
    ) "port=$script:Port stop=$script:MockStops"

    # Profile caller plus real exited Tick: both rollback results are observable.
    Reset-ProductionMocks
    $script:MockPortOpen = $true
    Restart-ProxyForProfile
    $script:MockPortOpen = $false
    $script:MockProcMode = 'exited'
    $exitTickError = $null
    try { Complete-ProxyWaitTick } catch { $exitTickError = $_.Exception.Message }
    Check '22i production exited Tick rollback succeeds' (
        -not $exitTickError -and $script:MockDisables -eq 1 -and
        (($script:MockLogs -join "`n") -match 'Restored direct routing')
    ) $(if ($exitTickError) { $exitTickError } else { $script:MockLogs -join ' | ' })

    Reset-ProductionMocks
    $script:MockPortOpen = $true
    $script:MockDisableMode = 'failure'
    Restart-ProxyForProfile
    $script:MockPortOpen = $false
    $script:MockProcMode = 'exited'
    $exitFailTickError = $null
    try { Complete-ProxyWaitTick } catch { $exitFailTickError = $_.Exception.Message }
    Check '22j profile rollback failure is explicit' (
        -not $exitFailTickError -and $script:MockDisables -eq 1 -and
        (($script:MockLogs -join "`n") -match 'Rollback failed; config may still point to localhost')
    ) $(if ($exitFailTickError) { $exitFailTickError } else { $script:MockLogs -join ' | ' })

    # Production TurnOff must keep routing alive unless config restoration succeeds.
    $prodTokens = $null
    $prodErrors = $null
    $prodAst = [System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$prodTokens, [ref]$prodErrors)
    $turnOffNode = $prodAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-TurnOff'
    }, $true) | Select-Object -First 1
    $turnOffText = if ($turnOffNode) {
        [regex]::Replace($turnOffNode.Extent.Text, '^function\s+Invoke-TurnOff', 'function Invoke-ProductionTurnOff')
    } else { '' }
    if ($turnOffText) { Invoke-Expression $turnOffText }
    Reset-ProductionMocks
    $script:MockDisableMode = 'failure'
    $turnOffFalse = if ($turnOffText) { Invoke-ProductionTurnOff } else { $true }
    Check '22k TurnOff false keeps proxy and tells truth' (
        -not $turnOffFalse -and $script:MockStops -eq 0 -and
        (($script:MockLogs -join "`n") -match 'Turn off aborted') -and
        (($script:MockLogs -join "`n") -notmatch 'Back to direct')
    ) "stop=$script:MockStops log=$($script:MockLogs -join ' | ')"

    Reset-ProductionMocks
    $script:MockDisableMode = 'throw'
    $turnOffThrow = if ($turnOffText) { Invoke-ProductionTurnOff } else { $true }
    Check '22l TurnOff throw keeps proxy and tells truth' (
        -not $turnOffThrow -and $script:MockStops -eq 0 -and
        (($script:MockLogs -join "`n") -match 'config may still point localhost') -and
        (($script:MockLogs -join "`n") -notmatch 'Back to direct')
    ) "stop=$script:MockStops log=$($script:MockLogs -join ' | ')"

    Reset-ProductionMocks
    $script:MockDisableMode = 'success'
    $turnOffOk = if ($turnOffText) { Invoke-ProductionTurnOff } else { $false }
    Check '22m TurnOff success stops proxy and reports direct' (
        $turnOffOk -and $script:MockStops -eq 1 -and
        (($script:MockLogs -join "`n") -match 'Back to direct')
    ) "stop=$script:MockStops log=$($script:MockLogs -join ' | ')"

    # Invoke the production Settings click handler rather than only its predicate.
    $prodTokens = $null
    $prodErrors = $null
    $prodAst = [System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$prodTokens, [ref]$prodErrors)
    $settingsClick = $prodAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'Add_Click' -and
        $node.Expression.Extent.Text -eq '$btnSettings'
    }, $true) | Select-Object -First 1
    $script:MockShowSettings = 0
    function script:Show-Settings { $script:MockShowSettings++ }
    $settingsHandler = if ($settingsClick) { $settingsClick.Arguments[0].ScriptBlock.GetScriptBlock() } else { $null }
    Reset-ProductionMocks
    $script:ProxyWaitPending = $true
    if ($settingsHandler) { & $settingsHandler }
    Check '22n pending Settings production handler blocked' ($settingsHandler -and $script:MockShowSettings -eq 0) "show=$script:MockShowSettings"
    $script:ProxyWaitPending = $false
    if ($settingsHandler) { & $settingsHandler }
    Check '22o idle Settings production handler allowed' ($settingsHandler -and $script:MockShowSettings -eq 1) "show=$script:MockShowSettings"

    # Execute the production Claude ownership gate with stale state but no current marker.
    $disableNode = $prodAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Disable-CurrentAppConfig'
    }, $true) | Select-Object -First 1
    $disableText = if ($disableNode) {
        [regex]::Replace($disableNode.Extent.Text, '^function\s+Disable-CurrentAppConfig', 'function Invoke-ProductionDisableCurrentAppConfig')
    } else { '' }
    if ($disableText) { Invoke-Expression $disableText }
    $foreignClaude = Join-Path $tmp 'foreign-claude-settings.json'
    Set-Content -LiteralPath $foreignClaude -Value '{"env":{"ANTHROPIC_BASE_URL":"https://foreign.example"}}' -Encoding UTF8
    $foreignClaudeBefore = Get-Content -LiteralPath $foreignClaude -Raw
    $script:TargetApp = 'claude'
    $script:ClaudeSettingsPath = $foreignClaude
    $script:OwnsClaude = $true
    $script:MockLogs.Clear()
    $foreignClaudeResult = if ($disableText) { Invoke-ProductionDisableCurrentAppConfig } else { $true }
    $foreignClaudeAfter = Get-Content -LiteralPath $foreignClaude -Raw
    Check '22p stale Claude state cannot authorize foreign config edit' (
        $disableText -and -not $foreignClaudeResult -and
        $foreignClaudeAfter -eq $foreignClaudeBefore -and
        (($script:MockLogs -join "`n") -match 'Settings left as-is')
    ) "result=$foreignClaudeResult unchanged=$($foreignClaudeAfter -eq $foreignClaudeBefore)"

    $chk = [regex]::Match($text, '(?s)function Start-UpdateCheck \{.*?function Test-UpdateBlocked').Value
    Check '7b failed chip is Retry' ($chk -match "Set-UpdateChip 'failed' 'Retry'") 'Retry'

    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($text, $ps1, [ref]$null, [ref]$errs)
    Check '7a PS1 parses' ($errs.Count -eq 0) "parse errors: $($errs.Count)"

    $results -join "`r`n" | Set-Content -LiteralPath (Join-Path $here 'verify-output.txt') -Encoding UTF8
    $results | ForEach-Object { Write-Host $_ }
    $failed = @($results | Where-Object { $_ -like 'FAIL*' })
    if ($failed.Count -gt 0) { exit 1 }
    exit 0
}
finally {
    if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    if ($purePath) { Remove-Item -LiteralPath $purePath -Force -ErrorAction SilentlyContinue }
}
