<#
.SYNOPSIS
  Are the V100 cards ready (and, once installed, is their server healthy)? Prints PASS / FAIL / WARN per check. Changes nothing.
.DESCRIPTION
  Run it right after you install the cards, before turning the tier on: it needs no settings file and no administrator rights.
  It checks that Windows sees the cards, the driver is the right one, the driver mode, the PCIe link, the temperature and the
  power limit. When the tier is installed (V100_ENABLED=1) it also checks the CUDA build, the Vulkan server's isolation, the
  firewall rule, the scheduled task and the server itself.
.EXAMPLE
  .\Check-V100.ps1
#>
[CmdletBinding()]
param([string]$ConfigFile, [switch]$Yes)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsAssumeYes = [bool]$Yes
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
if (Test-Path -LiteralPath $ConfigFile) { $cfg = Get-EffectiveConfig -Path $ConfigFile }
else {
    # no settings yet: the defaults answer the questions that matter before the tier is installed
    $cfg = [ordered]@{ V100_ENABLED = '0'; V100_COUNT = '2'; V100_VRAM_GB = '16'; V100_DRIVER_MODE = 'TCC'; V100_POWER_LIMIT_W = '200'; V100_PORT = '8081'; V100_CUDA_DIR = 'C:\llama-cuda'; DESKTOP_LLAMA_DIR = 'C:\llama'; V100_MODEL_FILE = '' }
}
$expect = [int]$cfg['V100_COUNT']
$script:fails = 0
function Show([string]$Tag, [string]$Text) {
    $color = @{ PASS = 'Green'; FAIL = 'Red'; WARN = 'Yellow'; INFO = 'Cyan' }[$Tag]
    Write-Host ('{0,-5} {1}' -f $Tag, $Text) -ForegroundColor $color
    if ($Tag -eq 'FAIL') { $script:fails++ }
}
function Check([bool]$Ok, [string]$Text, [string]$Tag = 'FAIL') { if ($Ok) { Show 'PASS' $Text } else { Show $Tag $Text } }

Write-Step 'Windows and the driver'
if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
    $pnp = Get-NvidiaPciDevices
    Check ($pnp.Count -ge $expect) "Windows sees $($pnp.Count) NVIDIA Volta card(s) on the PCIe bus (expected $expect)"
    foreach ($d in $pnp) {
        if ($d.ErrorCode -ne 0) { Show 'FAIL' "$($d.Name): Device Manager problem $($d.ErrorCode) - $(Get-PnpProblemHelp -Code $d.ErrorCode)" }
    }
} else { Show 'INFO' 'device enumeration is not available in this shell (run it on Windows)' }
$smi = Get-NvidiaSmiPath
Check ($null -ne $smi) "the NVIDIA driver is installed (nvidia-smi.exe found); wanted: Data Center driver $($script:V100Driver.Version), the last branch with the V100"
$gpus = @()
if ($smi) {
    $csv = Invoke-NativeText { & $smi "--query-gpu=$($script:V100QueryFields)" '--format=csv,noheader,nounits' }
    $all = Get-NvidiaGpus -Text $csv
    $gpus = @($all | Where-Object { $_.Name -match 'V100' })
    Check ($gpus.Count -ge $expect) "nvidia-smi lists $($gpus.Count) V100 card(s) (expected $expect)"
    foreach ($g in $gpus) {
        $label = "GPU $($g.Index) ($($g.Name))"
        $want = [int]$cfg['V100_VRAM_GB'] * 1024
        Check ([math]::Abs($g.MemoryMiB - $want) -le 1024) "$label has $($g.MemoryMiB) MiB (V100_VRAM_GB=$($cfg['V100_VRAM_GB']))" 'WARN'
        Check ($g.DriverModel -eq $cfg['V100_DRIVER_MODE']) "$label driver mode is $($g.DriverModel) (wanted $($cfg['V100_DRIVER_MODE']); Install-V100.ps1 switches it)" 'WARN'
        $major = 0; if ($g.DriverVersion -match '^([0-9]+)\.') { $major = [int]$Matches[1] }
        Check ($major -lt 590) "$label driver $($g.DriverVersion) still supports the V100 (R590 and newer do not)"
        Check ($major -ge 551) "$label driver $($g.DriverVersion) is new enough for CUDA 12.4 builds (551.61 or later)" 'WARN'
        $okLink = ($null -ne $g.PcieGen -and $null -ne $g.PcieWidth -and $g.PcieGen -ge 3 -and $g.PcieWidth -ge 4)
        Check $okLink "$label PCIe link gen $($g.PcieGen) x$($g.PcieWidth) (gen 3 x4 or better is plenty for generation; slower only loads the model slower)" 'WARN'
        if ($null -ne $g.PowerLimitW) { Show 'INFO' "$label power limit $($g.PowerLimitW) W (card range $($g.PowerMinW)-$($g.PowerMaxW) W, V100_POWER_LIMIT_W=$($cfg['V100_POWER_LIMIT_W']) is applied at every server start)" }
    }
    $live = Invoke-NativeText { & $smi '--query-gpu=index,temperature.gpu,power.draw' '--format=csv,noheader,nounits' }
    foreach ($line in ($live -split "`r?`n")) {
        $f = @($line -split ',\s*')
        if ($f.Count -ge 3 -and $f[0] -match '^[0-9]+$' -and $f[1] -match '^[0-9]+$') {
            Check ([int]$f[1] -lt 85) "GPU $($f[0]) is $($f[1]) C at $($f[2]) W (an SXM2 module has no fan of its own: it needs a blower or fan kit)" 'WARN'
        }
    }
}
if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
    $vc = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'AMD|Radeon' })
    Check ($vc.Count -ge 1) 'the AMD Radeon (the display and day-server card) is present' 'WARN'
}

if ($cfg['V100_ENABLED'] -eq '1') {
    Write-Step 'the V100 server'
    $cuda = $cfg['V100_CUDA_DIR']; $llama = $cfg['DESKTOP_LLAMA_DIR']
    Check (Test-Path "$cuda\llama-server.exe") "CUDA llama-server.exe in $cuda"
    Check (Test-Path "$cuda\cudart64_12.dll") 'the CUDA 12 runtime DLLs are next to it (cudart64_12.dll)'
    if (Test-Path "$cuda\llama-server.exe") {
        $text = Get-LlamaDeviceList -Exe "$cuda\llama-server.exe"
        $listed = Get-LlamaDevices -Text $text
        $cudaDevs = @($listed | Where-Object { $_.Name -like 'CUDA*' })
        Check ($cudaDevs.Count -ge $expect) "llama.cpp lists $($cudaDevs.Count) CUDA device(s) (expected $expect)"
    }
    Check (Test-Path "$cuda\start-llama-v100.cmd") 'start-llama-v100.cmd exists'
    if ($cfg['V100_MODEL_FILE']) { Check (Test-GgufFile "$($cfg['DESKTOP_MODELS_DIR'])\$($cfg['V100_MODEL_FILE'])") "model file is a valid GGUF: $($cfg['V100_MODEL_FILE'])" }
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        Check ($null -ne (Get-ScheduledTask -TaskName 'llama-v100' -ErrorAction SilentlyContinue)) "scheduled task 'llama-v100' exists (starts at logon)"
        $rule = Get-NetFirewallRule -DisplayName "llama-server $($cfg['V100_PORT']) (laptop only)" -ErrorAction SilentlyContinue
        Check ($null -ne $rule) 'firewall rule for the V100 port exists'
        if ($rule) { $addr = ($rule | Get-NetFirewallAddressFilter).RemoteAddress; Check ($addr -eq $cfg['LAPTOP_IP']) "firewall rule allows only the laptop ($addr)" }
    }
    if (Test-Path "$llama\llama-server.exe") {
        $vk = Get-LlamaDeviceList -Exe "$llama\llama-server.exe" -Env @{ VK_LOADER_DRIVERS_DISABLE = '*nv*' }
        Check (-not ($vk -match '(?i)tesla|v100')) 'the Vulkan day server does not see the V100 cards (its start script hides the NVIDIA Vulkan driver)'
    }
    $keyFile = "$llama\api-key.txt"
    if (Test-Path $keyFile) {
        $key = (Get-Content $keyFile -Raw).Trim()
        $base = "http://$($cfg['DESKTOP_IP']):$($cfg['V100_PORT'])"
        $up = Wait-Http -Url "$base/health" -Seconds 6 -Headers @{ Authorization = "Bearer $key" }
        Check $up "the V100 server answers on $base (needs the API key)" 'WARN'
        if ($up) {
            $served = (Invoke-RestMethod -Uri "$base/v1/models" -Headers @{ Authorization = "Bearer $key" }).data[0].id
            Check ($served -eq $cfg['V100_MODEL_ALIAS']) "serving '$served' (expected $($cfg['V100_MODEL_ALIAS']))" 'WARN'
        }
    }
} else {
    Show 'INFO' 'the V100 tier is not switched on yet (V100_ENABLED=0). When these checks pass: .\Install-V100.ps1'
}
Write-Host ''
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'No failures.' -ForegroundColor Green }
