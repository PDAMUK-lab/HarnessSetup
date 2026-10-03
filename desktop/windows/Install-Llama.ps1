<#
.SYNOPSIS
  Steps 19 and 20: the desktop's llama.cpp server (Vulkan build) with Qwen3.6-35B-A3B.
.DESCRIPTION
  Run in an ADMINISTRATOR PowerShell. Safe to re-run (it skips what is already in place):
    - downloads the latest llama.cpp Vulkan build to C:\llama and checks it sees the GPU
    - downloads the model (about 27GB), verifying it is really a GGUF file
    - creates a random API key in C:\llama\api-key.txt (readable only by you and administrators)
    - writes C:\llama\start-llama.cmd (key read from the file, not on the command line)
    - allows ONLY the laptop through the Windows firewall to the model port
    - registers the 'llama-server' scheduled task (starts at logon, no 72-hour time limit)
    - starts it and runs the tool-call smoke test
  The API key is printed once at the end: you paste it into the laptop's stage 11.
.EXAMPLE
  .\Install-Llama.ps1
  .\Install-Llama.ps1 -DryRun           # show what would happen, change nothing
  .\Install-Llama.ps1 -UpdateLlama      # replace C:\llama with the newest build
  .\Install-Llama.ps1 -NeverSleepOnAC   # Windows never sleeps while on mains power
#>
[CmdletBinding()]
param(
    [string]$ConfigFile,
    [switch]$SkipModelDownload,
    [switch]$UpdateLlama,
    [switch]$NeverSleepOnAC,
    [switch]$NoStart,
    [switch]$ShowKey,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsDryRun = [bool]$DryRun
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
$cfg = Read-NodeEnv $ConfigFile
Assert-Config $cfg 'LAPTOP_IP', 'DESKTOP_IP', 'LLM_PORT', 'DESKTOP_MODEL_FILE', 'DESKTOP_MODEL_URL', 'DESKTOP_MODEL_ALIAS',
    'DESKTOP_CTX', 'DESKTOP_N_CPU_MOE', 'DESKTOP_CACHE_RAM_MB', 'DESKTOP_LLAMA_DIR', 'DESKTOP_MODELS_DIR'
Assert-Admin

$llama = $cfg['DESKTOP_LLAMA_DIR']
$models = $cfg['DESKTOP_MODELS_DIR']
$keyFile = "$llama\api-key.txt"
$startCmd = "$llama\start-llama.cmd"
$base = "http://$($cfg['DESKTOP_IP']):$($cfg['LLM_PORT'])"

if ($ShowKey) {
    if (-not (Test-Path $keyFile)) { throw "No key yet: $keyFile" }
    Write-Host (Get-Content $keyFile -Raw)
    return
}

Write-Step 'folders'
Invoke-Action "create $llama and $models" { New-Item -ItemType Directory -Force -Path $llama, $models | Out-Null }

Write-Step 'Step 19.2: llama.cpp (Vulkan build, needs no CUDA or ROCm)'
if ((Test-Path "$llama\llama-server.exe") -and -not $UpdateLlama) {
    Write-Ok "llama-server.exe already in $llama (use -UpdateLlama to replace it)"
} else {
    Invoke-Action 'download and extract the latest llama-*-bin-win-vulkan-x64.zip' {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest' -Headers @{ 'User-Agent' = 'HarnessSetup' }
        $asset = Select-VulkanAsset $rel.assets
        $zip = Join-Path $env:TEMP $asset.name
        Write-Host "    $($rel.tag_name): $($asset.name)"
        & curl.exe -L --fail -o $zip $asset.browser_download_url
        if ($LASTEXITCODE -ne 0) { throw 'download of the llama.cpp zip failed' }
        Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
        Expand-Archive -Path $zip -DestinationPath $llama -Force
        Remove-Item $zip
        # some zips unpack into a subfolder: move the binaries up to $llama
        $exe = Get-ChildItem -Path $llama -Recurse -Filter llama-server.exe | Select-Object -First 1
        if ($exe -and $exe.DirectoryName -ne $llama) { Move-Item -Path "$($exe.DirectoryName)\*" -Destination $llama -Force }
    }
}
Invoke-Action 'llama-cli.exe --list-devices (the RX 6600 XT must be listed)' {
    $devices = & "$llama\llama-cli.exe" --list-devices 2>&1 | Out-String
    if ($LASTEXITCODE -eq -1073741515) { throw 'llama-cli.exe will not start: install the latest Microsoft Visual C++ Redistributable (x64), then re-run.' }
    Write-Host $devices
    if ($devices -notmatch '6600') { Write-Warn 'no RX 6600 XT in the device list. Install the current AMD Adrenalin driver (Step 19.1) and re-run.' }
}

Write-Step 'Step 19.3: the model'
if (-not $SkipModelDownload) {
    Invoke-Action "check free disk space on the models drive" {
        $drive = (Get-Item $models).PSDrive
        if ($drive.Free -lt 32GB) { throw "Only $([math]::Round($drive.Free / 1GB)) GB free on $($drive.Name):, the model needs about 27 GB plus working space." }
    }
    Save-Model -Url $cfg['DESKTOP_MODEL_URL'] -Dest "$models\$($cfg['DESKTOP_MODEL_FILE'])"
}

Write-Step 'Step 19.4: API key'
$newKey = $false
if (Test-Path $keyFile) {
    Write-Ok "keeping the existing key in $keyFile"
} else {
    Invoke-Action "create $keyFile (random 256-bit key, readable only by you and administrators)" {
        [System.IO.File]::WriteAllText($keyFile, (New-ApiKey), [System.Text.Encoding]::ASCII)
        & icacls.exe $keyFile /inheritance:r /grant:r "${env:USERNAME}:(R)" 'BUILTIN\Administrators:(F)' | Out-Null
    }
    $newKey = $true
}

Write-Step 'Step 19.5: start-llama.cmd'
Write-CmdFile -Path $startCmd -Lines (New-LlamaStartScript -Cfg $cfg -Tier Day)
Write-Ok "wrote $startCmd"
Write-Host "    --n-cpu-moe $($cfg['DESKTOP_N_CPU_MOE']) keeps every layer's experts in RAM (safe start). Tune it as in guide Step 19:"
Write-Host '    lower it until Task Manager > GPU > Dedicated GPU memory sits near 7.3 GB, and keep Memory under ~90%.'
if (Test-Path "$llama\llama-fit-params.exe") { Write-Host "    This build has llama-fit-params.exe: run it with the same model and -c $($cfg['DESKTOP_CTX']) and use the placement it suggests." }

Write-Step 'Step 19.6: Windows firewall - only the laptop may reach the model port'
$ruleName = "llama-server $($cfg['LLM_PORT']) (laptop only)"
Invoke-Action "firewall rule '$ruleName' from $($cfg['LAPTOP_IP'])" {
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $cfg['LLM_PORT'] `
        -Action Allow -RemoteAddress $cfg['LAPTOP_IP'] | Out-Null
}

Write-Step 'Step 19.7: start at logon'
Invoke-Action "scheduled task 'llama-server' (at logon, highest privileges, no time limit)" {
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$startCmd`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
    # The default task time limit is 72 hours, which would silently kill the server every third day.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName 'llama-server' -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force | Out-Null
}

if ($NeverSleepOnAC) {
    Invoke-Action 'powercfg: never sleep on mains power' {
        & powercfg.exe /change standby-timeout-ac 0
        & powercfg.exe /change hibernate-timeout-ac 0
    }
} else {
    Write-Host '    When the desktop sleeps, Hermes falls back to the laptop on its own. To keep the desktop model available,'
    Write-Host '    set Windows sleep to Never on mains power (or re-run with -NeverSleepOnAC).'
}

if (-not $NoStart) {
    Write-Step 'Step 20: start the server and run the tool-call smoke test'
    Invoke-Action "start the 'llama-server' task and wait for $base/health" {
        Stop-ScheduledTask -TaskName 'llama-server' -ErrorAction SilentlyContinue
        Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-ScheduledTask -TaskName 'llama-server'
        $key = (Get-Content $keyFile -Raw).Trim()
        Write-Host '    loading the model (a few minutes the first time)...'
        if (-not (Wait-Http -Url "$base/health" -Seconds 600 -Headers @{ Authorization = "Bearer $key" })) {
            throw "the server did not come up on $base. Run $startCmd by hand to read the error. If it fails with -fa on or the q8_0 value cache, remove -ctv q8_0 first, then -fa on (guide Step 19)."
        }
        Write-Ok "$base/health answers"
        if (Test-ToolCall -BaseUrl $base -Model $cfg['DESKTOP_MODEL_ALIAS'] -ApiKey $key) { Write-Ok 'tool calls work (get_weather came back as a tool call)' }
        else { Write-Warn 'no tool call came back; the server must run with --jinja (start-llama.cmd does).' }
    }
}

Write-Host ''
if ($script:HsDryRun -or $newKey) {
    Write-Host 'Desktop API key (paste it into the laptop when ./setup.sh run 11 asks; show it again with -ShowKey):' -ForegroundColor Green
    if ($script:HsDryRun) { Write-Host '    <printed here on a real run>' } else { Write-Host ('    ' + (Get-Content $keyFile -Raw).Trim()) }
} else {
    Write-Host "The API key is in $keyFile (show it with:  .\Install-Llama.ps1 -ShowKey)."
}
Write-Host "Next, on the laptop:  ./setup.sh run 11"
