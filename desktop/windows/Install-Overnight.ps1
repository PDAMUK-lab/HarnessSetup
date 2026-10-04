<#
.SYNOPSIS
  Step 31 (desktop side): the optional overnight tier, Qwen3.8-27B between NIGHT_START and NIGHT_END.
.DESCRIPTION
  Run in an ADMINISTRATOR PowerShell, after Install-Llama.ps1 works. Needs NIGHT_ENABLED=1 in config\node.env.
    - downloads the 27B model and writes C:\llama\start-llama-27b.cmd
    - registers 'llama-night' and 'llama-day' tasks that swap the server and WAKE the PC for it
    - allows wake timers
  It does not swap the running server now: try the 27B by hand first (the laptop's tools\overnight-laptop.sh
  prints the order). Leave your account signed in (lock the screen, do not sign out).
.EXAMPLE
  .\Install-Overnight.ps1 -DryRun
  .\Install-Overnight.ps1 -SetUpdateActiveHours
#>
[CmdletBinding()]
param(
    [string]$ConfigFile,
    [switch]$SkipModelDownload,
    [switch]$SetUpdateActiveHours,
    [switch]$DryRun,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsDryRun = [bool]$DryRun
$script:HsAssumeYes = [bool]$Yes
Assert-Admin
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
$cfg = Initialize-NodeConfig -Path $ConfigFile
if ($cfg['NIGHT_ENABLED'] -ne '1') {
    # never flip a setting without a person saying yes
    if (-not (Test-Interactive) -or -not (Read-YesNo -Question 'The overnight tier is switched off in your settings. Turn it on now?' -Default $true)) {
        throw 'The overnight tier is off (NIGHT_ENABLED=0). Run .\Configure.ps1 -Only NIGHT_ENABLED to turn it on.'
    }
    Set-NodeSettings -Path $ConfigFile -Set 'NIGHT_ENABLED=1'   # changes only that setting
    if (Test-Interactive) { Invoke-ConfigWizard -Path $ConfigFile -Scope desktop -Only 'NIGHT_START', 'NIGHT_END' }
}
$cfg = Initialize-NodeConfig -Path $ConfigFile -Need 'DESKTOP_LLAMA_DIR', 'DESKTOP_MODELS_DIR', 'NIGHT_MODEL_FILE', 'NIGHT_MODEL_URL',
    'NIGHT_MODEL_ALIAS', 'NIGHT_NGL', 'NIGHT_START', 'NIGHT_END', 'LLM_PORT', 'DESKTOP_IP'
Assert-Config $cfg 'DESKTOP_LLAMA_DIR', 'DESKTOP_MODELS_DIR', 'NIGHT_MODEL_FILE', 'NIGHT_MODEL_URL', 'NIGHT_MODEL_ALIAS',
    'NIGHT_NGL', 'NIGHT_START', 'NIGHT_END'
foreach ($t in 'NIGHT_START', 'NIGHT_END') {
    if ($cfg[$t] -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw "$t must look like 01:00 (got '$($cfg[$t])')" }
}
$llama = $cfg['DESKTOP_LLAMA_DIR']
$models = $cfg['DESKTOP_MODELS_DIR']
if (-not $script:HsDryRun -and -not (Test-Path "$llama\start-llama.cmd")) { throw "Run Install-Llama.ps1 first ($llama\start-llama.cmd is missing)." }

Write-Step 'the 27B model'
if (-not $SkipModelDownload) {
    Invoke-Action 'check free disk space on the models drive' {
        $drive = (Get-Item $models).PSDrive
        if ($drive.Free -lt 24GB) { throw "Only $([math]::Round($drive.Free / 1GB)) GB free on $($drive.Name):, the 27B needs about 17 GB plus working space." }
    }
    Save-Model -Url $cfg['NIGHT_MODEL_URL'] -Dest "$models\$($cfg['NIGHT_MODEL_FILE'])"
}
Write-CmdFile -Path "$llama\start-llama-27b.cmd" -Lines (New-LlamaStartScript -Cfg $cfg -Tier Night)
Write-Ok "wrote $llama\start-llama-27b.cmd (-ngl $($cfg['NIGHT_NGL']); raise it until dedicated GPU memory is about 7.3 GB)"

Write-CmdFile -Path "$llama\stop-llama.cmd" -Lines (New-StopLlamaScript -Dir $llama)
Write-Ok "wrote $llama\stop-llama.cmd (stops only the server that runs from $llama)"

Write-Step 'swap tasks (they wake the PC)'
Invoke-Action "tasks llama-night at $($cfg['NIGHT_START']) and llama-day at $($cfg['NIGHT_END'])" {
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -AllowStartIfOnBatteries
    # The day server runs elevated (its logon task is 'highest'); a non-elevated swap task cannot stop it ("Access is denied"),
    # so the 27B would fail to bind the port while the 35B kept answering. Run the swap tasks elevated too.
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
    # stop only THIS folder's server (the V100 server has the same program name), then start the other model
    $night = New-ScheduledTaskAction -Execute cmd.exe -Argument "/c call $llama\stop-llama.cmd & start `"`" $llama\start-llama-27b.cmd"
    $day = New-ScheduledTaskAction -Execute cmd.exe -Argument "/c call $llama\stop-llama.cmd & start `"`" $llama\start-llama.cmd"
    Register-ScheduledTask -TaskName llama-night -Action $night -Trigger (New-ScheduledTaskTrigger -Daily -At $cfg['NIGHT_START']) -Settings $settings -Principal $principal -Force | Out-Null
    Register-ScheduledTask -TaskName llama-day -Action $day -Trigger (New-ScheduledTaskTrigger -Daily -At $cfg['NIGHT_END']) -Settings $settings -Principal $principal -Force | Out-Null
}

Write-Step 'allow wake timers (Power Options > Sleep > Allow wake timers = Enable)'
Invoke-Action 'powercfg: wake timers on (mains)' {
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
    & powercfg.exe /setactive SCHEME_CURRENT
}
# After a timer wake with nobody at the PC, Windows goes back to sleep when the 'system unattended sleep timeout' (default 2 minutes) runs out,
# which can be before the job starts. 7 hours (25200 s) covers the night window.
Invoke-Action 'powercfg: stay awake for up to 7 hours after an unattended wake (mains)' {
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 25200
    & powercfg.exe /setactive SCHEME_CURRENT
}

$SetUpdateActiveHours = Resolve-Option -Bound $PSBoundParameters -Name SetUpdateActiveHours -Current ([bool]$SetUpdateActiveHours) -Default $false `
    -Question "Set Windows Update active hours to cover $($cfg['NIGHT_START'])-$($cfg['NIGHT_END']) so it does not restart mid-job?"
if ($SetUpdateActiveHours) {
    Invoke-Action 'Windows Update active hours cover the night window' {
        $key = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        Set-ItemProperty -Path $key -Name ActiveHoursStart -Value ([int]($cfg['NIGHT_START'].Split(':')[0]))
        Set-ItemProperty -Path $key -Name ActiveHoursEnd -Value ([int]($cfg['NIGHT_END'].Split(':')[0]))
    }
} else {
    Write-Host "    Set Windows Update active hours to cover $($cfg['NIGHT_START'])-$($cfg['NIGHT_END']) so it does not restart mid-job"
    Write-Host '    (Settings > Windows Update > Advanced options > Active hours), or re-run with -SetUpdateActiveHours.'
}

Write-Host ''
Write-Host 'Remember: sign-in stays on (lock the screen, do not sign out) and the PC must sleep, not hibernate.' -ForegroundColor Yellow
Write-Host "Schedule overnight jobs between $(Add-ClockMinutes $cfg['NIGHT_START'] 15) and $(Add-ClockMinutes $cfg['NIGHT_END'] -120), one per night. Pinned jobs never fall back."
Write-Host 'Next, on the laptop:  tools/overnight-laptop.sh prints the order (test by hand, then enable the job).'
