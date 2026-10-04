<#
.SYNOPSIS
  Ask for the settings (addresses, accounts, model choices) and save them to config\node.env.
.DESCRIPTION
  Asks one question at a time with a default in [brackets], explains it, and validates the answer.
  Addresses are detected where possible (this PC's address, the router). You can also copy the
  laptop's file over SSH instead of answering the shared questions twice. Nothing secret is asked.
  The Windows scripts call this by themselves when they find no settings, so running it is optional.
.EXAMPLE
  .\Configure.ps1                          # the guided questions
  .\Configure.ps1 -Advanced                # also ports, context sizes, model files, folders
  .\Configure.ps1 -Only DESKTOP_QUANT      # change one setting
  .\Configure.ps1 -Defaults -Set LAPTOP_IP=192.168.1.150,DESKTOP_IP=192.168.1.100   # no questions
#>
[CmdletBinding()]
param(
    [string]$ConfigFile,
    [switch]$Advanced,
    [switch]$Defaults,
    [string[]]$Only = @(),
    [string[]]$Set = @(),
    [switch]$Print
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
if (-not $ConfigFile) { $ConfigFile = Get-DefaultConfigPath }
Invoke-ConfigWizard -Path $ConfigFile -Scope desktop -Advanced:$Advanced -Defaults:$Defaults -Only $Only -Set $Set -Print:$Print
