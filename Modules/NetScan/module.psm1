# NetRing module: NetScan
# "Who is on my network?" A simple discovery of your own subnet:
#   1. ping every address (in parallel)
#   2. read the ARP table: devices that block ping still show up there
#   3. vendor from the MAC address, hostname from reverse DNS
#   4. a rough guess of the device type (gateway, TTL, name, vendor)
# No port scan.
#
# Works on Windows PowerShell 5.1 and PowerShell 7.
# Vendor names: a small built-in list. For a complete list, download
# https://standards-oui.ieee.org/oui/oui.txt and put it in this module folder.
# This file only contains ASCII characters: symbols are built with [char].

Set-StrictMode -Version 2.0

$script:Sym = @{
    V     = [string][char]0x2502
    Tee   = [string][char]0x251C
    End   = [string][char]0x2514
    H     = [string][char]0x2500
    Ping  = [string][char]0x25CF   # answered ping
    Arp   = [string][char]0x25CB   # only seen in the ARP table
    Star  = [string][char]0x2605   # gateway
    Self  = [string][char]0x25BA   # this computer
}

# Color theme, inspired by the One Ring: gold, dark gold and the fire of Mount Doom.
$script:Theme = @{
    Title = 'DarkYellow'
    Key   = 'Yellow'
    Text  = 'White'
    Muted = 'Gray'
    Dim   = 'DarkGray'
    Ok    = 'DarkYellow'
    Warn  = 'Yellow'
    Fire  = 'Red'
}

$script:MinPrefix = 16   # largest network that can be scanned: /16 (65534 addresses)
$script:SafePrefix = 22  # larger than /22 (1022 addresses): extra warning and confirmation
$script:SafeCount = 1022     # same limit for a range of addresses
$script:MaxAddresses = 65534 # same maximum for a range as for a /16
$script:BatchSize = 128  # pings sent at the same time

# A small, safe list of OUI prefixes (first 3 bytes of the MAC address).
$script:Vendors = @{
    '000C29' = 'VMware';            '005056' = 'VMware';           '000569' = 'VMware'
    '001C14' = 'VMware';            '080027' = 'VirtualBox';       '00155D' = 'Microsoft Hyper-V'
    'B827EB' = 'Raspberry Pi';      'DCA632' = 'Raspberry Pi';     'E45F01' = 'Raspberry Pi'
    'D83ADD' = 'Raspberry Pi';      '2CCF67' = 'Raspberry Pi';     '28CDC1' = 'Raspberry Pi'
    '00090F' = 'Fortinet';          '000C42' = 'MikroTik';         '001132' = 'Synology'
    '008077' = 'Brother';           '00000C' = 'Cisco';            '000E58' = 'Sonos'
    '5CAAFD' = 'Sonos';             '24A43C' = 'Ubiquiti';         '788A20' = 'Ubiquiti'
    'F09FC2' = 'Ubiquiti';          'FCECDA' = 'Ubiquiti';         '802AA8' = 'Ubiquiti'
    '44D9E7' = 'Ubiquiti';          '240AC4' = 'Espressif (IoT)';  '30AEA4' = 'Espressif (IoT)'
    'A4CF12' = 'Espressif (IoT)';   '3C5AB4' = 'Google';           'F4F5D8' = 'Google'
    '000393' = 'Apple';             '000A95' = 'Apple';            '0016CB' = 'Apple'
}
$script:OuiFileLoaded = $false

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function ConvertTo-UInt32 {
    param([System.Net.IPAddress]$Address)
    $b = $Address.GetAddressBytes()
    return [uint32](([uint64]$b[0] -shl 24) + ([uint64]$b[1] -shl 16) + ([uint64]$b[2] -shl 8) + [uint64]$b[3])
}

function ConvertFrom-UInt32 {
    param([uint32]$Value)
    $v = [uint64]$Value
    return ("{0}.{1}.{2}.{3}" -f (($v -shr 24) -band 255), (($v -shr 16) -band 255), (($v -shr 8) -band 255), ($v -band 255))
}

function Get-PrefixFromMask {
    param([System.Net.IPAddress]$Mask)
    if ($null -eq $Mask) { return $null }
    $bits = 0
    foreach ($b in $Mask.GetAddressBytes()) {
        $v = [int]$b
        while ($v -gt 0) { $bits += ($v -band 1); $v = $v -shr 1 }
    }
    return $bits
}

function Get-Network {
    # "192.168.1.77/24" -> @{ Network; Prefix; First; Last; Count }
    param([string]$Address, [int]$Prefix)
    $ip = ConvertTo-UInt32 ([System.Net.IPAddress]::Parse($Address))
    # Note: 0xFFFFFFFF is -1 in PowerShell, so we use 4294967295.
    $all = [uint64]4294967295
    $mask = [uint64]0
    if ($Prefix -gt 0) { $mask = ($all -shl (32 - $Prefix)) -band $all }
    $net = [uint64]$ip -band $mask
    $broadcast = $net + ($all - $mask)
    $first = $net + 1
    $last = $broadcast - 1
    if ($Prefix -ge 31) { $first = $net; $last = $broadcast }   # /31 and /32 have no network/broadcast address
    return @{
        Network   = ConvertFrom-UInt32 $net
        Prefix    = $Prefix
        First     = [uint32]$first
        Last      = [uint32]$last
        Count     = [int64]$last - [int64]$first + 1
        Label     = ("{0}/{1}" -f (ConvertFrom-UInt32 $net), $Prefix)
        IsRange   = $false
    }
}

function Get-Range {
    # Parses "192.168.1.100-192.168.1.200", "192.168.1.100-200" or "192.168.1.50".
    # Returns the same kind of object as Get-Network, or $null when the text is no range.
    param([string]$Text)

    $startText = ''
    $endText = ''
    if ($Text -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*-\s*(\d{1,3}(?:\.\d{1,3}){3})\s*$') {
        $startText = $Matches[1]; $endText = $Matches[2]
    } elseif ($Text -match '^\s*((\d{1,3}\.\d{1,3}\.\d{1,3}\.)(\d{1,3}))\s*-\s*(\d{1,3})\s*$') {
        $startText = $Matches[1]; $endText = $Matches[2] + $Matches[4]
    } elseif ($Text -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*$') {
        $startText = $Matches[1]; $endText = $Matches[1]
    } else {
        return $null
    }

    $a = $null
    $b = $null
    if (-not [System.Net.IPAddress]::TryParse($startText, [ref]$a)) { throw "'$startText' is not a valid IPv4 address." }
    if (-not [System.Net.IPAddress]::TryParse($endText, [ref]$b)) { throw "'$endText' is not a valid IPv4 address." }
    foreach ($octet in ($startText.Split('.') + $endText.Split('.'))) {
        if ([int]$octet -gt 255) { throw "'$Text' contains a number above 255." }
    }
    $first = ConvertTo-UInt32 $a
    $last = ConvertTo-UInt32 $b
    if ($last -lt $first) { throw "The range must go from low to high: $endText is lower than $startText." }

    $label = ("{0} - {1}" -f $startText, $endText)
    if ($first -eq $last) { $label = $startText }
    return @{
        Network = $startText
        Prefix  = $null
        First   = [uint32]$first
        Last    = [uint32]$last
        Count   = [int64]$last - [int64]$first + 1
        Label   = $label
        IsRange = $true
    }
}

function Get-LocalInfo {
    # Own IPv4 address, prefix, MAC and gateway, of the adapter with the default route.
    $info = @{ Address = ''; Prefix = 24; Mac = ''; Gateway = '' }
    $socket = $null
    try {
        $socket = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        $socket.Connect([System.Net.IPAddress]::Parse('8.8.8.8'), 53)
        $info.Address = $socket.LocalEndPoint.Address.ToString()
    } catch { } finally { if ($socket) { $socket.Dispose() } }
    if (-not $info.Address) { return $info }

    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        try { $props = $nic.GetIPProperties() } catch { continue }
        foreach ($u in $props.UnicastAddresses) {
            if ($u.Address.ToString() -ne $info.Address) { continue }
            $prefix = $null
            try { $prefix = [int]$u.PrefixLength } catch { }
            if (-not $prefix) { try { $prefix = Get-PrefixFromMask $u.IPv4Mask } catch { } }
            if ($prefix) { $info.Prefix = $prefix }
            try { $info.Mac = Format-Mac $nic.GetPhysicalAddress().ToString() } catch { }
            $gw = @($props.GatewayAddresses | ForEach-Object { $_.Address } |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $_.ToString() -ne '0.0.0.0' })
            if ($gw.Count -gt 0) { $info.Gateway = $gw[0].ToString() }
        }
    }
    return $info
}

function Format-Mac {
    param([string]$Raw)
    $hex = ($Raw -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($hex.Length -ne 12) { return '' }
    return (($hex -split '(..)' | Where-Object { $_ }) -join '-')
}

function Test-RandomMac {
    # The second hex digit 2, 6, A or E means a locally administered address:
    # phones and laptops use these as a privacy feature.
    param([string]$Mac)
    if ($Mac.Length -lt 2) { return $false }
    return ('26AE'.IndexOf($Mac.Substring(1, 1)) -ge 0)
}

function Import-OuiFile {
    # Optional complete vendor list: oui.txt from the IEEE, in this folder.
    if ($script:OuiFileLoaded) { return }
    $script:OuiFileLoaded = $true
    $path = Join-Path $PSScriptRoot 'oui.txt'
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        foreach ($line in [System.IO.File]::ReadLines($path)) {
            if ($line -match '^([0-9A-F]{2})-([0-9A-F]{2})-([0-9A-F]{2})\s+\(hex\)\s+(.+)$') {
                $script:Vendors[$Matches[1] + $Matches[2] + $Matches[3]] = $Matches[4].Trim()
            }
        }
    } catch { }
}

function Get-Vendor {
    param([string]$Mac)
    if (-not $Mac) { return '' }
    if (Test-RandomMac $Mac) { return 'random MAC' }
    $key = ($Mac -replace '-', '').Substring(0, 6)
    if ($script:Vendors.ContainsKey($key)) { return $script:Vendors[$key] }
    return ''
}

function Get-OsGuess {
    # Every OS starts with its own TTL; each router on the way lowers it by 1.
    param($Ttl)
    if ($null -eq $Ttl -or $Ttl -le 0) { return '' }
    if ($Ttl -le 64) { return 'Linux, Android or Apple' }
    if ($Ttl -le 128) { return 'Windows' }
    return 'network device'
}

function Get-TypeGuess {
    param($Device, [string]$Gateway, [string]$Self)
    if ($Device.IP -eq $Self) { return 'This computer' }
    if ($Device.IP -eq $Gateway) { return 'Router (gateway)' }

    $name = ([string]$Device.Name).ToLowerInvariant()
    $rules = [ordered]@{
        'Printer?'          = 'print|prn|epson|brother|canon|laserjet|officejet|kyocera|ricoh|xerox'
        'Smartphone?'       = 'iphone|android|galaxy|pixel|redmi|oneplus|huawei-p|phone'
        'Tablet?'           = 'ipad|tab-|tablet'
        'Access point?'     = 'unifi|uap|-ap\d|^ap-|accesspoint'
        'Switch?'           = 'switch|^sw-|-sw\d'
        'NAS?'              = 'nas|synology|diskstation|qnap'
        'TV or media?'      = 'tv|chromecast|sonos|roku|appletv|firetv'
        'Laptop or PC?'     = 'desktop-|laptop-|pc-|macbook|imac'
    }
    foreach ($guess in $rules.Keys) {
        if ($name -and $name -match $rules[$guess]) { return $guess }
    }

    switch -Regex ([string]$Device.Vendor) {
        'VMware|VirtualBox|Hyper-V' { return 'Virtual machine' }
        'Raspberry'                 { return 'Raspberry Pi' }
        'Ubiquiti'                  { return 'Access point or switch?' }
        'Brother'                   { return 'Printer?' }
        'Synology'                  { return 'NAS?' }
        'Sonos'                     { return 'Speaker?' }
        'Espressif'                 { return 'IoT device?' }
        'Cisco|MikroTik|Fortinet'   { return 'Network device?' }
        'Google'                    { return 'Chromecast or Nest?' }
        'Apple'                     { return 'Apple device?' }
        'random MAC'                { return 'Phone or laptop?' }
    }

    $os = Get-OsGuess $Device.Ttl
    if ($os -eq 'Windows') { return 'Windows computer?' }
    if ($os -eq 'network device') { return 'Network device?' }
    if ($os) { return 'Phone, Mac or Linux?' }
    return ''
}

# ----------------------------------------------------------------------------
# Data collection
# ----------------------------------------------------------------------------

function Invoke-PingSweep {
    # Pings all addresses in parallel batches. Returns a hashtable ip -> TTL (or 0).
    param([uint32]$First, [uint32]$Last, [int]$Timeout)

    $alive = @{}
    $total = [int64]$Last - [int64]$First + 1
    $done = 0
    $current = [int64]$First
    while ($current -le $Last) {
        $batchEnd = [math]::Min([int64]$Last, $current + $script:BatchSize - 1)
        $jobs = @()
        for ($n = $current; $n -le $batchEnd; $n++) {
            $ip = ConvertFrom-UInt32 ([uint32]$n)
            $ping = New-Object System.Net.NetworkInformation.Ping
            try {
                $jobs += @{ IP = $ip; Ping = $ping; Task = $ping.SendPingAsync($ip, $Timeout) }
            } catch {
                $ping.Dispose()
            }
        }
        $tasks = [System.Threading.Tasks.Task[]]@($jobs | ForEach-Object { $_.Task })
        try { [void][System.Threading.Tasks.Task]::WaitAll($tasks, $Timeout + 3000) } catch { }
        foreach ($job in $jobs) {
            try {
                if ($job.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                    $reply = $job.Task.Result
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $ttl = 0
                        try { if ($reply.Options) { $ttl = [int]$reply.Options.Ttl } } catch { }
                        $alive[$job.IP] = $ttl
                    }
                }
            } catch { }
            $job.Ping.Dispose()
        }
        $done += $jobs.Count
        Write-Progress -Activity 'NetRing scan' -Status ("Ping {0} of {1}" -f $done, $total) -PercentComplete ([int]($done * 100 / [math]::Max(1, $total)))
        $current = $batchEnd + 1
    }
    Write-Progress -Activity 'NetRing scan' -Completed
    return $alive
}

function Get-ArpTable {
    # Returns a hashtable ip -> MAC, from Get-NetNeighbor (Windows) or /proc/net/arp (Linux).
    $table = @{}
    if (Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue) {
        try {
            foreach ($n in (Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop)) {
                $state = [string]$n.State
                if ($state -in @('Unreachable', 'Incomplete')) { continue }
                $mac = Format-Mac ([string]$n.LinkLayerAddress)
                if (-not $mac -or $mac -eq '00-00-00-00-00-00' -or $mac -eq 'FF-FF-FF-FF-FF-FF') { continue }
                $table[[string]$n.IPAddress] = $mac
            }
        } catch { }
        return $table
    }
    if (Test-Path -LiteralPath '/proc/net/arp') {
        try {
            foreach ($line in (Get-Content -LiteralPath '/proc/net/arp' | Select-Object -Skip 1)) {
                $parts = @($line -split '\s+' | Where-Object { $_ })
                if ($parts.Count -lt 4 -or $parts[2] -eq '0x0') { continue }
                $mac = Format-Mac $parts[3]
                if ($mac -and $mac -ne '00-00-00-00-00-00') { $table[$parts[0]] = $mac }
            }
        } catch { }
    }
    return $table
}

function Resolve-Names {
    # Reverse DNS for many addresses at once. Returns a hashtable ip -> name.
    param([string[]]$Addresses)
    $names = @{}
    $jobs = @()
    foreach ($ip in $Addresses) {
        try { $jobs += @{ IP = $ip; Task = [System.Net.Dns]::GetHostEntryAsync([System.Net.IPAddress]::Parse($ip)) } } catch { }
    }
    if ($jobs.Count -eq 0) { return $names }
    $tasks = [System.Threading.Tasks.Task[]]@($jobs | ForEach-Object { $_.Task })
    try { [void][System.Threading.Tasks.Task]::WaitAll($tasks, 3000) } catch { }
    foreach ($job in $jobs) {
        try {
            if ($job.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                $name = [string]$job.Task.Result.HostName
                if ($name -and $name -ne $job.IP) { $names[$job.IP] = $name }
            }
        } catch { }
    }
    return $names
}

# --- extra name sources: NetBIOS (UDP 137) and mDNS (UDP 5353) ------------------
# Reverse DNS only works when the router puts its DHCP clients in DNS, which
# most home and lab routers do not. Devices often tell their name themselves:
# Windows PCs, NAS and printers via NetBIOS, Apple, Android, Chromecast and
# printers via mDNS.

function Send-UdpQueries {
    # Sends one packet to every address and collects the first answer of each.
    # Packets: hashtable ip -> byte[] ; returns hashtable ip -> byte[]
    param([hashtable]$Packets, [int]$Port, [int]$WaitMs = 1500)

    $answers = @{}
    if ($Packets.Count -eq 0) { return $answers }
    $udp = New-Object System.Net.Sockets.UdpClient(0)
    try {
        foreach ($ip in $Packets.Keys) {
            try {
                $bytes = $Packets[$ip]
                $target = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($ip), $Port)
                [void]$udp.Send($bytes, $bytes.Length, $target)
            } catch { }
        }
        $deadline = (Get-Date).AddMilliseconds($WaitMs)
        while ((Get-Date) -lt $deadline -and $answers.Count -lt $Packets.Count) {
            if ($udp.Available -le 0) { Start-Sleep -Milliseconds 20; continue }
            $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            try { $data = $udp.Receive([ref]$remote) } catch { continue }
            $from = $remote.Address.ToString()
            if ($Packets.ContainsKey($from) -and -not $answers.ContainsKey($from)) { $answers[$from] = $data }
        }
    } finally {
        $udp.Dispose()
    }
    return $answers
}

function New-NbstatQuery {
    # NetBIOS "node status" question for the name "*": who are you?
    $packet = New-Object System.Collections.Generic.List[byte]
    foreach ($b in @(0x13, 0x37, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)) { $packet.Add([byte]$b) }
    $packet.Add(0x20)
    $packet.AddRange([System.Text.Encoding]::ASCII.GetBytes('CK' + ('A' * 30)))   # "*" padded, NetBIOS encoded
    foreach ($b in @(0x00, 0x00, 0x21, 0x00, 0x01)) { $packet.Add([byte]$b) }     # end, type NBSTAT, class IN
    return , $packet.ToArray()
}

function Read-NbstatName {
    # Returns the computer name from a node status answer, or ''.
    param([byte[]]$Data)
    try {
        $pos = 12 + 34 + 10           # header, name, type/class/ttl/length
        if ($Data.Length -le $pos) { return '' }
        $count = [int]$Data[$pos]
        $pos++
        for ($i = 0; $i -lt $count; $i++) {
            if ($pos + 18 -gt $Data.Length) { break }
            $name = [System.Text.Encoding]::ASCII.GetString($Data, $pos, 15).Trim()
            $suffix = [int]$Data[$pos + 15]
            $isGroup = ([int]$Data[$pos + 16] -band 0x80) -ne 0
            if ($suffix -eq 0 -and -not $isGroup -and $name) { return $name }
            $pos += 18
        }
    } catch { }
    return ''
}

function Read-MdnsLabelName {
    # Reads a (compressed) DNS name; mDNS names may contain UTF-8.
    param([byte[]]$Data, [int]$Offset)
    $labels = @()
    $pos = $Offset
    $next = -1
    $jumps = 0
    while ($true) {
        if ($pos -ge $Data.Length) { throw 'damaged answer' }
        $len = [int]$Data[$pos]
        if ($len -eq 0) { $pos++; break }
        if (($len -band 0xC0) -eq 0xC0) {
            if ($next -lt 0) { $next = $pos + 2 }
            $pos = (($len -band 0x3F) -shl 8) -bor [int]$Data[$pos + 1]
            $jumps++
            if ($jumps -gt 30) { throw 'damaged answer' }
            continue
        }
        $labels += [System.Text.Encoding]::UTF8.GetString($Data, $pos + 1, $len)
        $pos += 1 + $len
    }
    if ($next -lt 0) { $next = $pos }
    return @{ Name = ($labels -join '.'); Next = $next }
}

function New-MdnsReverseQuery {
    # mDNS question "which name has 192.168.1.31?" (PTR 31.1.168.192.in-addr.arpa)
    param([string]$Address)
    $parts = $Address.Split('.')
    [array]::Reverse($parts)
    $packet = New-Object System.Collections.Generic.List[byte]
    foreach ($b in @(0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)) { $packet.Add([byte]$b) }
    foreach ($label in ($parts + @('in-addr', 'arpa'))) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($label)
        $packet.Add([byte]$bytes.Length)
        $packet.AddRange($bytes)
    }
    foreach ($b in @(0x00, 0x00, 0x0C, 0x80, 0x01)) { $packet.Add([byte]$b) }   # end, type PTR, class IN + unicast reply
    return , $packet.ToArray()
}

function Read-MdnsName {
    # Returns the PTR name from an mDNS answer, or ''.
    param([byte[]]$Data)
    try {
        if ($Data.Length -lt 12) { return '' }
        $qd = ([int]$Data[4] -shl 8) -bor [int]$Data[5]
        $an = ([int]$Data[6] -shl 8) -bor [int]$Data[7]
        $pos = 12
        for ($i = 0; $i -lt $qd; $i++) { $pos = (Read-MdnsLabelName $Data $pos).Next + 4 }
        for ($i = 0; $i -lt $an; $i++) {
            $pos = (Read-MdnsLabelName $Data $pos).Next
            $type = ([int]$Data[$pos] -shl 8) -bor [int]$Data[$pos + 1]
            $rdLength = ([int]$Data[$pos + 8] -shl 8) -bor [int]$Data[$pos + 9]
            if ($type -eq 12) { return (Read-MdnsLabelName $Data ($pos + 10)).Name.TrimEnd('.') }
            $pos += 10 + $rdLength
        }
    } catch { }
    return ''
}

function Find-DeviceNames {
    # Tries DNS, then NetBIOS, then mDNS. Returns @{ Names = ip -> name; Source = ip -> 'DNS'|'NetBIOS'|'mDNS' }
    param([string[]]$Addresses)

    $result = @{ Names = @{}; Source = @{} }
    $dns = Resolve-Names -Addresses $Addresses
    foreach ($ip in $dns.Keys) { $result.Names[$ip] = $dns[$ip]; $result.Source[$ip] = 'DNS' }

    $left = @($Addresses | Where-Object { -not $result.Names.ContainsKey($_) })
    if ($left.Count -gt 0) {
        $packets = @{}
        $query = New-NbstatQuery
        foreach ($ip in $left) { $packets[$ip] = $query }
        $answers = Send-UdpQueries -Packets $packets -Port 137 -WaitMs 1500
        foreach ($ip in $answers.Keys) {
            $name = Read-NbstatName $answers[$ip]
            if ($name) { $result.Names[$ip] = $name; $result.Source[$ip] = 'NetBIOS' }
        }
    }

    $left = @($Addresses | Where-Object { -not $result.Names.ContainsKey($_) })
    if ($left.Count -gt 0) {
        $packets = @{}
        foreach ($ip in $left) { $packets[$ip] = New-MdnsReverseQuery $ip }
        $answers = Send-UdpQueries -Packets $packets -Port 5353 -WaitMs 1500
        foreach ($ip in $answers.Keys) {
            $name = Read-MdnsName $answers[$ip]
            if ($name) { $result.Names[$ip] = $name; $result.Source[$ip] = 'mDNS' }
        }
    }
    return $result
}

# ----------------------------------------------------------------------------
# Rendering
# ----------------------------------------------------------------------------

function Format-Cell {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -ge $Width) { return $Text.Substring(0, $Width - 3) + '.. ' }
    return $Text.PadRight($Width)
}

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return ("about {0:0} seconds" -f [math]::Max(1, $Seconds)) }
    return ("about {0:0.#} minutes" -f ($Seconds / 60))
}

function Get-ScanEstimate {
    # Each batch waits at most the timeout, plus a little overhead.
    param([int64]$Count, [int]$Timeout)
    $batches = [math]::Ceiling($Count / $script:BatchSize)
    return $batches * ($Timeout / 1000.0 + 0.1)
}

function Confirm-Scan {
    param([string]$Question)
    Write-Host ("      {0} (y/N): " -f $Question) -ForegroundColor $script:Theme.Text -NoNewline
    $answer = Read-Host
    return ($null -ne $answer -and $answer.Trim().ToLowerInvariant() -in @('y', 'yes', 'j', 'ja'))
}

function Write-ScanWarning {
    $s = $script:Sym
    Write-Host ''
    Write-Host '  [!] Only scan networks you own or have permission for:' -ForegroundColor $script:Theme.Warn
    Write-Host '      your home network, your own lab. Scanning other networks' -ForegroundColor $script:Theme.Warn
    Write-Host '      (school, work, public wifi) without permission can be illegal.' -ForegroundColor $script:Theme.Warn
}

function Write-DeviceRow {
    param($Device, [bool]$Last)
    $s = $script:Sym
    $branch = $s.Tee
    if ($Last) { $branch = $s.End }

    $mark = $s.Ping
    $markColor = $script:Theme.Ok
    if (-not $Device.Pinged) { $mark = $s.Arp; $markColor = $script:Theme.Muted }
    if ($Device.Type -eq 'This computer') { $mark = $s.Self; $markColor = $script:Theme.Key }

    Write-Host ("    {0}{1}" -f $branch, $s.H) -ForegroundColor $script:Theme.Title -NoNewline
    Write-Host ("{0} " -f $mark) -ForegroundColor $markColor -NoNewline
    Write-Host (Format-Cell $Device.IP 16) -ForegroundColor $script:Theme.Key -NoNewline
    $name = $Device.Name
    if (-not $name) { $name = '-' }
    Write-Host (Format-Cell $name 24) -ForegroundColor $script:Theme.Text -NoNewline
    $mac = $Device.Mac
    if (-not $mac) { $mac = '-' }
    Write-Host (Format-Cell $mac 19) -ForegroundColor $script:Theme.Muted -NoNewline
    $vendor = $Device.Vendor
    $vendorColor = $script:Theme.Muted
    if ($vendor -eq 'random MAC') { $vendorColor = $script:Theme.Dim }
    if (-not $vendor) { $vendor = '-'; $vendorColor = $script:Theme.Dim }
    Write-Host (Format-Cell $vendor 17) -ForegroundColor $vendorColor -NoNewline
    $type = $Device.Type
    $typeColor = $script:Theme.Text
    if (-not $type) { $type = '?'; $typeColor = $script:Theme.Dim }
    if ($Device.Type -like 'Router*' -or $Device.Type -eq 'This computer') { $typeColor = $script:Theme.Key }
    Write-Host (Format-Cell $type 24) -ForegroundColor $typeColor -NoNewline
    $ttlText = ''
    if ($Device.Ttl -gt 0) { $ttlText = "TTL $($Device.Ttl)" }
    Write-Host $ttlText -ForegroundColor $script:Theme.Dim
}

# ----------------------------------------------------------------------------
# Exported tool
# ----------------------------------------------------------------------------

function Invoke-NRNetScan {
    <#
    .SYNOPSIS
        Who is on my network? Ping sweep plus ARP table, vendor and hostname.
    .EXAMPLE
        Invoke-NRNetScan -Subnet 192.168.56.0/24
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Subnet = 'auto',

        [Parameter(Position = 1)]
        [ValidateRange(100, 5000)]
        [int]$Timeout = 500,

        [Parameter(Position = 2)]
        [ValidateSet('on', 'off')]
        [string]$Resolve = 'on',

        [Parameter(Position = 3)]
        [ValidateSet('on', 'off')]
        [string]$Ask = 'on'
    )

    $s = $script:Sym
    $local = Get-LocalInfo

    # --- which network? ---------------------------------------------------
    $note = ''
    if (-not $Subnet -or $Subnet -eq 'auto') {
        if (-not $local.Address) { throw 'Could not find your own IP address. Give a subnet, e.g. scan 192.168.1.0/24' }
        $prefix = [int]$local.Prefix
        if ($prefix -lt $script:MinPrefix) {
            $note = ("Your network is /{0}, too big to scan (max /{1}): only your own /24 is scanned." -f $prefix, $script:MinPrefix)
            $prefix = 24
        }
        $net = Get-Network -Address $local.Address -Prefix $prefix
    } elseif ($Subnet -notmatch '/') {
        $net = Get-Range -Text $Subnet
        if ($null -eq $net) {
            throw "Use a subnet (192.168.1.0/24), a range (192.168.1.100-192.168.1.200 or 192.168.1.100-200) or one address."
        }
        if ($net.Count -gt $script:MaxAddresses) {
            throw ("This range has {0} addresses; the maximum is {1}." -f $net.Count, $script:MaxAddresses)
        }
    } else {
        if ($Subnet -notmatch '^(\d{1,3}(\.\d{1,3}){3})/(\d{1,2})$') { throw "Use CIDR notation, for example 192.168.1.0/24" }
        $address = $Matches[1]
        $prefix = [int]$Matches[3]
        $check = $null
        if (-not [System.Net.IPAddress]::TryParse($address, [ref]$check)) { throw "'$address' is not a valid IPv4 address." }
        if ($prefix -lt $script:MinPrefix -or $prefix -gt 30) {
            throw ("Choose a prefix between /{0} and /30 (at most {1} addresses)." -f $script:MinPrefix, ([math]::Pow(2, 32 - $script:MinPrefix) - 2))
        }
        $net = Get-Network -Address $address -Prefix $prefix
    }

    Write-Host ''
    Write-Host '  Who is on my network?' -ForegroundColor $script:Theme.Key
    Write-Host ("  {0}" -f ($s.H * 21)) -ForegroundColor $script:Theme.Title
    if (-not $net.IsRange) {
        Write-Host ("  Network   {0}   {1} {2} {3}   {4} addresses" -f $net.Label, (ConvertFrom-UInt32 $net.First), [string][char]0x2192, (ConvertFrom-UInt32 $net.Last), $net.Count) -ForegroundColor $script:Theme.Text
    } elseif ($net.Count -eq 1) {
        Write-Host ("  Address   {0}" -f $net.Label) -ForegroundColor $script:Theme.Text
    } else {
        Write-Host ("  Range     {0}   {1} addresses" -f $net.Label, $net.Count) -ForegroundColor $script:Theme.Text
    }
    if ($local.Address) { Write-Host ("  You       {0}   gateway {1}" -f $local.Address, $(if ($local.Gateway) { $local.Gateway } else { '-' })) -ForegroundColor $script:Theme.Muted }
    if ($note) { Write-Host ("  {0}" -f $note) -ForegroundColor $script:Theme.Warn }

    # ARP only works inside your own subnet: say so when (part of) the scan is outside it.
    if ($local.Address) {
        $own = Get-Network -Address $local.Address -Prefix ([int]$local.Prefix)
        $ownFirst = [uint64]$own.First - 1
        $ownLast = [uint64]$own.Last + 1
        if ([uint64]$net.First -lt $ownFirst -or [uint64]$net.Last -gt $ownLast) {
            Write-Host ("  [i] (Part of) this scan is outside your own subnet {0}." -f $own.Label) -ForegroundColor $script:Theme.Muted
            Write-Host '      There ARP does not work (it stops at the router), so only devices that' -ForegroundColor $script:Theme.Dim
            Write-Host '      answer ping are found, without MAC address or vendor.' -ForegroundColor $script:Theme.Dim
        }
    }

    Write-ScanWarning
    if ($Ask -eq 'on' -and -not (Confirm-Scan 'Scan this network?')) {
        Write-Host '  Cancelled.' -ForegroundColor $script:Theme.Dim
        Write-Host ''
        return
    }

    # Large networks: show what it costs and ask again.
    if ($net.Count -gt $script:SafeCount) {
        $estimate = Get-ScanEstimate -Count $net.Count -Timeout $Timeout
        Write-Host ''
        Write-Host ("  [!] Large scan: {0} has {1} addresses. Expected time: {2}." -f $net.Label, $net.Count, (Format-Duration $estimate)) -ForegroundColor $script:Theme.Fire
        Write-Host '      Thousands of pings can trigger alarms in firewalls or intrusion detection,' -ForegroundColor $script:Theme.Warn
        Write-Host '      and large networks are almost never your own. Tip: a lower -Timeout is faster.' -ForegroundColor $script:Theme.Warn
        if ($Ask -eq 'on' -and -not (Confirm-Scan 'Are you sure you want to scan this large network?')) {
            Write-Host '  Cancelled.' -ForegroundColor $script:Theme.Dim
            Write-Host ''
            return
        }
    }

    # --- 1. ping sweep --------------------------------------------------------
    Write-Host ''
    Write-Host ("  [1] Ping {0} addresses ({1} ms timeout)..." -f $net.Count, $Timeout) -ForegroundColor $script:Theme.Muted
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $alive = Invoke-PingSweep -First $net.First -Last $net.Last -Timeout $Timeout

    # --- 2. ARP table ------------------------------------------------------------
    Write-Host '  [2] Read the ARP table (IP address -> MAC address)...' -ForegroundColor $script:Theme.Muted
    $arp = Get-ArpTable

    # Collect every address in the subnet that answered ping or is in the ARP table.
    $devices = @{}
    foreach ($ip in $alive.Keys) {
        $devices[$ip] = [pscustomobject]@{ IP = $ip; Pinged = $true; Ttl = $alive[$ip]; Mac = ''; Vendor = ''; Name = ''; Type = '' }
    }
    foreach ($ip in $arp.Keys) {
        $value = ConvertTo-UInt32 ([System.Net.IPAddress]::Parse($ip))
        if ($value -lt $net.First -or $value -gt $net.Last) { continue }
        if (-not $devices.ContainsKey($ip)) {
            $devices[$ip] = [pscustomobject]@{ IP = $ip; Pinged = $false; Ttl = 0; Mac = ''; Vendor = ''; Name = ''; Type = '' }
        }
        $devices[$ip].Mac = $arp[$ip]
    }
    if ($local.Address -and $devices.ContainsKey($local.Address)) { $devices[$local.Address].Mac = $local.Mac }

    # --- 3. vendor and name --------------------------------------------------
    Write-Host '  [3] Look up vendors and names (reverse DNS, NetBIOS, mDNS)...' -ForegroundColor $script:Theme.Muted
    Import-OuiFile
    $found = @{ Names = @{}; Source = @{} }
    if ($Resolve -eq 'on' -and $devices.Count -gt 0) { $found = Find-DeviceNames -Addresses @($devices.Keys) }
    if ($local.Address -and $devices.ContainsKey($local.Address) -and -not $found.Names.ContainsKey($local.Address)) {
        $found.Names[$local.Address] = [System.Net.Dns]::GetHostName()
        $found.Source[$local.Address] = 'this computer'
    }
    foreach ($d in $devices.Values) {
        $d.Vendor = Get-Vendor $d.Mac
        if ($found.Names.ContainsKey($d.IP)) { $d.Name = $found.Names[$d.IP] }
        $d.Type = Get-TypeGuess -Device $d -Gateway $local.Gateway -Self $local.Address
    }
    $watch.Stop()

    # --- the map ------------------------------------------------------------------
    $ordered = @($devices.Values | Sort-Object @{ Expression = { if ($_.Type -like 'Router*') { 0 } elseif ($_.Type -eq 'This computer') { 1 } else { 2 } } },
        @{ Expression = { ConvertTo-UInt32 ([System.Net.IPAddress]::Parse($_.IP)) } })

    Write-Host ''
    Write-Host ("  {0}  {1} device(s) found in {2:0.0} s" -f $net.Label, $ordered.Count, $watch.Elapsed.TotalSeconds) -ForegroundColor $script:Theme.Title
    Write-Host ("    {0}" -f $s.V) -ForegroundColor $script:Theme.Title
    Write-Host ("        {0}{1}{2}{3}{4}{5}" -f (Format-Cell 'IP address' 16), (Format-Cell 'Name' 24), (Format-Cell 'MAC' 19), (Format-Cell 'Vendor' 17), (Format-Cell 'Guess' 24), 'TTL') -ForegroundColor $script:Theme.Dim
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        Write-DeviceRow -Device $ordered[$i] -Last ($i -eq $ordered.Count - 1)
    }
    if ($ordered.Count -eq 0) {
        Write-Host ("    {0}{1} nothing found" -f $s.End, $s.H) -ForegroundColor $script:Theme.Dim
    }

    # --- summary ---------------------------------------------------------------
    $pinged = @($ordered | Where-Object { $_.Pinged }).Count
    $arpOnly = $ordered.Count - $pinged
    $random = @($ordered | Where-Object { $_.Vendor -eq 'random MAC' }).Count
    Write-Host ''
    Write-Host ("  {0} answered ping   {1} only in the ARP table   {2} this computer" -f $s.Ping, $s.Arp, $s.Self) -ForegroundColor $script:Theme.Dim
    Write-Host ("  {0} answered ping, {1} only visible via ARP." -f $pinged, $arpOnly) -ForegroundColor $script:Theme.Muted
    if ($Resolve -eq 'on') {
        $bySource = @{ 'DNS' = 0; 'NetBIOS' = 0; 'mDNS' = 0 }
        foreach ($src in $found.Source.Values) { if ($bySource.ContainsKey($src)) { $bySource[$src]++ } }
        $nameless = @($ordered | Where-Object { -not $_.Name }).Count
        Write-Host ("  Names: {0} via reverse DNS, {1} via NetBIOS, {2} via mDNS, {3} without a name." -f $bySource['DNS'], $bySource['NetBIOS'], $bySource['mDNS'], $nameless) -ForegroundColor $script:Theme.Muted
    }
    if ($arpOnly -gt 0) {
        Write-Host '  Devices that block ping still answer ARP: on your own subnet you cannot hide.' -ForegroundColor $script:Theme.Dim
    }
    if ($random -gt 0) {
        Write-Host ("  {0} device(s) use a random MAC address: phones and laptops do this for privacy," -f $random) -ForegroundColor $script:Theme.Dim
        Write-Host '  so the vendor cannot be read from it.' -ForegroundColor $script:Theme.Dim
    }
    Write-Host '  Guess = a rough guess from gateway, name, vendor and TTL (64 Linux/Apple, 128 Windows, 255 network).' -ForegroundColor $script:Theme.Dim
    Write-Host ''
}

Export-ModuleMember -Function 'Invoke-NRNetScan'
