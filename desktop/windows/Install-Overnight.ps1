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
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsDryRun = [bool]$DryRun
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
$cfg = Read-NodeEnv $ConfigFile
if ($cfg['NIGHT_ENABLED'] -ne '1') { throw 'Set NIGHT_ENABLED=1 in config\node.env to use the overnight tier.' }
Assert-Config $cfg 'DESKTOP_LLAMA_DIR', 'DESKTOP_MODELS_DIR', 'NIGHT_MODEL_FILE', 'NIGHT_MODEL_URL', 'NIGHT_MODEL_ALIAS',
    'NIGHT_NGL', 'NIGHT_START', 'NIGHT_END'
foreach ($t in 'NIGHT_START', 'NIGHT_END') {
    if ($cfg[$t] -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw "$t must look like 01:00 (got '$($cfg[$t])')" }
}
Assert-Admin
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

Write-Step 'swap tasks (they wake the PC)'
Invoke-Action "tasks llama-night at $($cfg['NIGHT_START']) and llama-day at $($cfg['NIGHT_END'])" {
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -AllowStartIfOnBatteries
    $night = New-ScheduledTaskAction -Execute cmd.exe -Argument "/c taskkill /im llama-server.exe /f & start `"`" $llama\start-llama-27b.cmd"
    $day = New-ScheduledTaskAction -Execute cmd.exe -Argument "/c taskkill /im llama-server.exe /f & start `"`" $llama\start-llama.cmd"
    Register-ScheduledTask -TaskName llama-night -Action $night -Trigger (New-ScheduledTaskTrigger -Daily -At $cfg['NIGHT_START']) -Settings $settings -Force | Out-Null
    Register-ScheduledTask -TaskName llama-day -Action $day -Trigger (New-ScheduledTaskTrigger -Daily -At $cfg['NIGHT_END']) -Settings $settings -Force | Out-Null
}

Write-Step 'allow wake timers (Power Options > Sleep > Allow wake timers = Enable)'
Invoke-Action 'powercfg: wake timers on (mains)' {
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
    & powercfg.exe /setactive SCHEME_CURRENT
}

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
Write-Host 'Schedule overnight jobs between 01:15 and about 05:00, one per night. Pinned jobs never fall back.'
Write-Host 'Next, on the laptop:  tools/overnight-laptop.sh prints the order (test by hand, then enable the job).'
