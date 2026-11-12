#Requires -Version 5.1
<#
.SYNOPSIS
    NetRing - a modular network toolkit for PowerShell.

.DESCRIPTION
    Start without arguments for the interactive menu:
        .\NetRing.ps1

    Or run one alias directly and return to PowerShell:
        .\NetRing.ps1 trace 8.8.8.8
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Command
)

Set-StrictMode -Version 2.0

# Load the core. Without a working core NetRing cannot start.
$coreFiles = @('Console.ps1', 'ModuleLoader.ps1', 'AliasParser.ps1', 'Menu.ps1')
foreach ($file in $coreFiles) {
    $path = Join-Path (Join-Path $PSScriptRoot 'Core') $file
    try {
        . $path
    } catch {
        Write-Host ("NetRing core file could not be loaded: {0}" -f $path) -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        return
    }
}

Initialize-NRConsole
$context = New-NRContext -Root $PSScriptRoot
Import-NRModules -Context $context

if ($Command -and $Command.Count -gt 0) {
    # One-shot mode: run a single command, then stop.
    [void](Invoke-NRCommand -Context $context -Tokens $Command)
    return
}

Write-NRBanner -Context $context
Start-NRShell -Context $context
