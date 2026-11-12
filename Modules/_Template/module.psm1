# Template for a new NetRing module. See module.psd1 for the steps.
#
# Rules:
#  - Keep all logic inside this folder.
#  - Do not call functions of other modules.
#  - Validate input with parameter attributes and throw on errors:
#    the NetRing core catches the error and keeps running.
#  - Use only ASCII in this file (Windows PowerShell 5.1), build special
#    characters with [char]0x2500 and the like.

Set-StrictMode -Version 2.0

function Invoke-NRExample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Target,

        [ValidateRange(1, 100)]
        [int]$Count = 4
    )

    Write-Host ("  Example tool called with Target={0} Count={1}" -f $Target, $Count) -ForegroundColor Green
}

Export-ModuleMember -Function 'Invoke-NRExample'
