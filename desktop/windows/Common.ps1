# Shared helpers for the HarnessSetup Windows scripts. Dot-source it: . "$PSScriptRoot\Common.ps1"
# Works in Windows PowerShell 5.1 and PowerShell 7. The helpers that touch Windows (tasks, firewall)
# live in the scripts, inside Invoke-Action blocks, so -DryRun can run a script anywhere.
Set-StrictMode -Version Latest

$script:HsDryRun = $false

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host " ok $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "warn $Message" -ForegroundColor Yellow }

# Invoke-Action "what it does" { code }  - runs the block, or only prints it under -DryRun
function Invoke-Action {
    param([Parameter(Mandatory)][string]$What, [Parameter(Mandatory)][scriptblock]$Do)
    if ($script:HsDryRun) { Write-Host "[dry-run] $What" -ForegroundColor DarkGray; return }
    & $Do
}

function Assert-Admin {
    if ($script:HsDryRun) { return }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an administrator PowerShell (right-click PowerShell > Run as administrator).'
    }
}

function Get-DefaultConfigPath {
    Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'config/node.env'
}

# Read-NodeEnv PATH  - parse config/node.env (KEY=value, optional quotes, # comments) into an ordered dictionary
function Read-NodeEnv {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing $Path - copy config\node.env.example to config\node.env and edit it."
    }
    $cfg = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        $key = $Matches[1]
        $val = $Matches[2].Trim()
        if ($val -match '^"([^"]*)"') { $val = $Matches[1] }
        elseif ($val -match "^'([^']*)'") { $val = $Matches[1] }
        else { $val = $val -replace '\s+#.*$', '' }
        $cfg[$key] = $val
    }
    return $cfg
}

# Assert-Config $cfg 'KEY',...  - every key must be set, non-empty and not a <placeholder>
function Assert-Config {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Cfg, [Parameter(Mandatory)][string[]]$Keys)
    $bad = @($Keys | Where-Object { -not $Cfg.Contains($_) -or [string]::IsNullOrWhiteSpace($Cfg[$_]) -or $Cfg[$_] -match '<|CHANGEME' })
    if ($bad.Count -gt 0) { throw "Set these in config\node.env: $($bad -join ', ')" }
}

# New-ApiKey  - 32 random bytes from the OS generator as 64 hex characters (no quoting problems anywhere)
function New-ApiKey {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}

# Test-GgufFile PATH  - does the file start with the GGUF magic? (a saved HTML 404 page does not)
function Test-GgufFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 4
        if ($fs.Read($buf, 0, 4) -ne 4) { return $false }
        return ([System.Text.Encoding]::ASCII.GetString($buf) -eq 'GGUF')
    } finally { $fs.Dispose() }
}

# Save-Model URL DEST  - resumable download with curl.exe (ships with Windows 10+), then checks the GGUF magic
function Save-Model {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Dest)
    if (Test-GgufFile $Dest) { Write-Ok "already downloaded: $Dest"; return }
    Write-Step "downloading $(Split-Path $Dest -Leaf) (large; re-run to resume if interrupted)"
    Invoke-Action "curl.exe -L --fail -C - -o $Dest $Url" {
        & curl.exe -L --fail --retry 5 --retry-delay 5 -C - -o $Dest $Url
        if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit $LASTEXITCODE). Check the exact file name on the repo's Files tab." }
        if (-not (Test-GgufFile $Dest)) { throw "$Dest is not a GGUF file. Check the exact file name on the repo's Files tab." }
    }
}

# Select-VulkanAsset $assets  - the win-vulkan-x64 zip from a llama.cpp release's asset list
function Select-VulkanAsset {
    param([Parameter(Mandatory)][object[]]$Assets)
    $hit = $Assets | Where-Object { $_.name -match '^llama-.*-bin-win-vulkan-x64\.zip$' } | Select-Object -First 1
    if (-not $hit) { throw 'No win-vulkan-x64 zip in the latest llama.cpp release. Download it by hand from https://github.com/ggml-org/llama.cpp/releases' }
    return $hit
}

# New-LlamaStartScript -Cfg $cfg -Tier Day|Night  - lines of the cmd file that starts llama-server (guide Steps 19 and 31)
function New-LlamaStartScript {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Cfg,
        [ValidateSet('Day', 'Night')][string]$Tier = 'Day'
    )
    $dir = $Cfg['DESKTOP_LLAMA_DIR']
    $models = $Cfg['DESKTOP_MODELS_DIR']
    if ($Tier -eq 'Day') {
        $file = $Cfg['DESKTOP_MODEL_FILE']; $alias = $Cfg['DESKTOP_MODEL_ALIAS']
        $tail = @(
            "  --jinja -ngl 99 --n-cpu-moe $($Cfg['DESKTOP_N_CPU_MOE']) -fa on -np 1 -c $($Cfg['DESKTOP_CTX']) -ctk f16 -ctv q8_0 ^",
            "  --cache-ram $($Cfg['DESKTOP_CACHE_RAM_MB']) --chat-template-kwargs `"{\`"preserve_thinking\`":true}`" ^",
            '  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0'
        )
    } else {
        $file = $Cfg['NIGHT_MODEL_FILE']; $alias = $Cfg['NIGHT_MODEL_ALIAS']
        $tail = @(
            "  --jinja -ngl $($Cfg['NIGHT_NGL']) -fa on -np 1 -c $($Cfg['DESKTOP_CTX']) -ctk f16 -ctv q8_0 --cache-ram $($Cfg['DESKTOP_CACHE_RAM_MB']) ^",
            "  --chat-template-kwargs `"{\`"reasoning_effort\`":\`"high\`"}`" ^",
            '  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 ^',
            '  --spec-type draft-mtp --spec-draft-n-max 2'
        )
    }
    $head = @(
        "$dir\llama-server.exe -m $models\$file --alias $alias ^",
        "  --host $($Cfg['DESKTOP_IP']) --port $($Cfg['LLM_PORT']) --api-key-file $dir\api-key.txt ^"
    )
    return @($head + $tail)
}

# Write-CmdFile PATH LINES  - cmd.exe wants CRLF line endings, no BOM
function Write-CmdFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Lines)
    Invoke-Action "write $Path" {
        [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    }
}

# New-TunnelCmd -Cfg $cfg  - the SSH tunnel that publishes the laptop's dashboard on localhost (guide Step 15)
function New-TunnelCmd {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Cfg)
    $p = $Cfg['DASHBOARD_PORT']
    return @(
        '@echo off',
        'title Hermes dashboard tunnel - leave this window open',
        "echo Browse to http://localhost:$p",
        "ssh -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -L ${p}:127.0.0.1:${p} $($Cfg['ADMIN_USER'])@$($Cfg['LAPTOP_IP'])"
    )
}

# Wait-Http URL SECONDS [Headers]  - poll until the URL answers 2xx
function Wait-Http {
    param([Parameter(Mandatory)][string]$Url, [int]$Seconds = 120, [hashtable]$Headers = @{})
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
        } catch { Start-Sleep -Seconds 3 }
    }
    return $false
}

# Test-ToolCall BASE_URL MODEL [KEY]  - $true only if the model answers with a get_weather tool call (guide Step 20)
function Test-ToolCall {
    param([Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][string]$Model, [string]$ApiKey = '')
    $headers = @{}
    if ($ApiKey) { $headers['Authorization'] = "Bearer $ApiKey" }
    $body = @{
        model    = $Model
        messages = @(@{ role = 'user'; content = 'Weather in Paris?' })
        tools    = @(@{ type = 'function'; function = @{
                    name = 'get_weather'
                    parameters = @{ type = 'object'; properties = @{ city = @{ type = 'string' } }; required = @('city') }
                } })
    } | ConvertTo-Json -Depth 10
    try {
        $r = Invoke-RestMethod -Method Post -Uri "$BaseUrl/v1/chat/completions" -Headers $headers `
            -ContentType 'application/json' -Body $body -TimeoutSec 600
        # a server started without --jinja answers in prose: the message then has no tool_calls property at all
        $prop = $r.choices[0].message.PSObject.Properties['tool_calls']
        if (-not $prop -or -not $prop.Value) { return $false }
        return [bool]($prop.Value[0].function.name -eq 'get_weather')
    } catch { return $false }
}
