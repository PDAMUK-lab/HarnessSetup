<#
.SYNOPSIS
  Measure whether llama.cpp's ROCm (HIP) build is faster than the Vulkan build on this desktop's card. C:\llama is not changed.
.DESCRIPTION
  Run in an ADMINISTRATOR PowerShell when Hermes can do without the desktop model for about 15 minutes (the day server is
  stopped while it measures; the laptop's model takes over as usual, and the day server is started again at the end).
    - downloads the newest llama.cpp ROCm build into <DESKTOP_LLAMA_DIR>-rocm (e.g. C:\llama-rocm)
    - checks that build sees the card (--list-devices). The RX 6600 XT (gfx1032) is not on AMD's Windows ROCm list, so it
      may not; then the answer is simply "stay on Vulkan"
    - runs the same llama-bench on both builds: the day model with its expert split (DESKTOP_N_CPU_MOE) and cache types,
      2048 prompt tokens and 128 generated, on an empty context and 32768 tokens deep
    - prints the table and the advice. Switch only when ROCm wins by more than 10%:  .\Update-Llama.ps1 -Backend rocm
      (it keeps the Vulkan build in prev\ and checks tool calls; .\Update-Llama.ps1 -Backend vulkan goes back)
  -ZipUrl URL takes the ROCm zip by hand (when a release names it differently); -Depths '0,65536' and -Repetitions 5 change
  the measurement; -KeepRocm keeps the ROCm folder (it is removed at the end otherwise).
.EXAMPLE
  .\Compare-LlamaBackends.ps1 -DryRun     # show what would happen, change nothing
#>
[CmdletBinding()]
param(
    [string]$ConfigFile,
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
$benchArgs = @('-m', $model, '-ngl', '99', '-ncmoe', $cfg['DESKTOP_N_CPU_MOE'], '-fa', '1', '-ctk', 'f16', '-ctv', 'q8_0',
    '-p', '2048', '-n', '128', '-d', $Depths, '-r', "$Repetitions", '-o', 'csv')

if (-not $script:HsDryRun) {
    if (-not (Test-Path -LiteralPath "$llama\llama-bench.exe")) { throw "no llama-bench.exe in ${llama}: run Install-Llama.ps1 first" }
    if (-not (Test-Path -LiteralPath $model)) { throw "the day model is not there: $model" }
}

function Invoke-Bench([string]$Dir) {
    $exe = "$Dir\llama-bench.exe"
    if ($script:HsDryRun) { Write-Host "[dry-run] $exe $($benchArgs -join ' ')" -ForegroundColor DarkGray; return @() }
    Write-Host "    $exe $($benchArgs -join ' ')"
    $text = Invoke-NativeText { & $exe @benchArgs }
    if ($LASTEXITCODE -ne 0) { Write-Warn "llama-bench failed in $Dir ($LASTEXITCODE): $(($text -split "`n" | Select-Object -Last 3) -join ' | ')"; return @() }
    return ConvertFrom-LlamaBenchCsv $text
}

Write-Step "the ROCm build in $rocm ($llama is not touched)"
Invoke-Action "download and extract the latest llama-*-bin-win-hip zip into $rocm" {
    New-Item -ItemType Directory -Force -Path $rocm | Out-Null
    $null = Install-LlamaVulkanBuild -Dir $rocm -Backend rocm -ZipUrl $ZipUrl
}
$seen = $true
Invoke-Action "llama-cli.exe --list-devices in $rocm (the card must be listed as ROCm0)" {
    $devices = Invoke-NativeText { & "$rocm\llama-cli.exe" --list-devices }
    Write-Host $devices
    $script:seen = ($LASTEXITCODE -eq 0 -and $devices -match '(ROCm|HIP)[0-9]+:')
}
if (-not $seen) {
    Write-Warn 'the ROCm build does not see the card (or does not start): stay on the Vulkan build. Nothing was changed.'
    if (-not $KeepRocm) { Invoke-Action "remove $rocm" { Remove-Item -LiteralPath $rocm -Recurse -Force } }
    return
}

Write-Step 'measure both builds (the day server is stopped meanwhile; the laptop model takes over)'
$results = @{}
try {
    Invoke-Action "stop the day server (task 'llama-server')" {
        Stop-ScheduledTask -TaskName 'llama-server' -ErrorAction SilentlyContinue
        Stop-LlamaServer -Dir $llama
    }
    $results['vulkan'] = Invoke-Bench $llama
    $results['rocm'] = Invoke-Bench $rocm
} finally {
    Invoke-Action "start the day server again (task 'llama-server')" { Start-ScheduledTask -TaskName 'llama-server' }
}
if (-not $KeepRocm) { Invoke-Action "remove $rocm (-KeepRocm keeps it)" { Remove-Item -LiteralPath $rocm -Recurse -Force } }
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
} else {
    Write-Ok 'ROCm is not clearly faster (less than 10% at some depth): stay on the Vulkan build'
}
