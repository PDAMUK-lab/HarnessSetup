<#
.SYNOPSIS
  Measure whether llama.cpp's ROCm build is faster than the Vulkan build on this desktop's card. C:\llama is not changed.
.DESCRIPTION
  Run in an ADMINISTRATOR PowerShell when Hermes can do without the desktop model for about 15 minutes (the day server is
  stopped while it measures; the laptop's model takes over as usual, and the day server is started again at the end).
    - downloads the newest llama.cpp ROCm build (llama-bNNNN-bin-win-rocm-10.0-x64.zip) into <DESKTOP_LLAMA_DIR>-rocm
    - checks that build sees the card (--list-devices must show ROCm0). llama.cpp compiles it for gfx1032 (RX 6600 XT), but
      the zip leaves out hipBLAS/rocBLAS: they must be on PATH (AMD's ROCm 10 libraries; the script says how). Without them
      the ROCm build cannot use the card, and the answer is "stay on Vulkan" until they are installed
    - runs the same llama-bench on both builds, each pinned to the card (ROCm0 / Vulkan0): the day model with its expert
      split (DESKTOP_N_CPU_MOE) and cache types, 2048 prompt tokens and 128 generated, empty and 32768 tokens deep
    - prints the table and the advice. Switch only when ROCm generates more than 10% faster at every depth:
      .\Update-Llama.ps1 -Backend rocm   (keeps the Vulkan build in prev\, checks the card and tool calls, undoes a failure;
      .\Update-Llama.ps1 -Backend vulkan goes back)
  -RocmLibDir DIR puts a folder holding hipBLAS/rocBLAS on PATH for this run only; -ZipUrl URL takes the ROCm zip by hand;
  -Depths '0,65536' and -Repetitions 5 change the measurement; -KeepRocm keeps the ROCm folder (removed at the end otherwise).
.EXAMPLE
  .\Compare-LlamaBackends.ps1 -DryRun     # show what would happen, change nothing
#>
[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$RocmLibDir = '',
    [string]$ZipUrl = '',
    [ValidatePattern('^[0-9]+(,[0-9]+)*$')][string]$Depths = '0,32768',
    [ValidateRange(1, 10)][int]$Repetitions = 3,
    [switch]$KeepRocm,
    [switch]$DryRun,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
$script:HsDryRun = [bool]$DryRun
$script:HsAssumeYes = [bool]$Yes
Assert-Admin
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
$need = 'DESKTOP_LLAMA_DIR', 'DESKTOP_MODELS_DIR', 'DESKTOP_MODEL_FILE', 'DESKTOP_N_CPU_MOE'
$cfg = Initialize-NodeConfig -Path $ConfigFile -Need $need
Assert-Config $cfg $need
$llama = $cfg['DESKTOP_LLAMA_DIR'].TrimEnd('\')
$rocm = "$llama-rocm"
$model = "$($cfg['DESKTOP_MODELS_DIR'])\$($cfg['DESKTOP_MODEL_FILE'])"
# as the day server does: with the V100 tier on, NVIDIA's Vulkan driver is hidden from the Vulkan build
$vkEnv = @{}
if ($cfg.Contains('V100_ENABLED') -and $cfg['V100_ENABLED'] -eq '1') { $vkEnv['VK_LOADER_DRIVERS_DISABLE'] = '*nv*' }
if ($RocmLibDir) {
    if (-not $script:HsDryRun -and -not (Test-Path -LiteralPath $RocmLibDir)) { throw "-RocmLibDir: no such folder: $RocmLibDir" }
    $env:PATH = "$RocmLibDir;$env:PATH"
}

if (-not $script:HsDryRun) {
    if (-not (Test-Path -LiteralPath "$llama\llama-bench.exe")) { throw "no llama-bench.exe in ${llama}: run Install-Llama.ps1 first" }
    if (-not (Test-Path -LiteralPath $model)) { throw "the day model is not there: $model" }
}

# the device a build sees first with that name prefix (ROCm0, Vulkan0), from --list-devices run in the build's own folder
# (llama.cpp also looks for backend DLLs in the current folder: the other build's must not be picked up)
function Get-BuildDevice([string]$Dir, [string]$Prefix, [hashtable]$Env) {
    Push-Location -LiteralPath $Dir
    try { $listed = Get-LlamaDevices -Text (Get-LlamaDeviceList -Exe "$Dir\llama-server.exe" -Env $Env) } finally { Pop-Location }
    return @($listed | Where-Object { $_.Name -cmatch "^$Prefix[0-9]+$" })[0]
}

function Invoke-Bench([string]$Dir, [string]$Device, [hashtable]$Env) {
    $exe = "$Dir\llama-bench.exe"
    $benchArgs = @('-m', $model, '-dev', $Device, '-ngl', '99', '-ncmoe', $cfg['DESKTOP_N_CPU_MOE'], '-fa', '1', '-ctk', 'f16', '-ctv', 'q8_0',
        '-p', '2048', '-n', '128', '-d', $Depths, '-r', "$Repetitions", '-o', 'csv')
    if ($script:HsDryRun) { Write-Host "[dry-run] $exe $($benchArgs -join ' ')" -ForegroundColor DarkGray; return @() }
    Write-Host "    $exe $($benchArgs -join ' ')"
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    Push-Location -LiteralPath $Dir
    try { $text = Invoke-NativeText { & $exe @benchArgs } }
    finally { Pop-Location; foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    if ($LASTEXITCODE -ne 0) {
        $lines = @($text -split "`n")
        $why = @($lines | Where-Object { $_ -match 'error' } | Select-Object -First 3)
        if (-not $why) { $why = @($lines | Select-Object -Last 3) }
        Write-Warn "llama-bench failed in $Dir ($LASTEXITCODE): $($why -join ' | ')"
        return @()
    }
    return ConvertFrom-LlamaBenchCsv $text
}

function Remove-RocmFolder {
    if (-not $KeepRocm) { Invoke-Action "remove $rocm (-KeepRocm keeps it)" { Remove-Item -LiteralPath $rocm -Recurse -Force } }
}

Write-Step "the ROCm build in $rocm ($llama is not touched)"
$libs = Find-RocmLibraries -Dir $RocmLibDir
if ($libs.HipBlas -and $libs.RocBlas) { Write-Ok "hipBLAS in $($libs.HipBlas), rocBLAS in $($libs.RocBlas)" }
else { Write-Warn "$($script:RocmLibraryHelp) To try them before that: -RocmLibDir <that folder>." }
Invoke-Action "download and extract the latest llama-*-bin-win-rocm zip into $rocm" {
    New-Item -ItemType Directory -Force -Path $rocm | Out-Null
    $null = Install-LlamaVulkanBuild -Dir $rocm -Backend rocm -ZipUrl $ZipUrl
}
$rocmDev = 'ROCm0'; $vkDev = 'Vulkan0'
Invoke-Action "llama-server.exe --list-devices in $rocm and in $llama (the card must be ROCm0 and Vulkan0)" {
    $r = Get-BuildDevice -Dir $rocm -Prefix 'ROCm' -Env @{}
    $v = Get-BuildDevice -Dir $llama -Prefix 'Vulkan' -Env $vkEnv
    $script:rocmDev = if ($r) { $r.Name } else { '' }
    $script:vkDev = if ($v) { $v.Name } else { '' }
    if ($r) { Write-Ok "ROCm build: $($r.Name) $($r.Description)" }
    if ($v) { Write-Ok "Vulkan build: $($v.Name) $($v.Description)" }
}
if (-not $script:HsDryRun) { $rocmDev = $script:rocmDev; $vkDev = $script:vkDev }
if (-not $vkDev) { Remove-RocmFolder; throw "the Vulkan build in $llama does not list the card: run Check-Desktop.ps1 first" }
if (-not $rocmDev) {
    if (-not ($libs.HipBlas -and $libs.RocBlas)) { Write-Warn "the ROCm build does not see the card - most likely because of the missing libraries above. Install them and run this again; until then stay on the Vulkan build." }
    else { Write-Warn 'the ROCm build does not see the card although hipBLAS/rocBLAS were found (an older AMD driver, or libraries from another ROCm version than 10?): stay on the Vulkan build.' }
    Remove-RocmFolder
    return
}

Write-Step 'measure both builds (the day server is stopped meanwhile; the laptop model takes over)'
$results = @{}
try {
    Invoke-Action "stop the day server (task 'llama-server')" {
        Stop-ScheduledTask -TaskName 'llama-server' -ErrorAction SilentlyContinue
        Stop-LlamaServer -Dir $llama
    }
    $results['vulkan'] = Invoke-Bench $llama $vkDev $vkEnv
    $results['rocm'] = Invoke-Bench $rocm $rocmDev @{}
} finally {
    Invoke-Action "start the day server again (task 'llama-server')" { Start-ScheduledTask -TaskName 'llama-server' }
}
Remove-RocmFolder
if ($script:HsDryRun) { return }

Write-Step 'result (tokens per second, higher is better)'
$rows = foreach ($v in $results['vulkan']) {
    $r = @($results['rocm'] | Where-Object { $_.Test -eq $v.Test -and $_.Depth -eq $v.Depth })[0]
    [pscustomobject]@{
        Test = $v.Test; Depth = $v.Depth; Vulkan = $v.TokensPerSecond
        ROCm = $(if ($r) { $r.TokensPerSecond } else { $null })
        Change = $(if ($r -and $v.TokensPerSecond -gt 0) { '{0:+0;-0}%' -f (100 * ($r.TokensPerSecond / $v.TokensPerSecond - 1)) } else { 'n/a' })
    }
}
$rows | Format-Table -AutoSize | Out-Host
$tg = @($rows | Where-Object { $_.Test -like 'tg*' -and $null -ne $_.ROCm })
if (-not $tg) { Write-Warn 'no comparable generation results: stay on the Vulkan build'; return }
# generation speed is what an agent waits on most; every depth must win, not just the average
$worst = ($tg | ForEach-Object { $_.ROCm / $_.Vulkan } | Measure-Object -Minimum).Minimum
if ($worst -ge 1.10) {
    Write-Ok ('ROCm generates at least {0:0}% faster at every depth. Switch with:  .\Update-Llama.ps1 -Backend rocm' -f (100 * ($worst - 1)))
    if ($RocmLibDir) { Write-Warn "first put $RocmLibDir on the SYSTEM PATH: the server task does not see -RocmLibDir" }
} else {
    Write-Ok 'ROCm is not clearly faster (less than 10% at some depth): stay on the Vulkan build'
}
