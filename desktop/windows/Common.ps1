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

# ConvertFrom-EnvValue "text after KEY="  - the value the shell would assign: '...' and "..." segments, \x escapes,
# stops at the first unquoted blank (a trailing # comment). Never evaluates anything. Mirrors cfg_unquote in lib/config.sh.
function ConvertFrom-EnvValue {
    param([AllowEmptyString()][string]$Text)
    $t = $Text.TrimStart()
    $sb = New-Object System.Text.StringBuilder
    $mode = 'bare'
    for ($i = 0; $i -lt $t.Length; $i++) {
        $c = [string]$t[$i]
        if ($mode -eq 'bare') {
            if ($c -eq "'") { $mode = 'single' }
            elseif ($c -eq '"') { $mode = 'double' }
            elseif ($c -eq '\') { $i++; if ($i -lt $t.Length) { [void]$sb.Append($t[$i]) } }
            elseif ($c -eq ' ' -or $c -eq "`t") { break }
            else { [void]$sb.Append($c) }
        } elseif ($mode -eq 'single') {
            if ($c -eq "'") { $mode = 'bare' } else { [void]$sb.Append($c) }
        } else {
            if ($c -eq '"') { $mode = 'bare' }
            elseif ($c -eq '\' -and ($i + 1) -lt $t.Length -and '"\$`'.Contains([string]$t[$i + 1])) { $i++; [void]$sb.Append($t[$i]) }
            else { [void]$sb.Append($c) }
        }
    }
    return $sb.ToString()
}

# Read-NodeEnv PATH  - parse config/node.env (KEY=value, optional export, quotes, # comments) into an ordered dictionary
function Read-NodeEnv {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing $Path - run .\Configure.ps1 (it asks for the settings) or copy the laptop's config/node.env there."
    }
    $cfg = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        $cfg[$Matches[1]] = ConvertFrom-EnvValue $Matches[2]
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

# Resolve-ModelSetting VALUE AUTO  - a *_CHAT_KWARGS / *_SAMPLING value: 'auto' (or missing) = AUTO, 'none' = nothing
function Resolve-ModelSetting {
    param([AllowEmptyString()][AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Auto)
    if (-not $Value -or $Value -ceq 'auto') { return $Auto }
    if ($Value -ceq 'none') { return '' }
    return $Value
}

# Get-ModelSetting -Cfg $cfg -Key DESKTOP_SAMPLING -Type sampling -Auto '...'  - the validated, resolved value ('' = leave out).
# The start scripts are built from the settings file's raw text, so check it here: a bad value would break the cmd file.
function Get-ModelSetting {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Cfg, [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][ValidateSet('kwargs', 'sampling')][string]$Type, [Parameter(Mandatory)][string]$Auto)
    $raw = if ($Cfg.Contains($Key)) { [string]$Cfg[$Key] } else { '' }
    if (-not $raw) { return $Auto }
    $t = Test-SettingValue -Type $Type -Value $raw
    if (-not $t.Ok) { throw "${Key}: $($t.Error) (got '$raw'). Fix it with .\Configure.ps1 -Only $Key" }
    return (Resolve-ModelSetting $t.Norm $Auto)
}

# ConvertTo-CmdKwargs 'a=true,b=medium'  - the --chat-template-kwargs argument as a cmd file needs it: "{\"a\":true,\"b\":\"medium\"}"
function ConvertTo-CmdKwargs {
    param([Parameter(Mandatory)][string]$Pairs)
    $parts = foreach ($kv in ($Pairs -split ',')) {
        $k, $val = $kv -split '=', 2
        # bare only for true/false and valid JSON numbers (no leading zeros); everything else is a string
        if ($val -cmatch '^(true|false|-?(0|[1-9][0-9]*)(\.[0-9]+)?)$') { '\"' + $k + '\":' + $val } else { '\"' + $k + '\":\"' + $val + '\"' }
    }
    return '"{' + ($parts -join ',') + '}"'
}

# Join-CmdLines SEGMENTS  - continuation lines for a cmd file: ' ^' after every line but the last; empty segments are dropped
function Join-CmdLines {
    param([AllowEmptyCollection()][string[]]$Segments)
    $s = @($Segments | Where-Object { $_ -and $_.Trim() })
    for ($i = 0; $i -lt $s.Count - 1; $i++) { $s[$i] = $s[$i] + ' ^' }
    return , $s
}

# New-LlamaStartScript -Cfg $cfg -Tier Day|Night  - lines of the cmd file that starts llama-server (guide Steps 19 and 31)
function New-LlamaStartScript {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Cfg,
        [ValidateSet('Day', 'Night')][string]$Tier = 'Day'
    )
    $dir = $Cfg['DESKTOP_LLAMA_DIR']
    $models = $Cfg['DESKTOP_MODELS_DIR']
    # *_CHAT_KWARGS / *_SAMPLING: 'auto' = the kit's values for the Qwen model it ships (docs/MODELS.md for other families)
    if ($Tier -eq 'Day') {
        $file = $Cfg['DESKTOP_MODEL_FILE']; $alias = $Cfg['DESKTOP_MODEL_ALIAS']
        $kw = Get-ModelSetting -Cfg $Cfg -Key DESKTOP_CHAT_KWARGS -Type kwargs -Auto 'preserve_thinking=true'
        $smp = Get-ModelSetting -Cfg $Cfg -Key DESKTOP_SAMPLING -Type sampling -Auto '--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0'
        $tail = @(
            "  --jinja -ngl 99 --n-cpu-moe $($Cfg['DESKTOP_N_CPU_MOE']) -fa on -np 1 -c $($Cfg['DESKTOP_CTX']) -ctk f16 -ctv q8_0",
            "  --cache-ram $($Cfg['DESKTOP_CACHE_RAM_MB'])$(if ($kw) { ' --chat-template-kwargs ' + (ConvertTo-CmdKwargs $kw) })",
            "  $smp"
        )
    } else {
        $file = $Cfg['NIGHT_MODEL_FILE']; $alias = $Cfg['NIGHT_MODEL_ALIAS']
        $kw = Get-ModelSetting -Cfg $Cfg -Key NIGHT_CHAT_KWARGS -Type kwargs -Auto 'reasoning_effort=medium'
        $smp = Get-ModelSetting -Cfg $Cfg -Key NIGHT_SAMPLING -Type sampling -Auto '--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0'
        # missing = on (older settings files); any bool01 spelling of no (0, n, no, false, off) = off
        $mtp = -not ($Cfg.Contains('NIGHT_MTP') -and [string]$Cfg['NIGHT_MTP'] -and (Test-SettingValue -Type bool01 -Value ([string]$Cfg['NIGHT_MTP'])).Norm -eq '0')
        $tail = @(
            "  --jinja -ngl $($Cfg['NIGHT_NGL']) -fa on -np 1 -c $($Cfg['DESKTOP_CTX']) -ctk f16 -ctv q8_0 --cache-ram $($Cfg['DESKTOP_CACHE_RAM_MB'])",
            $(if ($kw) { '  --chat-template-kwargs ' + (ConvertTo-CmdKwargs $kw) }),
            "  $smp",
            $(if ($mtp) { '  --spec-type draft-mtp --spec-draft-n-max 2' })
        )
    }
    $head = @(
        "$dir\llama-server.exe -m $models\$file --alias $alias",
        "  --host $($Cfg['DESKTOP_IP']) --port $($Cfg['LLM_PORT']) --api-key-file $dir\api-key.txt"
    )
    # With the V100 tier on, keep this Vulkan server on the RX 6600 XT: hide NVIDIA's Vulkan driver from it (a V100 is compute-only
    # and should not show up in Vulkan at all; this makes sure, and Install-V100.ps1 / Check-V100.ps1 verify it)
    $guard = @()
    if ($Cfg.Contains('V100_ENABLED') -and $Cfg['V100_ENABLED'] -eq '1') { $guard = @('set VK_LOADER_DRIVERS_DISABLE=*nv*') }
    return @($guard + (Join-CmdLines -Segments @($head + $tail)))
}

# The release asset names of the two Windows builds for an AMD card
$script:LlamaAssetPatterns = @{
    vulkan = '^llama-.+-bin-win-vulkan-x64\.zip$'
    # the HIP (ROCm) build, e.g. llama-bNNNN-bin-win-hip-radeon-x64.zip. Whether it supports the RX 6600 XT (gfx1032) is
    # checked by Compare-LlamaBackends.ps1 with --list-devices, not assumed.
    rocm   = '^llama-.+-bin-win-(hip|rocm)[a-z0-9.-]*-x64\.zip$'
}

# Install-LlamaVulkanBuild -Dir C:\llama [-Backend vulkan|rocm] [-ZipUrl URL]  - download the newest llama.cpp Windows build
# for the backend and unpack it into Dir (stops the server running from Dir first). Used by Install-Llama.ps1,
# Update-Llama.ps1 and Compare-LlamaBackends.ps1. -ZipUrl takes a zip by hand (e.g. when a release renames its assets).
function Install-LlamaVulkanBuild {
    param([Parameter(Mandatory)][string]$Dir, [ValidateSet('vulkan', 'rocm')][string]$Backend = 'vulkan', [string]$ZipUrl = '')
    if ($ZipUrl) {
        $name = ($ZipUrl -split '/')[-1]; $url = $ZipUrl; $tag = 'given by hand'
    } else {
        # not /releases/latest: that is a source-only tag; the builds are pre-releases
        $pattern = $script:LlamaAssetPatterns[$Backend]
        $rel = Select-LlamaRelease -Releases (Get-LlamaReleases) -Patterns $pattern
        if (-not $rel) { throw "None of the ten newest llama.cpp releases has a Windows $Backend zip. Download it from https://github.com/ggml-org/llama.cpp/releases and pass -ZipUrl." }
        $asset = if ($Backend -eq 'vulkan') { Select-VulkanAsset $rel.assets } else { @($rel.assets | Where-Object { $_.name -cmatch $pattern })[0] }
        $name = $asset.name; $url = $asset.browser_download_url; $tag = $rel.tag_name
    }
    $zip = Join-Path ([IO.Path]::GetTempPath()) $name
    Write-Host "    ${tag}: $name"
    & curl.exe -L --fail -o $zip $url
    if ($LASTEXITCODE -ne 0) { throw 'download of the llama.cpp zip failed' }
    Stop-LlamaServer -Dir $Dir
    # the old programs and backend DLLs go first: a leftover ggml-vulkan.dll next to a ROCm build (or the other way round)
    # would be loaded too, and the server would see the card twice. Start scripts, the key and prev\ stay.
    Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.dll' } | Remove-Item -Force
    Expand-Archive -Path $zip -DestinationPath $Dir -Force
    Remove-Item $zip
    # some zips unpack into a subfolder: move the binaries up to Dir
    $exe = Get-ChildItem -Path $Dir -Recurse -Filter llama-server.exe | Where-Object { $_.DirectoryName -notlike "$Dir\prev*" } | Select-Object -First 1
    if ($exe -and $exe.DirectoryName -ne $Dir) { Move-Item -Path "$($exe.DirectoryName)\*" -Destination $Dir -Force }
    Set-Content -LiteralPath "$Dir\llama-backend.txt" -Value $Backend -Encoding ascii
    return $tag
}

# Get-LlamaBackend -Dir C:\llama  - vulkan or rocm: the build Install-LlamaVulkanBuild last put there (vulkan when unknown)
function Get-LlamaBackend {
    param([Parameter(Mandatory)][string]$Dir)
    $f = "$Dir\llama-backend.txt"
    if ((Test-Path -LiteralPath $f) -and ((Get-Content -LiteralPath $f -Raw).Trim() -ceq 'rocm')) { return 'rocm' }
    return 'vulkan'
}

# ConvertFrom-LlamaBenchCsv TEXT  - rows of `llama-bench -o csv`: { Test (pp2048 / tg128); Depth; TokensPerSecond }.
# TEXT may hold llama-bench's log lines too (stderr is merged): only the header line and the quoted value lines count.
function ConvertFrom-LlamaBenchCsv {
    param([AllowEmptyString()][string]$Text = '')
    $all = @($Text -split "`r?`n")
    $start = @(for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i] -match '(^|,)"?avg_ts"?(,|$)') { $i } })
    if (-not $start) { return @() }
    $lines = @($all[$start[0]]) + @($all | Select-Object -Skip ($start[0] + 1) | Where-Object { $_ -match '^"' })
    if ($lines.Count -lt 2) { return @() }
    $rows = $lines | ConvertFrom-Csv
    return @($rows | Where-Object { $_.avg_ts } | ForEach-Object {
            $test = if ([int]$_.n_prompt -gt 0) { "pp$($_.n_prompt)" } else { "tg$($_.n_gen)" }
            $depth = if ($_.PSObject.Properties['n_depth']) { [int]$_.n_depth } else { 0 }
            [pscustomobject]@{ Test = $test; Depth = $depth; TokensPerSecond = [math]::Round([double]::Parse($_.avg_ts, [Globalization.CultureInfo]::InvariantCulture), 2) }
        })
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
        "ssh -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -L ${p}:127.0.0.1:${p} $($Cfg['ADMIN_USER'])@$($Cfg['LAPTOP_IP'])",
        'echo.',
        'echo The tunnel has stopped. Read any message above, then press a key to close.',
        'pause'
    )
}

# ============================ asking the user ============================
# Test seam: $env:HS_INPUT = a file of answers, one per line (empty line = accept the default).

$script:HsAssumeYes = $false
$script:HsInputLines = $null
$script:HsInputIndex = 0

function Test-Interactive {
    if ($script:HsAssumeYes) { return $false }
    if ($env:HS_INPUT) { return $true }
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

# Read-Answer "prompt"  - one trimmed line from the keyboard (or from HS_INPUT)
function Read-Answer {
    param([Parameter(Mandatory)][string]$Prompt)
    if ($env:HS_INPUT) {
        if ($null -eq $script:HsInputLines) {
            $script:HsInputLines = @(Get-Content -LiteralPath $env:HS_INPUT)
            $script:HsInputIndex = 0
        }
        if ($script:HsInputIndex -ge $script:HsInputLines.Count) { throw "the scripted answers (HS_INPUT) ran out at: $Prompt" }
        $a = [string]$script:HsInputLines[$script:HsInputIndex]
        $script:HsInputIndex++
        Write-Host "$Prompt $a"
    } else {
        $a = Read-Host -Prompt $Prompt
    }
    return ([string]$a).Trim()
}

# Read-YesNo "Question?" [-Default $true]  - without a terminal (or with -Yes) the default answers
function Read-YesNo {
    param([Parameter(Mandatory)][string]$Question, [bool]$Default = $false)
    if (-not (Test-Interactive)) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $a = (Read-Answer "$Question [$hint]").ToLowerInvariant()
        if ($a -eq '') { return $Default }
        if ($a -in 'y', 'yes') { return $true }
        if ($a -in 'n', 'no') { return $false }
        Write-Warn 'please answer y or n'
    }
}

# Resolve-Option -Bound $PSBoundParameters -Name Foo -Current $Foo -Question "..." -Default $false
# A switch given on the command line wins and is not asked about; otherwise ask.
function Resolve-Option {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bound,
        [Parameter(Mandatory)][string]$Name,
        [bool]$Current = $false,
        [Parameter(Mandatory)][string]$Question,
        [bool]$Default = $false
    )
    if ($Bound.Keys -contains $Name) { return $Current }
    return (Read-YesNo -Question $Question -Default $Default)
}

# ============================ the settings schema ============================

function Get-SchemaPath {
    if ($env:HS_SCHEMA) { return $env:HS_SCHEMA }
    return (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'config/settings.schema')
}

# Get-SettingsSchema  - the rows of config/settings.schema (shared with the bash wizard)
function Get-SettingsSchema {
    $group = ''
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in Get-Content -LiteralPath (Get-SchemaPath)) {
        if ($line.StartsWith('#>')) { $group = $line.Substring(2).Trim(); continue }
        if ($line.Trim() -eq '' -or $line.StartsWith('#')) { continue }
        $f = $line -split '\|', 8
        $rows.Add([pscustomobject]@{
                Key = $f[0]; Scope = $f[1]; Level = $f[2]; Type = $f[3]; Default = $f[4]
                When = $f[5]; Prompt = $f[6]; Help = $f[7]; Group = $group
            })
    }
    return , $rows.ToArray()
}

function Expand-Setting {
    param([string]$Text, [System.Collections.IDictionary]$Values)
    foreach ($m in [regex]::Matches($Text, '\{([A-Z0-9_]+)\}')) {
        $Text = $Text.Replace($m.Value, [string]$Values[$m.Groups[1].Value])
    }
    return $Text
}

function Test-IPv4([string]$Value) {
    return ($Value -cmatch '^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$')
}

# Get-NetworkNetwork "a.b.c.d/p"  - the network address, e.g. 192.168.1.150/24 -> 192.168.1.0/24
function Get-NetworkAddress([string]$Cidr) {
    $ip, $p = $Cidr -split '/'
    $o = $ip -split '\.' | ForEach-Object { [uint32]$_ }
    $n = ([uint32]$o[0] -shl 24) -bor ([uint32]$o[1] -shl 16) -bor ([uint32]$o[2] -shl 8) -bor [uint32]$o[3]
    $prefix = [int]$p
    $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32](([uint64]4294967295 -shl (32 - $prefix)) -band [uint64]4294967295) }
    $n = $n -band $mask
    return ('{0}.{1}.{2}.{3}/{4}' -f (($n -shr 24) -band 255), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255), $prefix)
}

# Test-SettingValue TYPE VALUE  - { Ok; Norm; Error } (mirrors cfg_validate in lib/config.sh)
function Test-SettingValue {
    param([Parameter(Mandatory)][string]$Type, [AllowEmptyString()][string]$Value)
    $r = { param($ok, $norm, $err) [pscustomobject]@{ Ok = $ok; Norm = $norm; Error = $err } }
    $v = $Value
    if ($Type -ne 'optmodel' -and $v -eq '') { return & $r $false $v 'a value is required' }
    if ($v -match "['""`$``]" -or $v -match "[\r\n]") { return & $r $false $v 'quotes, $ and backticks are not allowed' }
    if ($v.Contains('\') -and $Type -ne 'winpath') { return & $r $false $v 'backslashes are not allowed here' }
    if ($v -cmatch 'yourorg|yourrepo|CHANGEME|<' -or $v.StartsWith('12345678+')) { return & $r $false $v 'that is still the example value' }
    switch -Regex ($Type) {
        '^ip$' {
            if (Test-IPv4 $v) { return & $r $true $v '' }
            return & $r $false $v 'expected an IPv4 address like 192.168.1.150'
        }
        '^cidr$' {
            if ($v -cmatch '^([0-9.]+)/([0-9]{1,2})$' -and (Test-IPv4 $Matches[1]) -and [int]$Matches[2] -ge 8 -and [int]$Matches[2] -le 30) {
                return & $r $true (Get-NetworkAddress $v) ''
            }
            return & $r $false $v 'expected a network like 192.168.1.0/24 (prefix 8 to 30)'
        }
        '^port$' {
            if ($v -cmatch '^[1-9][0-9]{0,4}$' -and [int]$v -le 65535) { return & $r $true $v '' }
            return & $r $false $v 'expected a port number from 1 to 65535'
        }
        '^int:(\d+)-(\d+)$' {
            $lo = [long]$Matches[1]; $hi = [long]$Matches[2]
            if ($v -cmatch '^[0-9]{1,9}$' -and [long]$v -ge $lo -and [long]$v -le $hi) { return & $r $true ([string][long]$v) '' }
            return & $r $false $v "expected a whole number from $lo to $hi"
        }
        '^bool01$' {
            switch ($v.ToLowerInvariant()) {
                { $_ -in '1', 'y', 'yes', 'true', 'on' } { return & $r $true '1' '' }
                { $_ -in '0', 'n', 'no', 'false', 'off' } { return & $r $true '0' '' }
            }
            return & $r $false $v 'answer y or n'
        }
        '^unixuser$' {
            if ($v -cmatch '^[a-z_][a-z0-9_-]{0,31}$' -and $v -ne 'root') { return & $r $true $v '' }
            return & $r $false $v 'expected a lower-case Linux user name (not root)'
        }
        '^ghname$' {
            if ($v -cmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$' -and -not $v.Contains('--')) { return & $r $true $v '' }
            return & $r $false $v 'expected a GitHub user or organisation name (letters, digits, single hyphens)'
        }
        '^repos$' {
            $norm = (($v -split '\s+') | Where-Object { $_ -ne '' }) -join ' '
            if ($norm -eq '') { return & $r $false $v 'a value is required' }
            foreach ($w in $norm -split ' ') {
                if ($w -cnotmatch '^[A-Za-z0-9._-]+$' -or $w -in '.', '..') { return & $r $false $v "'$w' is not a repository name (names only, no owner/ prefix)" }
            }
            return & $r $true $norm ''
        }
        '^noreply$' {
            if ($v -cmatch '^([0-9]+\+)?[A-Za-z0-9-]+@users\.noreply\.github\.com$') { return & $r $true $v '' }
            return & $r $false $v 'expected ID+name@users.noreply.github.com (machine account > Settings > Emails)'
        }
        '^(model|optmodel)$' {
            if ($Type -eq 'optmodel' -and ($v -eq '' -or $v -eq '-')) { return & $r $true '' '' }
            if ($v -cmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._:+-]+$') { return & $r $true $v '' }
            return & $r $false $v 'expected an OpenRouter model ID like vendor/model-name'
        }
        '^gguf$' {
            if ($v -cmatch '^[A-Za-z0-9._-]+\.gguf$') { return & $r $true $v '' }
            return & $r $false $v 'expected a file name ending in .gguf'
        }
        '^url$' {
            if ($v -cmatch '^https://[A-Za-z0-9._~:/?#@!&*+,;=%-]+$') { return & $r $true $v '' }
            return & $r $false $v 'expected an https:// URL without spaces or quotes'
        }
        '^time$' {
            if ($v -cmatch '^([01]?[0-9]|2[0-3]):([0-5][0-9])$') { return & $r $true ('{0:D2}:{1}' -f [int]$Matches[1], $Matches[2]) '' }
            return & $r $false $v 'expected a time like 01:00 (24-hour)'
        }
        '^winpath$' {
            if ($v -cmatch '^[A-Za-z]:\\[A-Za-z0-9._\\-]+$') { return & $r $true $v.TrimEnd('\') '' }
            return & $r $false $v 'expected a Windows folder without spaces, like C:\llama'
        }
        '^alias$' {
            if ($v -cnotmatch '^[A-Za-z][A-Za-z0-9._-]*$') { return & $r $false $v 'expected a name starting with a letter (then letters, digits, dots, dashes)' }
            if ($v.ToLowerInvariant() -in 'true', 'false', 'yes', 'no', 'on', 'off', 'null', 'y', 'n') { return & $r $false $v "'$v' would be read as a yes/no/null value in the YAML config" }
            return & $r $true $v ''
        }
        '^kwargs$' {
            if ($v -ceq 'none' -or $v -ceq 'auto') { return & $r $true $v '' }
            if ($v -match ',,' -or $v.StartsWith(',') -or $v.EndsWith(',')) { return & $r $false $v 'empty pair (two commas, or a comma at the start or end)' }
            $pairs = @($v -split ',')
            if ($pairs.Count -lt 1 -or $pairs.Count -gt 8) { return & $r $false $v 'expected 1 to 8 key=value pairs separated by commas, or none / auto' }
            $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)   # template keys are case-sensitive (as in bash)
            foreach ($w in $pairs) {
                if ($w -cnotmatch '^([A-Za-z_][A-Za-z0-9_]*)=[A-Za-z0-9._-]+$') { return & $r $false $v "'$w' is not key=value (letters, digits, . _ - only; no spaces)" }
                if (-not $seen.Add($Matches[1])) { return & $r $false $v "'$($Matches[1])' is given twice" }
            }
            return & $r $true $v ''
        }
        '^sampling$' {
            if ($v -ceq 'none' -or $v -ceq 'auto') { return & $r $true $v '' }
            $words = @($v.Trim() -split '\s+' | Where-Object { $_ -ne '' })
            if ($words.Count -lt 2 -or $words.Count % 2 -ne 0) { return & $r $false $v 'expected flag value pairs like --temp 0.6 --top-p 0.95, or none / auto' }
            $allowed = '--temp', '--top-p', '--top-k', '--min-p', '--presence-penalty', '--frequency-penalty', '--repeat-penalty', '--repeat-last-n', '--typical',
                '--top-nsigma', '--xtc-probability', '--xtc-threshold', '--dry-multiplier', '--dry-base', '--dry-allowed-length', '--dry-penalty-last-n'
            for ($i = 0; $i -lt $words.Count; $i += 2) {
                if ($allowed -cnotcontains $words[$i]) { return & $r $false $v "'$($words[$i])' is not an allowed sampling flag" }
                if ($words[$i + 1] -cnotmatch '^-?[0-9]+(\.[0-9]+)?$') { return & $r $false $v "'$($words[$i + 1])' after $($words[$i]) is not a number" }
            }
            return & $r $true ($words -join ' ') ''
        }
        '^text$' { return & $r $true $v '' }
        '^choice:(.+)$' {
            $opts = $Matches[1] -split ','
            if ($opts -ccontains $v) { return & $r $true $v '' }
            return & $r $false $v ('choose one of: ' + ($opts -join ', '))
        }
    }
    return & $r $false $v "unknown setting type '$Type' in the schema"
}

# Get-NetworkDetect  - this PC's address, gateway and prefix (null when it cannot tell, e.g. not on Windows)
function Get-NetworkDetect {
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
            Sort-Object { $_.RouteMetric + (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric } |
            Select-Object -First 1
        $addr = Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
        return [pscustomobject]@{ Gateway = [string]$route.NextHop; Ip = [string]$addr.IPAddress; Prefix = [int]$addr.PrefixLength }
    } catch { return $null }
}

# Get-SettingDefault $row $values  - { Value; Source } where Source is 'detected' or 'schema'
function Get-SettingDefault {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $d = $Row.Default
    if ($d.StartsWith('auto:')) {
        $name, $fallback = $d.Substring(5) -split '=', 2
        $net = Get-NetworkDetect
        $found = ''
        if ($net) {
            switch ($name) {
                'desktop_ip' { $found = $net.Ip }
                'router_ip' { $found = $net.Gateway }
                'lan_cidr' { $found = Get-NetworkAddress ('{0}/{1}' -f $net.Ip, $net.Prefix) }
            }
        }
        if ($found) { return [pscustomobject]@{ Value = $found; Source = 'detected' } }
        return [pscustomobject]@{ Value = $fallback; Source = 'schema' }
    }
    return [pscustomobject]@{ Value = (Expand-Setting $d $Values); Source = 'schema' }
}

function Test-SettingApplies {
    param($Row, [System.Collections.IDictionary]$Values, [string]$Scope)
    if ($Row.Scope -ne 'both' -and $Row.Scope -ne $Scope) { return $false }
    if ($Row.When) {
        $k, $want = $Row.When -split '=', 2
        if ([string]$Values[$k] -ne $want) { return $false }
    }
    return $true
}

# Test-SettingUsable $row $values  - does the setting have a valid value (in the file, or a literal default)?
function Test-SettingUsable {
    param($Row, [System.Collections.IDictionary]$Values)
    if ($Values.Contains($Row.Key)) { $v = [string]$Values[$Row.Key] }
    else {
        if ($Row.Default.StartsWith('auto:')) { return $false }
        $v = Expand-Setting $Row.Default $Values
    }
    return (Test-SettingValue -Type $Row.Type -Value $v).Ok
}

# Read-Setting $row $values  - ask one setting until the answer is valid; stores it in $values
function Read-Setting {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][System.Collections.IDictionary]$Values, [switch]$AllowSkip)
    $def = ''
    $src = 'current'
    if ($Values.Contains($Row.Key)) {
        $def = [string]$Values[$Row.Key]
        $chk = Test-SettingValue -Type $Row.Type -Value $def
        if ($def -ne '' -and -not $chk.Ok) {
            Write-Warn "the current value of $($Row.Key) is not usable ($($chk.Error)); ignoring it"
            $Values.Remove($Row.Key)
        }
    }
    if (-not $Values.Contains($Row.Key)) {
        $d = Get-SettingDefault -Row $Row -Values $Values; $def = $d.Value; $src = $d.Source
        # a default derived from a setting that is not known yet (e.g. "-hermes") is no default at all
        if ($def -ne '' -and $Row.Type -ne 'optmodel' -and -not (Test-SettingValue -Type $Row.Type -Value $def).Ok) { $def = '' }
    }
    Write-Host ''
    Write-Host "  $($Row.Help)"
    $hint = $def
    $opts = @()
    if ($Row.Type -eq 'bool01') { $hint = if ($def -eq '1') { 'Y/n' } else { 'y/N' } }
    elseif ($Row.Type -like 'choice:*') {
        $opts = $Row.Type.Substring(7) -split ','
        for ($i = 0; $i -lt $opts.Count; $i++) { Write-Host ('    {0}) {1}' -f ($i + 1), $opts[$i]) }
    } elseif (-not $hint) { $hint = if ($Row.Type -eq 'optmodel') { 'none' } elseif ($AllowSkip) { 'Enter to answer later' } else { 'required' } }
    if ($src -eq 'detected') { $hint = "$hint, detected" }
    while ($true) {
        $ans = Read-Answer "  $($Row.Prompt) [$hint]"
        if ($ans -eq '') { $ans = $def }
        if ($ans -eq '' -and $AllowSkip -and $Row.Type -ne 'optmodel') {
            Write-Host '  (left for later: you will be asked when a step needs it)'
            return
        }
        if ($opts.Count -gt 0 -and $ans -cmatch '^[0-9]{1,3}$' -and [int]$ans -ge 1 -and [int]$ans -le $opts.Count) { $ans = $opts[[int]$ans - 1] }
        $t = Test-SettingValue -Type $Row.Type -Value $ans
        if ($t.Ok) { $Values[$Row.Key] = $t.Norm; return }
        Write-Warn $t.Error
    }
}

# ============================ reading and writing node.env ============================

function ConvertTo-EnvValue([string]$Value) {
    if ($Value -cmatch '^[A-Za-z0-9._/:@+,=-]*$') { return $Value }
    return "'" + $Value.Replace("'", "'\''") + "'"
}

# Write-NodeEnv PATH $schema $values $extra  - same layout as `./setup.sh configure` writes
function Write-NodeEnv {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Schema,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [string[]]$Extra = @()
    )
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('# HarnessSetup settings - written by ./setup.sh configure.')
    $out.Add('# Safe to edit by hand, or run ./setup.sh configure again (it offers these values as the defaults).')
    $out.Add('# NO secrets belong here: tokens and API keys are always typed into prompts and stored elsewhere.')
    $group = ''
    foreach ($row in $Schema) {
        if ($row.Group -ne $group) { $group = $row.Group; $out.Add(''); $out.Add("# ---- $group ----") }
        $k = $row.Key
        $isSet = $Values.Contains($k)
        $v = if ($isSet) { [string]$Values[$k] } else { '' }
        if ($row.Default -match '\{[A-Z0-9_]+\}' -and $row.Level -eq 'advanced' -and $isSet -and $v -ceq (Expand-Setting $row.Default $Values)) {
            $out.Add("# $k=$(ConvertTo-EnvValue $v)   (derived from other settings; uncomment to override)")
        } elseif (-not $isSet) {
            $out.Add("# $($row.Prompt)")
            $out.Add("# $k=   (not set yet: you will be asked when a step needs it)")
        } else {
            $out.Add("# $($row.Prompt)")
            $out.Add("$k=$(ConvertTo-EnvValue $v)")
        }
    }
    if ($Extra.Count -gt 0) { $out.Add(''); $out.Add('# ---- Other settings (kept as found) ----'); foreach ($e in $Extra) { $out.Add($e) } }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, (($out -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Show-NodeEnv  - print what Write-NodeEnv would save
function Show-NodeEnv {
    param([object[]]$Schema, [System.Collections.IDictionary]$Values, [string[]]$Extra = @())
    $tmp = [System.IO.Path]::GetTempFileName()
    try { Write-NodeEnv -Path $tmp -Schema $Schema -Values $Values -Extra $Extra; Write-Host (Get-Content -LiteralPath $tmp -Raw) } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

# Read-SettingsFile PATH $schema  - { Values; Extra }; derived advanced values that still equal their derivation are forgotten
function Read-SettingsFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Schema)
    $values = [ordered]@{}
    $extra = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Path) {
        $known = @{}
        foreach ($row in $Schema) { $known[$row.Key] = $true }
        $file = Read-NodeEnv $Path
        foreach ($k in $file.Keys) {
            if ($known.ContainsKey($k)) { $values[$k] = [string]$file[$k] }
        }
        # everything that is not a comment, a blank or a setting we know is kept exactly as found
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^\s*(#|$)') { continue }
            if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=' -and $known.ContainsKey($Matches[1])) { continue }
            $extra.Add($line)
        }
        foreach ($row in $Schema) {
            if ($row.Default -match '\{[A-Z0-9_]+\}' -and $row.Level -eq 'advanced' -and $values.Contains($row.Key) -and
                [string]$values[$row.Key] -ceq (Expand-Setting $row.Default $values)) { $values.Remove($row.Key) }
        }
    }
    return [pscustomobject]@{ Values = $values; Extra = $extra.ToArray() }
}

function Complete-Settings {
    param([object[]]$Schema, [System.Collections.IDictionary]$Values, [switch]$NoAuto, [string]$Scope = 'desktop')
    foreach ($row in $Schema) {
        if ($Values.Contains($row.Key)) { continue }
        # a detected default is only adopted for settings this machine's wizard owns
        if ($row.Default.StartsWith('auto:') -and ($NoAuto -or ($row.Scope -ne 'both' -and $row.Scope -ne $Scope))) { continue }
        $d = Get-SettingDefault -Row $row -Values $Values
        if ($d.Value -eq '') { continue }
        $t = Test-SettingValue -Type $row.Type -Value $d.Value
        if ($t.Ok) { $Values[$row.Key] = $t.Norm }
    }
}

# Get-EffectiveConfig PATH  - the settings as the scripts use them: the file plus the schema's literal and derived defaults
function Get-EffectiveConfig {
    param([Parameter(Mandatory)][string]$Path)
    $schema = Get-SettingsSchema
    $cfg = Read-NodeEnv $Path
    $vals = [ordered]@{}
    foreach ($k in $cfg.Keys) { $vals[$k] = [string]$cfg[$k] }
    foreach ($row in $schema) {
        if ($vals.Contains($row.Key) -or $row.Default -eq '' -or $row.Default.StartsWith('auto:')) { continue }
        $vals[$row.Key] = Expand-Setting $row.Default $vals
    }
    return $vals
}

# Set-NodeSettings -Path P -Set "KEY=VALUE",...  - change just those settings (validated) and save; nothing else is touched
function Set-NodeSettings {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Set)
    $schema = Get-SettingsSchema
    $state = Read-SettingsFile -Path $Path -Schema $schema
    foreach ($kv in $Set) {
        $k, $v = $kv -split '=', 2
        $row = $schema | Where-Object { $_.Key -eq $k } | Select-Object -First 1
        if (-not $row) { throw "unknown setting '$k'" }
        $t = Test-SettingValue -Type $row.Type -Value $v
        if (-not $t.Ok) { throw "${k}: $($t.Error)" }
        $state.Values[$k] = $t.Norm
    }
    Complete-Settings -Schema $schema -Values $state.Values -NoAuto
    Write-NodeEnv -Path $Path -Schema $schema -Values $state.Values -Extra $state.Extra
    Write-Ok "saved $Path"
}

# Invoke-ConfigWizard  - what Configure.ps1 does (and Initialize-NodeConfig on a first run)
function Invoke-ConfigWizard {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Scope = 'desktop',
        [switch]$Advanced,
        [switch]$Defaults,
        [string[]]$Only = @(),
        [string[]]$Set = @(),
        [switch]$Print
    )
    # powershell -File passes "-Set A=1,B=2" as one string: split it ourselves
    $schema = Get-SettingsSchema
    $byKey = @{}
    foreach ($row in $schema) { $byKey[$row.Key] = $row }
    $keyAlt = ($schema | ForEach-Object { [regex]::Escape($_.Key) }) -join '|'
    # A value may itself hold commas (DESKTOP_CHAT_KWARGS=a=1,b=2), and PowerShell splits an unquoted -Set A=a=1,b=2 into
    # ('A=a=1','b=2'): a piece that does not start with a known KEY= belongs to the value before it.
    # Only a kwargs value takes commas, and only a piece that does not look like a setting name (upper case) is joined back,
    # so a mistyped setting still reaches the 'unknown setting' check.
    $merged = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($Set | ForEach-Object { $_ -csplit ",(?=(?:$keyAlt)=)" } | Where-Object { $_ })) {
        $prevKey = if ($merged.Count -gt 0) { ($merged[$merged.Count - 1] -split '=', 2)[0] } else { '' }
        $prevKwargs = $prevKey -and $byKey.ContainsKey($prevKey) -and $byKey[$prevKey].Type -eq 'kwargs'
        if ($prevKwargs -and $p -cnotmatch '^[A-Z][A-Z0-9_]*=') { $merged[$merged.Count - 1] += ",$p" } else { $merged.Add($p) }
    }
    $Set = @($merged)
    $Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $state = Read-SettingsFile -Path $Path -Schema $schema
    $values = $state.Values
    $forced = @{}
    foreach ($kv in $Set) {
        $k, $v = $kv -split '=', 2
        if (-not $byKey.ContainsKey($k)) { throw "-Set: unknown setting '$k'" }
        $t = Test-SettingValue -Type $byKey[$k].Type -Value $v
        if (-not $t.Ok) { throw "-Set ${k}: $($t.Error)" }
        $values[$k] = $t.Norm; $forced[$k] = $true
    }
    if ($Only.Count -gt 0) {
        foreach ($k in $Only) {
            if (-not $byKey.ContainsKey($k)) { throw "unknown setting '$k'" }
            if (-not (Test-Interactive)) { throw "-Only needs a terminal (or use -Set ${k}=VALUE)" }
            Read-Setting -Row $byKey[$k] -Values $values
        }
        Complete-Settings -Schema $schema -Values $values -Scope $Scope -NoAuto
        if ($Print) { Show-NodeEnv -Schema $schema -Values $values -Extra $state.Extra; return }
        Write-NodeEnv -Path $Path -Schema $schema -Values $values -Extra $state.Extra
        Write-Ok "saved $Path"
        return
    }
    $ask = (-not $Defaults) -and (Test-Interactive)
    if (-not $Defaults -and -not $ask) { throw 'The wizard needs a terminal to ask on. Use -Defaults to accept the defaults, and -Set KEY=VALUE for the rest.' }
    if ($ask) {
        Write-Host ''
        Write-Host 'HarnessSetup settings. Press Enter to accept the value in [brackets].'
        Write-Host "Nothing secret is asked for here; the file is $Path"
    }
    $pass = {
        param($level)
        $grp = ''
        foreach ($row in $schema) {
            if ($row.Level -ne $level -or -not (Test-SettingApplies $row $values $Scope) -or $forced.ContainsKey($row.Key)) { continue }
            if (-not $ask) {
                if (-not $values.Contains($row.Key)) {
                    $d = Get-SettingDefault -Row $row -Values $values
                    if ($d.Value -ne '' -and (Test-SettingValue -Type $row.Type -Value $d.Value).Ok) { $values[$row.Key] = (Test-SettingValue -Type $row.Type -Value $d.Value).Norm }
                }
                continue
            }
            if ($row.Group -ne $grp) { $grp = $row.Group; Write-Host ''; Write-Host "== $grp ==" -ForegroundColor Cyan }
            Read-Setting -Row $row -Values $values -AllowSkip
        }
    }
    & $pass 'basic'
    if ($Advanced) { & $pass 'advanced' }
    elseif ($ask -and (Read-YesNo -Question "`nReview the advanced settings too (ports, context sizes, model files, folders)?" -Default $false)) { & $pass 'advanced' }
    Complete-Settings -Schema $schema -Values $values -Scope $Scope

    $problems = @()
    $missing = @()
    foreach ($row in $schema) {
        if ($row.Level -ne 'basic' -or -not (Test-SettingApplies $row $values $Scope)) { continue }
        $v = [string]$values[$row.Key]
        if ($v -eq '' -and $row.Type -ne 'optmodel') { $missing += $row.Key }
        elseif ($v -ne '' -and -not (Test-SettingValue -Type $row.Type -Value $v).Ok) { $problems += "$($row.Key) ($((Test-SettingValue -Type $row.Type -Value $v).Error))" }
    }
    if ($problems.Count -gt 0) { throw "invalid settings: $($problems -join '; '). Fix them in $Path or run Configure.ps1 again." }
    if ($values.Contains('DESKTOP_IP') -and $values.Contains('LAPTOP_IP') -and $values['DESKTOP_IP'] -eq $values['LAPTOP_IP']) { Write-Warn 'the laptop and the desktop have the same IP address' }
    if ($values.Contains('NIGHT_ENABLED') -and $values['NIGHT_ENABLED'] -eq '1' -and $values['NIGHT_START'] -eq $values['NIGHT_END']) { Write-Warn 'the overnight tier starts and ends at the same time' }
    if ($Print) { Show-NodeEnv -Schema $schema -Values $values -Extra $state.Extra; return }
    if ($ask) {
        Write-Host ''
        foreach ($row in $schema) {
            if ($row.Level -ne 'basic' -or -not (Test-SettingApplies $row $values $Scope)) { continue }
            $shown = [string]$values[$row.Key]
            if ($row.Type -eq 'bool01') { $shown = if ($shown -eq '1') { 'yes' } else { 'no' } }
            Write-Host ('  {0,-36} {1}' -f $row.Prompt, $(if ($shown) { $shown } else { '(not set yet)' }))
        }
        if (-not (Read-YesNo -Question "`nSave these settings to ${Path}?" -Default $true)) { throw 'not saved' }
    }
    Write-NodeEnv -Path $Path -Schema $schema -Values $values -Extra $state.Extra
    Write-Ok "saved $Path"
    if ($missing.Count -gt 0) { Write-Warn "not set yet: $($missing -join ' ') (you will be asked when a step needs them)" }
}

# Get-SettingsProblem PATH  - one message per setting in the file that fails validation
function Get-SettingsProblem {
    param([Parameter(Mandatory)][string]$Path)
    $schema = Get-SettingsSchema
    $state = Read-SettingsFile -Path $Path -Schema $schema
    $problems = @()
    foreach ($row in $schema) {
        if (-not $state.Values.Contains($row.Key)) { continue }
        $t = Test-SettingValue -Type $row.Type -Value ([string]$state.Values[$row.Key])
        if (-not $t.Ok) { $problems += "$($row.Key): $($t.Error)" }
    }
    return , $problems
}

# Initialize-NodeConfig -Path P -Need KEYS  - the settings every Windows script starts with:
# creates the file by asking (or imports the laptop's), asks for any needed setting that is missing, returns the config.
function Initialize-NodeConfig {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Need = @())
    if (-not (Test-Path -LiteralPath $Path)) {
        if (-not (Test-Interactive)) {
            throw "No settings yet ($Path). Run .\Configure.ps1 to be asked for them, or copy the laptop's config/node.env there."
        }
        Write-Step "no settings yet: let's create $Path (about a minute; nothing secret is asked)"
        $imported = $false
        $login = Read-Answer 'If the laptop is already set up, copy its settings over SSH: enter user@address (or press Enter to answer the questions here)'
        if ($login -ne '') {
            $remote = Read-Answer 'Path of node.env on the laptop [~/HarnessSetup/config/node.env]'
            if ($remote -eq '') { $remote = '~/HarnessSetup/config/node.env' }
            if ($login -cnotmatch '^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$' -or $remote -cnotmatch '^[A-Za-z0-9._~/-]+$') {
                Write-Warn 'that does not look like user@address and a file path; asking the questions here instead.'
                $login = ''
            }
        }
        if ($login -ne '') {
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            try {
                & scp -- "${login}:${remote}" $Path
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Path)) {
                    $probs = Get-SettingsProblem -Path $Path
                    if ($probs.Count -eq 0) { Write-Ok "copied the laptop's settings to $Path"; $imported = $true }
                    else {
                        Write-Warn ("the copied file has settings that are not valid ($($probs -join '; ')); ignoring it.")
                        Remove-Item -LiteralPath $Path -ErrorAction SilentlyContinue
                    }
                } else { Write-Warn "could not copy it (scp exit $LASTEXITCODE); asking the questions here instead." }
            } catch { Write-Warn "could not run scp ($($_.Exception.Message)); asking the questions here instead." }
        }
        if (-not $imported) { Invoke-ConfigWizard -Path $Path -Scope desktop }
    }
    $schema = Get-SettingsSchema
    if ($Need.Count -gt 0) {
        $state = Read-SettingsFile -Path $Path -Schema $schema
        $bad = @()
        foreach ($row in $schema) {
            if ($Need -notcontains $row.Key) { continue }
            if (-not (Test-SettingApplies $row $state.Values 'desktop')) { continue }
            if (-not (Test-SettingUsable $row $state.Values)) { $bad += $row }
        }
        if ($bad.Count -gt 0) {
            $names = ($bad | ForEach-Object { $_.Key }) -join ' '
            if (-not (Test-Interactive)) { throw "These settings are missing or invalid: $names. Run .\Configure.ps1 -Only $(($bad | ForEach-Object { $_.Key }) -join ',') (or -Set KEY=VALUE)." }
            Write-Step "this step needs: $names"
            foreach ($row in $bad) { Read-Setting -Row $row -Values $state.Values }
            Complete-Settings -Schema $schema -Values $state.Values -NoAuto
            Write-NodeEnv -Path $Path -Schema $schema -Values $state.Values -Extra $state.Extra
            Write-Ok "saved to $Path"
        }
    }
    return (Get-EffectiveConfig -Path $Path)
}

# Invoke-NativeText { & tool args }  - run a native command and return its stdout+stderr as one string.
# Windows PowerShell 5.1 turns a native command's stderr into a terminating error under
# $ErrorActionPreference = 'Stop'; here it is just text. $LASTEXITCODE is left for the caller.
function Invoke-NativeText {
    param([Parameter(Mandatory)][scriptblock]$Block)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return ((& $Block 2>&1 | ForEach-Object { "$_" }) -join "`n") } finally { $ErrorActionPreference = $old }
}

# Add-ClockMinutes "HH:MM" MINUTES  - clock arithmetic around midnight, e.g. 01:00 +75 -> 02:15
function Add-ClockMinutes {
    param([Parameter(Mandatory)][string]$Time, [int]$Minutes)
    $h, $m = $Time -split ':'
    $t = ((([int]$h * 60 + [int]$m + $Minutes) % 1440) + 1440) % 1440
    return ('{0:D2}:{1:D2}' -f [int][math]::Floor($t / 60), [int]($t % 60))
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

# ============================ llama.cpp releases and servers ============================

# Select-LlamaRelease -Releases $list -Patterns 'regex',...  - the newest non-draft release that has an asset matching EVERY
# pattern. Not /releases/latest: that is a source-only stable tag; the build releases (bNNNN) are marked pre-release, and a
# new one can be listed before its zips are uploaded. Returns $null when none of the releases qualifies.
function Select-LlamaRelease {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Releases, [Parameter(Mandatory)][string[]]$Patterns)
    foreach ($rel in $Releases) {
        if ($rel.PSObject.Properties['draft'] -and $rel.draft) { continue }
        if (-not $rel.PSObject.Properties['assets']) { continue }
        $names = @($rel.assets | ForEach-Object { $_.name })
        $missing = @($Patterns | Where-Object { $p = $_; -not ($names | Where-Object { $_ -match $p }) })
        if ($missing.Count -eq 0) { return $rel }
    }
    return $null
}

# Get-LlamaReleases  - the ten newest llama.cpp releases (pre-releases included), newest first
function Get-LlamaReleases {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    return , @(Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10' -Headers @{ 'User-Agent' = 'HarnessSetup' })
}

# Get-LlamaServerProcess -Dir C:\llama  - the llama-server processes that run from that folder and no other (the V100 server has
# the same program name as the day server). WMI shows the path of elevated processes too, so a plain shell can look.
function Get-LlamaServerProcess {
    param([Parameter(Mandatory)][string]$Dir)
    $prefix = $Dir.TrimEnd('\') + '\'
    return , @(Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'llama-server%'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

# Stop-LlamaServer -Dir C:\llama  - stop those processes (stopping by program name would take the other server down too)
function Stop-LlamaServer {
    param([Parameter(Mandatory)][string]$Dir)
    foreach ($p in (Get-LlamaServerProcess -Dir $Dir)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ============================ desktop away (Desktop-Mode.ps1) ============================

# Get-LlamaTaskNames -Cfg  - the scheduled tasks that keep the desktop's model servers running
function Get-LlamaTaskNames {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Cfg)
    $names = @('llama-server')
    if ($Cfg['V100_ENABLED'] -eq '1') { $names += 'llama-v100' }
    if ($Cfg['NIGHT_ENABLED'] -eq '1') { $names += 'llama-night', 'llama-day' }
    return , $names
}

# Get-LlamaServerDirs -Cfg  - the folders whose llama-server.exe belongs to the kit
function Get-LlamaServerDirs {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Cfg)
    $dirs = @($Cfg['DESKTOP_LLAMA_DIR'])
    if ($Cfg['V100_ENABLED'] -eq '1') { $dirs += $Cfg['V100_CUDA_DIR'] }
    return , $dirs
}

# Get-LaptopDesktopCommand -Cfg -Action off|on [-For 4h]  - the command line that runs hermes-desktop on the laptop as the agent user
function Get-LaptopDesktopCommand {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Cfg,
        [Parameter(Mandatory)][ValidateSet('off', 'on')][string]$Action,
        [string]$For = ''
    )
    if ($For -ne '' -and $For -cnotmatch '^[0-9]{1,3}[mhd]$') { throw "-For expects a duration like 90m, 4h or 1d (got '$For')" }
    $agent = $Cfg['AGENT_USER']
    $cmd = "sudo -u $agent -H /home/$agent/.local/bin/hermes-desktop $Action"
    if ($For -ne '' -and $Action -eq 'off') { $cmd += " --for $For" }
    return $cmd
}

# Get-AwayReturnTime -Now $date -For 4h  - when the desktop starts its servers again for a timed absence: five minutes before
# the laptop puts the endpoints back (a model needs a few minutes to load), at least one minute from now
function Get-AwayReturnTime {
    param([Parameter(Mandatory)][datetime]$Now, [Parameter(Mandatory)][string]$For)
    if ($For -cnotmatch '^([0-9]{1,3})([mhd])$') { throw "-For expects a duration like 90m, 4h or 1d (got '$For')" }
    $n = [int]$Matches[1]
    $span = switch ($Matches[2]) { 'm' { [TimeSpan]::FromMinutes($n) } 'h' { [TimeSpan]::FromHours($n) } default { [TimeSpan]::FromDays($n) } }
    $early = $span - [TimeSpan]::FromMinutes(5)
    if ($early -lt [TimeSpan]::FromMinutes(1)) { $early = [TimeSpan]::FromMinutes(1) }
    return $Now.Add($early)
}

# New-StopLlamaScript -Dir C:\llama  - lines of a cmd file that stops the llama-server running from that folder only
function New-StopLlamaScript {
    param([Parameter(Mandatory)][string]$Dir)
    $d = $Dir.TrimEnd('\')
    return @(
        '@echo off',
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"Get-CimInstance Win32_Process | Where-Object { `$_.Name -like 'llama-server*' -and `$_.ExecutablePath -like '$d\*' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force }`""
    )
}

# ============================ V100 GPU tier (optional) ============================
# Pure helpers for Install-V100.ps1 / Check-V100.ps1: they parse text and compute, so the tests run anywhere.

# Select-CudaRelease -Releases $list  - the newest non-draft release that has a CUDA 12.x Windows zip AND its runtime bundle.
# CUDA 13 builds have no Volta code, so only 12.x qualifies; the highest 12.x wins. Returns Release, Main, Runtime, CudaVersion or $null.
function Select-CudaRelease {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Releases)
    foreach ($rel in $Releases) {
        if ($rel.PSObject.Properties['draft'] -and $rel.draft) { continue }
        if (-not $rel.PSObject.Properties['assets']) { continue }
        $assets = @($rel.assets)
        $mains = @($assets | Where-Object { $_.name -match '^llama-.+-bin-win-cuda-(12\.[0-9]+)-x64\.zip$' } |
                ForEach-Object { [pscustomobject]@{ Asset = $_; Version = [version]([regex]::Match($_.name, 'cuda-(12\.[0-9]+)-x64').Groups[1].Value) } } |
                Sort-Object -Property Version -Descending)
        foreach ($m in $mains) {
            $rtName = "cudart-llama-bin-win-cuda-$($m.Version.ToString(2))-x64.zip"
            $rt = $assets | Where-Object { $_.name -eq $rtName } | Select-Object -First 1
            if ($rt) { return [pscustomobject]@{ Release = $rel; Main = $m.Asset; Runtime = $rt; CudaVersion = $m.Version.ToString(2) } }
        }
    }
    return $null
}

# Get-NvidiaGpus TEXT  - parse the output of
#   nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,memory.total,power.limit,power.default_limit,power.min_limit,power.max_limit,driver_model.current,driver_version,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader,nounits
function Get-NvidiaGpus {
    param([AllowEmptyString()][string]$Text = '')
    $found = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $f = @($line -split ',\s*')
        if ($f.Count -lt 13 -or $f[0] -notmatch '^[0-9]+$') { continue }
        $num = { param($v) if ($v -match '^[0-9]+(\.[0-9]+)?$') { [double]$v } else { $null } }
        $found += [pscustomobject]@{
            Index = [int]$f[0]; Name = $f[1]; Uuid = $f[2]; BusId = $f[3]
            MemoryMiB = & $num $f[4]; PowerLimitW = & $num $f[5]; PowerDefaultW = & $num $f[6]; PowerMinW = & $num $f[7]; PowerMaxW = & $num $f[8]
            DriverModel = $f[9]; DriverVersion = $f[10]; PcieGen = & $num $f[11]; PcieWidth = & $num $f[12]
        }
    }
    return , $found
}

# Get-V100PowerLimit -Gpu $g -Requested 200  - the limit to set: the request, never above the card's default, clamped to the
# range the card reports; $null when the request is 0 (leave the stock limit)
function Get-V100PowerLimit {
    param([Parameter(Mandatory)][object]$Gpu, [Parameter(Mandatory)][int]$Requested)
    if ($Requested -le 0) { return $null }
    $w = [double]$Requested
    if ($null -ne $Gpu.PowerDefaultW -and $w -gt $Gpu.PowerDefaultW) { $w = $Gpu.PowerDefaultW }
    if ($null -ne $Gpu.PowerMinW -and $w -lt $Gpu.PowerMinW) { $w = $Gpu.PowerMinW }
    if ($null -ne $Gpu.PowerMaxW -and $w -gt $Gpu.PowerMaxW) { $w = $Gpu.PowerMaxW }
    return [int][math]::Floor($w)
}

# Get-V100Family -ModelFile x.gguf  - '27B', '35B' (the 35B-A3B MoE) or '' for a model the sizing constants do not cover
function Get-V100Family {
    param([Parameter(Mandatory)][string]$ModelFile)
    if ($ModelFile -match '(?i)Qwen3\.[0-9]+-27B') { return '27B' }
    if ($ModelFile -match '(?i)Qwen3\.[0-9]+-35B-A3B') { return '35B' }
    return ''
}

# Get-V100KvType -ModelFile x.gguf [-SplitMode layer|tensor]  - the context cache type for both K and V. They must match: on CUDA only
# q8_0/q8_0, q4_0/q4_0, f16/f16 and bf16/bf16 have a compiled flash-attention kernel (the Vulkan server's f16/q8_0 mix does not).
# The 35B-A3B decodes through the tile kernel, which converts a quantized cache on every token, and its f16 cache is small anyway;
# tensor split wants an unquantized cache.
function Get-V100KvType {
    param([Parameter(Mandatory)][string]$ModelFile, [string]$SplitMode = 'layer')
    if ($SplitMode -eq 'tensor' -or (Get-V100Family -ModelFile $ModelFile) -eq '35B') { return 'f16' }
    return 'q8_0'
}

# Get-V100QuantAdvice -Count 2 -VramGB 16  - the quantization of Qwen3.8-27B that fits that many cards at 128K context with margin
function Get-V100QuantAdvice {
    param([Parameter(Mandatory)][int]$Count, [Parameter(Mandatory)][int]$VramGB)
    $total = $Count * $VramGB
    if ($total -ge 64) { return 'UD-Q6_K_XL' }
    if ($total -ge 32 -and $Count -eq 1) { return 'UD-Q5_K_XL' }
    if ($total -ge 32) { return 'UD-Q4_K_XL' }
    return ''
}

# Get-V100Fit -FileBytes N -Context 131072 -ModelFile x.gguf -Gpus 2 -CardMiB 16384 [-FreeMiB 16000] [-KvType q8_0] [-Mtp]
# Will the model fit on the card that holds the most? Layer split puts the output layer (and the MTP block) on the last card, so that
# one is the heaviest. The pieces: the weights that live on the GPU (the embedding stays on the CPU), the context cache of the
# attention layers (only 1 layer in 4 of these hybrid models has one), the small recurrent state, the CUDA runtime, and the compute
# buffers. The constants come from the Qwen3.8-27B and Qwen3.6-35B-A3B configs and GGUF headers; the result matches a real
# llama.cpp log for the cache. The budget per card is the smaller of total and free memory, minus 1 GiB of margin.
# Verdict: fit (spare >= 0), tight (within the margin), no.
function Get-V100Fit {
    param(
        [Parameter(Mandatory)][double]$FileBytes,
        [Parameter(Mandatory)][int]$Context,
        [Parameter(Mandatory)][string]$ModelFile,
        [Parameter(Mandatory)][int]$Gpus,
        [Parameter(Mandatory)][double]$CardMiB,
        [double]$FreeMiB = 0,
        [ValidateSet('q8_0', 'f16')][string]$KvType = 'q8_0',
        [switch]$Mtp,
        [int]$Ub = 512
    )
    $fam = Get-V100Family -ModelFile $ModelFile
    # KvEl: cache elements per token; KvHd: KV heads x head size; RsMiB: recurrent state per sequence; Kw: share of the file on the GPU;
    # Extra: extra share of the last card; MtpKvB: bytes per token of the MTP block's own cache
    $c = switch ($fam) {
        '35B' { @{ KvEl = 10240; KvHd = 512; RsMiB = 62.8125; Kw = 0.977; Extra = 0.02; MtpKvB = 2048 } }
        default { @{ KvEl = 32768; KvHd = 1024; RsMiB = 149.625; Kw = 0.955; Extra = 0.05; MtpKvB = 4096 } }   # 27B, and the safe choice for an unknown model
    }
    $gib = 1GB
    $bpe = if ($KvType -eq 'f16') { 2.0 } else { 1.0625 }
    $w = $FileBytes * $c.Kw / $gib
    $share = if ($Gpus -le 1) { 1.0 } else { 1.0 / $Gpus + $c.Extra }
    $kv = $c.KvEl * $bpe * $Context / $gib
    $rs = $c.RsMiB / 1024 * $(if ($Mtp) { 3 } else { 1 })
    $conv = if ($KvType -eq 'f16') { 0 } else { 4 * $c.KvHd }
    $comp = 1.0 + $Context * (2 * $Ub + $conv) / $gib
    $mtpExtra = if ($Mtp) { $Context * ($c.MtpKvB + 4096) / $gib } else { 0 }
    $need = $share * $w + $kv / $Gpus + $rs / $Gpus + 0.35 + $comp + $mtpExtra
    $card = if ($FreeMiB -gt 0) { [math]::Min($CardMiB, $FreeMiB) } else { $CardMiB }
    $budget = $card / 1024 - 1.0
    $spare = $budget - $need
    $verdict = if ($spare -ge 0) { 'fit' } elseif ($spare -ge -1.0) { 'tight' } else { 'no' }
    return [pscustomobject]@{
        NeededGiB = [math]::Round($need, 1); BudgetGiB = [math]::Round($budget, 1); SpareGiB = [math]::Round($spare, 1)
        KvGiB = [math]::Round($kv, 2); Verdict = $verdict; KnownModel = ($fam -ne ''); Family = $fam
    }
}

# Test-GgufMtp -Path file.gguf  - does the file carry a multi-token-prediction head? Those files have tensors named blk.N.nextn.*
# in the header; the plain Qwen3.6-35B-A3B files and the smallest 27B quants do not. Reads the first 64 MB at most.
function Test-GgufMtp {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $needle = [System.Text.Encoding]::ASCII.GetBytes('.nextn.')
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] (4MB + $needle.Length)
        $keep = 0
        $read = 0
        while ($read -lt 64MB) {
            $n = $fs.Read($buf, $keep, 4MB)
            if ($n -le 0) { break }
            $read += $n
            $len = $keep + $n
            for ($i = 0; $i -le $len - $needle.Length; $i++) {
                if ($buf[$i] -eq $needle[0]) {
                    $hit = $true
                    for ($j = 1; $j -lt $needle.Length; $j++) { if ($buf[$i + $j] -ne $needle[$j]) { $hit = $false; break } }
                    if ($hit) { return $true }
                }
            }
            # carry the tail over so a name cut by the chunk edge is still found
            $keep = [math]::Min($needle.Length - 1, $len)
            [Array]::Copy($buf, $len - $keep, $buf, 0, $keep)
        }
        return $false
    } finally { $fs.Dispose() }
}

# Get-RemoteFileSize -Url  - the size Hugging Face reports (x-linked-size on the redirect), or $null when it cannot be read
function Get-RemoteFileSize {
    param([Parameter(Mandatory)][string]$Url)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'HEAD'; $req.AllowAutoRedirect = $false; $req.UserAgent = 'HarnessSetup'; $req.Timeout = 30000
        $resp = $req.GetResponse()
        try {
            $h = $resp.Headers['X-Linked-Size']
            if (-not $h) { $h = [string]$resp.ContentLength }
            if ($h -match '^[0-9]+$' -and [double]$h -gt 0) { return [double]$h }
        } finally { $resp.Close() }
    } catch { }
    return $null
}

# New-V100StartScript -Cfg $cfg -Gpus $gpuObjects [-Mtp]  - lines of the cmd file that starts the CUDA llama-server on the V100s.
# Layer split over plain PCIe by default; matched cache types; the power limit is set at every start because Windows forgets it at reboot.
function New-V100StartScript {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Cfg,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Gpus,
        [switch]$Mtp
    )
    $dir = $Cfg['V100_CUDA_DIR']
    $day = $Cfg['DESKTOP_LLAMA_DIR']
    $models = $Cfg['DESKTOP_MODELS_DIR']
    $count = [int]$Cfg['V100_COUNT']
    $file = $Cfg['V100_MODEL_FILE']
    $split = if ($Cfg.Contains('V100_SPLIT_MODE') -and $Cfg['V100_SPLIT_MODE']) { $Cfg['V100_SPLIT_MODE'] } else { 'layer' }
    $kvType = Get-V100KvType -ModelFile $file -SplitMode $split
    $devices = (0..($count - 1) | ForEach-Object { "CUDA$_" }) -join ','
    $lines = @(
        '@echo off',
        'rem Generated by Install-V100.ps1: re-run the installer instead of editing this file.',
        'set CUDA_DEVICE_ORDER=PCI_BUS_ID',
        'set CUDA_SCALE_LAUNCH_QUEUES=4x',
        'set CUDA_CACHE_MAXSIZE=4294967296'
    )
    if ($split -ne 'tensor') {
        $lines += 'rem CUDA graphs on Volta had a reported memory leak with layer split; remove the next line to try them (llama.cpp issue 25835)'
        $lines += 'set GGML_CUDA_DISABLE_GRAPHS=1'
    }
    foreach ($g in $Gpus) {
        $w = Get-V100PowerLimit -Gpu $g -Requested ([int]$Cfg['V100_POWER_LIMIT_W'])
        if ($null -ne $w) { $lines += "`"$env:SystemRoot\System32\nvidia-smi.exe`" -i $($g.Index) -pl $w >nul" }
    }
    $lines += "cd /d $dir"
    $moe = ((Get-V100Family -ModelFile $file) -eq '35B')
    $kw = Get-ModelSetting -Cfg $Cfg -Key V100_CHAT_KWARGS -Type kwargs -Auto $(if ($moe) { 'preserve_thinking=true' } else { 'reasoning_effort=medium' })
    $sampling = Get-ModelSetting -Cfg $Cfg -Key V100_SAMPLING -Type sampling -Auto $(if ($moe) { '--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0' } else { '--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0' })
    $segments = @(
        "$dir\llama-server.exe -m $models\$file --alias $($Cfg['V100_MODEL_ALIAS'])",
        "  --host $($Cfg['DESKTOP_IP']) --port $($Cfg['V100_PORT']) --api-key-file $day\api-key.txt",
        "  --device $devices --split-mode $split --jinja -ngl 99 -fit off -fa on -np 1 -ub 512 -c $($Cfg['V100_CTX']) -ctk $kvType -ctv $kvType",
        "  --cache-ram 2048$(if ($kw) { ' --chat-template-kwargs ' + (ConvertTo-CmdKwargs $kw) })",
        $(if ($Mtp -and $split -ne 'tensor') { '  --spec-type draft-mtp --spec-draft-n-max 2' }),
        "  $sampling"
    )
    $lines += Join-CmdLines -Segments $segments
    return $lines
}

# Get-LlamaDevices TEXT  - the devices in `llama-server.exe --list-devices` output (stdout). Lines look like
#   "  CUDA0: Tesla V100-SXM2-16GB (16384 MiB, 16000 MiB free)"   /   "  Vulkan0: AMD Radeon RX 6600 XT (8176 MiB, 8000 MiB free)"
function Get-LlamaDevices {
    param([AllowEmptyString()][string]$Text = '')
    $found = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*([A-Za-z]+[0-9]+):\s+(.+?)\s+\(([0-9]+) MiB,\s*([0-9]+) MiB free\)\s*$') {
            $found += [pscustomobject]@{ Name = $Matches[1]; Description = $Matches[2]; TotalMiB = [int]$Matches[3]; FreeMiB = [int]$Matches[4] }
        }
    }
    return , $found
}

# Get-LlamaDeviceList -Exe C:\llama-cuda\llama-server.exe [-Env @{ NAME = 'value' }]  - run --list-devices and return its stdout.
# A release build loads its GPU backend silently, so a missing runtime DLL shows up only as an empty list.
function Get-LlamaDeviceList {
    param([Parameter(Mandatory)][string]$Exe, [hashtable]$Env = @{})
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try { return (Invoke-NativeText { & cmd.exe /c "`"$Exe`" --list-devices 2>nul" }) }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
}

# Get-NvidiaSmiPath  - nvidia-smi.exe from the PATH, else the copy the driver puts in System32; $null without a driver
function Get-NvidiaSmiPath {
    $cmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($env:SystemRoot) {
        $p = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# The newest driver that still supports the Tesla V100 on Windows: the Data Center driver of the R580 branch, NVIDIA's last
# branch for Volta (R590 and later do not contain the V100). Pinned on purpose; check docs/V100.md before changing it.
$script:V100Driver = @{
    Version = '582.78'
    Url     = 'https://us.download.nvidia.com/tesla/582.78/582.78-data-center-tesla-desktop-win10-win11-64bit-dch-international.exe'
    Finder  = 'https://www.nvidia.com/Download/index.aspx'
}
$script:V100QueryFields = 'index,name,uuid,pci.bus_id,memory.total,power.limit,power.default_limit,power.min_limit,power.max_limit,driver_model.current,driver_version,pcie.link.gen.current,pcie.link.width.current'

# Get-NvidiaPciDevices  - the NVIDIA Volta-family devices Windows sees on the PCIe bus (vendor 10DE, device 1Dxx), driver or no driver.
# WMI gives the numeric Device Manager error code (Get-PnpDevice only gives a CM_PROB name). Empty where WMI is not available.
function Get-NvidiaPciDevices {
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { return , @() }
    $all = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE&DEV_1D*' })
    return , @($all | ForEach-Object { [pscustomobject]@{ Name = $_.Name; InstanceId = $_.PNPDeviceID; ErrorCode = [int]$_.ConfigManagerErrorCode; Status = $_.Status } })
}

# Get-PnpProblemHelp -Code 12  - what a Device Manager error code on a V100 usually means ('' for 0 = fine)
function Get-PnpProblemHelp {
    param([Parameter(Mandatory)][int]$Code)
    switch ($Code) {
        0 { return '' }
        12 { return 'not enough free resources: enable Above 4G Decoding (and Resizable BAR) in the BIOS, with CSM off' }
        10 { return 'the device failed to start: a power or cooling fault, or the wrong driver' }
        43 { return 'Windows stopped the device: check the 12 V power cables and the driver' }
        28 { return 'no driver is installed for it' }
        default { return "Device Manager error code $Code (see Microsoft's list of Device Manager error codes)" }
    }
}
