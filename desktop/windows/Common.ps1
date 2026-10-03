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
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
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
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][System.Collections.IDictionary]$Values)
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
    if (-not $Values.Contains($Row.Key)) { $d = Get-SettingDefault -Row $Row -Values $Values; $def = $d.Value; $src = $d.Source }
    Write-Host ''
    Write-Host "  $($Row.Help)"
    $hint = $def
    $opts = @()
    if ($Row.Type -eq 'bool01') { $hint = if ($def -eq '1') { 'Y/n' } else { 'y/N' } }
    elseif ($Row.Type -like 'choice:*') {
        $opts = $Row.Type.Substring(7) -split ','
        for ($i = 0; $i -lt $opts.Count; $i++) { Write-Host ('    {0}) {1}' -f ($i + 1), $opts[$i]) }
    } elseif (-not $hint) { $hint = if ($Row.Type -eq 'optmodel') { 'none' } else { 'required' } }
    if ($src -eq 'detected') { $hint = "$hint, detected" }
    while ($true) {
        $ans = Read-Answer "  $($Row.Prompt) [$hint]"
        if ($ans -eq '') { $ans = $def }
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
    $Set = @($Set | ForEach-Object { $_ -split ",(?=(?:$keyAlt)=)" } | Where-Object { $_ })
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
            Read-Setting -Row $row -Values $values
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
