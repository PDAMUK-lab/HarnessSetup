<#
.SYNOPSIS
  Copy the laptop's newest backup of the agent's state to this PC, so a copy survives the laptop.
.DESCRIPTION
  The laptop makes the backups (./setup.sh tool backup --install, every day at BACKUP_TIME). This copies the newest one
  over SSH into DESKTOP_BACKUP_DIR and keeps the newest BACKUP_KEEP there. The folder is made readable by you and
  administrators only: the backups hold the agent's API keys and GitHub token.
    .\Backup-Laptop.ps1              copy the newest backup now
    .\Backup-Laptop.ps1 -Register    also every day, half an hour after the laptop's backup (task 'hermes-backup-copy')
  To restore one, copy it back (scp FILE ai-node@<laptop>:) and run on the laptop: ./setup.sh tool restore FILE
.EXAMPLE
  .\Backup-Laptop.ps1 -Register
#>
[CmdletBinding()]
param([string]$ConfigFile, [switch]$Register, [switch]$DryRun, [switch]$Yes)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsDryRun = [bool]$DryRun
$script:HsAssumeYes = [bool]$Yes
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
$need = 'LAPTOP_IP', 'ADMIN_USER', 'DESKTOP_BACKUP_DIR', 'BACKUP_KEEP', 'BACKUP_TIME'
$cfg = Initialize-NodeConfig -Path $ConfigFile -Need $need
Assert-Config $cfg $need
$dir = $cfg['DESKTOP_BACKUP_DIR']
$keep = [int]$cfg['BACKUP_KEEP']
$target = "$($cfg['ADMIN_USER'])@$($cfg['LAPTOP_IP'])"
$remoteDir = '/var/backups/hermes-node'

Write-Step "the backup folder $dir (you and administrators only)"
if (-not (Test-Path -LiteralPath $dir)) {
    Invoke-Action "create $dir" { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
Invoke-Action "restrict $dir to $env:USERNAME and administrators" {
    & icacls.exe $dir /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" 'BUILTIN\Administrators:(OI)(CI)F' | Out-Null
}

Write-Step "the newest backup on the laptop ($target)"
$latest = ''
if ($script:HsDryRun) { Write-Host "[dry-run] ssh $target ls -1t $remoteDir/hermes-node-*.tar.gz" -ForegroundColor DarkGray }
else {
    $out = Invoke-NativeText { & ssh -o BatchMode=yes -o ConnectTimeout=8 $target "ls -1t $remoteDir/hermes-node-*.tar.gz 2>/dev/null | head -1" }
    $latest = ([string]$out).Trim()
    if ($latest -cnotmatch '^/var/backups/hermes-node/hermes-node-[0-9-]+\.tar\.gz$') {
        throw "no backup found on the laptop (got '$latest'). On the laptop: ./setup.sh tool backup --install"
    }
}
if ($latest) {
    $name = Split-Path $latest -Leaf
    $dest = Join-Path $dir $name
    if (Test-Path -LiteralPath $dest) { Write-Ok "already copied: $dest" }
    else {
        Invoke-Action "scp $target`:$latest $dest" {
            & scp -q -o BatchMode=yes "${target}:$latest" $dest
            if ($LASTEXITCODE -ne 0) { throw "scp failed ($LASTEXITCODE)" }
        }
        Write-Ok "copied $name"
    }
}
$old = @(Get-ChildItem -LiteralPath $dir -Filter 'hermes-node-*.tar.gz' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep)
foreach ($f in $old) { Invoke-Action "remove the old copy $($f.Name)" { Remove-Item -LiteralPath $f.FullName -Force } }

if ($Register) {
    Write-Step 'daily copy task'
    $at = ([datetime]::ParseExact($cfg['BACKUP_TIME'], 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)).AddMinutes(30).ToString('HH:mm')
    Invoke-Action "task 'hermes-backup-copy' every day at $at" {
        $me = "$env:USERDOMAIN\$env:USERNAME"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Yes"
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive
        Register-ScheduledTask -TaskName 'hermes-backup-copy' -Action $action -Trigger (New-ScheduledTaskTrigger -Daily -At $at) `
            -Settings $settings -Principal $principal -Force | Out-Null
    }
}
