# NetRing core: menu engine, built-in commands and the interactive shell.

function Show-NRMenu {
    param([Parameter(Mandatory)][hashtable]$Context)

    if (-not $Context.Location) {
        Write-NRTitle 'Main menu'
        if (@($Context.Modules | Where-Object { $_.Status -eq 'Loaded' }).Count -eq 0) {
            Write-NRWarn "No modules loaded. Type 'modules' to see why."
        }
        $i = 0
        foreach ($category in $Context.Categories) {
            $i++
            $count = @(Get-NRCategoryTools -Context $Context -Category $category.Key).Count
            Write-NRCategoryItem -Number $i -Category $category -Count $count
        }
        Write-Host ''
        Write-NRMenuItem -Key '0' -Label 'Exit'
    } else {
        $category = Get-NRCategory -Context $Context -Key $Context.Location
        Write-NRTitle $category.Name
        $tools = @(Get-NRCategoryTools -Context $Context -Category $Context.Location)
        if ($tools.Count -eq 0) {
            Write-Host '     No tools in this category yet.' -ForegroundColor $script:NRTheme.Dim
        }
        $i = 0
        foreach ($tool in $tools) {
            $i++
            Write-NRMenuItem -Key $i -Label $tool.Name -Hint ("alias: {0}" -f $tool.Alias)
        }
        Write-Host ''
        Write-NRMenuItem -Key '0' -Label 'Back'
    }
    Write-Host ''
}

function Write-NRCategoryItem {
    # One line in the main menu:  1) This machine   1 tool
    # Empty categories are shown in gray, so the numbers never change.
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)]$Category,
        [Parameter(Mandatory)][int]$Count
    )

    $countText = "$Count tools"
    if ($Count -eq 1) { $countText = '1 tool' }

    $keyColor = $script:NRTheme.Key
    $nameColor = $script:NRTheme.Text
    $countColor = $script:NRTheme.Muted
    if ($Count -eq 0) {
        $keyColor = $script:NRTheme.Dim
        $nameColor = $script:NRTheme.Dim
        $countColor = $script:NRTheme.Dim
    }

    Write-Host ("   {0,3}) " -f $Number) -ForegroundColor $keyColor -NoNewline
    Write-Host ("{0,-16}" -f $Category.Name) -ForegroundColor $nameColor -NoNewline
    Write-Host $countText -ForegroundColor $countColor
}

function Show-NRHelp {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [string]$Alias
    )

    if (-not $Alias) {
        Write-NRTitle 'Help'
        Write-Host '  Menu mode : type a number and press Enter. 0 or back goes one level up.' -ForegroundColor $script:NRTheme.Muted
        Write-Host '              Several numbers at once also work, for example: 1 1' -ForegroundColor $script:NRTheme.Muted
        Write-Host '  Alias mode: ALIAS PARAMETER PARAMETER, for example: trace 8.8.8.8' -ForegroundColor $script:NRTheme.Muted
        Write-Host '              Named parameters also work: trace 8.8.8.8 -MaxHops 15' -ForegroundColor $script:NRTheme.Muted
        Write-Host ''
        $builtins = [ordered]@{
            'help'         = 'Show this help'
            'help <alias>' = 'Show help and parameters for a tool'
            'aliases'      = 'List all available aliases'
            'modules'      = 'List modules and their status'
            'menu'         = 'Show the current menu (or press Enter)'
            'back / 0'     = 'Return to the previous menu'
            'reload'       = 'Reload all modules'
            'clear'        = 'Clear the screen'
            'exit'         = 'Quit NetRing'
        }
        foreach ($key in $builtins.Keys) {
            Write-Host ("   {0,-14}" -f $key) -ForegroundColor $script:NRTheme.Key -NoNewline
            Write-Host $builtins[$key] -ForegroundColor $script:NRTheme.Muted
        }
        Write-Host ''
        return
    }

    if (-not $Context.Aliases.ContainsKey($Alias)) {
        Write-NRError "Unknown alias '$Alias'. Type 'aliases' for the list."
        return
    }

    $tool = $Context.Aliases[$Alias]
    Write-NRTitle ("{0}  ({1})" -f $tool.Name, $tool.Alias)
    if ($tool.Description) { Write-Host ("  {0}" -f $tool.Description) -ForegroundColor $script:NRTheme.Muted }
    Write-Host ("  Module: {0}   Category: {1}" -f $tool.Module, $tool.Category) -ForegroundColor $script:NRTheme.Dim
    Write-Host ''
    Write-Host '  Usage: ' -ForegroundColor $script:NRTheme.Text -NoNewline
    Write-Host (Get-NRUsage -Tool $tool) -ForegroundColor $script:NRTheme.Key
    Write-Host ''
    if ($tool.Parameters.Count -gt 0) {
        Write-Host '  Parameters:' -ForegroundColor $script:NRTheme.Text
        foreach ($p in $tool.Parameters) {
            $flag = 'optional'
            if ($p.Required) { $flag = 'required' }
            elseif ($p.ContainsKey('Default')) { $flag = "default: $($p.Default)" }
            Write-Host ("   {0,-12}" -f $p.Name) -ForegroundColor $script:NRTheme.Key -NoNewline
            Write-Host ("{0,-20}" -f $flag) -ForegroundColor $script:NRTheme.Dim -NoNewline
            Write-Host $p.Description -ForegroundColor $script:NRTheme.Muted
        }
        Write-Host ''
    }
    if ($tool.Examples.Count -gt 0) {
        Write-Host '  Examples:' -ForegroundColor $script:NRTheme.Text
        foreach ($e in $tool.Examples) { Write-Host ("   netring> {0}" -f $e) -ForegroundColor $script:NRTheme.Muted }
        Write-Host ''
    }
}

function Show-NRAliases {
    param([Parameter(Mandatory)][hashtable]$Context)

    Write-NRTitle 'Aliases'
    if ($Context.Aliases.Count -eq 0) {
        Write-NRWarn 'No aliases available.'
        return
    }
    foreach ($tool in ($Context.Aliases.Values | Sort-Object CategoryOrder, Alias)) {
        Write-Host ("   {0,-12}" -f $tool.Alias) -ForegroundColor $script:NRTheme.Key -NoNewline
        Write-Host ("{0,-28}" -f $tool.Name) -ForegroundColor $script:NRTheme.Text -NoNewline
        Write-Host (Get-NRUsage -Tool $tool) -ForegroundColor $script:NRTheme.Dim
    }
    Write-Host ''
}

function Show-NRModules {
    param([Parameter(Mandatory)][hashtable]$Context)

    Write-NRTitle 'Modules'
    if ($Context.Modules.Count -eq 0) {
        Write-NRWarn "No modules found in $($Context.ModulePath)"
        return
    }
    foreach ($m in $Context.Modules) {
        $color = $script:NRTheme.Ok
        if ($m.Status -ne 'Loaded') { $color = $script:NRTheme.Error }
        Write-Host ("   {0,-7}" -f $m.Status) -ForegroundColor $color -NoNewline
        Write-Host ("{0,-20} v{1,-8}" -f $m.Name, $m.Version) -ForegroundColor $script:NRTheme.Text -NoNewline
        $aliases = ($m.Tools | ForEach-Object { $_.Alias }) -join ', '
        Write-Host ("{0,-16} {1}" -f $m.Category, $aliases) -ForegroundColor $script:NRTheme.Dim
        if ($m.Error) { Write-Host ("            error: {0}" -f $m.Error) -ForegroundColor $script:NRTheme.Error }
        foreach ($w in $m.Warnings) { Write-Host ("            warning: {0}" -f $w) -ForegroundColor $script:NRTheme.Warn }
    }
    Write-Host ''
}

function Select-NRMenuNumber {
    # Handles one number in the current menu. Returns $false when NetRing must stop.
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][int]$Number,
        [bool]$ShowMenu = $true
    )

    if ($Number -eq 0) {
        if (-not $Context.Location) { return $false }
        $Context.Location = ''
        if ($ShowMenu) { Show-NRMenu -Context $Context }
        return $true
    }

    if (-not $Context.Location) {
        if ($Number -gt $Context.Categories.Count) {
            Write-NRError "No menu item $Number."
            return $true
        }
        $Context.Location = $Context.Categories[$Number - 1].Key
        if ($ShowMenu) { Show-NRMenu -Context $Context }
        return $true
    }

    $tools = @(Get-NRCategoryTools -Context $Context -Category $Context.Location)
    if ($Number -gt $tools.Count) {
        Write-NRError "No menu item $Number."
        return $true
    }
    $tool = $tools[$Number - 1]
    Write-NRTitle $tool.Name
    if ($tool.Description) { Write-Host ("  {0}" -f $tool.Description) -ForegroundColor $script:NRTheme.Dim }
    Write-Host ("  Tip: next time type '{0}'" -f (Get-NRUsage -Tool $tool)) -ForegroundColor $script:NRTheme.Dim
    Write-Host ''
    $arguments = ConvertTo-NRArguments -Tool $tool -Tokens @() -PromptAll
    if ($null -ne $arguments) { Invoke-NRTool -Context $Context -Tool $tool -Arguments $arguments }
    Write-Host '  (Enter = show menu)' -ForegroundColor $script:NRTheme.Dim
    return $true
}

function Invoke-NRCommand {
    # Handles one line of input. Returns $false when NetRing must stop.
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [AllowEmptyCollection()][string[]]$Tokens = @()
    )

    if ($Tokens.Count -eq 0) {
        Show-NRMenu -Context $Context
        return $true
    }

    $first = $Tokens[0]
    $rest = @()
    if ($Tokens.Count -gt 1) { $rest = @($Tokens[1..($Tokens.Count - 1)]) }

    switch ($first.ToLowerInvariant()) {
        'exit'    { return $false }
        'quit'    { return $false }
        'back'    { return (Select-NRMenuNumber -Context $Context -Number 0) }
        'menu'    { Show-NRMenu -Context $Context; return $true }
        'help'    {
            if ($rest.Count -gt 0) { Show-NRHelp -Context $Context -Alias $rest[0] } else { Show-NRHelp -Context $Context }
            return $true
        }
        'aliases' { Show-NRAliases -Context $Context; return $true }
        'modules' { Show-NRModules -Context $Context; return $true }
        'clear'   { Clear-Host; return $true }
        'cls'     { Clear-Host; return $true }
        'reload'  {
            Import-NRModules -Context $Context
            if ($Context.Location -and -not (Get-NRCategory -Context $Context -Key $Context.Location)) { $Context.Location = '' }
            Write-NRInfo ("Modules reloaded: {0} loaded." -f @($Context.Modules | Where-Object { $_.Status -eq 'Loaded' }).Count)
            return $true
        }
    }

    # Numbers: menu navigation. One number works in the current menu.
    # Several numbers ("1 1") are a full path, always starting at the main menu.
    if (@($Tokens | Where-Object { $_ -notmatch '^\d+$' }).Count -eq 0) {
        if ($Tokens.Count -gt 1) { $Context.Location = '' }
        for ($i = 0; $i -lt $Tokens.Count; $i++) {
            $wasInCategory = [bool]$Context.Location
            $isLast = ($i -eq $Tokens.Count - 1)
            $keepGoing = Select-NRMenuNumber -Context $Context -Number ([int]$Tokens[$i]) -ShowMenu $isLast
            if (-not $keepGoing) { return $false }
            # A number inside a category runs a tool: ignore what follows.
            if ($wasInCategory -and [int]$Tokens[$i] -ne 0) { break }
        }
        return $true
    }

    if ($Context.Aliases.ContainsKey($first)) {
        $tool = $Context.Aliases[$first]
        $arguments = ConvertTo-NRArguments -Tool $tool -Tokens $rest
        if ($null -ne $arguments) { Invoke-NRTool -Context $Context -Tool $tool -Arguments $arguments }
        return $true
    }

    Write-NRError "Unknown command '$first'. Type 'help' or 'aliases'."
    return $true
}

function Get-NRPrompt {
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context.Location) { return ("netring/{0}> " -f $Context.Location) }
    return 'netring> '
}

function Start-NRShell {
    param([Parameter(Mandatory)][hashtable]$Context)

    Show-NRMenu -Context $Context
    while ($true) {
        Write-Host (Get-NRPrompt -Context $Context) -ForegroundColor $script:NRTheme.Primary -NoNewline
        $line = Read-Host
        if ($null -eq $line) { break }   # input stream closed
        $tokens = Split-NRInput -Line $line
        $keepGoing = $true
        try {
            $keepGoing = Invoke-NRCommand -Context $Context -Tokens $tokens
        } catch {
            # Last safety net: a bug in the core itself must not kill the session.
            Write-NRError ("Internal error: {0}" -f $_.Exception.Message)
        }
        if (-not $keepGoing) { break }
    }
    Write-Host ''
    Write-Host '  Bye.' -ForegroundColor $script:NRTheme.Dim
}
