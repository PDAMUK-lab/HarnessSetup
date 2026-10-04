<#
.SYNOPSIS
  Update the desktop's llama.cpp to the newest release, and put the old one back if the new one fails.
.DESCRIPTION
  Run in an ADMINISTRATOR PowerShell, during the day (it restarts the day server).
    .\Update-Llama.ps1             keep the current binaries in <DESKTOP_LLAMA_DIR>\prev, unpack the newest build, start the
                                   day server and run the tool-call test; if it fails, the previous build is put back
    .\Update-Llama.ps1 -Rollback   put the previous build back by hand
    .\Update-Llama.ps1 -Backend rocm   switch the day server to llama.cpp's ROCm build (after Compare-LlamaBackends.ps1
                                   showed it is faster); -Backend vulkan switches back. Without -Backend the update keeps
                                   the build in use (Vulkan unless switched). -ZipUrl takes a zip by hand.
  The new build must list the card (ROCm0 or Vulkan0) and answer with a tool call, or the previous one is put back: a ROCm
  build without hipBLAS/rocBLAS on the system PATH would otherwise run on the CPU without saying so.
  The start scripts, the API key and the models are not touched. The V100 tier's CUDA build is updated by
  re-running Install-V100.ps1.
#>
[CmdletBinding()]
param([string]$ConfigFile, [switch]$Rollback, [ValidateSet('', 'vulkan', 'rocm')][string]$Backend = '', [string]$ZipUrl = '', [switch]$DryRun, [switch]$Yes)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsDryRun = [bool]$DryRun
$script:HsAssumeYes = [bool]$Yes
Assert-Admin
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
$need = 'DESKTOP_IP', 'LLM_PORT', 'DESKTOP_LLAMA_DIR', 'DESKTOP_MODEL_ALIAS'
$cfg = Initialize-NodeConfig -Path $ConfigFile -Need $need
Assert-Config $cfg $need
$llama = $cfg['DESKTOP_LLAMA_DIR']
$prev = "$llama\prev"
$base = "http://$($cfg['DESKTOP_IP']):$($cfg['LLM_PORT'])"
$current = Get-LlamaBackend -Dir $llama
if (-not $Backend) { $Backend = $current }
$Backend = $Backend.ToLowerInvariant()   # ValidateSet lets 'ROCm' through as typed
$taskPath = Get-TaskPath                 # what the server task will see, not this window's PATH
$vkEnv = @{}
if ($cfg.Contains('V100_ENABLED') -and $cfg['V100_ENABLED'] -eq '1') { $vkEnv['VK_LOADER_DRIVERS_DISABLE'] = '*nv*' }

function Get-Binaries { @(Get-ChildItem -LiteralPath $llama -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.dll' }) }
function Start-DayServer {
    Invoke-Action "start the day server (task 'llama-server')" { Start-ScheduledTask -TaskName 'llama-server' }
}
function Test-DayServer {
    if ($script:HsDryRun) { return $true }
    $key = (Get-Content -LiteralPath "$llama\api-key.txt" -Raw).Trim()
    if (-not (Wait-Http -Url "$base/health" -Seconds 300 -Headers @{ Authorization = "Bearer $key" })) { return $false }
    return (Test-ToolCall -BaseUrl $base -Model $cfg['DESKTOP_MODEL_ALIAS'] -ApiKey $key)
}
# the new build lists the card under its backend's name (run in its own folder, with the day server's environment)
function Test-BuildDevice {
    $prefix = if ($Backend -eq 'rocm') { 'ROCm' } else { 'Vulkan' }
    if ($script:HsDryRun) { Write-Host "[dry-run] $llama\llama-server.exe --list-devices must list $($prefix)0" -ForegroundColor DarkGray; return $true }
    Push-Location -LiteralPath $llama
    $runEnv = @{ PATH = $taskPath }
    if ($Backend -eq 'vulkan') { $runEnv += $vkEnv }
    try { $listed = Get-LlamaDevices -Text (Get-LlamaDeviceList -Exe "$llama\llama-server.exe" -Env $runEnv) }
    finally { Pop-Location }
    $dev = $listed | Where-Object { $_.Name -cmatch "^$prefix[0-9]+$" } | Select-Object -First 1
    if ($dev) { Write-Ok "the new build sees $($dev.Name): $($dev.Description)"; return $true }
    return $false
}
function Restore-Previous {
    if (-not $script:HsDryRun -and -not (Test-Path -LiteralPath "$prev\llama-server.exe")) { throw "no previous build in $prev" }
    Invoke-Action "stop the server and put the build in $prev back" {
        Stop-LlamaServer -Dir $llama
        Get-Binaries | Remove-Item -Force   # a failed build's backend DLLs must not stay beside the old ones
        Remove-Item -LiteralPath "$llama\llama-backend.txt" -Force -ErrorAction SilentlyContinue
        Copy-Item -Path "$prev\*" -Destination $llama -Force
    }
    Start-DayServer
}

if ($Rollback) {
    Write-Step 'rollback'
    Restore-Previous
    if (Test-DayServer) { Write-Ok 'the previous build answers with tool calls' } else { throw 'the previous build does not answer either: look at the server window' }
    return
}

if (-not $script:HsDryRun -and -not (Test-Path -LiteralPath "$llama\llama-server.exe")) { throw "no llama-server.exe in $llama yet: run Install-Llama.ps1 first" }
if ($Backend -eq 'rocm') {
    $libs = Find-RocmLibraries -PathList $taskPath
    if (-not ($libs.HipBlas -and $libs.RocBlas)) {
        Write-Warn $script:RocmLibraryHelp
        if (-not (Read-YesNo -Question 'Install the ROCm build anyway? (it is put back if it does not see the card)' -Default $false)) { throw 'Stopped before changing anything.' }
    }
}
Write-Step "keep the current build in $prev"
Invoke-Action "copy the current .exe and .dll files to $prev" {
    if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Recurse -Force }
    New-Item -ItemType Directory -Path $prev | Out-Null
    Get-Binaries | Copy-Item -Destination $prev
    Set-Content -LiteralPath "$prev\llama-backend.txt" -Value $current -Encoding ascii   # a rollback restores the backend too
}
Write-Step 'the newest build'
try {
    Invoke-Action "download and extract the latest llama-*-bin-win-$Backend zip" { $null = Install-LlamaVulkanBuild -Dir $llama -Backend $Backend -ZipUrl $ZipUrl }
} catch {
    Write-Warn "the new build could not be installed ($($_.Exception.Message)): putting the previous one back"
    Restore-Previous
    throw
}
if (-not (Test-BuildDevice)) {
    Write-Warn "the new build does not list the card as a $Backend device: putting the previous one back"
    Restore-Previous
    if ($Backend -eq 'rocm' -and -not ($libs.HipBlas -and $libs.RocBlas)) { throw "rolled back. The ROCm build cannot use the card: $($script:RocmLibraryHelp)" }
    if ($Backend -eq 'rocm') { throw 'rolled back. The ROCm build does not see the card although hipBLAS/rocBLAS are on the PATH (an older AMD driver, or libraries from another ROCm version than 10?)' }
    throw 'rolled back. The new build does not see the card: check the AMD driver (Check-Desktop.ps1)'
}
Start-DayServer
Write-Step 'test it'
if (Test-DayServer) {
    Write-Ok "updated; the previous build stays in $prev (.\Update-Llama.ps1 -Rollback goes back)"
} else {
    Write-Warn 'the new build did not answer with a tool call: putting the previous one back'
    Restore-Previous
    if (Test-DayServer) { throw 'rolled back to the previous build (it answers again); the new one failed - see its server window or try again later' }
    throw 'rolled back, but the previous build does not answer either: look at the server window'
}
