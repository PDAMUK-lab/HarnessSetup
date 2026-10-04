# Unit tests for desktop/windows/Common.ps1 (pure helpers). Run by tests/test-powershell.sh.
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Tmp)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$Root/desktop/windows/Common.ps1"
$pass = 0; $fail = 0
function Check([string]$Name, [scriptblock]$Test) {
    try { $ok = [bool](& $Test) } catch { $ok = $false; Write-Host "  ($($_.Exception.Message))" }
    if ($ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $Name" }
}
function Throws([scriptblock]$Block) { try { & $Block | Out-Null; return $false } catch { return $true } }

# ---- Read-NodeEnv / Assert-Config
$cfg = Read-NodeEnv "$Root/config/node.env.example"
Check 'Read-NodeEnv reads plain values' { $cfg['LAPTOP_IP'] -eq '192.168.1.150' }
Check "Read-NodeEnv strips single quotes (the Windows paths)" { $cfg['DESKTOP_LLAMA_DIR'] -eq 'C:\llama' -and $cfg['DESKTOP_MODELS_DIR'] -eq 'C:\models' }
Check 'Read-NodeEnv strips double quotes' { $cfg['GITHUB_REPOS'] -eq 'yourrepo' }
Check 'Read-NodeEnv ignores comment lines' { -not $cfg.Contains('#') -and $cfg.Keys.Count -gt 30 }
Check 'Read-NodeEnv keeps empty values' { $cfg.Contains('OR_WORKER_MODEL') -and $cfg['OR_WORKER_MODEL'] -eq '' }
"A=1 # trailing`nB=`"x y`" # c`nC='p q'`n# D=4`n  E = 5`nF=http://h:1/a=b" | Set-Content "$Tmp/q.env"
$q = Read-NodeEnv "$Tmp/q.env"
Check 'Read-NodeEnv drops trailing comments on bare values' { $q['A'] -eq '1' }
Check 'Read-NodeEnv keeps spaces inside quotes' { $q['B'] -eq 'x y' -and $q['C'] -eq 'p q' }
Check 'Read-NodeEnv skips commented-out and malformed lines' { -not $q.Contains('D') -and -not $q.Contains('E') }
Check 'Read-NodeEnv keeps = inside values (URLs)' { $q['F'] -eq 'http://h:1/a=b' }
Check 'Read-NodeEnv fails helpfully on a missing file' { Throws { Read-NodeEnv "$Tmp/nope.env" } }
Check 'Assert-Config accepts set keys' { -not (Throws { Assert-Config $cfg 'LAPTOP_IP', 'DESKTOP_IP' }) }
Check 'Assert-Config rejects an empty key' { Throws { Assert-Config $cfg 'OR_WORKER_MODEL' } }
Check 'Assert-Config rejects a missing key' { Throws { Assert-Config $cfg 'NOT_THERE' } }

# ---- clock arithmetic (overnight window)
Check 'Add-ClockMinutes: +15' { (Add-ClockMinutes '01:00' 15) -eq '01:15' }
Check 'Add-ClockMinutes: -120 from 07:00' { (Add-ClockMinutes '07:00' -120) -eq '05:00' }
Check 'Add-ClockMinutes: wraps past midnight' { (Add-ClockMinutes '23:30' 75) -eq '00:45' -and (Add-ClockMinutes '00:10' -30) -eq '23:40' }

# ---- New-ApiKey
$k1 = New-ApiKey; $k2 = New-ApiKey
Check 'New-ApiKey is 64 hex characters' { $k1 -match '^[0-9a-f]{64}$' }
Check 'New-ApiKey differs every time' { $k1 -ne $k2 }

# ---- New-LlamaStartScript
$day = New-LlamaStartScript -Cfg $cfg -Tier Day
Check 'Day: first line launches the right binary, model and alias' { $day[0] -eq 'C:\llama\llama-server.exe -m C:\models\Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf --alias qwen3.6-35b-a3b ^' }
Check 'Day: listens on the desktop address and reads the key from a file' { $day[1] -eq '  --host 192.168.1.100 --port 8080 --api-key-file C:\llama\api-key.txt ^' }
Check 'Day: GPU/context flags match the guide' { $day[2] -eq '  --jinja -ngl 99 --n-cpu-moe 40 -fa on -np 1 -c 131072 -ctk f16 -ctv q8_0 ^' }
Check 'Day: preserved thinking with the guide''s exact cmd quoting' { $day[3] -eq '  --cache-ram 1024 --chat-template-kwargs "{\"preserve_thinking\":true}" ^' }
Check 'Day: sampling for thinking mode' { $day[4] -eq '  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0' }
Check 'Day: every line but the last continues with ^' { (@($day[0..($day.Count - 2)] | Where-Object { $_ -notmatch ' \^$' }).Count -eq 0) -and ($day[-1] -notmatch '\^$') }
Check 'Day: the key itself never appears in the script' { -not (($day -join "`n") -match '--api-key [^f]') }
$night = New-LlamaStartScript -Cfg $cfg -Tier Night
Check 'Night: 27B model and alias' { $night[0] -eq 'C:\llama\llama-server.exe -m C:\models\Qwen3.8-27B-UD-Q4_K_XL.gguf --alias qwen3.8-27b ^' }
Check 'Night: partial GPU offload (-ngl 16), no --n-cpu-moe' { ($night -join "`n") -match '-ngl 16 ' -and ($night -join "`n") -notmatch 'n-cpu-moe' }
Check 'Night: reasoning effort medium (the template maps high to the default xhigh)' { ($night -join "`n").Contains('--chat-template-kwargs "{\"reasoning_effort\":\"medium\"}"') }
Check 'Night: temp 1.0 and MTP speculative decoding' { ($night -join "`n") -match '--temp 1\.0' -and ($night -join "`n") -match '--spec-type draft-mtp --spec-draft-n-max 2' }
Check 'Night: every line but the last continues with ^' { (@($night[0..($night.Count - 2)] | Where-Object { $_ -notmatch ' \^$' }).Count -eq 0) -and ($night[-1] -notmatch '\^$') }
$cfg2 = [ordered]@{} + $cfg; $cfg2['DESKTOP_N_CPU_MOE'] = '32'
Check 'settings flow through (-n-cpu-moe 32)' { (New-LlamaStartScript -Cfg $cfg2 -Tier Day)[2] -match '--n-cpu-moe 32 ' }
# ---- other model families: chat-template switches, sampling, MTP are settings
Check 'ConvertTo-CmdKwargs: booleans and numbers bare, words quoted, cmd escaping' { (ConvertTo-CmdKwargs 'enable_thinking=false,reasoning_effort=low,n=-1.5') -eq '"{\"enable_thinking\":false,\"reasoning_effort\":\"low\",\"n\":-1.5}"' }
Check 'ConvertTo-CmdKwargs: a leading-zero number stays a string (07 is not JSON)' { (ConvertTo-CmdKwargs 'n=07,m=0,k=0.5') -eq '"{\"n\":\"07\",\"m\":0,\"k\":0.5}"' }
$bad = [ordered]@{} + $cfg; $bad['DESKTOP_SAMPLING'] = '--temp'
Check 'a bad sampling value in the settings file stops the start script with the setting name' { try { $null = New-LlamaStartScript -Cfg $bad -Tier Day; $false } catch { $_.Exception.Message -match 'DESKTOP_SAMPLING' } }
$bad = [ordered]@{} + $cfg; $bad['NIGHT_CHAT_KWARGS'] = '{x}'
Check 'a bad switch value stops the night script too' { try { $null = New-LlamaStartScript -Cfg $bad -Tier Night; $false } catch { $_.Exception.Message -match 'NIGHT_CHAT_KWARGS' } }
$mtpno = [ordered]@{} + $cfg; $mtpno['NIGHT_MTP'] = 'no'
Check 'NIGHT_MTP=no (any spelling of no) turns MTP off' { -not ((New-LlamaStartScript -Cfg $mtpno -Tier Night) -join "`n").Contains('draft-mtp') }
Check 'Resolve-ModelSetting: auto, none, missing, value' { (Resolve-ModelSetting 'auto' 'X') -eq 'X' -and (Resolve-ModelSetting 'none' 'X') -eq '' -and (Resolve-ModelSetting $null 'X') -eq 'X' -and (Resolve-ModelSetting 'a=1' 'X') -eq 'a=1' }
$cfg3 = [ordered]@{} + $cfg; $cfg3['DESKTOP_CHAT_KWARGS'] = 'reasoning_effort=high'; $cfg3['DESKTOP_SAMPLING'] = '--temp 1.0 --top-p 1.0'
$d3 = New-LlamaStartScript -Cfg $cfg3 -Tier Day
Check 'Day: another family''s switches and sampling come from the settings' { $d3[3] -eq '  --cache-ram 1024 --chat-template-kwargs "{\"reasoning_effort\":\"high\"}" ^' -and $d3[4] -eq '  --temp 1.0 --top-p 1.0' }
$cfg3['DESKTOP_CHAT_KWARGS'] = 'none'; $cfg3['DESKTOP_SAMPLING'] = 'none'
$d3 = New-LlamaStartScript -Cfg $cfg3 -Tier Day
Check 'Day: none and none leave out both flags, and the last line has no ^' { -not (($d3 -join "`n") -match 'chat-template-kwargs|--temp') -and $d3[-1] -eq '  --cache-ram 1024' }
$cfg3 = [ordered]@{} + $cfg; $cfg3['NIGHT_MTP'] = '0'; $cfg3['NIGHT_SAMPLING'] = '--temp 0.7'
$n3 = New-LlamaStartScript -Cfg $cfg3 -Tier Night
Check 'Night: NIGHT_MTP=0 drops the MTP flags; the sampling line ends the command' { -not (($n3 -join "`n") -match 'draft-mtp') -and $n3[-1] -eq '  --temp 0.7' }
Check 'Night: every line but the last continues with ^ (MTP off)' { (@($n3[0..($n3.Count - 2)] | Where-Object { $_ -notmatch ' \^$' }).Count -eq 0) -and ($n3[-1] -notmatch '\^$') }

# ---- Write-CmdFile / New-TunnelCmd
Write-CmdFile -Path "$Tmp/t.cmd" -Lines (New-TunnelCmd -Cfg $cfg)
$raw = [System.IO.File]::ReadAllBytes("$Tmp/t.cmd")
Check 'cmd file uses CRLF line endings' { ([System.Text.Encoding]::ASCII.GetString($raw) -split "`r`n").Count -ge 4 -and ([System.Text.Encoding]::ASCII.GetString($raw) -notmatch "[^`r]`n") }
Check 'cmd file has no BOM' { $raw[0] -ne 0xEF -and $raw[0] -ne 0xFF }
$tun = (New-TunnelCmd -Cfg $cfg) -join "`n"
Check 'tunnel uses 9119 on both ends and the laptop address' { $tun.Contains('-L 9119:127.0.0.1:9119 ai-node@192.168.1.150') }
Check 'tunnel window stays open after a failed connection (pause)' { $tun.Contains('pause') }
Check 'tunnel keeps the connection alive and fails loudly' { $tun.Contains('ServerAliveInterval=30') -and $tun.Contains('ExitOnForwardFailure=yes') }

# ---- Test-GgufFile / Select-VulkanAsset
[System.IO.File]::WriteAllBytes("$Tmp/good.gguf", [byte[]](71, 71, 85, 70, 1, 2, 3))
[System.IO.File]::WriteAllText("$Tmp/bad.gguf", '<html>404</html>')
[System.IO.File]::WriteAllBytes("$Tmp/short.gguf", [byte[]](71, 71))
Check 'Test-GgufFile accepts the GGUF magic' { Test-GgufFile "$Tmp/good.gguf" }
Check 'Test-GgufFile rejects an HTML page' { -not (Test-GgufFile "$Tmp/bad.gguf") }
Check 'Test-GgufFile rejects a truncated file' { -not (Test-GgufFile "$Tmp/short.gguf") }
Check 'Test-GgufFile rejects a missing file' { -not (Test-GgufFile "$Tmp/none.gguf") }
$assets = @(
    [pscustomobject]@{ name = 'llama-b9999-bin-win-cpu-x64.zip' },
    [pscustomobject]@{ name = 'llama-b9999-bin-win-vulkan-x64.zip' },
    [pscustomobject]@{ name = 'llama-b9999-bin-ubuntu-x64.zip' })
Check 'Select-VulkanAsset picks the win-vulkan-x64 zip' { (Select-VulkanAsset $assets).name -eq 'llama-b9999-bin-win-vulkan-x64.zip' }
Check 'Select-VulkanAsset fails when there is none' { Throws { Select-VulkanAsset @([pscustomobject]@{ name = 'x.zip' }) } }

# ---- Invoke-Action honours -DryRun
$script:HsDryRun = $true; $ran = $false
Invoke-Action 'x' { $script:ran = $true } *> $null
Check 'Invoke-Action does not run the block under DryRun' { -not $ran }
$script:HsDryRun = $false
Invoke-Action 'x' { $script:ran = $true } *> $null
Check 'Invoke-Action runs the block normally' { $ran }

# ---- Wait-Http / Test-ToolCall against the fake llama-servers
$tool = $env:FAKE_TOOL_PORT; $prose = $env:FAKE_PROSE_PORT; $keyed = $env:FAKE_KEY_PORT
Check 'Wait-Http sees a live server' { Wait-Http -Url "http://127.0.0.1:$prose/health" -Seconds 10 }
Check 'Wait-Http gives up on a dead port' { -not (Wait-Http -Url 'http://127.0.0.1:1/health' -Seconds 4) }
Check 'Test-ToolCall: a real tool call passes' { Test-ToolCall -BaseUrl "http://127.0.0.1:$tool" -Model m }
Check 'Test-ToolCall: a prose answer (no --jinja) fails' { -not (Test-ToolCall -BaseUrl "http://127.0.0.1:$prose" -Model m) }
Check 'Test-ToolCall: sends the API key' { Test-ToolCall -BaseUrl "http://127.0.0.1:$keyed" -Model m -ApiKey secret }
Check 'Test-ToolCall: fails without the key' { -not (Test-ToolCall -BaseUrl "http://127.0.0.1:$keyed" -Model m) }
Check 'Wait-Http sends headers (health needs the key)' { Wait-Http -Url "http://127.0.0.1:$keyed/health" -Seconds 10 -Headers @{ Authorization = 'Bearer secret' } }

# ---- llama.cpp release selection (the "latest" release is a source-only tag; the builds are pre-releases)
function New-Rel([string]$Tag, [string[]]$Assets, [bool]$Draft = $false) {
    [pscustomobject]@{ tag_name = $Tag; draft = $Draft; prerelease = $true; assets = @($Assets | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
}
$vk = '^llama-.+-bin-win-vulkan-x64\.zip$'
$rels = @(
    (New-Rel 'b3' @('llama-b3-bin-win-cpu-x64.zip')),                                   # uploaded halfway: no Vulkan zip yet
    (New-Rel 'b2' @('llama-b2-bin-win-vulkan-x64.zip', 'llama-b2-bin-win-cuda-12.4-x64.zip') $true),   # a draft
    (New-Rel 'b1' @('llama-b1-bin-win-vulkan-x64.zip', 'llama-b1-bin-win-cuda-12.4-x64.zip', 'cudart-llama-bin-win-cuda-12.4-x64.zip')),
    (New-Rel 'v0.5.0' @('nightly-tag.txt')))
Check 'Select-LlamaRelease skips an incomplete release and a draft' { (Select-LlamaRelease -Releases $rels -Patterns $vk).tag_name -eq 'b1' }
Check 'Select-LlamaRelease needs EVERY pattern (CUDA zip and its runtime)' { (Select-LlamaRelease -Releases $rels -Patterns '^llama-.+-bin-win-cuda-12\.\d+-x64\.zip$', '^cudart-llama-bin-win-cuda-12\.\d+-x64\.zip$').tag_name -eq 'b1' }
Check 'Select-LlamaRelease: a CUDA zip without its runtime bundle does not qualify' {
    $half = @((New-Rel 'b9' @('llama-b9-bin-win-cuda-12.4-x64.zip'))) + $rels
    (Select-LlamaRelease -Releases $half -Patterns '^llama-.+-bin-win-cuda-12\.\d+-x64\.zip$', '^cudart-llama-bin-win-cuda-12\.\d+-x64\.zip$').tag_name -eq 'b1' }
Check 'Select-LlamaRelease takes the newest complete one' { (Select-LlamaRelease -Releases (@(New-Rel 'b4' @('llama-b4-bin-win-vulkan-x64.zip')) + $rels) -Patterns $vk).tag_name -eq 'b4' }
Check 'Select-LlamaRelease returns nothing when no release qualifies' { $null -eq (Select-LlamaRelease -Releases $rels -Patterns '^llama-.+-bin-win-hip-x64\.zip$') }
Check 'Select-LlamaRelease copes with an empty list' { $null -eq (Select-LlamaRelease -Releases @() -Patterns $vk) }
Check 'the ROCm asset pattern finds the HIP Radeon build and not the Vulkan one' {
    $p = $script:LlamaAssetPatterns['rocm']
    'llama-b6500-bin-win-rocm-10.0-x64.zip' -cmatch $p -and 'llama-b6500-bin-win-hip-radeon-x64.zip' -cmatch $p -and
    -not ('llama-b6500-bin-win-vulkan-x64.zip' -cmatch $p) -and -not ('llama-b6500-bin-ubuntu-rocm-10.0-x64.tar.gz' -cmatch $p) -and
    -not ('llama-b6500-bin-win-rocm-10.0-arm64.zip' -cmatch $p) -and -not ('cudart-llama-bin-win-cuda-12.4-x64.zip' -cmatch $p) }
Check 'Find-RocmLibraries: the folders holding hipBLAS and rocBLAS, $null for a missing one' {
    $sep = [IO.Path]::PathSeparator
    $a = Join-Path ([IO.Path]::GetTempPath()) "hs-rocm-a-$PID"; $b = Join-Path ([IO.Path]::GetTempPath()) "hs-rocm-b-$PID"
    New-Item -ItemType Directory -Force -Path $a, $b | Out-Null
    Set-Content -LiteralPath (Join-Path $a 'hipblas.dll') -Value x; Set-Content -LiteralPath (Join-Path $b 'rocblas.dll') -Value x
    $both = Find-RocmLibraries -PathList "$a$sep$b"
    $half = Find-RocmLibraries -PathList "nowhere$sep$a"
    $none = Find-RocmLibraries -PathList ''
    $viaDir = Find-RocmLibraries -PathList $a -Dir $b
    Remove-Item -LiteralPath $a, $b -Recurse -Force
    $both.HipBlas -eq $a -and $both.RocBlas -eq $b -and $half.HipBlas -eq $a -and $null -eq $half.RocBlas -and
    $null -eq $none.HipBlas -and $viaDir.RocBlas -eq $b }
$benchCsv = @(
    'load_backend: loaded ROCm backend from C:\llama-rocm\ggml-hip.dll, with commas',
    'build_commit,build_number,model_type,n_prompt,n_gen,n_depth,avg_ts,stddev_ts',
    '"abc","6500","qwen3moe 35B","2048","0","0","812.50","3.1"',
    'llama_kv_cache: some log line, between rows',
    '"abc","6500","qwen3moe 35B","0","128","0","24.75","0.2"',
    '"abc","6500","qwen3moe 35B","0","128","32768","19.1","0.2"'
) -join "`r`n"
$bench = @(ConvertFrom-LlamaBenchCsv $benchCsv)
Check 'ConvertFrom-LlamaBenchCsv: test name, depth and speed of each row, log lines ignored' {
    $bench.Count -eq 3 -and $bench[0].Test -eq 'pp2048' -and $bench[0].TokensPerSecond -eq 812.5 -and
    $bench[1].Test -eq 'tg128' -and $bench[1].Depth -eq 0 -and $bench[2].Depth -eq 32768 -and $bench[2].TokensPerSecond -eq 19.1 }
Check 'Get-LlamaBackend: vulkan unless the folder says rocm' {
    $d = Join-Path ([IO.Path]::GetTempPath()) "hs-backend-$PID"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $a = Get-LlamaBackend -Dir $d
    Set-Content -LiteralPath "$d\llama-backend.txt" -Value 'rocm'; $b = Get-LlamaBackend -Dir $d
    Remove-Item -LiteralPath $d -Recurse -Force
    $a -eq 'vulkan' -and $b -eq 'rocm' }
Check 'ConvertFrom-LlamaBenchCsv: nothing from output without a CSV table' { @(ConvertFrom-LlamaBenchCsv 'error: failed to load model').Count -eq 0 -and @(ConvertFrom-LlamaBenchCsv '').Count -eq 0 }

Check 'Measure-OtherGpuUse: 3D and compute use of other programs only, the model servers left out' {
    $smp = @(
        [pscustomobject]@{ Instance = 'pid_100_luid_0x0_0x1_phys_0_eng_0_engtype_3D'; Value = 30.5 },
        [pscustomobject]@{ Instance = 'pid_100_luid_0x0_0x1_phys_0_eng_1_engtype_Compute_0'; Value = 4 },
        [pscustomobject]@{ Instance = 'pid_200_luid_0x0_0x1_phys_0_eng_1_engtype_Compute_0'; Value = 95 },
        [pscustomobject]@{ Instance = 'pid_300_luid_0x0_0x1_phys_0_eng_2_engtype_VideoDecode'; Value = 50 })
    (Measure-OtherGpuUse -Samples $smp -ExcludePids 200) -eq 34.5 -and (Measure-OtherGpuUse -Samples $smp) -eq 100 -and (Measure-OtherGpuUse) -eq 0 }
$t0 = [datetime]'2026-01-01T12:00:00'
$aa = @{ Threshold = 25; AwayAfter = 2; BackAfter = 15 }
Check 'Step-AutoAway: away only after AwayAfter minutes of other GPU use' {
    $st = @{}
    $a = Step-AutoAway -State $st -OtherPct 60 -Now $t0 -ServersOn $true @aa
    $b = Step-AutoAway -State $st -OtherPct 60 -Now $t0.AddMinutes(1) -ServersOn $true @aa
    $c = Step-AutoAway -State $st -OtherPct 60 -Now $t0.AddMinutes(2) -ServersOn $true @aa
    $a -eq '' -and $b -eq '' -and $c -eq 'away' -and $st['Away'] }
Check 'Step-AutoAway: a quiet sample restarts the count' {
    $st = @{}
    $null = Step-AutoAway -State $st -OtherPct 60 -Now $t0 -ServersOn $true @aa
    $null = Step-AutoAway -State $st -OtherPct 5 -Now $t0.AddMinutes(1) -ServersOn $true @aa
    (Step-AutoAway -State $st -OtherPct 60 -Now $t0.AddMinutes(2) -ServersOn $true @aa) -eq '' }
Check 'Step-AutoAway: a manual away (servers off) is left alone' {
    $st = @{}
    $null = Step-AutoAway -State $st -OtherPct 60 -Now $t0 -ServersOn $false @aa
    (Step-AutoAway -State $st -OtherPct 60 -Now $t0.AddMinutes(5) -ServersOn $false @aa) -eq '' -and -not $st['Away'] }
Check 'Step-AutoAway: back after BackAfter quiet minutes, not while still busy' {
    $st = @{ Away = $true; Since = $null }
    $a = Step-AutoAway -State $st -OtherPct 5 -Now $t0 -ServersOn $false @aa
    $b = Step-AutoAway -State $st -OtherPct 70 -Now $t0.AddMinutes(10) -ServersOn $false @aa
    $c = Step-AutoAway -State $st -OtherPct 5 -Now $t0.AddMinutes(11) -ServersOn $false @aa
    $d = Step-AutoAway -State $st -OtherPct 5 -Now $t0.AddMinutes(26) -ServersOn $false @aa
    $a -eq '' -and $b -eq '' -and $c -eq '' -and $d -eq 'back' -and -not $st['Away'] }

# ---- desktop away
$cfgA = [ordered]@{ AGENT_USER = 'hermes'; DESKTOP_LLAMA_DIR = 'C:\llama'; V100_ENABLED = '0'; NIGHT_ENABLED = '0'; V100_CUDA_DIR = 'C:\llama-cuda' }
Check 'Get-LlamaTaskNames: only the day server by default' { (Get-LlamaTaskNames -Cfg $cfgA) -join ',' -eq 'llama-server' }
$cfgB = [ordered]@{} + $cfgA; $cfgB['V100_ENABLED'] = '1'; $cfgB['NIGHT_ENABLED'] = '1'
Check 'Get-LlamaTaskNames: V100 and night tasks when those tiers are on' { (Get-LlamaTaskNames -Cfg $cfgB) -join ',' -eq 'llama-server,llama-v100,llama-night,llama-day' }
Check 'Get-LlamaServerDirs: the V100 folder only when the tier is on' { ((Get-LlamaServerDirs -Cfg $cfgA) -join ',') -eq 'C:\llama' -and ((Get-LlamaServerDirs -Cfg $cfgB) -join ',') -eq 'C:\llama,C:\llama-cuda' }
Check 'Get-LaptopDesktopCommand: off runs hermes-desktop as the agent user' { (Get-LaptopDesktopCommand -Cfg $cfgA -Action off) -ceq 'sudo -u hermes -H /home/hermes/.local/bin/hermes-desktop off' }
Check 'Get-LaptopDesktopCommand: off --for' { (Get-LaptopDesktopCommand -Cfg $cfgA -Action off -For 4h) -ceq 'sudo -u hermes -H /home/hermes/.local/bin/hermes-desktop off --for 4h' }
Check 'Get-LaptopDesktopCommand: on ignores -For' { (Get-LaptopDesktopCommand -Cfg $cfgA -Action on -For 4h) -ceq 'sudo -u hermes -H /home/hermes/.local/bin/hermes-desktop on' }
Check 'Get-LaptopDesktopCommand: a duration with shell text is refused' { Throws { Get-LaptopDesktopCommand -Cfg $cfgA -Action off -For '4h; reboot' } }
Check 'Get-LaptopDesktopCommand: a duration without a unit is refused' { Throws { Get-LaptopDesktopCommand -Cfg $cfgA -Action off -For '4' } }
$t0 = [datetime]'2026-10-03T12:00:00'
Check 'Get-AwayReturnTime: five minutes before the laptop (4h)' { (Get-AwayReturnTime -Now $t0 -For 4h) -eq [datetime]'2026-10-03T15:55:00' }
Check 'Get-AwayReturnTime: minutes and days' { (Get-AwayReturnTime -Now $t0 -For 90m) -eq [datetime]'2026-10-03T13:25:00' -and (Get-AwayReturnTime -Now $t0 -For 1d) -eq [datetime]'2026-10-04T11:55:00' }
Check 'Get-AwayReturnTime: never sooner than a minute from now' { (Get-AwayReturnTime -Now $t0 -For 3m) -eq [datetime]'2026-10-03T12:01:00' }
Check 'Get-AwayReturnTime: rejects a bad duration' { Throws { Get-AwayReturnTime -Now $t0 -For 'soon' } }
$stop = (New-StopLlamaScript -Dir 'C:\llama\') -join "`n"
Check 'New-StopLlamaScript: stops only the server in that folder' { $stop.Contains("-like 'C:\llama\*'") -and $stop.Contains("-like 'llama-server*'") -and -not $stop.Contains('taskkill') }
Check 'New-StopLlamaScript: no percent signs (cmd would eat them)' { -not $stop.Contains('%') }

# ---- V100 tier helpers
$cudaRels = @(
    (New-Rel 'b6' @('llama-b6-bin-win-cuda-13.4-x64.zip', 'cudart-llama-bin-win-cuda-13.4-x64.zip', 'llama-b6-bin-win-vulkan-x64.zip')),   # CUDA 13 only: no Volta
    (New-Rel 'b5' @('llama-b5-bin-win-cuda-12.4-x64.zip', 'llama-b5-bin-win-cuda-13.4-x64.zip')),                                          # no runtime bundle
    (New-Rel 'b4' @('llama-b4-bin-win-cuda-12.4-x64.zip', 'cudart-llama-bin-win-cuda-12.4-x64.zip', 'llama-b4-bin-win-cuda-13.4-x64.zip', 'cudart-llama-bin-win-cuda-13.4-x64.zip')))
$pick = Select-CudaRelease -Releases $cudaRels
Check 'Select-CudaRelease: skips CUDA 13 only and a release without the runtime bundle' { $pick.Release.tag_name -eq 'b4' }
Check 'Select-CudaRelease: returns the CUDA 12 zip and its own runtime bundle' { $pick.Main.name -eq 'llama-b4-bin-win-cuda-12.4-x64.zip' -and $pick.Runtime.name -eq 'cudart-llama-bin-win-cuda-12.4-x64.zip' -and $pick.CudaVersion -eq '12.4' }
Check 'Select-CudaRelease: prefers the highest 12.x' {
    $r = New-Rel 'b7' @('llama-b7-bin-win-cuda-12.4-x64.zip', 'cudart-llama-bin-win-cuda-12.4-x64.zip', 'llama-b7-bin-win-cuda-12.9-x64.zip', 'cudart-llama-bin-win-cuda-12.9-x64.zip')
    (Select-CudaRelease -Releases @($r)).CudaVersion -eq '12.9' }
Check 'Select-CudaRelease: nothing when only CUDA 13 exists' { $null -eq (Select-CudaRelease -Releases @($cudaRels[0])) }
Check 'Select-CudaRelease: skips a draft' { $null -eq (Select-CudaRelease -Releases @((New-Rel 'b8' @('llama-b8-bin-win-cuda-12.4-x64.zip', 'cudart-llama-bin-win-cuda-12.4-x64.zip') $true))) }

$smiText = "0, Tesla V100-SXM2-16GB, GPU-aaaa, 00000000:41:00.0, 16384, 200.00, 300.00, 100.00, 300.00, TCC, 582.78, 3, 4`n1, Tesla V100-SXM2-32GB, GPU-bbbb, 00000000:42:00.0, 32768, 300.00, 300.00, [N/A], [N/A], WDDM, 582.78, 3, 1`nnot a gpu line`n"
$g = Get-NvidiaGpus -Text $smiText
Check 'Get-NvidiaGpus: reads both cards' { $g.Count -eq 2 -and $g[0].Name -eq 'Tesla V100-SXM2-16GB' -and $g[1].MemoryMiB -eq 32768 }
Check 'Get-NvidiaGpus: reads power, driver model, driver version and the PCIe link' { $g[0].PowerLimitW -eq 200 -and $g[0].DriverModel -eq 'TCC' -and $g[0].DriverVersion -eq '582.78' -and $g[0].PcieGen -eq 3 -and $g[0].PcieWidth -eq 4 -and $g[1].PcieWidth -eq 1 }
Check 'Get-NvidiaGpus: [N/A] becomes nothing, not a crash' { $null -eq $g[1].PowerMinW -and $null -eq $g[1].PowerMaxW }
Check 'Get-NvidiaGpus: an error message is not a card' { (Get-NvidiaGpus -Text "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.").Count -eq 0 }
Check 'Get-NvidiaGpus: empty text' { (Get-NvidiaGpus -Text '').Count -eq 0 }
Check 'Get-V100PowerLimit: the request when it is inside the range' { (Get-V100PowerLimit -Gpu $g[0] -Requested 200) -eq 200 }
Check 'Get-V100PowerLimit: never above the card default' { (Get-V100PowerLimit -Gpu $g[0] -Requested 400) -eq 300 }
Check 'Get-V100PowerLimit: a low-power module (default 163 W, max 250 W) is never pushed past its default' {
    $ls = [pscustomobject]@{ PowerDefaultW = 163.0; PowerMinW = 100.0; PowerMaxW = 250.0 }
    (Get-V100PowerLimit -Gpu $ls -Requested 200) -eq 163 -and (Get-V100PowerLimit -Gpu $ls -Requested 120) -eq 120 }
Check 'Get-V100PowerLimit: not below the card minimum' { (Get-V100PowerLimit -Gpu $g[0] -Requested 50) -eq 100 }
Check 'Get-V100PowerLimit: 0 leaves the stock limit' { $null -eq (Get-V100PowerLimit -Gpu $g[0] -Requested 0) }
Check 'Get-V100PowerLimit: unknown limits (N/A) just pass the request through' { (Get-V100PowerLimit -Gpu $g[1] -Requested 220) -eq 220 }

function Fit($Name, [double]$Bytes, [double]$CardMiB, [int]$Gpus, [string]$Kv, [bool]$Mtp) {
    Get-V100Fit -FileBytes $Bytes -Context 131072 -ModelFile $Name -Gpus $Gpus -CardMiB $CardMiB -KvType $Kv -Mtp:$Mtp }
$q4 = 'Qwen3.8-27B-UD-Q4_K_XL.gguf'; $q5 = 'Qwen3.8-27B-UD-Q5_K_XL.gguf'
# the expected numbers are the fit table from the research (llama.cpp log arithmetic), to within rounding
Check 'Get-V100Fit: 27B UD-Q4_K_XL fits two 16 GB cards with MTP, +1.1 GiB spare' { $f = Fit $q4 17559178144 16384 2 q8_0 $true; $f.Verdict -eq 'fit' -and [math]::Abs($f.SpareGiB - 1.1) -le 0.15 -and $f.KnownModel }
Check 'Get-V100Fit: ...and +2.2 GiB without MTP (MTP costs about 1.1-1.3 GiB)' { [math]::Abs((Fit $q4 17559178144 16384 2 q8_0 $false).SpareGiB - 2.2) -le 0.15 }
Check 'Get-V100Fit: UD-Q5_K_XL on two 16 GB cards is TIGHT with MTP and fits without' { (Fit $q5 20876938144 16384 2 q8_0 $true).Verdict -eq 'tight' -and (Fit $q5 20876938144 16384 2 q8_0 $false).Verdict -eq 'fit' }
Check 'Get-V100Fit: one 32 GB card takes UD-Q5_K_XL (+4.8 GiB)' { [math]::Abs((Fit $q5 20876938144 32768 1 q8_0 $true).SpareGiB - 4.8) -le 0.15 }
Check 'Get-V100Fit: one 16 GB card cannot hold the 27B' { (Fit $q4 17559178144 16384 1 q8_0 $true).Verdict -eq 'no' }
Check 'Get-V100Fit: two 32 GB cards take UD-Q6_K_XL with room to spare' { $f = Fit 'Qwen3.8-27B-UD-Q6_K_XL.gguf' 25299061664 32768 2 q8_0 $true; $f.Verdict -eq 'fit' -and $f.SpareGiB -gt 12 }
Check 'Get-V100Fit: the 35B-A3B UD-Q4_K_XL fits two 16 GB cards with an f16 cache (+1.7), UD-Q5_K_XL is tight' { (Fit 'Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf' 22360456160 16384 2 f16 $false).Verdict -eq 'fit' -and (Fit 'Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf' 26592508896 16384 2 f16 $false).Verdict -eq 'tight' }
Check 'Get-V100Fit: the 35B-A3B has a much smaller context cache than the 27B' { (Fit 'Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf' 22360456160 32768 2 q8_0 $false).KvGiB -lt 1.5 -and (Fit $q4 17559178144 32768 2 q8_0 $false).KvGiB -gt 4 }
Check 'Get-V100Fit: free memory below the total shrinks the budget' { (Get-V100Fit -FileBytes 17559178144 -Context 131072 -ModelFile $q4 -Gpus 2 -CardMiB 16384 -FreeMiB 12288 -KvType q8_0).BudgetGiB -eq 11 }
Check 'Get-V100Fit: an unknown model is flagged and sized like the 27B' { $u = Get-V100Fit -FileBytes 10e9 -Context 65536 -ModelFile 'Some-Other.gguf' -Gpus 2 -CardMiB 16384 -KvType q8_0; (-not $u.KnownModel) -and $u.KvGiB -eq 2.12 }
Check 'Get-V100Family' { (Get-V100Family 'Qwen3.8-27B-x.gguf') -eq '27B' -and (Get-V100Family 'Qwen3.6-27B-x.gguf') -eq '27B' -and (Get-V100Family 'Qwen3.6-35B-A3B-x.gguf') -eq '35B' -and (Get-V100Family 'x.gguf') -eq '' }
Check 'Get-V100KvType: matched q8_0 for the 27B, f16 for the 35B-A3B and for tensor split' { (Get-V100KvType $q4) -eq 'q8_0' -and (Get-V100KvType 'Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf') -eq 'f16' -and (Get-V100KvType $q4 -SplitMode tensor) -eq 'f16' }
Check 'Get-V100QuantAdvice: the research table per VRAM class' { (Get-V100QuantAdvice -Count 2 -VramGB 16) -eq 'UD-Q4_K_XL' -and (Get-V100QuantAdvice -Count 1 -VramGB 32) -eq 'UD-Q5_K_XL' -and (Get-V100QuantAdvice -Count 2 -VramGB 32) -eq 'UD-Q6_K_XL' -and (Get-V100QuantAdvice -Count 1 -VramGB 16) -eq '' }

# Test-GgufMtp: a name cut by the 4 MB read boundary must still be found
$mtpFile = Join-Path $Tmp 'mtp.gguf'; $plainFile = Join-Path $Tmp 'plain.gguf'; $edgeFile = Join-Path $Tmp 'edge.gguf'
[System.IO.File]::WriteAllBytes($mtpFile, ([byte[]](71, 71, 85, 70)) + ([System.Text.Encoding]::ASCII.GetBytes('....blk.64.nextn.eh_proj.weight....')))
[System.IO.File]::WriteAllBytes($plainFile, ([byte[]](71, 71, 85, 70)) + ([System.Text.Encoding]::ASCII.GetBytes('....blk.39.ffn_down.weight....')))
$pad = New-Object byte[] (4MB - 3); [System.IO.File]::WriteAllBytes($edgeFile, $pad + [System.Text.Encoding]::ASCII.GetBytes('.nextn.x'))
Check 'Test-GgufMtp: finds the MTP tensors' { Test-GgufMtp $mtpFile }
Check 'Test-GgufMtp: a plain model has none' { -not (Test-GgufMtp $plainFile) }
Check 'Test-GgufMtp: finds a name cut by the read boundary' { Test-GgufMtp $edgeFile }
Check 'Test-GgufMtp: a missing file is not MTP' { -not (Test-GgufMtp (Join-Path $Tmp 'nope.gguf')) }

$cfgV = [ordered]@{} + $cfg
$cfgV['V100_ENABLED'] = '1'; $cfgV['V100_COUNT'] = '2'; $cfgV['V100_CUDA_DIR'] = 'C:\llama-cuda'; $cfgV['V100_MODEL_FILE'] = 'Qwen3.8-27B-UD-Q4_K_XL.gguf'; $cfgV['V100_MODEL_ALIAS'] = 'qwen3.8-27b'
$cfgV['V100_PORT'] = '8081'; $cfgV['V100_CTX'] = '131072'; $cfgV['V100_POWER_LIMIT_W'] = '200'; $cfgV['V100_SPLIT_MODE'] = 'layer'
$v100 = New-V100StartScript -Cfg $cfgV -Gpus $g
$vtext = $v100 -join "`n"
Check 'V100 start script: launches the CUDA server with the model and alias' { $vtext.Contains('C:\llama-cuda\llama-server.exe -m C:\models\Qwen3.8-27B-UD-Q4_K_XL.gguf --alias qwen3.8-27b ^') }
Check 'V100 start script: listens on the desktop address and its own port, key from the day server''s file' { $vtext.Contains('--host 192.168.1.100 --port 8081 --api-key-file C:\llama\api-key.txt ^') }
Check 'V100 start script: names the devices, layer split, fixed fit/batch, matched q8_0 context cache' { $vtext.Contains('--device CUDA0,CUDA1 --split-mode layer --jinja -ngl 99 -fit off -fa on -np 1 -ub 512 -c 131072 -ctk q8_0 -ctv q8_0 ^') }
Check 'V100 start script: never the f16/q8_0 mix (no compiled CUDA kernel)' { -not $vtext.Contains('-ctk f16 -ctv q8_0') }
Check 'V100 start script: the CUDA environment, graphs off for layer split' { $vtext.Contains('set CUDA_DEVICE_ORDER=PCI_BUS_ID') -and $vtext.Contains('set CUDA_SCALE_LAUNCH_QUEUES=4x') -and $vtext.Contains('set CUDA_CACHE_MAXSIZE=4294967296') -and $vtext.Contains('set GGML_CUDA_DISABLE_GRAPHS=1') }
Check 'V100 start script: sets the power limit on each card at every start (200 W)' { @($v100 | Where-Object { $_ -match 'nvidia-smi.exe" -i [01] -pl 200 >nul$' }).Count -eq 2 }
Check 'V100 start script: runs from the CUDA folder so no other backend is picked up' { $vtext.Contains('cd /d C:\llama-cuda') }
Check 'V100 start script: no --tensor-split, no --n-cpu-moe, no MTP unless asked' { -not $vtext.Contains('--tensor-split') -and -not $vtext.Contains(' -ts ') -and -not $vtext.Contains('n-cpu-moe') -and -not $vtext.Contains('draft-mtp') }
Check 'V100 start script: -Mtp adds speculative decoding' { ((New-V100StartScript -Cfg $cfgV -Gpus $g -Mtp) -join "`n").Contains('--spec-type draft-mtp --spec-draft-n-max 2 ^') }
Check 'V100 start script: every line of the command continues with ^ except the last' {
    $i = [array]::IndexOf($v100, ($v100 | Where-Object { $_ -like '*llama-server.exe -m*' } | Select-Object -First 1))
    (@($v100[$i..($v100.Count - 2)] | Where-Object { $_ -notmatch ' \^$' }).Count -eq 0) -and ($v100[-1] -notmatch '\^$') }
Check 'V100 start script (with MTP): every line of the command continues with ^ except the last' {
    $m = New-V100StartScript -Cfg $cfgV -Gpus $g -Mtp
    $i = [array]::IndexOf($m, ($m | Where-Object { $_ -like '*llama-server.exe -m*' } | Select-Object -First 1))
    (@($m[$i..($m.Count - 2)] | Where-Object { $_ -notmatch ' \^$' }).Count -eq 0) -and ($m[-1] -notmatch '\^$') }
$cfgW = [ordered]@{} + $cfgV; $cfgW['V100_POWER_LIMIT_W'] = '0'; $cfgW['V100_COUNT'] = '1'; $cfgW['V100_MODEL_FILE'] = 'Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf'
$v35 = (New-V100StartScript -Cfg $cfgW -Gpus @($g[0])) -join "`n"
Check 'V100 start script: power limit 0 sets nothing' { -not $v35.Contains('-pl ') }
Check 'V100 start script: the 35B-A3B gets an f16 cache and its own sampling and thinking flags' { $v35.Contains('--device CUDA0 ') -and $v35.Contains('-ctk f16 -ctv f16') -and $v35.Contains('preserve_thinking') -and $v35.Contains('--temp 0.6') }
Check 'V100 start script: the 27B uses the reasoning-effort flags' { $vtext.Contains('reasoning_effort') -and $vtext.Contains('--temp 1.0') }
$cfgT = [ordered]@{} + $cfgV; $cfgT['V100_SPLIT_MODE'] = 'tensor'
$vt = (New-V100StartScript -Cfg $cfgT -Gpus $g -Mtp) -join "`n"
Check 'V100 start script: tensor split uses an unquantized cache, keeps CUDA graphs, drops MTP' { $vt.Contains('--split-mode tensor') -and $vt.Contains('-ctk f16 -ctv f16') -and -not $vt.Contains('GGML_CUDA_DISABLE_GRAPHS') -and -not $vt.Contains('draft-mtp') }

$cfgG = [ordered]@{} + $cfg; $cfgG['V100_ENABLED'] = '1'
$guarded = New-LlamaStartScript -Cfg $cfgG -Tier Day
Check 'Vulkan day script: hides NVIDIA''s Vulkan driver while the V100 tier is on' { $guarded[0] -eq 'set VK_LOADER_DRIVERS_DISABLE=*nv*' -and $guarded[1].StartsWith('C:\llama\llama-server.exe') }
Check 'Vulkan day script: unchanged while the tier is off' { (New-LlamaStartScript -Cfg $cfg -Tier Day)[0].StartsWith('C:\llama\llama-server.exe') }
Check 'Vulkan night script: guarded too' { (New-LlamaStartScript -Cfg $cfgG -Tier Night)[0] -eq 'set VK_LOADER_DRIVERS_DISABLE=*nv*' }

$listText = "Available devices:`n  CUDA0: Tesla V100-SXM2-16GB (16384 MiB, 16000 MiB free)`n  CUDA1: Tesla V100-SXM2-16GB (16384 MiB, 16100 MiB free)`n  Vulkan0: AMD Radeon(TM) RX 6600 XT (8176 MiB, 8000 MiB free)`n"
$devs = Get-LlamaDevices -Text $listText
Check 'Get-LlamaDevices: parses CUDA and Vulkan lines' { $devs.Count -eq 3 -and $devs[0].Name -eq 'CUDA0' -and $devs[1].FreeMiB -eq 16100 -and $devs[2].Description -eq 'AMD Radeon(TM) RX 6600 XT' }
Check 'Get-LlamaDevices: "(none)" and empty text give no devices' { (Get-LlamaDevices -Text "Available devices:`n  (none)`n").Count -eq 0 -and (Get-LlamaDevices -Text '').Count -eq 0 }

Check 'Get-PnpProblemHelp: the codes a V100 build meets' { (Get-PnpProblemHelp 12) -match 'Above 4G' -and (Get-PnpProblemHelp 43) -match 'power cables' -and (Get-PnpProblemHelp 10) -match 'failed to start' -and (Get-PnpProblemHelp 28) -match 'no driver' -and (Get-PnpProblemHelp 0) -eq '' -and (Get-PnpProblemHelp 99) -match '99' }
Check 'Get-NvidiaPciDevices: an empty list where WMI is missing (not a crash)' { @(Get-NvidiaPciDevices).Count -ge 0 }

Write-Host "powershell helpers: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
