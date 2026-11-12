# NetRing core: module discovery, validation and loading.
#
# Every folder inside Modules/ is a module, except folders whose name starts
# with "_" or "." (for example Modules/_Template). A module needs two files:
#   module.psd1  metadata (name, version, category, tools, aliases, parameters)
#   module.psm1  the PowerShell code with the functions named in the metadata
#
# Each module is loaded inside its own try/catch. A broken module is marked
# as "Failed" and skipped; it never stops the core or other modules.

# Words the core reserves for itself. Modules cannot use them as alias.
$script:NRBuiltinCommands = @('help', 'aliases', 'modules', 'back', 'exit', 'quit', 'menu', 'clear', 'cls', 'reload')

function New-NRContext {
    param([Parameter(Mandatory)][string]$Root)

    return @{
        Root       = $Root
        Version    = '0.1.0'
        ModulePath = Join-Path $Root 'Modules'
        Modules    = @()
        # Case insensitive lookup: alias -> tool record
        Aliases    = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
        Categories = @()
        Location   = ''   # '' = main menu, otherwise the category name
    }
}

function Test-NRManifest {
    # Returns a list of problems. An empty list means the manifest is valid.
    param([Parameter(Mandatory)][hashtable]$Manifest)

    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($key in 'Name', 'Version', 'Category', 'Tools') {
        if (-not $Manifest.ContainsKey($key) -or -not $Manifest[$key]) {
            $problems.Add("missing key '$key'")
        }
    }
    if ($Manifest.ContainsKey('Tools') -and $Manifest['Tools']) {
        $i = 0
        foreach ($tool in @($Manifest['Tools'])) {
            $i++
            if ($tool -isnot [hashtable]) {
                $problems.Add("tool #$i is not a hashtable")
                continue
            }
            foreach ($key in 'Name', 'Alias', 'Command') {
                if (-not $tool.ContainsKey($key) -or -not $tool[$key]) {
                    $problems.Add("tool #$i is missing key '$key'")
                }
            }
            if ($tool.ContainsKey('Alias') -and $tool['Alias'] -match '\s') {
                $problems.Add("alias '$($tool['Alias'])' contains spaces")
            }
            if ($tool.ContainsKey('Parameters')) {
                foreach ($p in @($tool['Parameters'])) {
                    if ($p -isnot [hashtable] -or -not $p.ContainsKey('Name')) {
                        $problems.Add("tool '$($tool['Name'])' has a parameter without 'Name'")
                    }
                }
            }
        }
    }
    return , $problems
}

function Import-NRModuleFolder {
    # Loads one module folder. Always returns a module record, also on failure.
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][System.IO.DirectoryInfo]$Folder
    )

    $record = [pscustomobject]@{
        Name     = $Folder.Name
        Version  = '?'
        Category = ''
        Path     = $Folder.FullName
        Status   = 'Failed'
        Error    = ''
        Warnings = New-Object System.Collections.Generic.List[string]
        Tools    = @()
    }

    try {
        $manifestPath = Join-Path $Folder.FullName 'module.psd1'
        $codePath     = Join-Path $Folder.FullName 'module.psm1'
        if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'module.psd1 not found' }
        if (-not (Test-Path -LiteralPath $codePath))     { throw 'module.psm1 not found' }

        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
        $problems = Test-NRManifest -Manifest $manifest
        if ($problems.Count -gt 0) { throw ('invalid module.psd1: ' + ($problems -join '; ')) }

        $record.Name     = [string]$manifest.Name
        $record.Version  = [string]$manifest.Version
        $record.Category = [string]$manifest.Category

        if ($manifest.ContainsKey('MinPSVersion') -and $manifest.MinPSVersion) {
            if ($PSVersionTable.PSVersion -lt [version]$manifest.MinPSVersion) {
                throw ("needs PowerShell {0} or newer" -f $manifest.MinPSVersion)
            }
        }

        # Import without -Global: the functions stay out of the user's session.
        # We keep a reference to every command so the core can still call it.
        $psModule = Import-Module -Name $codePath -Force -PassThru -DisableNameChecking -ErrorAction Stop

        $tools = New-Object System.Collections.Generic.List[object]
        foreach ($t in @($manifest.Tools)) {
            $alias = [string]$t.Alias

            if ($script:NRBuiltinCommands -contains $alias.ToLowerInvariant()) {
                $record.Warnings.Add("alias '$alias' is a built-in command, tool '$($t.Name)' skipped")
                continue
            }
            if ($alias -match '^\d+$') {
                $record.Warnings.Add("alias '$alias' is a number, tool '$($t.Name)' skipped")
                continue
            }
            if ($Context.Aliases.ContainsKey($alias)) {
                $owner = $Context.Aliases[$alias].Module
                $record.Warnings.Add("alias '$alias' already used by module '$owner', tool '$($t.Name)' skipped")
                continue
            }
            if (-not $psModule.ExportedCommands.ContainsKey([string]$t.Command)) {
                $record.Warnings.Add("command '$($t.Command)' is not exported by module.psm1, tool '$($t.Name)' skipped")
                continue
            }

            $params = @()
            if ($t.ContainsKey('Parameters') -and $t.Parameters) { $params = @($t.Parameters) }
            $examples = @()
            if ($t.ContainsKey('Examples') -and $t.Examples) { $examples = @($t.Examples) }
            $description = ''
            if ($t.ContainsKey('Description')) { $description = [string]$t.Description }

            $tool = [pscustomobject]@{
                Name        = [string]$t.Name
                Alias       = $alias
                Description = $description
                Parameters  = $params
                Examples    = $examples
                Command     = $psModule.ExportedCommands[[string]$t.Command]
                Module      = $record.Name
                Category    = $record.Category
            }
            $tools.Add($tool)
            $Context.Aliases[$alias] = $tool
        }

        if ($tools.Count -eq 0) { throw 'no usable tools (see warnings)' }

        $record.Tools  = $tools.ToArray()
        $record.Status = 'Loaded'
    } catch {
        $record.Status = 'Failed'
        $record.Error  = $_.Exception.Message
    }

    return $record
}

function Import-NRModules {
    param([Parameter(Mandatory)][hashtable]$Context)

    $Context.Modules = @()
    $Context.Aliases.Clear()

    if (-not (Test-Path -LiteralPath $Context.ModulePath)) {
        Write-NRWarn "Modules folder not found: $($Context.ModulePath)"
        $Context.Categories = @()
        return
    }

    $folders = Get-ChildItem -LiteralPath $Context.ModulePath -Directory |
        Where-Object { $_.Name -notmatch '^[_.]' } |
        Sort-Object Name

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($folder in $folders) {
        $records.Add((Import-NRModuleFolder -Context $Context -Folder $folder))
    }
    $Context.Modules = $records.ToArray()

    $Context.Categories = @(
        $Context.Modules |
            Where-Object { $_.Status -eq 'Loaded' } |
            ForEach-Object { $_.Category } |
            Sort-Object -Unique
    )
}

function Get-NRCategoryTools {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$Category
    )
    return @(
        $Context.Modules |
            Where-Object { $_.Status -eq 'Loaded' -and $_.Category -eq $Category } |
            ForEach-Object { $_.Tools } |
            Sort-Object Name
    )
}
