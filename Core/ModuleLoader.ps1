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
        CategoryDefs = @()   # from Core/Categories.psd1
        Categories = @()     # categories shown in the main menu
        Location   = ''      # '' = main menu, otherwise the category key
    }
}

function Import-NRCategories {
    # Reads Core/Categories.psd1. Without it NetRing still works, every
    # module then ends up in 'Other'.
    param([Parameter(Mandatory)][hashtable]$Context)

    $defs = New-Object System.Collections.Generic.List[object]
    $path = Join-Path (Join-Path $Context.Root 'Core') 'Categories.psd1'
    try {
        $data = Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop
        $order = 0
        foreach ($c in @($data.Categories)) {
            if ($c -isnot [hashtable] -or -not $c.Key -or -not $c.Name) {
                Write-NRWarn "Categories.psd1: an entry without Key or Name is skipped."
                continue
            }
            $order++
            $description = ''
            if ($c.ContainsKey('Description')) { $description = [string]$c.Description }
            $defs.Add([pscustomobject]@{
                Key         = ([string]$c.Key).ToLowerInvariant()
                Name        = [string]$c.Name
                Description = $description
                Order       = $order
            })
        }
    } catch {
        Write-NRWarn ("Core/Categories.psd1 could not be loaded: {0}" -f $_.Exception.Message)
    }
    $Context.CategoryDefs = $defs.ToArray()
}

function Get-NROtherCategory {
    return [pscustomobject]@{
        Key         = 'other'
        Name        = 'Other'
        Description = 'Tools without a known category'
        Order       = 999
    }
}

function Resolve-NRCategory {
    # Finds a category by key or by name (not case sensitive).
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [string]$Value
    )
    foreach ($def in $Context.CategoryDefs) {
        if ($def.Key -eq $Value -or $def.Name -eq $Value) { return $def }
    }
    if ($Value -eq 'other') { return (Get-NROtherCategory) }
    return $null
}

function Get-NRCategory {
    # Returns the menu category with this key, or $null.
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [string]$Key
    )
    foreach ($c in $Context.Categories) {
        if ($c.Key -eq $Key) { return $c }
    }
    return $null
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
        CategoryKey = ''
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
        $category = Resolve-NRCategory -Context $Context -Value ([string]$manifest.Category)
        if (-not $category) {
            $record.Warnings.Add("unknown category '$($manifest.Category)', module placed in 'Other' (see Core/Categories.psd1)")
            $category = Get-NROtherCategory
        }
        $record.Category    = $category.Name
        $record.CategoryKey = $category.Key

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
                Module        = $record.Name
                Category      = $category.Name
                CategoryKey   = $category.Key
                CategoryOrder = $category.Order
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
    Import-NRCategories -Context $Context

    if (-not (Test-Path -LiteralPath $Context.ModulePath)) {
        Write-NRWarn "Modules folder not found: $($Context.ModulePath)"
        $Context.Categories = @($Context.CategoryDefs)
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

    # All categories from Categories.psd1, also the empty ones, so the menu
    # numbers never change. 'Other' only appears when a module needs it.
    $categories = New-Object System.Collections.Generic.List[object]
    foreach ($def in $Context.CategoryDefs) { $categories.Add($def) }
    $needsOther = @($Context.Modules | Where-Object { $_.Status -eq 'Loaded' -and $_.CategoryKey -eq 'other' }).Count -gt 0
    if ($needsOther -and -not (@($Context.CategoryDefs | Where-Object { $_.Key -eq 'other' }).Count -gt 0)) {
        $categories.Add((Get-NROtherCategory))
    }
    $Context.Categories = $categories.ToArray()
}

function Get-NRCategoryTools {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$Category
    )
    return @(
        $Context.Modules |
            Where-Object { $_.Status -eq 'Loaded' -and $_.CategoryKey -eq $Category } |
            ForEach-Object { $_.Tools } |
            Sort-Object Name
    )
}
