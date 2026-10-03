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
Check 'Night: partial GPU offload (-ngl 24), no --n-cpu-moe' { ($night -join "`n") -match '-ngl 24' -and ($night -join "`n") -notmatch 'n-cpu-moe' }
Check 'Night: reasoning effort high' { ($night -join "`n").Contains('--chat-template-kwargs "{\"reasoning_effort\":\"high\"}"') }
Check 'Night: temp 1.0 and MTP speculative decoding' { ($night -join "`n") -match '--temp 1\.0' -and ($night -join "`n") -match '--spec-type draft-mtp --spec-draft-n-max 2' }
Check 'Night: every line but the last continues with ^' { (@($night[0..($night.Count - 2)] | Where-Object { $_ -notmatch ' \^$' }).Count -eq 0) -and ($night[-1] -notmatch '\^$') }
$cfg2 = [ordered]@{} + $cfg; $cfg2['DESKTOP_N_CPU_MOE'] = '32'
Check 'settings flow through (-n-cpu-moe 32)' { (New-LlamaStartScript -Cfg $cfg2 -Tier Day)[2] -match '--n-cpu-moe 32 ' }

# ---- Write-CmdFile / New-TunnelCmd
Write-CmdFile -Path "$Tmp/t.cmd" -Lines (New-TunnelCmd -Cfg $cfg)
$raw = [System.IO.File]::ReadAllBytes("$Tmp/t.cmd")
Check 'cmd file uses CRLF line endings' { ([System.Text.Encoding]::ASCII.GetString($raw) -split "`r`n").Count -ge 4 -and ([System.Text.Encoding]::ASCII.GetString($raw) -notmatch "[^`r]`n") }
Check 'cmd file has no BOM' { $raw[0] -ne 0xEF -and $raw[0] -ne 0xFF }
$tun = (New-TunnelCmd -Cfg $cfg) -join "`n"
Check 'tunnel uses 9119 on both ends and the laptop address' { $tun.Contains('-L 9119:127.0.0.1:9119 ai-node@192.168.1.150') }
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

Write-Host "powershell helpers: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
