<#
.SYNOPSIS
  Step 5 (desktop side) and Step 15: key-only SSH to the laptop, and the dashboard tunnel shortcut.
.DESCRIPTION
  1. Creates an ed25519 key if you have none (ssh-keygen asks for a passphrase; choose one).
  2. Installs the public key on the laptop (you type the laptop password here; if you also let it copy the
     laptop's settings you are asked once more, because that happens before the key exists).
  3. Proves a key-only login works. Only then is it safe to run ./setup.sh run 02 on the laptop.
  4. Offers to write hermes-tunnel.cmd to your Desktop (pin it to the taskbar).
  Settings (laptop address, admin account ...) are asked for when config\node.env does not have them yet.
.EXAMPLE
  .\Setup-LaptopAccess.ps1
  .\Setup-LaptopAccess.ps1 -DryRun
  .\Setup-LaptopAccess.ps1 -TunnelFile -Yes     # no questions: write the shortcut
#>
[CmdletBinding()]
param(
    [string]$ConfigFile,
    [switch]$NoTunnelFile,
    [switch]$TunnelFile,
    [string]$TunnelDir,
    [switch]$DryRun,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsDryRun = [bool]$DryRun
$script:HsAssumeYes = [bool]$Yes
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
$cfg = Initialize-NodeConfig -Path $ConfigFile -Need 'LAPTOP_IP', 'ADMIN_USER', 'DASHBOARD_PORT'
Assert-Config $cfg 'LAPTOP_IP', 'ADMIN_USER', 'DASHBOARD_PORT'
if ($NoTunnelFile) { $makeTunnel = $false }
elseif ($TunnelFile) { $makeTunnel = $true }
else { $makeTunnel = Read-YesNo -Question "Create the hermes-tunnel.cmd shortcut on your Desktop? (it opens the dashboard at http://localhost:$($cfg['DASHBOARD_PORT']))" -Default $true }
$target = "$($cfg['ADMIN_USER'])@$($cfg['LAPTOP_IP'])"

$sshDir = Join-Path $env:USERPROFILE '.ssh'
$key = Join-Path $sshDir 'id_ed25519'
Write-Step 'Step 5: SSH key'
if (Test-Path "$key.pub") {
    Write-Ok "using the existing key $key.pub"
} else {
    Invoke-Action "ssh-keygen -t ed25519 -f $key" {
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        & ssh-keygen -t ed25519 -f $key
        if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen failed' }
    }
}

# The remote command is sent base64-encoded: quoting differs between Windows PowerShell 5.1 and 7,
# and this way no quote ever reaches the native ssh.exe.
Write-Step "installing the public key on $target (enter the laptop password when asked)"
Invoke-Action "ssh $target (append the key to ~/.ssh/authorized_keys)" {
    $pub = (Get-Content "$key.pub" -Raw).Trim()
    if ($pub -match "'") { throw 'unexpected quote in the public key' }
    $script = "KEY='$pub'; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qxF `"`$KEY`" ~/.ssh/authorized_keys || echo `"`$KEY`" >> ~/.ssh/authorized_keys; }"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    & ssh -o StrictHostKeyChecking=accept-new $target "echo $b64 | base64 -d | sh"
    if ($LASTEXITCODE -ne 0) { throw 'could not install the key' }
}

Write-Step 'proving a key-only login works (no password allowed)'
Invoke-Action "ssh -o BatchMode=yes -o PasswordAuthentication=no $target" {
    $out = Invoke-NativeText { & ssh -o BatchMode=yes -o PasswordAuthentication=no $target 'echo key-login-ok' }
    if ($out -notmatch 'key-login-ok') { throw "key login failed: $out" }
    Write-Ok 'key-only login works'
}

if ($makeTunnel) {
    if (-not $TunnelDir) { $TunnelDir = [Environment]::GetFolderPath('Desktop') }
    $tunnel = "$TunnelDir\hermes-tunnel.cmd"
    Write-Step 'Step 15: dashboard tunnel shortcut'
    Write-CmdFile -Path $tunnel -Lines (New-TunnelCmd -Cfg $cfg)
    Write-Ok "wrote $tunnel - pin it to the taskbar. Run it, then browse to http://localhost:$($cfg['DASHBOARD_PORT'])"
    Write-Host "Use port $($cfg['DASHBOARD_PORT']) on BOTH ends: the dashboard rejects other Host headers."
}

Write-Host ''
Write-Host "Next, on the laptop (this session may stay open):  ./setup.sh run 02" -ForegroundColor Green
Write-Host "Then open a NEW PowerShell window and check:  ssh $target   (no password prompt)"
