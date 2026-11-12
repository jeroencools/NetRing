# NetRing module: LanInfo
# Shows the local network configuration of every adapter in a clear overview:
# IP, subnet, network range, gateway, DHCP, DNS, MAC, speed and more.
#
# Uses .NET (System.Net.NetworkInformation), so it needs no extra modules and
# works on Windows PowerShell 5.1 and PowerShell 7. Information that the OS
# does not provide is shown as '?'.
# This file only contains ASCII characters: symbols are built with [char].

Set-StrictMode -Version 2.0

$script:Sym = @{
    V      = [string][char]0x2502   # vertical line
    Tee    = [string][char]0x251C   # branch
    End    = [string][char]0x2514   # last branch
    H      = [string][char]0x2500   # horizontal line
    Node   = [string][char]0x25CF   # filled circle
    Miss   = [string][char]0x25CB   # open circle
    Star   = [string][char]0x2605   # star: default route
}

# Color theme, inspired by the One Ring: gold, dark gold and the fire of Mount Doom.
# In Windows Terminal 'DarkYellow' is the real gold and 'Yellow' a pale gold.
$script:Theme = @{
    Line   = 'DarkYellow'   # the golden thread
    Title  = 'DarkYellow'
    Label  = 'Gray'
    Value  = 'White'
    Accent = 'Yellow'       # IP addresses
    Dim    = 'DarkGray'
    Up     = 'DarkYellow'
    Down   = 'DarkGray'
    Warn   = 'Yellow'
    Fire   = 'Red'
}

# ----------------------------------------------------------------------------
# Helpers (not exported)
# ----------------------------------------------------------------------------

function Invoke-Safe {
    # Runs a script block and returns $Fallback when it fails. Some properties
    # are not available on every OS or adapter type.
    param([scriptblock]$Script, $Fallback = $null)
    try { return (& $Script) } catch { return $Fallback }
}

function Get-PrefixFromMask {
    param([System.Net.IPAddress]$Mask)
    if ($null -eq $Mask) { return $null }
    $bits = 0
    foreach ($b in $Mask.GetAddressBytes()) {
        $value = [int]$b
        while ($value -gt 0) { $bits += ($value -band 1); $value = $value -shr 1 }
    }
    return $bits
}

function Get-MaskFromPrefix {
    param([int]$Prefix)
    $bytes = New-Object byte[] 4
    for ($i = 0; $i -lt 4; $i++) {
        $n = [math]::Max(0, [math]::Min(8, $Prefix - ($i * 8)))
        $bytes[$i] = [byte]((0xFF -shl (8 - $n)) -band 0xFF)
    }
    return New-Object System.Net.IPAddress (, $bytes)
}

function Get-NetworkRange {
    # Returns network address, broadcast address and number of usable hosts.
    param([System.Net.IPAddress]$Address, [int]$Prefix)

    $ip = $Address.GetAddressBytes()
    $mask = (Get-MaskFromPrefix $Prefix).GetAddressBytes()
    $net = New-Object byte[] 4
    $bc = New-Object byte[] 4
    for ($i = 0; $i -lt 4; $i++) {
        $net[$i] = [byte]($ip[$i] -band $mask[$i])
        $bc[$i] = [byte]($net[$i] -bor ((-bnot $mask[$i]) -band 0xFF))
    }
    $hosts = [math]::Pow(2, 32 - $Prefix) - 2
    if ($Prefix -ge 31) { $hosts = [math]::Pow(2, 32 - $Prefix) }
    return [pscustomobject]@{
        Network   = New-Object System.Net.IPAddress (, $net)
        Broadcast = New-Object System.Net.IPAddress (, $bc)
        Hosts     = [int64]$hosts
    }
}

function Format-Speed {
    param([int64]$BitsPerSecond)
    # Unknown speed shows up as 0, -1 or a nonsense value like UInt32.MaxValue.
    if ($BitsPerSecond -le 0 -or $BitsPerSecond -ge 1000000000000) { return '' }
    if ($BitsPerSecond -ge 1000000000) { return ("{0:0.#} Gbps" -f ($BitsPerSecond / 1000000000)) }
    if ($BitsPerSecond -ge 1000000) { return ("{0:0.#} Mbps" -f ($BitsPerSecond / 1000000)) }
    return ("{0:0} kbps" -f ($BitsPerSecond / 1000))
}

function Format-Mac {
    param([string]$Raw)
    if (-not $Raw -or $Raw.Length -ne 12) { return '' }
    $pairs = for ($i = 0; $i -lt 12; $i += 2) { $Raw.Substring($i, 2) }
    return ($pairs -join '-')
}

function Get-DefaultRouteAddress {
    # Asks the OS which local IPv4 address it would use to reach the internet.
    # A UDP "connect" does not send any packet.
    $socket = $null
    try {
        $socket = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        $socket.Connect([System.Net.IPAddress]::Parse('8.8.8.8'), 53)
        return $socket.LocalEndPoint.Address.ToString()
    } catch {
        return ''
    } finally {
        if ($socket) { $socket.Dispose() }
    }
}

function Get-AdapterInfo {
    # Collects everything about one adapter in a single object.
    param([System.Net.NetworkInformation.NetworkInterface]$Nic, [string]$DefaultIp)

    $props = Invoke-Safe { $Nic.GetIPProperties() }
    $v4props = Invoke-Safe { $props.GetIPv4Properties() }

    $ipv4 = @()
    $ipv6 = @()
    if ($props) {
        foreach ($u in $props.UnicastAddresses) {
            $addr = $u.Address
            if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                $prefix = Invoke-Safe { [int]$u.PrefixLength }
                if (-not $prefix) { $prefix = Get-PrefixFromMask (Invoke-Safe { $u.IPv4Mask }) }
                $ipv4 += [pscustomobject]@{ Address = $addr; Prefix = $prefix }
            } elseif ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                $text = $addr.ToString()
                $scopeAt = $text.IndexOf('%')
                if ($scopeAt -gt 0) { $text = $text.Substring(0, $scopeAt) }
                $kind = 'global'
                if ($addr.IsIPv6LinkLocal) { $kind = 'link-local' }
                elseif ($addr.IsIPv6SiteLocal -or (($addr.GetAddressBytes()[0] -band 0xFE) -eq 0xFC)) { $kind = 'unique local' }
                $ipv6 += [pscustomobject]@{ Text = $text; Kind = $kind }
            }
        }
    }

    $gateways = @()
    $dns = @()
    $dhcpServers = @()
    $suffix = ''
    if ($props) {
        $gateways = @($props.GatewayAddresses | ForEach-Object { $_.Address } |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $_.ToString() -ne '0.0.0.0' } |
            ForEach-Object { $_.ToString() })
        $dns = @($props.DnsAddresses | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.ToString() })
        $dnsV6 = @($props.DnsAddresses | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and -not $_.IsIPv6SiteLocal } | ForEach-Object { $_.ToString() })
        if ($dns.Count -eq 0) { $dns = $dnsV6 }
        $dhcpServers = @(Invoke-Safe { $props.DhcpServerAddresses | ForEach-Object { $_.ToString() } } @())
        $suffix = [string](Invoke-Safe { $props.DnsSuffix } '')
    }

    $dhcp = '?'
    $dhcpValue = Invoke-Safe { $v4props.IsDhcpEnabled }
    if ($dhcpValue -eq $true) { $dhcp = 'yes' } elseif ($dhcpValue -eq $false) { $dhcp = 'no' }

    $mtu = Invoke-Safe { $v4props.Mtu }
    $isDefault = $false
    if ($DefaultIp) {
        foreach ($a in $ipv4) { if ($a.Address.ToString() -eq $DefaultIp) { $isDefault = $true } }
    }

    return [pscustomobject]@{
        Name        = $Nic.Name
        Description = $Nic.Description
        Type        = [string]$Nic.NetworkInterfaceType
        Status      = [string]$Nic.OperationalStatus
        Speed       = Format-Speed (Invoke-Safe { $Nic.Speed } 0)
        Mac         = Format-Mac (Invoke-Safe { $Nic.GetPhysicalAddress().ToString() } '')
        IPv4        = $ipv4
        IPv6        = $ipv6
        Gateways    = $gateways
        Dhcp        = $dhcp
        DhcpServers = $dhcpServers
        Dns         = $dns
        Suffix      = $suffix
        Mtu         = $mtu
        IsDefault   = $isDefault
    }
}

# ----------------------------------------------------------------------------
# Rendering
# ----------------------------------------------------------------------------

function Write-Row {
    # One line of a card:  |- Label      : value
    param([string]$Label, [string]$Value, [string]$Color, [switch]$Last, [string]$Note = '', [string]$NoteColor = '')

    $s = $script:Sym
    $branch = $s.Tee
    if ($Last) { $branch = $s.End }
    if (-not $Color) { $Color = $script:Theme.Value }
    if (-not $NoteColor) { $NoteColor = $script:Theme.Dim }

    Write-Host ("    {0}{1} " -f $branch, $s.H) -ForegroundColor $script:Theme.Line -NoNewline
    Write-Host ("{0,-11}: " -f $Label) -ForegroundColor $script:Theme.Label -NoNewline
    Write-Host $Value -ForegroundColor $Color -NoNewline
    if ($Note) { Write-Host ("  {0}" -f $Note) -ForegroundColor $NoteColor -NoNewline }
    Write-Host ''
}

function Write-AdapterCard {
    param($Info)

    $s = $script:Sym
    $isUp = ($Info.Status -eq 'Up')

    # Header
    Write-Host ''
    $dotColor = $script:Theme.Down
    if ($isUp) { $dotColor = $script:Theme.Up }
    Write-Host ("  {0} " -f $s.Node) -ForegroundColor $dotColor -NoNewline
    Write-Host ("{0}" -f $Info.Name) -ForegroundColor $script:Theme.Title -NoNewline
    if ($Info.IsDefault) {
        Write-Host ("  {0} default route" -f $s.Star) -ForegroundColor $script:Theme.Accent -NoNewline
    }
    Write-Host ''
    $sub = @($Info.Status, $Info.Type, $Info.Speed) | Where-Object { $_ }
    Write-Host ("    {0}" -f ($sub -join '  |  ')) -ForegroundColor $script:Theme.Dim
    if ($Info.Description -and $Info.Description -ne $Info.Name) {
        Write-Host ("    {0}" -f $Info.Description) -ForegroundColor $script:Theme.Dim
    }
    Write-Host ("    {0}" -f $s.V) -ForegroundColor $script:Theme.Line

    # Rows: build them first, so we know which one is the last.
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Row([string]$Label, [string]$Value, [string]$Color = '', [string]$Note = '', [string]$NoteColor = '') {
        $rows.Add(@{ Label = $Label; Value = $Value; Color = $Color; Note = $Note; NoteColor = $NoteColor })
    }

    if ($Info.IPv4.Count -eq 0) {
        Add-Row 'IPv4' 'none' $script:Theme.Dim
    }
    foreach ($a in $Info.IPv4) {
        $ipText = $a.Address.ToString()
        $note = ''
        $noteColor = ''
        if ($ipText.StartsWith('169.254.')) {
            $note = '[!] APIPA: no answer from a DHCP server'
            $noteColor = $script:Theme.Fire
        }
        if ($null -ne $a.Prefix) {
            $mask = Get-MaskFromPrefix $a.Prefix
            Add-Row 'IPv4' ("{0}/{1}" -f $ipText, $a.Prefix) $script:Theme.Accent $note $noteColor
            Add-Row 'Subnet mask' $mask.ToString()
            if ($a.Prefix -le 30 -and -not $ipText.StartsWith('127.')) {
                $range = Get-NetworkRange -Address $a.Address -Prefix $a.Prefix
                Add-Row 'Network' ("{0} - {1}" -f $range.Network, $range.Broadcast) '' ("{0} usable hosts" -f $range.Hosts)
            }
        } else {
            Add-Row 'IPv4' $ipText $script:Theme.Accent $note $noteColor
        }
    }

    if ($Info.Gateways.Count -gt 0) {
        Add-Row 'Gateway' ($Info.Gateways -join ', ')
    } elseif ($isUp -and $Info.Type -ne 'Loopback') {
        Add-Row 'Gateway' 'none' $script:Theme.Dim 'no internet via this adapter'
    }

    switch ($Info.Dhcp) {
        'yes' {
            $server = ''
            if ($Info.DhcpServers.Count -gt 0) { $server = 'server ' + ($Info.DhcpServers -join ', ') }
            Add-Row 'DHCP' 'yes' '' $server
        }
        'no'  { Add-Row 'DHCP' 'no' $script:Theme.Warn 'static configuration' }
        default { Add-Row 'DHCP' '?' $script:Theme.Dim 'not available on this system' }
    }

    if ($Info.Dns.Count -gt 0) { Add-Row 'DNS' ($Info.Dns -join ', ') }
    elseif ($isUp -and $Info.Type -ne 'Loopback') { Add-Row 'DNS' 'none' $script:Theme.Dim }
    if ($Info.Suffix) { Add-Row 'DNS suffix' $Info.Suffix }

    foreach ($v6 in $Info.IPv6) { Add-Row 'IPv6' $v6.Text '' $v6.Kind }

    if ($Info.Mac) { Add-Row 'MAC' $Info.Mac }
    if ($Info.Mtu -and $Info.Mtu -gt 0) { Add-Row 'MTU' ([string]$Info.Mtu) }

    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $isLast = ($i -eq $rows.Count - 1)
        Write-Row -Label $r.Label -Value $r.Value -Color $r.Color -Note $r.Note -NoteColor $r.NoteColor -Last:$isLast
    }
}

function Write-AdapterTable {
    param($Infos)

    $s = $script:Sym
    $header = "   {0,-24} {1,-18} {2,-15} {3,-5} {4}" -f 'Adapter', 'IPv4', 'Gateway', 'DHCP', 'DNS'
    Write-Host ''
    Write-Host $header -ForegroundColor $script:Theme.Title
    Write-Host ("   {0}" -f ($s.H * ($header.Length - 3))) -ForegroundColor $script:Theme.Line

    foreach ($info in $Infos) {
        $name = $info.Name
        if ($name.Length -gt 23) { $name = $name.Substring(0, 21) + '..' }
        $ip = '-'
        if ($info.IPv4.Count -gt 0) {
            $first = $info.IPv4[0]
            $ip = $first.Address.ToString()
            if ($null -ne $first.Prefix) { $ip = "$ip/$($first.Prefix)" }
        }
        $gw = '-'
        if ($info.Gateways.Count -gt 0) { $gw = $info.Gateways[0] }
        $dnsText = '-'
        if ($info.Dns.Count -gt 0) { $dnsText = $info.Dns -join ', ' }

        $dot = $s.Miss
        $dotColor = $script:Theme.Down
        if ($info.Status -eq 'Up') { $dot = $s.Node; $dotColor = $script:Theme.Up }
        if ($info.IsDefault) { $dot = $s.Star; $dotColor = $script:Theme.Accent }

        Write-Host ' ' -NoNewline
        Write-Host $dot -ForegroundColor $dotColor -NoNewline
        Write-Host (" {0,-24} " -f $name) -ForegroundColor $script:Theme.Value -NoNewline
        $ipColor = $script:Theme.Accent
        if ($ip.StartsWith('169.254.')) { $ipColor = $script:Theme.Fire }
        Write-Host ("{0,-18} " -f $ip) -ForegroundColor $ipColor -NoNewline
        Write-Host ("{0,-15} " -f $gw) -ForegroundColor $script:Theme.Value -NoNewline
        $dhcpColor = $script:Theme.Value
        if ($info.Dhcp -eq 'no') { $dhcpColor = $script:Theme.Warn }
        Write-Host ("{0,-5} " -f $info.Dhcp) -ForegroundColor $dhcpColor -NoNewline
        Write-Host $dnsText -ForegroundColor $script:Theme.Label
    }
    Write-Host ''
    Write-Host ("   {0} default route   {1} up   {2} down" -f $s.Star, $s.Node, $s.Miss) -ForegroundColor $script:Theme.Dim
}

# ----------------------------------------------------------------------------
# Exported tool
# ----------------------------------------------------------------------------

function Show-NRLanInfo {
    <#
    .SYNOPSIS
        Overview of the network configuration of every adapter.
    .EXAMPLE
        Show-NRLanInfo -View table -All on
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Filter = '*',

        [Parameter(Position = 1)]
        [ValidateSet('card', 'table')]
        [string]$View = 'card',

        [Parameter(Position = 2)]
        [ValidateSet('on', 'off')]
        [string]$All = 'off'
    )

    # "wifi" also finds "Wi-Fi 2": without wildcards we search for a part of the name.
    $pattern = $Filter
    if (-not $pattern) { $pattern = '*' }
    if ($pattern -notmatch '[\*\?]') { $pattern = "*$pattern*" }

    $nics = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.Name -like $pattern -or $_.Description -like $pattern })

    $hidden = 0
    if ($All -eq 'off') {
        $visible = @($nics | Where-Object {
            $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up -and
            $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback
        })
        $hidden = $nics.Count - $visible.Count
        $nics = $visible
    }

    if ($nics.Count -eq 0) {
        Write-Host ''
        Write-Host ("  No adapters found for '{0}'." -f $Filter) -ForegroundColor $script:Theme.Warn
        if ($hidden -gt 0) {
            Write-Host ("  {0} adapter(s) hidden because they are down or loopback. Try: lan {1} -All on" -f $hidden, $Filter) -ForegroundColor $script:Theme.Dim
        }
        Write-Host ''
        return
    }

    $defaultIp = Get-DefaultRouteAddress
    $infos = @($nics | ForEach-Object { Get-AdapterInfo -Nic $_ -DefaultIp $defaultIp } |
        Sort-Object @{ Expression = { -not $_.IsDefault } }, @{ Expression = { $_.Status -ne 'Up' } }, Name)

    Write-Host ''
    Write-Host ("  LAN info  |  {0}  |  {1} adapter(s)" -f [System.Net.Dns]::GetHostName(), $infos.Count) -ForegroundColor $script:Theme.Title

    if ($View -eq 'table') {
        Write-AdapterTable -Infos $infos
    } else {
        foreach ($info in $infos) { Write-AdapterCard -Info $info }
    }

    if ($hidden -gt 0) {
        Write-Host ''
        Write-Host ("  {0} adapter(s) hidden (down or loopback). Show them with: lan -All on" -f $hidden) -ForegroundColor $script:Theme.Dim
    }
    Write-Host ''
}

Export-ModuleMember -Function 'Show-NRLanInfo'
