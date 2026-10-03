<#
.SYNOPSIS
  Take the desktop's models out of Hermes's loop while you use the desktop for something else, and bring them back.
.DESCRIPTION
  Run in an ADMINISTRATOR PowerShell (it stops and starts the model servers).
    .\Desktop-Mode.ps1 away            tell the laptop to leave the desktop out, then stop the model servers
                                       (the GPU and the memory are yours again). The startup and night tasks stay off.
    .\Desktop-Mode.ps1 away -For 4h    the same, and everything comes back by itself after 4 hours (90m, 4h, 1d)
    .\Desktop-Mode.ps1 back            start the model servers, wait until they answer, then tell the laptop to use them again
    .\Desktop-Mode.ps1 status          show the tasks, the servers and the model ports
  Telling the laptop runs 'hermes-desktop' there over SSH (one sudo password prompt). If that does not work the script says
  which command to run on the laptop instead; add -NoLaptop to skip that step.
.EXAMPLE
  .\Desktop-Mode.ps1 away -For 3h -DryRun      # show what would happen, change nothing
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('away', 'back', 'status')][string]$Mode = 'status',
    [string]$For = '',
    [string]$ConfigFile,
    [switch]$NoLaptop,
    [switch]$DryRun,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsDryRun = [bool]$DryRun
$script:HsAssumeYes = [bool]$Yes
if ($Mode -ne 'status') { Assert-Admin }
if ($For -ne '' -and $Mode -ne 'away') { throw "-For only goes with 'away'" }
if ($For -ne '' -and $For -cnotmatch '^[0-9]{1,3}[mhd]$') { throw "-For expects a duration like 90m, 4h or 1d (got '$For')" }
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
$cfg = Initialize-NodeConfig -Path $ConfigFile -Need 'LAPTOP_IP', 'DESKTOP_IP', 'ADMIN_USER', 'AGENT_USER', 'LLM_PORT', 'DESKTOP_LLAMA_DIR', 'V100_ENABLED'
if ($cfg['V100_ENABLED'] -eq '1') {
    $cfg = Initialize-NodeConfig -Path $ConfigFile -Need 'V100_PORT', 'V100_CUDA_DIR'
}

$tasks = Get-LlamaTaskNames -Cfg $cfg
$dirs = Get-LlamaServerDirs -Cfg $cfg
$llama = $cfg['DESKTOP_LLAMA_DIR']
$returnTask = 'llama-return'
$ports = @([int]$cfg['LLM_PORT'])
if ($cfg['V100_ENABLED'] -eq '1') { $ports += [int]$cfg['V100_PORT'] }

function Invoke-Laptop([string]$Action, [string]$Duration = '') {
    if ($NoLaptop) { Write-Host "    (-NoLaptop) on the laptop, as $($cfg['AGENT_USER']):  hermes-desktop $Action$(if ($Duration) { " --for $Duration" })"; return $true }
    $remote = Get-LaptopDesktopCommand -Cfg $cfg -Action $Action -For $Duration
    $target = "$($cfg['ADMIN_USER'])@$($cfg['LAPTOP_IP'])"
    $ok = $false
    $script:laptopOk = $false
    Invoke-Action "ssh $target `"$remote`"  (asks for the laptop's sudo password)" {
        $sshArgs = @('-o', 'ConnectTimeout=8')
        if (Test-Interactive) { $sshArgs += '-t' } else { $sshArgs += @('-o', 'BatchMode=yes') }
        try {
            & ssh @sshArgs -- $target $remote
            $script:laptopOk = ($LASTEXITCODE -eq 0)
        } catch { Write-Warn "could not run ssh: $($_.Exception.Message)" }
    }
    if ($script:HsDryRun) { return $true }
    if (-not $script:laptopOk) {
        Write-Warn "could not run hermes-desktop on the laptop. Run it there yourself, as $($cfg['AGENT_USER']):  hermes-desktop $Action$(if ($Duration) { " --for $Duration" })"
    }
    return $script:laptopOk
}

function Show-Status {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { Write-Warn 'the scheduled task commands are not available in this shell (this script is for Windows)'; return }
    Write-Step 'model server tasks'
    foreach ($t in $tasks) {
        $st = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        if ($st) { Write-Host ("    {0,-14} {1}" -f $t, $st.State) } else { Write-Host ("    {0,-14} (not installed)" -f $t) }
    }
    $rt = Get-ScheduledTask -TaskName $returnTask -ErrorAction SilentlyContinue
    if ($rt) { Write-Host "    $returnTask   comes back at $((Get-ScheduledTaskInfo -TaskName $returnTask).NextRunTime)" }
    Write-Step 'running servers'
    $any = $false
    foreach ($d in $dirs) {
        $p = Get-LlamaServerProcess -Dir $d
        if ($p.Count) { $any = $true; Write-Host "    running from $d" } else { Write-Host "    not running from $d" }
    }
    if (-not $any) { Write-Ok 'the desktop is free: no model server is running' }
}

function Wait-ModelServers {
    $keyFile = "$llama\api-key.txt"
    $headers = @{}
    if (Test-Path $keyFile) { $headers['Authorization'] = 'Bearer ' + (Get-Content $keyFile -Raw).Trim() }
    $allUp = $true
    foreach ($port in $ports) {
        $url = "http://$($cfg['DESKTOP_IP']):$port/health"
        Write-Host "    waiting for $url (a model takes a few minutes to load)..."
        if (Wait-Http -Url $url -Seconds 600 -Headers $headers) { Write-Ok "$url answers" } else { Write-Warn "$url did not answer"; $allUp = $false }
    }
    return $allUp
}

switch ($Mode) {
    'status' {
        Show-Status
        Write-Host ''
        Write-Host 'The laptop side:  hermes-desktop status   (on the laptop, as the agent user)'
    }
    'away' {
        Write-Step 'tell the laptop to leave the desktop out of the loop'
        $laptopOk = Invoke-Laptop 'off' $For
        if (-not $laptopOk) {
            if (-not (Read-YesNo -Question 'The laptop was not told. Stop the desktop servers anyway? (Hermes will still try them and fall back on its own)' -Default $false)) {
                throw 'Stopped before changing anything on the desktop.'
            }
        }
        Write-Step 'stop the model servers and keep them from restarting'
        foreach ($t in $tasks) {
            Invoke-Action "stop and disable the scheduled task '$t'" {
                if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
                    Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
                    Disable-ScheduledTask -TaskName $t | Out-Null
                }
            }
        }
        foreach ($d in $dirs) {
            Invoke-Action "stop the llama-server that runs from $d" { Stop-LlamaServer -Dir $d }
        }
        Invoke-Action "remove an earlier '$returnTask' task" { Unregister-ScheduledTask -TaskName $returnTask -Confirm:$false -ErrorAction SilentlyContinue }
        if ($For -ne '') {
            $when = Get-AwayReturnTime -Now (Get-Date) -For $For
            Invoke-Action "scheduled task '$returnTask' starts the servers again at $($when.ToString('yyyy-MM-dd HH:mm')) (five minutes before the laptop puts them back)" {
                $me = "$env:USERDOMAIN\$env:USERNAME"
                $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" back -NoLaptop -Yes"
                $trigger = New-ScheduledTaskTrigger -Once -At $when
                $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
                $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
                Register-ScheduledTask -TaskName $returnTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
            }
        }
        Write-Ok 'the desktop is yours: the model servers are stopped and will not restart until you run  .\Desktop-Mode.ps1 back'
        if ($For -ne '') { Write-Host "    Everything comes back by itself in $For." }
    }
    'back' {
        Write-Step 'start the model servers'
        Invoke-Action "remove the '$returnTask' task" { Unregister-ScheduledTask -TaskName $returnTask -Confirm:$false -ErrorAction SilentlyContinue }
        foreach ($t in $tasks) {
            Invoke-Action "enable the scheduled task '$t'" {
                if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) { Enable-ScheduledTask -TaskName $t | Out-Null }
            }
        }
        # the day model and (when installed) the V100 server start now; the night tasks wait for their time
        foreach ($t in ($tasks | Where-Object { $_ -in 'llama-server', 'llama-v100' })) {
            Invoke-Action "start the scheduled task '$t'" {
                if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) { Start-ScheduledTask -TaskName $t }
            }
        }
        $up = $true
        Invoke-Action 'wait until the model ports answer' { $script:up = Wait-ModelServers }
        if ($script:HsDryRun) { $up = $true } else { $up = $script:up }
        if ($up) {
            Write-Step 'tell the laptop to use the desktop again'
            $null = Invoke-Laptop 'on'
            Write-Ok 'the desktop models are back in the loop'
        } else {
            Write-Warn 'a model server did not come up, so the laptop was NOT told. Check the server (Show-Status), then run this again.'
            Show-Status
            exit 1
        }
    }
}
