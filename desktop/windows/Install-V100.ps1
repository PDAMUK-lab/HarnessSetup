<#
.SYNOPSIS
  The optional V100 tier: a second llama-server (CUDA) on two (or more) Tesla V100 cards, beside the RX 6600 XT server.
.DESCRIPTION
  Run in an ADMINISTRATOR PowerShell, after Install-Llama.ps1 works and the cards are physically installed
  (docs\V100.md has the hardware checklist; .\Check-V100.ps1 checks the cards without changing anything).
  Needs V100_ENABLED=1 in config\node.env (this script offers to switch it on). Safe to re-run. It:
    - checks the NVIDIA data-center driver and that the cards are there, and sets the driver mode (TCC) and the power limit
    - downloads the llama.cpp CUDA 12 build (CUDA 13 builds have no Volta code) into its own folder and checks it sees the cards
    - downloads the model and checks it fits in the cards' memory
    - writes start-llama-v100.cmd, a firewall rule for the laptop only, and the 'llama-v100' scheduled task
    - keeps the Vulkan server on the RX 6600 XT, starts the V100 server and runs the tool-call smoke test
  The V100 server shares the API key of the day server (C:\llama\api-key.txt).
.EXAMPLE
  .\Install-V100.ps1 -DryRun            # show what would happen, change nothing
  .\Install-V100.ps1 -DownloadDriver    # fetch and verify NVIDIA's R580 data-center driver (you run it yourself)
  .\Install-V100.ps1 -IgnoreFit         # go on even if the memory estimate says the model will not fit
#>
[CmdletBinding()]
param(
    [string]$ConfigFile,
    [switch]$SkipModelDownload,
    [switch]$UpdateLlama,
    [switch]$NoStart,
    [switch]$DownloadDriver,
    [switch]$IgnoreFit,
    [switch]$DryRun,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsDryRun = [bool]$DryRun
$script:HsAssumeYes = [bool]$Yes
Assert-Admin
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
$cfg = Initialize-NodeConfig -Path $ConfigFile -Need 'LAPTOP_IP', 'DESKTOP_IP', 'LLM_PORT', 'V100_ENABLED'
if ($cfg['V100_ENABLED'] -ne '1') {
    # never flip a setting without a person saying yes
    if (-not (Test-Interactive) -or -not (Read-YesNo -Question 'The V100 tier is switched off in your settings. Turn it on now?' -Default $true)) {
        throw 'The V100 tier is off (V100_ENABLED=0). Run .\Configure.ps1 -Only V100_ENABLED to turn it on.'
    }
    Set-NodeSettings -Path $ConfigFile -Set 'V100_ENABLED=1'   # changes only that setting
    if (Test-Interactive) { Invoke-ConfigWizard -Path $ConfigFile -Scope desktop -Only 'V100_COUNT', 'V100_VRAM_GB', 'V100_QUANT' }
}
$need = 'DESKTOP_IP', 'LLM_PORT', 'LAPTOP_IP', 'DESKTOP_LLAMA_DIR', 'DESKTOP_MODELS_DIR', 'V100_COUNT', 'V100_VRAM_GB', 'V100_QUANT',
    'V100_MODEL_ALIAS', 'V100_MODEL_FILE', 'V100_MODEL_URL', 'V100_CTX', 'V100_PORT', 'V100_MTP', 'V100_SPLIT_MODE', 'V100_DRIVER_MODE', 'V100_POWER_LIMIT_W', 'V100_CUDA_DIR',
    'V100_CHAT_KWARGS', 'V100_SAMPLING', 'DESKTOP_CHAT_KWARGS', 'DESKTOP_SAMPLING'   # it rewrites the day (and night) start scripts too
$cfg = Initialize-NodeConfig -Path $ConfigFile -Need $need
Assert-Config $cfg $need
if ($cfg['V100_PORT'] -eq $cfg['LLM_PORT']) { throw "V100_PORT and LLM_PORT are both $($cfg['LLM_PORT']): the two servers need different ports (.\Configure.ps1 -Only V100_PORT)" }

$llama = $cfg['DESKTOP_LLAMA_DIR']
$cuda = $cfg['V100_CUDA_DIR']
$models = $cfg['DESKTOP_MODELS_DIR']
$count = [int]$cfg['V100_COUNT']
$keyFile = "$llama\api-key.txt"
$startCmd = "$cuda\start-llama-v100.cmd"
$base = "http://$($cfg['DESKTOP_IP']):$($cfg['V100_PORT'])"
if ($cuda.TrimEnd('\') -eq $llama.TrimEnd('\')) { throw "V100_CUDA_DIR and DESKTOP_LLAMA_DIR are the same folder ($llama): the CUDA and Vulkan builds must not share one." }
if (-not $script:HsDryRun -and -not (Test-Path "$llama\start-llama.cmd")) { throw "Run Install-Llama.ps1 first ($llama\start-llama.cmd is missing): it also creates the API key both servers share." }

if ($PSBoundParameters.ContainsKey('NoStart')) { $startNow = -not $NoStart }
else { $startNow = Read-YesNo -Question 'Start the V100 server when it is installed, and run the tool-call smoke test?' -Default $true }
if ((Test-Path "$cuda\llama-server.exe") -and -not $PSBoundParameters.ContainsKey('UpdateLlama')) {
    $UpdateLlama = Read-YesNo -Question "$cuda\llama-server.exe is already installed. Replace it with the newest CUDA 12 build?" -Default $false
}

# ---------------------------------------------------------------- the cards and the driver
Write-Step 'the NVIDIA driver and the cards'
$smi = Get-NvidiaSmiPath
if ($DownloadDriver) {
    $drv = $script:V100Driver
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "nvidia-data-center-$($drv.Version).exe"
    Invoke-Action "download NVIDIA data-center driver $($drv.Version) (R580, the last branch with the V100; about 700 MB) to $file and check its signature" {
        & curl.exe -L --fail --retry 3 -o $file $drv.Url
        if ($LASTEXITCODE -ne 0) { throw "download failed. Get the Tesla V100 / Windows driver from $($drv.Finder) (Data Center / Tesla > V-Series > Tesla V100) instead." }
        $sig = Get-AuthenticodeSignature -FilePath $file
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'NVIDIA Corporation') { throw "the downloaded file is not signed by NVIDIA ($($sig.Status)); deleting it is safest: $file" }
        Write-Ok "signature is valid (NVIDIA Corporation). Run it yourself: $file   (Express install, then reboot and re-run this script)"
    }
    return
}
if (-not $smi) {
    $pnp = Get-NvidiaPciDevices
    if ($script:HsDryRun) {
        Write-Warn 'no nvidia-smi here: a real run stops now unless the NVIDIA data-center driver is installed. Carrying on with the dry run.'
        $gpus = @(0..($count - 1) | ForEach-Object { [pscustomobject]@{ Index = $_; Name = 'Tesla V100 (dry run)'; Uuid = ''; BusId = ''; MemoryMiB = [double]([int]$cfg['V100_VRAM_GB'] * 1024); PowerLimitW = 300.0; PowerDefaultW = 300.0; PowerMinW = 100.0; PowerMaxW = 300.0; DriverModel = 'TCC'; DriverVersion = ''; PcieGen = 3.0; PcieWidth = 4.0 } })
    } elseif ($pnp.Count -gt 0) {
        throw "Found $($pnp.Count) NVIDIA card(s) but no driver (nvidia-smi.exe is missing). Install the Data Center driver $($script:V100Driver.Version) (NOT R590 or newer: they dropped the V100): .\Install-V100.ps1 -DownloadDriver fetches and verifies it, or use $($script:V100Driver.Finder)."
    } else {
        throw 'No NVIDIA card is visible to Windows. Power the PC off and check the cards: seating, the 12 V power cables, the fans, and the BIOS settings (Above 4G Decoding on, CSM off). docs\V100.md has the checklist; .\Check-V100.ps1 shows what Windows sees.'
    }
} else {
    $csv = Invoke-NativeText { & $smi "--query-gpu=$($script:V100QueryFields)" '--format=csv,noheader,nounits' }
    $all = Get-NvidiaGpus -Text $csv
    $gpus = @($all | Where-Object { $_.Name -match 'V100' })
}
if (-not $script:HsDryRun) {
    if ($gpus.Count -lt $count) { throw "Expected ${count} V100 card(s), nvidia-smi shows $($gpus.Count): $(($gpus | ForEach-Object { $_.Name }) -join ', '). Run .\Check-V100.ps1; set V100_COUNT to what is installed ( .\Configure.ps1 -Only V100_COUNT ) if that is right." }
}
if ($gpus.Count -gt $count) { Write-Warn "nvidia-smi shows $($gpus.Count) V100 cards but V100_COUNT is ${count}: only the first ${count} are used." }
$gpus = @($gpus | Select-Object -First $count)
foreach ($g in $gpus) {
    Write-Host ("    GPU {0}: {1}, {2:N0} MiB, {3}, PCIe gen {4} x{5}, power {6} W (range {7}-{8})" -f $g.Index, $g.Name, $g.MemoryMiB, $g.DriverModel, $g.PcieGen, $g.PcieWidth, $g.PowerLimitW, $g.PowerMinW, $g.PowerMaxW)
    if ($g.DriverVersion -match '^([0-9]+)\.' -and [int]$Matches[1] -ge 590) { Write-Warn "driver $($g.DriverVersion): R590 and newer dropped the V100. Install $($script:V100Driver.Version) (-DownloadDriver)." }
    if ($null -ne $g.PcieWidth -and $g.PcieWidth -lt 4) { Write-Warn "GPU $($g.Index) runs at PCIe x$($g.PcieWidth): fine for generation, but loading the model will be slow. Check the slot (docs\V100.md)." }
    $want = [int]$cfg['V100_VRAM_GB'] * 1024
    if ($null -ne $g.MemoryMiB -and [math]::Abs($g.MemoryMiB - $want) -gt 1024) { Write-Warn "GPU $($g.Index) has $($g.MemoryMiB) MiB but V100_VRAM_GB is $($cfg['V100_VRAM_GB']): fix the setting (.\Configure.ps1 -Only V100_VRAM_GB) so the fit check is right." }
}

# driver mode: TCC (or MCDM). Changing it needs a reboot; stop there so nothing else runs half-configured.
$wantMode = $cfg['V100_DRIVER_MODE']
$modeNumber = @{ TCC = 1; MCDM = 2 }[$wantMode]
$switch = @($gpus | Where-Object { $_.DriverModel -ne $wantMode -and -not $script:HsDryRun })
if ($switch.Count -gt 0) {
    Write-Warn "$($switch.Count) card(s) are not in $wantMode mode ($(($switch | ForEach-Object { "GPU $($_.Index): $($_.DriverModel)" }) -join ', '))."
    if (-not (Read-YesNo -Question "Switch them to $wantMode now? (needs a reboot afterwards)" -Default $true)) { throw "The cards must be in $wantMode mode. Run:  nvidia-smi -i <index> -dm $modeNumber  for each card, reboot, and re-run this script." }
    foreach ($g in $switch) {
        Invoke-Action "nvidia-smi -i $($g.Index) -dm $modeNumber  ($wantMode)" {
            $out = Invoke-NativeText { & $smi '-i' "$($g.Index)" '-dm' "$modeNumber" }
            Write-Host "    $out"
            if ($LASTEXITCODE -ne 0) { throw "nvidia-smi could not switch GPU $($g.Index) to $wantMode. If it says a display is attached, the card is the primary display: move the monitor to the RX 6600 XT." }
        }
    }
    Write-Host ''
    Write-Warn 'REBOOT now, then run this script again. Nothing else was changed.'
    return
}

# ---------------------------------------------------------------- llama.cpp, the CUDA build
Write-Step 'llama.cpp CUDA 12 build (CUDA 13 builds have no Volta code)'
Invoke-Action "create $cuda" { New-Item -ItemType Directory -Force -Path $cuda | Out-Null }
if ((Test-Path "$cuda\llama-server.exe") -and -not $UpdateLlama) {
    Write-Ok "llama-server.exe already in $cuda (use -UpdateLlama to replace it)"
} else {
    Invoke-Action 'download and extract the newest llama-*-bin-win-cuda-12.x-x64.zip and cudart-llama-bin-win-cuda-12.x-x64.zip' {
        $pick = Select-CudaRelease -Releases (Get-LlamaReleases)
        if (-not $pick) { throw 'None of the ten newest llama.cpp releases has a CUDA 12 Windows zip with its runtime bundle. Download both by hand from https://github.com/ggml-org/llama.cpp/releases, or build llama.cpp with a CUDA 12.x toolkit and -DCMAKE_CUDA_ARCHITECTURES=70.' }
        Write-Host "    $($pick.Release.tag_name): $($pick.Main.name) + $($pick.Runtime.name)"
        Stop-LlamaServer -Dir $cuda
        foreach ($a in $pick.Main, $pick.Runtime) {
            $zip = Join-Path $env:TEMP $a.name
            & curl.exe -L --fail -o $zip $a.browser_download_url
            if ($LASTEXITCODE -ne 0) { throw "download of $($a.name) failed" }
            Expand-Archive -Path $zip -DestinationPath $cuda -Force
            Remove-Item $zip
        }
        $exe = Get-ChildItem -Path $cuda -Recurse -Filter llama-server.exe | Select-Object -First 1
        if ($exe -and $exe.DirectoryName -ne $cuda) { Move-Item -Path "$($exe.DirectoryName)\*" -Destination $cuda -Force }
    }
}
Invoke-Action "llama-server.exe --list-devices ($count CUDA devices must be listed)" {
    $env:CUDA_DEVICE_ORDER = 'PCI_BUS_ID'
    $text = Get-LlamaDeviceList -Exe "$cuda\llama-server.exe"
    Write-Host $text
    $listed = Get-LlamaDevices -Text $text
    $devs = @($listed | Where-Object { $_.Name -like 'CUDA*' })
    if ($devs.Count -lt $count) {
        throw "llama.cpp sees $($devs.Count) CUDA device(s), expected $count. Release builds fail silently: check that cudart64_12.dll, cublas64_12.dll and cublasLt64_12.dll sit next to llama-server.exe in $cuda, that the driver is the data-center driver of the R580 branch, and that nvidia-smi lists the cards."
    }
    if (@($listed | Where-Object { $_.Name -like 'Vulkan*' }).Count -gt 0) { Write-Warn "$cuda also holds a Vulkan backend (ggml-vulkan.dll); the start script names its devices explicitly, but keep the two builds in separate folders." }
}

# ---------------------------------------------------------------- the model
Write-Step 'the model'
$modelPath = "$models\$($cfg['V100_MODEL_FILE'])"
$split = $cfg['V100_SPLIT_MODE']
$kvType = Get-V100KvType -ModelFile $cfg['V100_MODEL_FILE'] -SplitMode $split
$wantMtp = ($cfg['V100_MTP'] -eq '1') -and ($split -ne 'tensor')
$cardMiB = ($gpus | Measure-Object -Property MemoryMiB -Minimum).Minimum
$advice = Get-V100QuantAdvice -Count $gpus.Count -VramGB ([int]$cfg['V100_VRAM_GB'])
function Show-Fit([double]$Bytes, [bool]$Mtp) {
    $fit = Get-V100Fit -FileBytes $Bytes -Context ([int]$cfg['V100_CTX']) -ModelFile $cfg['V100_MODEL_FILE'] -Gpus $gpus.Count -CardMiB $cardMiB -KvType $kvType -Mtp:$Mtp
    Write-Host ("    estimate for the busiest card: {0} GiB needed of {1} GiB usable ({2:+0.0;-0.0} GiB spare): {3} - model {4:N1} GB, context cache {5} GiB ({6}){7}" -f $fit.NeededGiB, $fit.BudgetGiB, $fit.SpareGiB, $fit.Verdict.ToUpper(), ($Bytes / 1e9), $fit.KvGiB, $kvType, $(if ($Mtp) { ', MTP on' } else { '' }))
    if (-not $fit.KnownModel) { Write-Warn 'the estimate assumes a Qwen3.x 27B-class model; for another model it is only a guide. The server log prints the real memory use.' }
    return $fit
}
function Test-FitAllowed($Fit) {
    if ($Fit.Verdict -eq 'fit') { return }
    $hint = if ($advice) { " For $($gpus.Count) x $($cfg['V100_VRAM_GB']) GB the table recommends $advice at 128K context." } else { '' }
    if ($Fit.Verdict -eq 'tight') { Write-Warn "this is tight: it may run out of memory at long contexts.$hint" }
    elseif ($IgnoreFit) { Write-Warn "this will probably not fit, but -IgnoreFit was given.$hint" }
    else { throw "This model will probably not fit in the cards' memory.$hint Choose a smaller quantization or a shorter context (.\Configure.ps1 -Only V100_QUANT,V100_CTX), or add -IgnoreFit to try anyway." }
}
$size = $null
if (Test-Path -LiteralPath $modelPath) { $size = (Get-Item -LiteralPath $modelPath).Length }
elseif (-not $script:HsDryRun) { $size = Get-RemoteFileSize -Url $cfg['V100_MODEL_URL'] }
if ($size) { Test-FitAllowed (Show-Fit -Bytes $size -Mtp $wantMtp) }
if (-not $SkipModelDownload) {
    Invoke-Action 'check free disk space on the models drive' {
        $drive = (Get-Item $models).PSDrive
        $need = if ($size) { [double]$size * 1.1 + 2GB } else { 45GB }
        if ($drive.Free -lt $need) { throw "Only $([math]::Round($drive.Free / 1GB)) GB free on $($drive.Name):, the model needs about $([math]::Round($need / 1GB)) GB." }
    }
    Save-Model -Url $cfg['V100_MODEL_URL'] -Dest $modelPath
}
$useMtp = $wantMtp
if ((Test-Path -LiteralPath $modelPath) -and $wantMtp) {
    $useMtp = Test-GgufMtp -Path $modelPath
    if (-not $useMtp) { Write-Warn "this model file has no MTP head (only the Qwen3.8-27B files do), so speculative decoding is left off. Set V100_MTP=0 to silence this." }
    if ($size) { $null = Show-Fit -Bytes ((Get-Item -LiteralPath $modelPath).Length) -Mtp $useMtp }
}

# ---------------------------------------------------------------- start script, Vulkan guard, firewall, task
Write-Step 'start-llama-v100.cmd'
Write-CmdFile -Path $startCmd -Lines (New-V100StartScript -Cfg $cfg -Gpus $gpus -Mtp:$useMtp)
Write-Ok "wrote $startCmd ($split split over $count cards, $kvType context cache, $(if ($useMtp) { 'MTP on' } else { 'no MTP' }), power limit $($cfg['V100_POWER_LIMIT_W']) W per card)"

Write-Step 'keep the Vulkan server on the RX 6600 XT'
$cfg['V100_ENABLED'] = '1'
Write-CmdFile -Path "$llama\start-llama.cmd" -Lines (New-LlamaStartScript -Cfg $cfg -Tier Day)
if ($cfg['NIGHT_ENABLED'] -eq '1' -and (Test-Path "$llama\start-llama-27b.cmd")) { Write-CmdFile -Path "$llama\start-llama-27b.cmd" -Lines (New-LlamaStartScript -Cfg $cfg -Tier Night) }
Invoke-Action 'check the Vulkan build lists no NVIDIA card (with the NVIDIA Vulkan driver hidden from it)' {
    $vk = Get-LlamaDeviceList -Exe "$llama\llama-server.exe" -Env @{ VK_LOADER_DRIVERS_DISABLE = '*nv*' }
    if ($vk -match '(?i)tesla|v100|nvidia') { Write-Warn "the Vulkan server still sees an NVIDIA card:`n$vk`nIt would spread its layers over the V100s. Add --device Vulkan<N> (the RX 6600 XT's number from the list) to $llama\start-llama.cmd." }
    else { Write-Ok 'the Vulkan server sees only the RX 6600 XT' }
}
Write-Host "    The day server needs a restart to pick this up (Desktop-Mode.ps1 away, then back, or restart the 'llama-server' task)."

Write-Step 'Windows firewall - only the laptop may reach the V100 port'
$ruleName = "llama-server $($cfg['V100_PORT']) (laptop only)"
Invoke-Action "firewall rule '$ruleName' from $($cfg['LAPTOP_IP'])" {
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $cfg['V100_PORT'] -Action Allow -RemoteAddress $cfg['LAPTOP_IP'] | Out-Null
}

Write-Step 'start at logon'
Invoke-Action "scheduled task 'llama-v100' (at logon, highest privileges, no time limit)" {
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$startCmd`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'llama-v100' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

if ($startNow) {
    Write-Step 'start the V100 server and run the tool-call smoke test'
    Invoke-Action "start the 'llama-v100' task and wait for $base/health" {
        Stop-ScheduledTask -TaskName 'llama-v100' -ErrorAction SilentlyContinue
        Stop-LlamaServer -Dir $cuda
        Start-ScheduledTask -TaskName 'llama-v100'
        $key = (Get-Content $keyFile -Raw).Trim()
        Write-Host '    loading the model. The FIRST start is slow: the driver compiles the CUDA code for the V100 once (do not stop it).'
        if (-not (Wait-Http -Url "$base/health" -Seconds 1500 -Headers @{ Authorization = "Bearer $key" })) {
            throw "the V100 server did not come up on $base. Run $startCmd by hand to read the error. 'out of memory' means a smaller V100_QUANT or V100_CTX; 'no kernel image' means a CUDA 13 build or a wrong driver."
        }
        Write-Ok "$base/health answers"
        if (Test-ToolCall -BaseUrl $base -Model $cfg['V100_MODEL_ALIAS'] -ApiKey $key) { Write-Ok 'tool calls work (get_weather came back as a tool call)' }
        else { Write-Warn 'no tool call came back; the server must run with --jinja (start-llama-v100.cmd does).' }
    }
}

Write-Host ''
Write-Host 'The V100 server is set up. Idle, each card draws about 40 W; Desktop-Mode.ps1 away stops the servers when you need the desktop.' -ForegroundColor Green
Write-Host 'Next, on the laptop:   ./setup.sh run 13   (opens the port in the laptop firewall)'
Write-Host '                       ./setup.sh tool v100-laptop   (adds the endpoint to Hermes and puts it first)'
