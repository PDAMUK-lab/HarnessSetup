# Tests for the settings engine in desktop/windows/Common.ps1: schema, validators (shared cases with bash),
# the wizard driven by scripted answers, Initialize-NodeConfig, and format parity with the bash writer.
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Tmp)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$Root/desktop/windows/Common.ps1"
$pass = 0; $fail = 0
function Check([string]$Name, [scriptblock]$Test) {
    try { $ok = [bool](& $Test) } catch { $ok = $false; Write-Host "  ($($_.Exception.Message))" }
    if ($ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $Name" }
}
function Throws([scriptblock]$Block) { try { & $Block *> $null; return $false } catch { return $true } }
function Use-Answers([string[]]$Lines) {
    $f = Join-Path $Tmp ('ans-' + [guid]::NewGuid().ToString('N') + '.txt')
    $text = if ($Lines.Count -gt 0) { ($Lines -join "`n") + "`n" } else { '' }
    [System.IO.File]::WriteAllText($f, $text)
    $env:HS_INPUT = $f
    $script:HsInputLines = $null
    $script:HsInputIndex = 0
}
function Clear-Answers { Remove-Item Env:HS_INPUT -ErrorAction SilentlyContinue; $script:HsInputLines = $null }
function Quiet([scriptblock]$B) { & $B *> $null }
Clear-Answers

# ---- schema
$schema = Get-SettingsSchema
Check 'schema loads' { $schema.Count -gt 40 }
Check 'every row has prompt, help and group' { @($schema | Where-Object { -not $_.Prompt -or -not $_.Help -or -not $_.Group }).Count -eq 0 }
Check 'keys are unique' { ($schema | Select-Object -ExpandProperty Key | Sort-Object -Unique).Count -eq $schema.Count }
$exampleKeys = (Read-NodeEnv "$Root/config/node.env.example").Keys | Sort-Object
Check 'the example has exactly the schema keys' { (($schema | Select-Object -ExpandProperty Key | Sort-Object) -join ',') -eq ($exampleKeys -join ',') }

# ---- validators: the same cases the bash tests run
$cases = Get-Content "$Root/tests/validator-cases.psv" | Where-Object { $_ -and -not $_.StartsWith('#') }
$bad = @()
foreach ($line in $cases) {
    $f = $line -split '\|'
    $type = $f[0]; $val = $f[1]; $want = $f[2]; $norm = if ($f.Count -gt 3) { $f[3] } else { '' }
    $t = Test-SettingValue -Type $type -Value $val
    $got = if ($t.Ok) { 'ok' } else { 'bad' }
    if ($got -ne $want) { $bad += "$type '$val': wanted $want got $got ($($t.Error))"; continue }
    if ($norm -ne '') {
        $expected = if ($norm -eq '<empty>') { '' } else { $norm }
        if ($t.Norm -cne $expected) { $bad += "$type '$val': normalised to '$($t.Norm)', wanted '$expected'" }
    }
}
$bad | ForEach-Object { Write-Host "  $_" }
Check "all $($cases.Count) shared validator cases agree with bash" { $bad.Count -eq 0 }
Check 'Get-NetworkAddress /24' { (Get-NetworkAddress '192.168.1.150/24') -eq '192.168.1.0/24' }
Check 'Get-NetworkAddress /20' { (Get-NetworkAddress '172.16.37.9/20') -eq '172.16.32.0/20' }
Check 'Get-NetworkAddress /8' { (Get-NetworkAddress '10.200.3.4/8') -eq '10.0.0.0/8' }

# ---- yes/no and options
Use-Answers 'y', 'no', '', 'huh', 'n'
Check 'Read-YesNo: y' { Read-YesNo -Question 'Q' -Default $false 6>$null }
Check 'Read-YesNo: no' { -not (Read-YesNo -Question 'Q' -Default $true 6>$null) }
Check 'Read-YesNo: Enter takes the default' { Read-YesNo -Question 'Q' -Default $true 6>$null }
Check 'Read-YesNo: re-asks after junk (and then takes the n)' { $r = Read-YesNo -Question 'Q' -Default $true 6>$null; ($r -is [bool]) -and -not $r }
Clear-Answers
Check 'Read-YesNo: no terminal takes the default' { (Read-YesNo -Question 'Q' -Default $true) -and -not (Read-YesNo -Question 'Q' -Default $false) }
Use-Answers 'y'
$script:HsAssumeYes = $true
Check '-Yes takes the default even when answers exist' { -not (Read-YesNo -Question 'Q' -Default $false) }
$script:HsAssumeYes = $false
Clear-Answers
Check 'Resolve-Option: a bound switch wins and is not asked' {
    Use-Answers @(); $r = Resolve-Option -Bound @{ Foo = $true } -Name Foo -Current $true -Question 'Q' -Default $false; Clear-Answers; $r }
Check 'Resolve-Option: an unbound switch is asked' {
    Use-Answers 'y'; $r = Resolve-Option -Bound @{} -Name Foo -Current $false -Question 'Q' -Default $false; Clear-Answers; $r }
Use-Answers @()
Check 'the scripted answers running out is a clear error' { Throws { Read-Answer 'Q' } }
Clear-Answers

# ---- the wizard, fed like a user typing (desktop scope: shared and desktop-only questions)
$f1 = Join-Path $Tmp 'wiz.env'
Use-Answers '300.1.1.1', '10.0.0.20', '10.0.0.30', '10.0.0.1', 'james', '2', 'y', '2:00', '', 'n', 'n', ''
Quiet { Invoke-ConfigWizard -Path $f1 -Scope desktop }
Clear-Answers
$w = Read-NodeEnv $f1
Check 'wizard: laptop ip saved (after rejecting 300.1.1.1)' { $w['LAPTOP_IP'] -eq '10.0.0.20' }
Check 'wizard: desktop ip, router, admin user' { $w['DESKTOP_IP'] -eq '10.0.0.30' -and $w['ROUTER_IP'] -eq '10.0.0.1' -and $w['ADMIN_USER'] -eq 'james' }
Check 'wizard: quantization chosen by number' { $w['DESKTOP_QUANT'] -eq 'UD-Q4_K_XL' }
Check 'wizard: overnight tier on with a padded start time' { $w['NIGHT_ENABLED'] -eq '1' -and $w['NIGHT_START'] -eq '02:00' -and $w['NIGHT_END'] -eq '07:00' }
Check 'wizard: derived model file is not pinned in the file' { -not $w.Contains('DESKTOP_MODEL_FILE') }
Check 'wizard: ...but is derived from the quantization when the config is loaded' { (Get-EffectiveConfig $f1)['DESKTOP_MODEL_FILE'] -ceq 'Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf' }
Check 'wizard: the laptop-only questions were not asked and their detected defaults not adopted' { -not $w.Contains('LAN_CIDR') -and -not $w.Contains('GITHUB_ORG') }
Check 'wizard: unset required settings are commented, not empty' { (Get-Content $f1 -Raw) -match '# OR_WORKER_MODEL=   \(not set yet' }

# edit session: Enter keeps values, a new quant re-derives
Use-Answers '', '', '', '', '1', '', '', '', '', 'n', ''
Quiet { Invoke-ConfigWizard -Path $f1 -Scope desktop }
Clear-Answers
Check 'edit: Enter keeps the laptop ip' { (Read-NodeEnv $f1)['LAPTOP_IP'] -eq '10.0.0.20' }
Check 'edit: the new quantization re-derives the model file' { (Get-EffectiveConfig $f1)['DESKTOP_MODEL_FILE'] -ceq 'Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf' }

# -Defaults / -Set / -Only / -Print
$f2 = Join-Path $Tmp 'def.env'
Quiet { Invoke-ConfigWizard -Path $f2 -Scope desktop -Defaults -Set 'LAPTOP_IP=10.9.8.7,DESKTOP_IP=10.9.8.8' }
Check '-Defaults -Set (comma-separated, as from powershell -File)' { $d = Read-NodeEnv $f2; $d['LAPTOP_IP'] -eq '10.9.8.7' -and $d['DESKTOP_IP'] -eq '10.9.8.8' }
Check '-Set refuses an invalid value' { Throws { Invoke-ConfigWizard -Path $f2 -Scope desktop -Defaults -Set 'LAPTOP_IP=nope' } }
Check '-Set refuses an unknown setting' { Throws { Invoke-ConfigWizard -Path $f2 -Scope desktop -Defaults -Set 'NOPE=1' } }
Check 'no terminal and no -Defaults: refuses instead of guessing' { Throws { Invoke-ConfigWizard -Path (Join-Path $Tmp 'never.env') -Scope desktop } }
Use-Answers '9090'
Quiet { Invoke-ConfigWizard -Path $f2 -Scope desktop -Only 'LLM_PORT' }
Clear-Answers
Check '-Only asks one setting and keeps the rest' { $d = Read-NodeEnv $f2; $d['LLM_PORT'] -eq '9090' -and $d['LAPTOP_IP'] -eq '10.9.8.7' }
Add-Content $f2 'MY_EXTRA=keepme'
Use-Answers '8080'
Quiet { Invoke-ConfigWizard -Path $f2 -Scope desktop -Only 'LLM_PORT' }
Clear-Answers
Check 'unknown lines survive a rewrite' { (Read-NodeEnv $f2)['MY_EXTRA'] -eq 'keepme' }

# ---- Initialize-NodeConfig
$f3 = Join-Path $Tmp 'init.env'
Check 'no settings and no terminal: refuses and points at Configure.ps1' {
    try { Initialize-NodeConfig -Path $f3 *> $null; $false } catch { $_.Exception.Message -match 'Configure\.ps1' } }
Use-Answers '', '10.0.0.20', '10.0.0.30', '10.0.0.1', 'james', '', 'n', 'n', 'n', ''
$c = Initialize-NodeConfig -Path $f3 -Need 'LAPTOP_IP', 'DESKTOP_IP' 6>$null
Clear-Answers
Check 'first run starts the wizard by itself and returns the config' { $c['LAPTOP_IP'] -eq '10.0.0.20' -and (Test-Path $f3) }
Check 'the returned config carries derived defaults' { $c['DESKTOP_MODEL_FILE'] -ceq 'Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf' -and $c['DASHBOARD_PORT'] -eq '9119' }
$c2 = Initialize-NodeConfig -Path $f3 -Need 'LAPTOP_IP', 'DESKTOP_IP', 'DASHBOARD_PORT'
Check 'second run asks nothing' { $c2['DESKTOP_IP'] -eq '10.0.0.30' }
# a needed setting that is invalid in the file is asked for; without a terminal it is a clear error
(Get-Content $f3) -replace '^ROUTER_IP=.*', 'ROUTER_IP=not-an-ip' | Set-Content $f3
Check 'an invalid needed setting without a terminal is an error naming it' {
    try { Initialize-NodeConfig -Path $f3 -Need 'ROUTER_IP' *> $null; $false } catch { $_.Exception.Message -match 'ROUTER_IP' } }
Use-Answers '10.0.0.1'
$c3 = Initialize-NodeConfig -Path $f3 -Need 'ROUTER_IP' 6>$null
Clear-Answers
Check 'an invalid needed setting is asked for and saved' { $c3['ROUTER_IP'] -eq '10.0.0.1' -and (Read-NodeEnv $f3)['ROUTER_IP'] -eq '10.0.0.1' }
Check 'a detected (auto) setting that is missing is never adopted silently' {
    $f = Join-Path $Tmp 'auto.env'; Set-Content $f 'ADMIN_USER=james'
    try { Initialize-NodeConfig -Path $f -Need 'LAPTOP_IP' *> $null; $false } catch { $_.Exception.Message -match 'LAPTOP_IP' } }

# import the laptop's file over SSH instead of re-typing (scp is a stub in tests)
$f4 = Join-Path $Tmp 'imported.env'
Quiet { Invoke-ConfigWizard -Path (Join-Path $Tmp 'laptop-node.env') -Scope laptop -Defaults -Set 'LAPTOP_IP=192.168.1.150,DESKTOP_IP=192.168.1.100' }
$env:FAKE_SCP_SRC = Join-Path $Tmp 'laptop-node.env'
Use-Answers 'ai-node@10.0.0.20', ''
$c4 = Initialize-NodeConfig -Path $f4 6>$null
Clear-Answers
Check 'import: copies the laptop file instead of asking questions' { (Test-Path $f4) -and $c4['LAPTOP_IP'] -eq '192.168.1.150' }
# a file that is not valid (the example still has placeholders) is refused and the questions are asked instead
$f5 = Join-Path $Tmp 'imported-bad.env'
Copy-Item "$Root/config/node.env.example" (Join-Path $Tmp 'example-copy.env')
$env:FAKE_SCP_SRC = Join-Path $Tmp 'example-copy.env'
Use-Answers 'ai-node@10.0.0.20', '', '10.0.0.20', '10.0.0.30', '10.0.0.1', 'james', '', 'n', 'n', 'n', ''
$c5 = Initialize-NodeConfig -Path $f5 6>$null 3>$null
Clear-Answers
Check 'import: an invalid file is refused and the questions are asked' { $c5['LAPTOP_IP'] -eq '10.0.0.20' -and -not (Get-Content $f5 -Raw).Contains('yourorg') }
# a login or path that could be read as an option never reaches scp
Use-Answers '-oProxyCommand=evil@host', '', '10.0.0.20', '10.0.0.30', '10.0.0.1', 'james', '', 'n', 'n', 'n', ''
$f6 = Join-Path $Tmp 'imported-opt.env'
$null = Initialize-NodeConfig -Path $f6 6>$null 3>$null
Clear-Answers
Check 'import: an option-looking login is rejected without calling scp' { (Test-Path $f6) -and (Read-NodeEnv $f6)['LAPTOP_IP'] -eq '10.0.0.20' }
Remove-Item Env:FAKE_SCP_SRC

# ---- file integrity: hostile values survive a rewrite inertly; extras and export lines are kept as found
$f7 = Join-Path $Tmp 'hostile.env'
Set-Content $f7 @("LAPTOP_IP=10.0.0.20", "DESKTOP_IP=10.0.0.30", "ROUTER_IP=10.0.0.1", "ADMIN_USER=james",
    'LAPTOP_MODEL_ALIAS="x'' ; touch PWNED ; echo ''"', 'export DASHBOARD_PORT=9120', 'MY_ARR=(a b)', 'MY_Q="it''s"', 'FOO=$HOME/x')
Quiet { Invoke-ConfigWizard -Path $f7 -Scope desktop -Defaults }
$after = Get-Content $f7
Check 'integrity: the export line is read as a setting' { (Read-NodeEnv $f7)['DASHBOARD_PORT'] -eq '9120' }
Check 'integrity: a value with a single quote is re-quoted so it reads back identical' { (Read-NodeEnv $f7)['LAPTOP_MODEL_ALIAS'] -ceq "x' ; touch PWNED ; echo '" }
Check 'integrity: unknown lines are kept exactly as found' { ($after -contains 'MY_ARR=(a b)') -and ($after -contains 'MY_Q="it''s"') -and ($after -contains 'FOO=$HOME/x') }
Check 'integrity: ConvertFrom-EnvValue handles the shell quoting forms' {
    (ConvertFrom-EnvValue "'a'\''b'") -ceq "a'b" -and (ConvertFrom-EnvValue '"a b" # c') -ceq 'a b' -and (ConvertFrom-EnvValue 'x\ y') -ceq 'x y' -and (ConvertFrom-EnvValue '"q\"r"') -ceq 'q"r' }
Check 'integrity: the file has no BOM and no CR' {
    $b = [System.IO.File]::ReadAllBytes($f7); -not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB) -and -not ($b -contains 13) }

# ---- answer later (wizard) vs required (just in time)
$rowWorker = $schema | Where-Object { $_.Key -eq 'OR_WORKER_MODEL' }
Use-Answers ''
$vals = [ordered]@{}
Quiet { Read-Setting -Row $rowWorker -Values $vals -AllowSkip }
Clear-Answers
Check 'AllowSkip: Enter leaves a setting with no default unset' { -not $vals.Contains('OR_WORKER_MODEL') }
Use-Answers '', 'vendor-a/worker'
$vals2 = [ordered]@{}
Quiet { Read-Setting -Row $rowWorker -Values $vals2 }
Clear-Answers
Check 'without AllowSkip an empty answer is refused and asked again' { $vals2['OR_WORKER_MODEL'] -eq 'vendor-a/worker' }
Use-Answers ''
$rowUser = $schema | Where-Object { $_.Key -eq 'GITHUB_MACHINE_USER' }
$vals3 = [ordered]@{}
Quiet { Read-Setting -Row $rowUser -Values $vals3 -AllowSkip }
Clear-Answers
Check 'a default derived from an unknown setting ("-hermes") is not offered' { -not $vals3.Contains('GITHUB_MACHINE_USER') }
Use-Answers '99999999999', '2'
$rowQ = $schema | Where-Object { $_.Key -eq 'DESKTOP_QUANT' }
$vals4 = [ordered]@{}
Quiet { Read-Setting -Row $rowQ -Values $vals4 }
Clear-Answers
Check 'a huge number at a choice prompt is just invalid, not a crash' { $vals4['DESKTOP_QUANT'] -eq 'UD-Q4_K_XL' }

# ---- Set-NodeSettings changes only what it is told to
$f8 = Join-Path $Tmp 'setonly.env'
Set-Content $f8 @('LAPTOP_IP=10.0.0.20', 'DESKTOP_IP=10.0.0.30', 'ADMIN_USER=james')
Quiet { Set-NodeSettings -Path $f8 -Set 'NIGHT_ENABLED=1' }
$r8 = Read-NodeEnv $f8
Check 'Set-NodeSettings: the setting is set' { $r8['NIGHT_ENABLED'] -eq '1' }
Check 'Set-NodeSettings: the existing values are kept' { $r8['LAPTOP_IP'] -eq '10.0.0.20' -and $r8['ADMIN_USER'] -eq 'james' }
Check 'Set-NodeSettings: no detected address is adopted for the settings that were never given' { -not $r8.Contains('ROUTER_IP') -and -not $r8.Contains('LAN_CIDR') }
Check 'Set-NodeSettings: an invalid value is refused' { Throws { Set-NodeSettings -Path $f8 -Set 'NIGHT_ENABLED=maybe' } }

# ---- a native command's stderr is text, not an error, under $ErrorActionPreference = 'Stop'
$old = $ErrorActionPreference; $ErrorActionPreference = 'Stop'
$txt = Invoke-NativeText { & bash -c 'echo out; echo err >&2' }
$ErrorActionPreference = $old
Check 'Invoke-NativeText returns stdout and stderr and does not throw' { $txt -match 'out' -and $txt -match 'err' }

# ---- parity: a file bash wrote survives a PowerShell read-and-rewrite byte for byte
if ($env:HS_PARITY_FILE) {
    $schema2 = Get-SettingsSchema
    $state = Read-SettingsFile -Path $env:HS_PARITY_FILE -Schema $schema2
    Complete-Settings -Schema $schema2 -Values $state.Values -Scope laptop
    $out = Join-Path $Tmp 'parity-out.env'
    Write-NodeEnv -Path $out -Schema $schema2 -Values $state.Values -Extra $state.Extra
    $a = (Get-Content $env:HS_PARITY_FILE -Raw).Replace("`r`n", "`n")
    $b = (Get-Content $out -Raw).Replace("`r`n", "`n")
    if ($a -ne $b) { Compare-Object ($a -split "`n") ($b -split "`n") | Select-Object -First 6 | ForEach-Object { Write-Host "  parity: $($_.SideIndicator) $($_.InputObject)" } }
    Check 'the PowerShell writer produces the same file as the bash writer' { $a -ceq $b }
}

Write-Host "powershell settings: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
