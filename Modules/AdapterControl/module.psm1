# NetRing module: AdapterControl
# Pick a network adapter and get the actions that fit it:
# renew/release the DHCP lease, restart, disable, enable, flush the DNS cache.
#
# Windows only. Uses the NetAdapter/NetTCPIP cmdlets and ipconfig, which exist
# in Windows PowerShell 5.1 and PowerShell 7 on Windows.
# Most actions need administrator rights; the module checks this up front.
# This file only contains ASCII characters: symbols are built with [char].

Set-StrictMode -Version 2.0

$script:Sym = @{
    Star  = [string][char]0x2605   # default route
    Arrow = [string][char]0x2192   # before -> after
    H     = [string][char]0x2500   # box: horizontal
    V     = [string][char]0x2502   # box: vertical
    TL    = [string][char]0x250C   # box: top left
    TR    = [string][char]0x2510   # box: top right
    BL    = [string][char]0x2514   # box: bottom left
    BR    = [string][char]0x2518   # box: bottom right
    On    = [string][char]0x25CF   # filled circle: up
    Off   = [string][char]0x25CB   # open circle: down / disabled
    Pick  = [string][char]0x25BA   # pointer
}

$script:BoxWidth = 64   # inner width of the 'Selected adapter' box
$script:StepRan = $false

# Color theme, inspired by the One Ring (same palette as the other modules).
$script:Theme = @{
    Title = 'DarkYellow'
    Key   = 'Yellow'
    Text  = 'White'
    Muted = 'Gray'
    Dim   = 'DarkGray'
    Up    = 'DarkYellow'
    Ok    = 'DarkYellow'
    Warn  = 'Yellow'
    Fire  = 'Red'
}

# All actions. Admin = needs administrator rights.
# Risky = can cut the connection, so ask first on the adapter of the default route.
$script:Actions = [ordered]@{
    renew    = @{ Label = 'Renew IP';        Desc = 'ask the DHCP server for an address';       Admin = $true;  Risky = $false }
    release  = @{ Label = 'Release IP';      Desc = 'give the address back, offline until renew'; Admin = $true;  Risky = $true  }
    restart  = @{ Label = 'Restart adapter'; Desc = 'disable and enable again';                 Admin = $true;  Risky = $true  }
    off      = @{ Label = 'Disable adapter'; Desc = 'turn the adapter off';                     Admin = $true;  Risky = $true  }
    on       = @{ Label = 'Enable adapter';  Desc = 'turn the adapter on';                      Admin = $true;  Risky = $false }
    flushdns = @{ Label = 'Flush DNS cache'; Desc = 'clear cached names, for all adapters';     Admin = $false; Risky = $false }
}

# Other words that are accepted for an action.
$script:ActionAliases = @{
    enable  = 'on';      disable = 'off';     reset   = 'restart'
    flush   = 'flushdns'; dns    = 'flushdns'
}

# ----------------------------------------------------------------------------
# System layer: everything that talks to Windows (kept small and separate)
# ----------------------------------------------------------------------------

function Test-NicPlatform {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'The adapter manager only works on Windows.'
    }
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
        throw 'Get-NetAdapter is not available on this system.'
    }
}

function Test-NicAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-NicDefaultIndex {
    # Interface index of the default route (lowest total metric), or -1.
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object { try { [int]$_.RouteMetric + [int]$_.InterfaceMetric } catch { [int]$_.RouteMetric } } |
            Select-Object -First 1
        if ($route) { return [int]$route.ifIndex }
    } catch { }
    return -1
}

function Get-NicList {
    # Returns one object per adapter. With -Index only that adapter.
    param([int]$Index = -1)

    $defaultIndex = Get-NicDefaultIndex
    if ($Index -ge 0) {
        $adapters = @(Get-NetAdapter -InterfaceIndex $Index -ErrorAction Stop)
    } else {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Sort-Object Name)
    }

    foreach ($a in $adapters) {
        $ips = @()
        $dhcp = $null
        try {
            $ips = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
                ForEach-Object { "{0}/{1}" -f $_.IPAddress, $_.PrefixLength })
        } catch { }
        try {
            $ipInterface = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
            if ($ipInterface) { $dhcp = ([string]$ipInterface.Dhcp -eq 'Enabled') }
        } catch { }
        $gateways = @()
        try {
            $gateways = @(Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                ForEach-Object { [string]$_.NextHop } | Where-Object { $_ -and $_ -ne '0.0.0.0' } | Select-Object -Unique)
        } catch { }
        $dns = @()
        try {
            $dns = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
                ForEach-Object { $_.ServerAddresses })
        } catch { }
        $speed = ''
        try { $speed = [string]$a.LinkSpeed } catch { }

        [pscustomobject]@{
            Name        = [string]$a.Name
            Description = [string]$a.InterfaceDescription
            Status      = [string]$a.Status
            Index       = [int]$a.ifIndex
            IPv4        = $ips
            Dhcp        = $dhcp
            Gateway     = $gateways
            Dns         = $dns
            Mac         = [string]$a.MacAddress
            Speed       = $speed
            IsDefault   = ([int]$a.ifIndex -eq $defaultIndex)
        }
    }
}

function Invoke-IpConfig {
    param([string[]]$Arguments)
    $output = & ipconfig.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $text = (@($output) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' '
        if (-not $text) { $text = "ipconfig failed with exit code $LASTEXITCODE" }
        throw $text
    }
}

function Invoke-NicAction {
    param($Nic, [string]$Action)

    switch ($Action) {
        'off'      { Disable-NetAdapter -Name $Nic.Name -Confirm:$false -ErrorAction Stop }
        'on'       { Enable-NetAdapter  -Name $Nic.Name -Confirm:$false -ErrorAction Stop }
        'restart'  { Restart-NetAdapter -Name $Nic.Name -Confirm:$false -ErrorAction Stop }
        'release'  { Invoke-IpConfig @('/release', $Nic.Name) }
        'renew'    { Invoke-IpConfig @('/renew', $Nic.Name) }
        'flushdns' { Invoke-IpConfig @('/flushdns') }
    }
}

# ----------------------------------------------------------------------------
# Logic
# ----------------------------------------------------------------------------

function Resolve-NicActionName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $key = $Name.ToLowerInvariant()
    if ($script:Actions.Contains($key)) { return $key }
    if ($script:ActionAliases.ContainsKey($key)) { return $script:ActionAliases[$key] }
    return ''
}

function Get-NicActions {
    # The actions that make sense for this adapter, in menu order.
    param($Nic)

    if ($Nic.Status -eq 'Disabled') { return @('on', 'flushdns') }
    $list = @()
    if ($Nic.Dhcp -eq $true -and $Nic.Status -eq 'Up') { $list += 'renew', 'release' }
    $list += 'restart', 'off', 'flushdns'
    return $list
}

function ConvertTo-NicSearchText {
    # "Wi-Fi 2" -> "wifi2": so "wifi" finds "Wi-Fi" and "vbox host" finds "VBox Host-Only".
    param([string]$Text)
    if (-not $Text) { return '' }
    return ($Text.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Find-Nic {
    # Exact name first, then part of the name, then part of the description.
    # Spaces, dashes and other signs are ignored.
    param($List, [string]$Name)

    $exact = @($List | Where-Object { $_.Name -eq $Name })
    if ($exact.Count -gt 0) { return $exact }
    $needle = ConvertTo-NicSearchText $Name
    if (-not $needle) { return @() }
    $byName = @($List | Where-Object { (ConvertTo-NicSearchText $_.Name).Contains($needle) })
    if ($byName.Count -gt 0) { return $byName }
    return @($List | Where-Object { (ConvertTo-NicSearchText $_.Description).Contains($needle) })
}

function Format-NicIp {
    param($Nic)
    if ($null -eq $Nic -or @($Nic.IPv4).Count -eq 0) { return 'none' }
    return (@($Nic.IPv4) -join ', ')
}

function Format-NicDhcp {
    param($Nic)
    if ($Nic.Dhcp -eq $true) { return 'DHCP' }
    if ($Nic.Dhcp -eq $false) { return 'static' }
    return ''
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'Up'       { return $script:Theme.Up }
        'Disabled' { return $script:Theme.Dim }
        default    { return $script:Theme.Muted }
    }
}

function Wait-NicState {
    # After an action Windows needs a moment. Poll until the expected state
    # is reached (max about 15 seconds) and return the new adapter state.
    param($Nic, [string]$Action)

    $deadline = (Get-Date).AddSeconds(15)
    $state = $null
    $first = $true
    while ($true) {
        if (-not $first) { Start-Sleep -Milliseconds 1000; Write-Host '.' -ForegroundColor $script:Theme.Dim -NoNewline }
        $first = $false
        try { $state = @(Get-NicList -Index $Nic.Index)[0] } catch { $state = $null }

        if ($state) {
            $realIp = @($state.IPv4 | Where-Object { $_ -notlike '169.254.*' }).Count -gt 0
            $done = $false
            switch ($Action) {
                'off'     { $done = ($state.Status -eq 'Disabled') }
                'release' { $done = -not $realIp }
                'renew'   { $done = $true }
                default   {
                    # on, restart: up with a real address, or no cable at all
                    $done = ($state.Status -eq 'Up' -and ($realIp -or $state.Dhcp -ne $true)) -or
                            ($state.Status -eq 'Disconnected' -and (Get-Date) -gt $deadline.AddSeconds(-11))
                }
            }
            if ($done) { break }
        }
        if ((Get-Date) -gt $deadline) { break }
    }
    Write-Host ''
    return $state
}

# ----------------------------------------------------------------------------
# Rendering and input
# ----------------------------------------------------------------------------

function Get-NicSlug {
    # "VirtualBox Host-Only" -> "virtualbox-host-only" (for the prompt)
    param([string]$Name)
    $slug = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $slug) { $slug = 'adapter' }
    return $slug
}

function Read-NicChoice {
    # Prompt like the core: netring/nic>  or  netring/nic/wi-fi>
    param([string]$Path = 'nic')
    Write-Host ("netring/{0}> " -f $Path) -ForegroundColor $script:Theme.Title -NoNewline
    $value = Read-Host
    if ($null -eq $value) { return '0' }   # input closed: leave
    return $value.Trim()
}

function Write-NicHeading {
    param([string]$Text)
    Write-Host ''
    Write-Host ("  {0}" -f $Text) -ForegroundColor $script:Theme.Title
    Write-Host ("  {0}" -f ($script:Sym.H * $Text.Length)) -ForegroundColor $script:Theme.Title
}

function Write-NicAdminNote {
    param([bool]$IsAdmin)
    if (-not $IsAdmin) {
        Write-Host '  [!] Not running as administrator: actions marked "admin" will not work.' -ForegroundColor $script:Theme.Warn
        Write-Host '      Start PowerShell with "Run as administrator" to use them.' -ForegroundColor $script:Theme.Dim
    }
}

function Write-NicStatus {
    # Colored status with a dot: (filled) Up, (open) Disconnected / Disabled
    param([string]$Status, [int]$Width = 0)
    $dot = $script:Sym.Off
    if ($Status -eq 'Up') { $dot = $script:Sym.On }
    $text = "$dot $Status"
    if ($Width -gt 0) { $text = $text.PadRight($Width) }
    Write-Host $text -ForegroundColor (Get-StatusColor $Status) -NoNewline
}

function Show-NicList {
    param($List, [bool]$IsAdmin, [string]$Title = 'Network adapters')

    $s = $script:Sym
    Write-NicHeading $Title
    Write-Host ''
    Write-Host ("   {0,3}   {1,-24}{2,-16}{3,-20}{4}" -f '#', 'Adapter', 'Status', 'IPv4', 'Type') -ForegroundColor $script:Theme.Muted
    Write-Host ("   {0}" -f ($s.H * 72)) -ForegroundColor $script:Theme.Dim

    $i = 0
    foreach ($nic in $List) {
        $i++
        $mark = ' '
        if ($nic.IsDefault) { $mark = $s.Star }
        $name = $nic.Name
        if ($name.Length -gt 23) { $name = $name.Substring(0, 21) + '..' }

        Write-Host ("   {0,3} " -f $i) -ForegroundColor $script:Theme.Key -NoNewline
        Write-Host ("{0} " -f $mark) -ForegroundColor $script:Theme.Key -NoNewline
        Write-Host ("{0,-24}" -f $name) -ForegroundColor $script:Theme.Text -NoNewline
        Write-NicStatus -Status $nic.Status -Width 16

        $ip = '-'
        if (@($nic.IPv4).Count -gt 0) { $ip = @($nic.IPv4)[0] }
        $ipColor = $script:Theme.Key
        if ($ip -like '169.254.*') { $ipColor = $script:Theme.Fire }
        if ($ip -eq '-') { $ipColor = $script:Theme.Dim }
        Write-Host ("{0,-20}" -f $ip) -ForegroundColor $ipColor -NoNewline
        Write-Host (Format-NicDhcp $nic) -ForegroundColor $script:Theme.Muted
    }
    Write-Host ''
    Write-Host '     0   Back' -ForegroundColor $script:Theme.Key
    Write-Host ''
    Write-Host ("   {0} default route   {1} up   {2} down or disabled" -f $s.Star, $s.On, $s.Off) -ForegroundColor $script:Theme.Dim
    Write-NicAdminNote -IsAdmin $IsAdmin
    Write-Host ''
}

function Select-NicFromList {
    # Shows the list and returns the chosen adapter, or $null for back.
    param($List, [bool]$IsAdmin, [string]$Title = 'Network adapters')

    Show-NicList -List $List -IsAdmin $IsAdmin -Title $Title
    while ($true) {
        $choice = Read-NicChoice -Path 'nic'
        if ($choice -eq '0' -or $choice -eq 'back') { return $null }
        if ($choice -eq '') { Show-NicList -List $List -IsAdmin $IsAdmin -Title $Title; continue }
        $n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le @($List).Count) {
            return @($List)[$n - 1]
        }
        Write-Host '  [x] Choose a number from the list, or 0 to go back.' -ForegroundColor $script:Theme.Fire
    }
}

# --- the 'Selected adapter' box ---------------------------------------------

function Write-BoxEdge {
    param([string]$Title = '', [switch]$Bottom)
    $s = $script:Sym
    if ($Bottom) {
        Write-Host ("  {0}{1}{2}" -f $s.BL, ($s.H * ($script:BoxWidth + 2)), $s.BR) -ForegroundColor $script:Theme.Title
        return
    }
    $label = ''
    if ($Title) { $label = " $Title " }
    $rest = $script:BoxWidth + 2 - 1 - $label.Length
    Write-Host ("  {0}{1}" -f $s.TL, $s.H) -ForegroundColor $script:Theme.Title -NoNewline
    Write-Host $label -ForegroundColor $script:Theme.Key -NoNewline
    Write-Host ("{0}{1}" -f ($s.H * $rest), $s.TR) -ForegroundColor $script:Theme.Title
}

function Write-BoxLine {
    # One line inside the box. Segments: @( @('text', 'Color'), ... )
    param([object[]]$Segments = @())
    $s = $script:Sym
    Write-Host ("  {0} " -f $s.V) -ForegroundColor $script:Theme.Title -NoNewline
    $used = 0
    foreach ($seg in $Segments) {
        $text = [string]$seg[0]
        $room = $script:BoxWidth - $used
        if ($room -le 0) { break }
        if ($text.Length -gt $room) { $text = $text.Substring(0, [math]::Max(0, $room - 2)) + '..' }
        Write-Host $text -ForegroundColor $seg[1] -NoNewline
        $used += $text.Length
    }
    Write-Host (' ' * [math]::Max(0, $script:BoxWidth - $used)) -NoNewline
    Write-Host (" {0}" -f $s.V) -ForegroundColor $script:Theme.Title
}

function Write-BoxField {
    param([string]$Label, [string]$Value, [string]$Color = '', [string]$Note = '', [string]$NoteColor = '')
    if (-not $Color) { $Color = $script:Theme.Text }
    if (-not $NoteColor) { $NoteColor = $script:Theme.Dim }
    $segments = @(, @(("  {0,-9}" -f $Label), $script:Theme.Muted))
    $segments += , @($Value, $Color)
    if ($Note) { $segments += , @("  $Note", $NoteColor) }
    Write-BoxLine -Segments $segments
}

function Show-NicCard {
    param($Nic)

    $s = $script:Sym
    Write-Host ''
    Write-BoxEdge -Title 'Selected adapter'

    $title = @(, @(("{0} {1}" -f $s.Pick, $Nic.Name), $script:Theme.Key))
    if ($Nic.IsDefault) { $title += , @(("   {0} default route" -f $s.Star), $script:Theme.Title) }
    Write-BoxLine -Segments $title
    if ($Nic.Description -and $Nic.Description -ne $Nic.Name) {
        Write-BoxLine -Segments @(, @(("  {0}" -f $Nic.Description), $script:Theme.Dim))
    }
    Write-BoxLine

    $dot = $s.Off
    if ($Nic.Status -eq 'Up') { $dot = $s.On }
    $speedNote = ''
    if ($Nic.Status -eq 'Up' -and $Nic.Speed) { $speedNote = $Nic.Speed }
    Write-BoxField 'Status' ("$dot $($Nic.Status)") (Get-StatusColor $Nic.Status) $speedNote

    $ip = Format-NicIp $Nic
    $ipColor = $script:Theme.Key
    $ipNote = ''
    if ($ip -like '169.254.*') { $ipColor = $script:Theme.Fire; $ipNote = '[!] APIPA: no DHCP answer'; }
    if ($ip -eq 'none') { $ipColor = $script:Theme.Dim }
    Write-BoxField 'IPv4' $ip $ipColor $ipNote $script:Theme.Fire

    $gateway = 'none'
    if (@($Nic.Gateway).Count -gt 0) { $gateway = @($Nic.Gateway) -join ', ' }
    $gwColor = $script:Theme.Text
    if ($gateway -eq 'none') { $gwColor = $script:Theme.Dim }
    Write-BoxField 'Gateway' $gateway $gwColor

    $dhcpText = '?'
    if ($Nic.Dhcp -eq $true) { $dhcpText = 'yes' }
    elseif ($Nic.Dhcp -eq $false) { $dhcpText = 'no (static)' }
    Write-BoxField 'DHCP' $dhcpText

    $dnsText = 'none'
    if (@($Nic.Dns).Count -gt 0) { $dnsText = @($Nic.Dns) -join ', ' }
    $dnsColor = $script:Theme.Text
    if ($dnsText -eq 'none') { $dnsColor = $script:Theme.Dim }
    Write-BoxField 'DNS' $dnsText $dnsColor

    if ($Nic.Mac) { Write-BoxField 'MAC' $Nic.Mac }
    Write-BoxEdge -Bottom
}

function Show-NicActionMenu {
    param($Nic, $Actions, [bool]$IsAdmin)

    Show-NicCard -Nic $Nic
    Write-Host ''
    Write-Host '  Actions' -ForegroundColor $script:Theme.Title
    $i = 0
    foreach ($a in $Actions) {
        $i++
        $def = $script:Actions[$a]
        $blocked = ($def.Admin -and -not $IsAdmin)
        $labelColor = $script:Theme.Text
        if ($blocked) { $labelColor = $script:Theme.Dim }
        Write-Host ("   {0,3}) " -f $i) -ForegroundColor $script:Theme.Key -NoNewline
        Write-Host ("{0,-18}" -f $def.Label) -ForegroundColor $labelColor -NoNewline
        Write-Host ("{0,-44}" -f $def.Desc) -ForegroundColor $script:Theme.Dim -NoNewline
        if ($blocked) { Write-Host 'admin' -ForegroundColor $script:Theme.Warn } else { Write-Host '' }
    }
    Write-Host ''
    Write-Host '     0) Back to the adapter list' -ForegroundColor $script:Theme.Key
    Write-Host ''

    $name = $Nic.Name
    if ($name -match '\s') { $name = '"' + $name + '"' }
    Write-Host ("  Shortcut: nic {0} <action>   (renew, release, restart, off, on, flushdns)" -f $name) -ForegroundColor $script:Theme.Dim
    Write-NicAdminNote -IsAdmin $IsAdmin
    Write-Host ''
}

function Write-NicChange {
    param($Before, $After)

    $s = $script:Sym
    if ($null -eq $After) {
        Write-Host '   [!] Could not read the new state of the adapter.' -ForegroundColor $script:Theme.Warn
        return
    }

    Write-Host '   Status  ' -ForegroundColor $script:Theme.Muted -NoNewline
    Write-NicStatus -Status $Before.Status
    Write-Host ("  {0}  " -f $s.Arrow) -ForegroundColor $script:Theme.Dim -NoNewline
    Write-NicStatus -Status $After.Status
    Write-Host ''

    $beforeIp = Format-NicIp $Before
    $afterIp = Format-NicIp $After
    Write-Host '   IPv4    ' -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $beforeIp -ForegroundColor $script:Theme.Text -NoNewline
    Write-Host ("  {0}  " -f $s.Arrow) -ForegroundColor $script:Theme.Dim -NoNewline
    $afterColor = $script:Theme.Key
    if ($afterIp -like '169.254.*') { $afterColor = $script:Theme.Fire }
    Write-Host $afterIp -ForegroundColor $afterColor -NoNewline
    if ($afterIp -like '169.254.*') {
        Write-Host '   [!] APIPA: no answer from a DHCP server' -ForegroundColor $script:Theme.Fire
    } elseif ($afterIp -eq $beforeIp) {
        Write-Host '   (unchanged)' -ForegroundColor $script:Theme.Dim
    } else {
        Write-Host ''
    }
}

function Write-NicResultHeader {
    param([string]$Text)
    $s = $script:Sym
    Write-Host ''
    Write-Host ("  {0}{0} " -f $s.H) -ForegroundColor $script:Theme.Title -NoNewline
    Write-Host $Text -ForegroundColor $script:Theme.Key -NoNewline
    Write-Host (" {0}" -f ($s.H * [math]::Max(3, 60 - $Text.Length))) -ForegroundColor $script:Theme.Title
}

function Invoke-NicStep {
    # Runs one action with all checks. Returns the (new) adapter state.
    param($Nic, [string]$Action, [bool]$IsAdmin)

    $def = $script:Actions[$Action]
    $script:StepRan = $false   # becomes $true once the action really runs

    if ($null -ne $Nic -and $Action -ne 'flushdns') {
        $possible = @(Get-NicActions -Nic $Nic)
        if ($possible -notcontains $Action) {
            $why = "status $($Nic.Status)"
            if ($Action -in @('renew', 'release') -and $Nic.Dhcp -ne $true) { $why = 'no DHCP on this adapter' }
            Write-Host ("  [x] '{0}' is not possible for {1} ({2})." -f $Action, $Nic.Name, $why) -ForegroundColor $script:Theme.Fire
            Write-Host ("      Possible: {0}" -f ($possible -join ', ')) -ForegroundColor $script:Theme.Dim
            return $Nic
        }
    }

    if ($def.Admin -and -not $IsAdmin) {
        Write-Host ("  [!] '{0}' needs administrator rights." -f $def.Label) -ForegroundColor $script:Theme.Warn
        Write-Host '      Start PowerShell with "Run as administrator" and start NetRing again.' -ForegroundColor $script:Theme.Dim
        return $Nic
    }

    if ($def.Risky -and $null -ne $Nic -and $Nic.IsDefault) {
        Write-Host ''
        Write-Host ("  [!] {0} carries your default route. You can lose your connection," -f $Nic.Name) -ForegroundColor $script:Theme.Warn
        Write-Host '      and a remote session (RDP, SSH) will drop.' -ForegroundColor $script:Theme.Warn
        Write-Host '      Continue? (y/N): ' -ForegroundColor $script:Theme.Text -NoNewline
        $answer = Read-Host
        if ($null -eq $answer -or $answer.Trim().ToLowerInvariant() -notin @('y', 'yes', 'j', 'ja')) {
            Write-Host '  Cancelled.' -ForegroundColor $script:Theme.Dim
            return $Nic
        }
    }

    $header = $def.Label
    if ($null -ne $Nic -and $Action -ne 'flushdns') { $header = "$($def.Label)  $($script:Sym.Arrow)  $($Nic.Name)" }
    Write-NicResultHeader -Text $header
    Write-Host '   Working ' -ForegroundColor $script:Theme.Muted -NoNewline
    $script:StepRan = $true

    try {
        Invoke-NicAction -Nic $Nic -Action $Action
    } catch {
        Write-Host ''
        Write-Host ("   [x] Failed: {0}" -f $_.Exception.Message) -ForegroundColor $script:Theme.Fire
        if (-not $IsAdmin) { Write-Host '       Tip: try again in PowerShell started as administrator.' -ForegroundColor $script:Theme.Dim }
        return $Nic
    }

    if ($Action -eq 'flushdns') {
        Write-Host ''
        Write-Host '   Done: DNS cache flushed.' -ForegroundColor $script:Theme.Ok
        return $Nic
    }

    $after = Wait-NicState -Nic $Nic -Action $Action
    Write-NicChange -Before $Nic -After $after
    Write-Host '   Done.' -ForegroundColor $script:Theme.Ok
    if ($null -eq $after) { return $Nic }
    return $after
}

function Start-NicActionLoop {
    # Action menu for one adapter, until the user chooses 0.
    param($Nic, [bool]$IsAdmin)

    while ($true) {
        $actions = @(Get-NicActions -Nic $Nic)
        Show-NicActionMenu -Nic $Nic -Actions $actions -IsAdmin $IsAdmin
        while ($true) {
            $choice = Read-NicChoice -Path ("nic/{0}" -f (Get-NicSlug $Nic.Name))
            if ($choice -eq '0' -or $choice -eq 'back') { return }
            if ($choice -eq '') { break }   # show the card and menu again
            $key = Resolve-NicActionName $choice
            $n = 0
            if (-not $key -and [int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $actions.Count) {
                $key = $actions[$n - 1]
            }
            if ($key) {
                $Nic = Invoke-NicStep -Nic $Nic -Action $key -IsAdmin $IsAdmin
                # Only redraw the card after a real action; after a refusal
                # (no admin, cancelled) just ask again.
                if ($script:StepRan) { break }
                continue
            }
            Write-Host '  [x] Choose a number from the menu, or 0 to go back.' -ForegroundColor $script:Theme.Fire
        }
    }
}

# ----------------------------------------------------------------------------
# Exported tool
# ----------------------------------------------------------------------------

function Invoke-NRAdapterManager {
    <#
    .SYNOPSIS
        Pick a network adapter and manage it.
    .EXAMPLE
        Invoke-NRAdapterManager -Adapter wifi -Action renew
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Adapter = '',

        [Parameter(Position = 1)]
        [string]$Action = ''
    )

    Test-NicPlatform
    $isAdmin = Test-NicAdmin

    # "nic flushdns": the only action that needs no adapter.
    if ($Adapter -and -not $Action -and (Resolve-NicActionName $Adapter) -eq 'flushdns') {
        [void](Invoke-NicStep -Nic $null -Action 'flushdns' -IsAdmin $isAdmin)
        return
    }

    $actionKey = ''
    if ($Action) {
        $actionKey = Resolve-NicActionName $Action
        if (-not $actionKey) {
            throw ("Unknown action '{0}'. Use: {1}." -f $Action, ($script:Actions.Keys -join ', '))
        }
        if ($actionKey -eq 'flushdns') {
            [void](Invoke-NicStep -Nic $null -Action 'flushdns' -IsAdmin $isAdmin)
            return
        }
    }

    if ($Adapter) {
        $found = @(Find-Nic -List @(Get-NicList) -Name $Adapter)
        if ($found.Count -eq 0) { throw "No adapter matches '$Adapter'. Type 'nic' to see the list." }
        $nic = $found[0]
        if ($found.Count -gt 1) {
            $nic = Select-NicFromList -List $found -IsAdmin $isAdmin -Title "Several adapters match '$Adapter'"
            if ($null -eq $nic) { return }
        }
        if ($actionKey) {
            [void](Invoke-NicStep -Nic $nic -Action $actionKey -IsAdmin $isAdmin)
        } else {
            Start-NicActionLoop -Nic $nic -IsAdmin $isAdmin
        }
        return
    }

    # No adapter given: list, choose, act, and back to the list.
    while ($true) {
        $list = @(Get-NicList)
        if ($list.Count -eq 0) {
            Write-Host '  [!] No network adapters found.' -ForegroundColor $script:Theme.Warn
            return
        }
        $nic = Select-NicFromList -List $list -IsAdmin $isAdmin
        if ($null -eq $nic) { return }
        if ($actionKey) {
            [void](Invoke-NicStep -Nic $nic -Action $actionKey -IsAdmin $isAdmin)
            return
        }
        Start-NicActionLoop -Nic $nic -IsAdmin $isAdmin
    }
}

Export-ModuleMember -Function 'Invoke-NRAdapterManager'
