# NetRing core: input tokenizer, argument binding and the tool error boundary.

function Split-NRInput {
    # Splits a command line into tokens. Supports "double" and 'single' quotes.
    param([AllowEmptyString()][string]$Line)

    $tokens = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Line)) { return , $tokens.ToArray() }

    $pattern = '"([^"]*)"|''([^'']*)''|(\S+)'
    foreach ($m in [regex]::Matches($Line, $pattern)) {
        if ($m.Groups[1].Success)     { $tokens.Add($m.Groups[1].Value) }
        elseif ($m.Groups[2].Success) { $tokens.Add($m.Groups[2].Value) }
        else                          { $tokens.Add($m.Groups[3].Value) }
    }
    return , $tokens.ToArray()
}

function Get-NRUsage {
    # Builds a usage line like: trace <Target> [MaxHops] [Timeout]
    param([Parameter(Mandatory)]$Tool)

    $parts = @($Tool.Alias)
    foreach ($p in $Tool.Parameters) {
        if ($p.Required) { $parts += "<$($p.Name)>" } else { $parts += "[$($p.Name)]" }
    }
    return ($parts -join ' ')
}

function Read-NRParameterValue {
    param([Parameter(Mandatory)][hashtable]$Parameter)

    $label = $Parameter.Name
    if ($Parameter.Description) { $label = "$label ($($Parameter.Description))" }

    while ($true) {
        if ($Parameter.Required) {
            Write-Host ("  {0}: " -f $label) -ForegroundColor $script:NRTheme.Text -NoNewline
        } else {
            $default = ''
            if ($Parameter.ContainsKey('Default')) { $default = [string]$Parameter.Default }
            Write-Host ("  {0} [{1}]: " -f $label, $default) -ForegroundColor $script:NRTheme.Text -NoNewline
        }
        $value = Read-Host
        if ($null -eq $value) { $value = '' }
        $value = $value.Trim()

        if ($value -ne '') { return $value }
        if (-not $Parameter.Required) { return $null }
        Write-NRWarn "$($Parameter.Name) is required."
    }
}

function ConvertTo-NRArguments {
    # Maps tokens to the tool parameters.
    #   positional: trace 8.8.8.8 20
    #   named:      trace 8.8.8.8 -MaxHops 20
    # Missing required parameters are asked interactively.
    # Returns a hashtable for splatting, or $null when the input is invalid.
    param(
        [Parameter(Mandatory)]$Tool,
        [AllowEmptyCollection()][string[]]$Tokens = @(),
        [switch]$PromptAll
    )

    $bound = @{}
    $definitions = @($Tool.Parameters)
    $positional = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $token = $Tokens[$i]
        if ($token -match '^-([A-Za-z][\w]*)$') {
            $name = $Matches[1]
            $def = $definitions | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($def) {
                if ($i + 1 -ge $Tokens.Count) {
                    Write-NRError "Parameter -$name needs a value."
                    return $null
                }
                $bound[$def.Name] = $Tokens[$i + 1]
                $i++
                continue
            }
        }
        $positional.Add($token)
    }

    foreach ($value in $positional) {
        $next = $definitions | Where-Object { -not $bound.ContainsKey($_.Name) } | Select-Object -First 1
        if (-not $next) {
            Write-NRError ("Too many arguments. Usage: {0}" -f (Get-NRUsage -Tool $Tool))
            return $null
        }
        $bound[$next.Name] = $value
    }

    foreach ($def in $definitions) {
        if ($bound.ContainsKey($def.Name)) { continue }
        if ($def.Required -or $PromptAll) {
            $value = Read-NRParameterValue -Parameter $def
            if ($null -ne $value) { $bound[$def.Name] = $value }
        }
    }

    return $bound
}

function Invoke-NRTool {
    # The error boundary: whatever a tool does, NetRing keeps running.
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)]$Tool,
        [Parameter(Mandatory)][hashtable]$Arguments
    )

    $splat = @{}
    foreach ($key in $Arguments.Keys) { $splat[$key] = $Arguments[$key] }
    if ($Tool.Command.CmdletBinding) { $splat['ErrorAction'] = 'Stop' }

    try {
        $output = & $Tool.Command @splat
        if ($null -ne $output) { $output | Out-Host }
    } catch {
        Write-Host ''
        Write-NRError ("'{0}' (module {1}) stopped with an error:" -f $Tool.Alias, $Tool.Module)
        Write-Host ("      {0}" -f $_.Exception.Message) -ForegroundColor $script:NRTheme.Error
        Write-Host ("      Usage: {0}   (help {1} for details)" -f (Get-NRUsage -Tool $Tool), $Tool.Alias) -ForegroundColor $script:NRTheme.Dim
    }
}
