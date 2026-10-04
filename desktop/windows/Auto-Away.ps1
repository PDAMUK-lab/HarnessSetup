<#
.SYNOPSIS
  Take the desktop's models out of Hermes's loop by themselves when you start using the GPU, and bring them back when you stop.
.DESCRIPTION
  Every 30 seconds this looks at how busy the GPU is with programs other than the model servers (games, video, 3D work).
  When that stays at AUTO_AWAY_GPU_PCT or more for AUTO_AWAY_AFTER_MIN minutes, it runs  Desktop-Mode.ps1 away  (the
  laptop is told, the servers stop, the GPU is yours). After AUTO_BACK_AFTER_MIN quiet minutes it runs  Desktop-Mode.ps1 back.
  A manual  Desktop-Mode.ps1 away  is left alone: only an automatic away is undone automatically.
    .\Auto-Away.ps1 -Register      run it from now on, at every logon, hidden (task 'hermes-auto-away'; ADMINISTRATOR PowerShell)
    .\Auto-Away.ps1 -Unregister    stop it
    .\Auto-Away.ps1 -Once          one sample: print the GPU use and what it would do
  Telling the laptop without a password needs the laptop's stage 03 from kit 0.5.0 or later (re-run ./setup.sh run 03).
  Until then Desktop-Mode.ps1 cannot tell the laptop from a task, so it changes nothing and the log says so: automatic away
  does not work before that. The log is <DESKTOP_LLAMA_DIR>\auto-away.log.
#>
[CmdletBinding()]
param([string]$ConfigFile, [switch]$Register, [switch]$Unregister, [switch]$Once, [switch]$DryRun, [switch]$Yes)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsDryRun = [bool]$DryRun
$script:HsAssumeYes = [bool]$Yes
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
$need = 'DESKTOP_LLAMA_DIR', 'V100_ENABLED', 'AUTO_AWAY_GPU_PCT', 'AUTO_AWAY_AFTER_MIN', 'AUTO_BACK_AFTER_MIN'
$cfg = Initialize-NodeConfig -Path $ConfigFile -Need $need
Assert-Config $cfg $need
if ($cfg['V100_ENABLED'] -eq '1') { $cfg = Initialize-NodeConfig -Path $ConfigFile -Need 'V100_CUDA_DIR' }
$taskName = 'hermes-auto-away'
$llama = $cfg['DESKTOP_LLAMA_DIR']
$logFile = "$llama\auto-away.log"
$modeScript = "$PSScriptRoot\Desktop-Mode.ps1"
$rule = @{ Threshold = [int]$cfg['AUTO_AWAY_GPU_PCT']; AwayAfter = [int]$cfg['AUTO_AWAY_AFTER_MIN']; BackAfter = [int]$cfg['AUTO_BACK_AFTER_MIN'] }
$what = "away after $($rule.AwayAfter) min with other programs using >= $($rule.Threshold)% of the GPU, back after $($rule.BackAfter) quiet min"

if ($Unregister) {
    Assert-Admin
    Invoke-Action "remove the task '$taskName'" {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Ok 'automatic away is off (Desktop-Mode.ps1 away / back still work by hand)'
    return
}
if ($Register) {
    Assert-Admin
    Write-Step "task '$taskName' at every logon: $what"
    Invoke-Action "register the task '$taskName' (hidden, highest privileges, no time limit) and start it" {
        $me = "$env:USERDOMAIN\$env:USERNAME"
        # as you, not SYSTEM: the ssh key that tells the laptop is in your profile
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Yes"
        $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $me) `
            -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
    }
    Write-Ok "automatic away is on. Log: $logFile   Off again: .\Auto-Away.ps1 -Unregister"
    return
}

function Write-Log([string]$Message) {
    $line = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $Message"
    if ($Once -or $script:HsDryRun) { Write-Host $line } else { Add-Content -LiteralPath $logFile -Value $line }
}
function Get-ServerPids { @(foreach ($d in (Get-LlamaServerDirs -Cfg $cfg)) { foreach ($p in (Get-LlamaServerProcess -Dir $d)) { [int]$p.ProcessId } }) }
function Test-ServersOn {
    $t = Get-ScheduledTask -TaskName 'llama-server' -ErrorAction SilentlyContinue
    return ($null -ne $t -and $t.State -ne 'Disabled')
}

if ($script:HsDryRun) {
    Write-Host "[dry-run] every 30 s: sample '\GPU Engine(*)\Utilization Percentage' without the model servers; $what" -ForegroundColor DarkGray
    Write-Host "[dry-run] away runs: $modeScript away -Yes;  back runs: $modeScript back -Yes   (log: $logFile)" -ForegroundColor DarkGray
    return
}
Assert-Admin
$state = @{}
Write-Log "started: $what"
while ($true) {
    try {
        $pct = Get-OtherGpuUse -ExcludePids (Get-ServerPids)
        $on = Test-ServersOn
        $act = Step-AutoAway -State $state -OtherPct $pct -Now (Get-Date) -ServersOn $on @rule
        if ($Once) { Write-Log "other programs use $pct% of the GPU; model servers $(if ($on) { 'on' } else { 'off' }); would do: $(if ($act) { $act } else { 'nothing' })"; break }
        if ($act) {
            Write-Log "other programs use $pct% of the GPU: $act"
            $global:LASTEXITCODE = 0
            $failed = $false
            try { & $modeScript $act -ConfigFile $ConfigFile -Yes *>> $logFile } catch { $failed = $true; Write-Log "Desktop-Mode.ps1 $act failed: $($_.Exception.Message)" }
            if ($LASTEXITCODE -ne 0) { $failed = $true }
            # a failed away is tried again after another streak; a failed back stays 'away' and is tried again later
            if ($failed -and $act -eq 'away') { $state['Away'] = $false }
            if ($failed -and $act -eq 'back') { $state['Away'] = $true; $state['Since'] = $null }
        }
    } catch { Write-Log "sample failed: $($_.Exception.Message)" }
    Start-Sleep -Seconds 30
}
