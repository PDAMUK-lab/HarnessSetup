<#
.SYNOPSIS
  Is the desktop's model server set up and healthy? Prints PASS / FAIL / WARN per check. No admin needed.
.EXAMPLE
  .\Check-Desktop.ps1
  .\Check-Desktop.ps1 -ToolCall      # also run the (slow) tool-call smoke test
#>
[CmdletBinding()]
param([string]$ConfigFile, [switch]$ToolCall, [switch]$Yes)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsAssumeYes = [bool]$Yes
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
$cfg = Initialize-NodeConfig -Path $ConfigFile -Need 'LAPTOP_IP', 'DESKTOP_IP', 'LLM_PORT', 'DESKTOP_MODEL_FILE', 'DESKTOP_MODEL_ALIAS', 'DESKTOP_LLAMA_DIR', 'DESKTOP_MODELS_DIR'
$ToolCall = Resolve-Option -Bound $PSBoundParameters -Name ToolCall -Current ([bool]$ToolCall) -Default $false `
    -Question 'Also run the tool-call smoke test? (slow: it makes the model think)'
$llama = $cfg['DESKTOP_LLAMA_DIR']
$models = $cfg['DESKTOP_MODELS_DIR']
$script:fails = 0
function Show([string]$Tag, [string]$Text) {
    $color = @{ PASS = 'Green'; FAIL = 'Red'; WARN = 'Yellow' }[$Tag]
    Write-Host ('{0,-5} {1}' -f $Tag, $Text) -ForegroundColor $color
    if ($Tag -eq 'FAIL') { $script:fails++ }
}
function Check([bool]$Ok, [string]$Text, [string]$Tag = 'FAIL') { if ($Ok) { Show 'PASS' $Text } else { Show $Tag $Text } }

Check (Test-Path "$llama\llama-server.exe") "llama-server.exe in $llama"
Check (Test-GgufFile "$models\$($cfg['DESKTOP_MODEL_FILE'])") "model file is a valid GGUF: $($cfg['DESKTOP_MODEL_FILE'])"
Check (Test-Path "$llama\start-llama.cmd") 'start-llama.cmd exists'
$hasKey = Test-Path "$llama\api-key.txt"
Check $hasKey 'API key file exists'
Check ($null -ne (Get-ScheduledTask -TaskName 'llama-server' -ErrorAction SilentlyContinue)) "scheduled task 'llama-server' exists (starts at logon)"
$rule = Get-NetFirewallRule -DisplayName "llama-server $($cfg['LLM_PORT']) (laptop only)" -ErrorAction SilentlyContinue
Check ($null -ne $rule) 'firewall rule exists'
if ($rule) {
    $addr = ($rule | Get-NetFirewallAddressFilter).RemoteAddress
    Check ($addr -eq $cfg['LAPTOP_IP']) "firewall rule allows only the laptop ($addr)"
}
if ($cfg['NIGHT_ENABLED'] -eq '1') {
    Check ($null -ne (Get-ScheduledTask -TaskName 'llama-night' -ErrorAction SilentlyContinue)) "overnight task 'llama-night' exists"
    Check ($null -ne (Get-ScheduledTask -TaskName 'llama-day' -ErrorAction SilentlyContinue)) "overnight task 'llama-day' exists"
}
if ($hasKey) {
    $key = (Get-Content "$llama\api-key.txt" -Raw).Trim()
    $base = "http://$($cfg['DESKTOP_IP']):$($cfg['LLM_PORT'])"
    $up = Wait-Http -Url "$base/health" -Seconds 6 -Headers @{ Authorization = "Bearer $key" }
    Check $up "server answers on $base (needs the API key)"
    if ($up) {
        $noKey = $true
        try { Invoke-WebRequest -Uri "$base/health" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch { $noKey = $false }
        Check (-not $noKey) 'a request WITHOUT the key is refused' 'WARN'
        $served = (Invoke-RestMethod -Uri "$base/v1/models" -Headers @{ Authorization = "Bearer $key" }).data[0].id
        Check ($served -eq $cfg['DESKTOP_MODEL_ALIAS']) "serving '$served' (daytime expects $($cfg['DESKTOP_MODEL_ALIAS']))" 'WARN'
        if ($ToolCall) { Check (Test-ToolCall -BaseUrl $base -Model $served -ApiKey $key) 'tool-call smoke test' }
    }
}
$os = Get-CimInstance Win32_OperatingSystem
$usedPct = [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize))
Check ($usedPct -lt 90) "memory use is $usedPct% (stay under ~90% at Q5, or switch to UD-Q4_K_XL)" 'WARN'
Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'No failures.' -ForegroundColor Green }
