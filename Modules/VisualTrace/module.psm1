# NetRing module: VisualTrace
# A traceroute that draws the path hop by hop, with latency bars,
# network zones (LAN, CGNAT, public internet) and a compact path map.
#
# Works on Windows PowerShell 5.1 and PowerShell 7. Uses .NET Ping with an
# increasing TTL, exactly like tracert does with ICMP.
# This file only contains ASCII characters: symbols are built with [char].

Set-StrictMode -Version 2.0

$script:Sym = @{
    V     = [string][char]0x2502   # vertical line
    Tee   = [string][char]0x251C   # branch
    H     = [string][char]0x2500   # horizontal line
    Dash  = [string][char]0x2506   # dashed vertical line
    Node  = [string][char]0x25CF   # filled circle: hop answered
    Miss  = [string][char]0x25CB   # open circle: no answer
    Full  = [string][char]0x2588   # full block
    Light = [string][char]0x2591   # light shade
    Down  = [string][char]0x25BC   # arrow down
    Right = [string][char]0x25BA   # arrow right
    Up    = [string][char]0x25B2   # arrow up
}

# Color theme, inspired by the One Ring: gold, dark gold and the fire of
# Mount Doom. Latency runs from gold (fast) over amber to fire (slow).
$script:Theme = @{
    Line     = 'DarkYellow'   # the golden thread of the path
    Text     = 'White'
    Muted    = 'Gray'
    Dim      = 'DarkGray'     # silent hops, hints
    Gold     = 'DarkYellow'   # real gold in Windows Terminal
    Warn     = 'Yellow'
    Fire     = 'Red'
    Fast     = 'Yellow'       # < 30 ms (pale gold)
    Medium   = 'DarkYellow'   # 30 - 99 ms (gold)
    Slow     = 'Red'          # >= 100 ms
}

$script:ZoneColor = @{
    'LAN'       = 'White'
    'CGNAT'     = 'Gray'
    'PUBLIC'    = 'DarkYellow'
    'LOOPBACK'  = 'Gray'
    'LINKLOCAL' = 'Gray'
    '?'         = 'DarkGray'
}

$script:DnsCache = @{}
$script:MaxSilentHops = 6   # stop after this many hops in a row without any reply
$script:BarWidth = 20       # one block = 10 ms, so a full bar = 200 ms or more

# ----------------------------------------------------------------------------
# Helpers (not exported)
# ----------------------------------------------------------------------------

function Get-TraceZone {
    param([System.Net.IPAddress]$Address)

    if ($null -eq $Address) { return '?' }
    if ([System.Net.IPAddress]::IsLoopback($Address)) { return 'LOOPBACK' }

    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $b = $Address.GetAddressBytes()
        if ($b[0] -eq 10) { return 'LAN' }
        if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return 'LAN' }
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return 'LAN' }
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return 'LINKLOCAL' }
        if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return 'CGNAT' }   # carrier-grade NAT 100.64.0.0/10
        return 'PUBLIC'
    }

    if ($Address.IsIPv6LinkLocal) { return 'LINKLOCAL' }
    $first = $Address.GetAddressBytes()[0]
    if (($first -band 0xFE) -eq 0xFC) { return 'LAN' }   # unique local fc00::/7
    return 'PUBLIC'
}

function Resolve-TraceTarget {
    param([Parameter(Mandatory)][string]$Target)

    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($Target, [ref]$parsed)) { return $parsed }

    try {
        $all = [System.Net.Dns]::GetHostAddresses($Target)
    } catch {
        throw "Could not resolve '$Target'. Check the name and your DNS."
    }
    $v4 = $all | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
    if ($v4) { return $v4 }
    if ($all.Count -gt 0) { return $all[0] }
    throw "'$Target' has no IP address."
}

function Resolve-TraceName {
    param(
        [System.Net.IPAddress]$Address,
        [int]$TimeoutMs = 1500
    )

    if ($null -eq $Address) { return '' }
    $key = $Address.ToString()
    if ($script:DnsCache.ContainsKey($key)) { return $script:DnsCache[$key] }

    $name = ''
    try {
        $task = [System.Net.Dns]::GetHostEntryAsync($Address)
        if ($task.Wait($TimeoutMs)) { $name = [string]$task.Result.HostName }
    } catch {
        $name = ''
    }
    if ($name -eq $key) { $name = '' }   # no PTR record: Windows returns the IP itself
    $script:DnsCache[$key] = $name
    return $name
}

function Get-TraceLocalAddress {
    # Asks the OS which local address it would use to reach the target.
    # A UDP "connect" does not send any packet.
    param([Parameter(Mandatory)][System.Net.IPAddress]$Target)

    $socket = $null
    try {
        $socket = New-Object System.Net.Sockets.Socket($Target.AddressFamily, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        $socket.Connect($Target, 53)
        return $socket.LocalEndPoint.Address
    } catch {
        return $null
    } finally {
        if ($socket) { $socket.Dispose() }
    }
}

function Send-TraceProbe {
    param(
        [Parameter(Mandatory)][System.Net.NetworkInformation.Ping]$Ping,
        [Parameter(Mandatory)][System.Net.IPAddress]$Address,
        [Parameter(Mandatory)][int]$Ttl,
        [Parameter(Mandatory)][int]$Timeout,
        [Parameter(Mandatory)][byte[]]$Buffer
    )

    $options = New-Object System.Net.NetworkInformation.PingOptions($Ttl, $true)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $reply = $Ping.Send($Address, $Timeout, $Buffer, $options)
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        return [pscustomobject]@{ Status = 'Error'; Address = $null; Rtt = $null; Message = $msg }
    }
    $watch.Stop()

    $status = [string]$reply.Status
    $from = $null
    $rtt = $null
    if ($status -ne 'TimedOut' -and $reply.Address -and $reply.Address.ToString() -notin @('0.0.0.0', '::')) {
        $from = $reply.Address
        # .NET reports RoundtripTime 0 for "TTL expired" replies, so we time it ourselves.
        if ($status -eq 'Success' -and $reply.RoundtripTime -gt 0) { $rtt = [int]$reply.RoundtripTime }
        else { $rtt = [int]$watch.ElapsedMilliseconds }
    }
    return [pscustomobject]@{ Status = $status; Address = $from; Rtt = $rtt; Message = '' }
}

function Get-LatencyColor {
    param([double]$Ms)
    if ($Ms -lt 30) { return $script:Theme.Fast }
    if ($Ms -lt 100) { return $script:Theme.Medium }
    return $script:Theme.Slow
}

function Format-Fixed {
    # Pads or cuts a string to an exact width.
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    # Always keeps at least one space at the end as column separator.
    if ($Text.Length -ge $Width) { return $Text.Substring(0, $Width - 3) + '.. ' }
    return $Text.PadRight($Width)
}

# ----------------------------------------------------------------------------
# Rendering
# ----------------------------------------------------------------------------

function Write-TraceStart {
    param([string]$TargetLabel, [System.Net.IPAddress]$TargetIp, [System.Net.IPAddress]$LocalIp, [int]$MaxHops)

    $s = $script:Sym
    $local = '?'
    if ($LocalIp) { $local = $LocalIp.ToString() }

    Write-Host ''
    Write-Host '  Visual traceroute to ' -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $TargetLabel -ForegroundColor $script:Theme.Text -NoNewline
    if ($TargetLabel -ne $TargetIp.ToString()) { Write-Host (" [{0}]" -f $TargetIp) -ForegroundColor $script:Theme.Muted -NoNewline }
    Write-Host (", max {0} hops" -f $MaxHops) -ForegroundColor $script:Theme.Muted
    Write-Host ''
    Write-Host '   [ YOU ]  ' -ForegroundColor Black -BackgroundColor Yellow -NoNewline
    Write-Host ("  {0}  {1}" -f [System.Net.Dns]::GetHostName(), $local) -ForegroundColor $script:Theme.Text
    Write-Host ("    {0}" -f $s.V) -ForegroundColor $script:Theme.Line
}

function Write-TraceZoneChange {
    param([string]$From, [string]$To)
    $s = $script:Sym
    Write-Host ("    {0}   " -f $s.Dash) -ForegroundColor $script:Theme.Dim -NoNewline
    Write-Host ("{0}{0} {1} " -f $s.H, $From) -ForegroundColor $script:ZoneColor[$From] -NoNewline
    Write-Host ("{0} " -f $s.Right) -ForegroundColor $script:Theme.Dim -NoNewline
    Write-Host ("{0} {1}{1}" -f $To, $s.H) -ForegroundColor $script:ZoneColor[$To]
    Write-Host ("    {0}" -f $s.V) -ForegroundColor $script:Theme.Line
}

function Write-TraceHop {
    param(
        [Parameter(Mandatory)]$Hop,
        [Nullable[double]]$PreviousAvg
    )

    $s = $script:Sym
    Write-Host ("    {0}{1}" -f $s.Tee, $s.H) -ForegroundColor $script:Theme.Line -NoNewline

    if ($Hop.Received -eq 0) {
        Write-Host $s.Miss -ForegroundColor $script:Theme.Dim -NoNewline
        Write-Host (" {0,2}  " -f $Hop.Ttl) -ForegroundColor $script:Theme.Dim -NoNewline
        $reason = 'no reply (router hides itself or filters ICMP)'
        if ($Hop.Note) { $reason = $Hop.Note }
        Write-Host ("{0}{1}" -f (Format-Fixed '*' 17), $reason) -ForegroundColor $script:Theme.Dim
        Write-Host ("    {0}" -f $s.V) -ForegroundColor $script:Theme.Line
        return
    }

    $zoneColor = $script:ZoneColor[$Hop.Zone]
    Write-Host $s.Node -ForegroundColor $zoneColor -NoNewline
    Write-Host (" {0,2}  " -f $Hop.Ttl) -ForegroundColor $script:Theme.Text -NoNewline
    $ipText = $Hop.Address.ToString()
    Write-Host (Format-Fixed $ipText ([math]::Max(17, $ipText.Length + 2))) -ForegroundColor $script:Theme.Text -NoNewline
    Write-Host (Format-Fixed $Hop.HostName 30) -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host (Format-Fixed $Hop.Zone 8) -ForegroundColor $zoneColor -NoNewline

    $color = Get-LatencyColor $Hop.Avg
    Write-Host ("{0,5} ms " -f [math]::Round($Hop.Avg)) -ForegroundColor $color -NoNewline

    $filled = [int][math]::Min($script:BarWidth, [math]::Max(1, [math]::Ceiling($Hop.Avg / 10)))
    Write-Host ($s.Full * $filled) -ForegroundColor $color -NoNewline
    Write-Host ($s.Light * ($script:BarWidth - $filled)) -ForegroundColor $script:Theme.Dim -NoNewline

    if ($Hop.Received -lt $Hop.Sent) {
        Write-Host ("  loss {0}/{1}" -f ($Hop.Sent - $Hop.Received), $Hop.Sent) -ForegroundColor $script:Theme.Warn -NoNewline
    }
    if ($null -ne $PreviousAvg) {
        $delta = $Hop.Avg - $PreviousAvg
        if ($delta -ge 30) {
            Write-Host ("  {0} +{1} ms" -f $s.Up, [math]::Round($delta)) -ForegroundColor $script:Theme.Fire -NoNewline
        }
    }
    Write-Host ''
    Write-Host ("    {0}" -f $s.V) -ForegroundColor $script:Theme.Line
}

function Write-TraceEnd {
    param($Hops, [bool]$Reached, [string]$TargetLabel, [System.Net.IPAddress]$TargetIp, [string]$StopReason)

    $s = $script:Sym
    if ($Reached) {
        $last = $Hops[$Hops.Count - 1]
        Write-Host ("    {0}" -f $s.Down) -ForegroundColor $script:Theme.Gold
        Write-Host '   [ TARGET ]  ' -ForegroundColor Black -BackgroundColor DarkYellow -NoNewline
        Write-Host ("  {0}  {1}" -f $TargetLabel, $TargetIp) -ForegroundColor $script:Theme.Text -NoNewline
        Write-Host ("   reached in {0} hops, {1} ms" -f $last.Ttl, [math]::Round($last.Avg)) -ForegroundColor $script:Theme.Gold
    } else {
        Write-Host ("    {0}" -f $s.Dash) -ForegroundColor $script:Theme.Line
        Write-Host '   [ NOT REACHED ]  ' -ForegroundColor $script:Theme.Text -BackgroundColor DarkRed -NoNewline
        Write-Host ("  {0}  {1}" -f $TargetLabel, $TargetIp) -ForegroundColor $script:Theme.Text
        if ($StopReason) { Write-Host ("   {0}" -f $StopReason) -ForegroundColor $script:Theme.Warn }
    }
}

function Write-TracePathMap {
    # One compact line (wrapped when needed): YOU > hop > hop > TARGET
    param($Hops)

    $s = $script:Sym
    $segments = New-Object System.Collections.Generic.List[object]
    $segments.Add(@{ Text = 'YOU'; Color = $script:Theme.Gold })

    $silent = 0
    foreach ($hop in $Hops) {
        if ($hop.Received -eq 0) { $silent++; continue }
        if ($silent -gt 0) {
            $label = '*'
            if ($silent -gt 1) { $label = "* x$silent" }
            $segments.Add(@{ Text = $label; Color = $script:Theme.Dim })
            $silent = 0
        }
        $label = $hop.Address.ToString()
        if ($hop.HostName) {
            $name = $hop.HostName
            if ($name.Length -gt 24) { $name = $name.Split('.')[0] }
            $label = "$name ($label)"
        }
        $segments.Add(@{ Text = $label; Color = $script:ZoneColor[$hop.Zone] })
    }
    if ($silent -gt 0) {
        $label = '*'
        if ($silent -gt 1) { $label = "* x$silent" }
        $segments.Add(@{ Text = $label; Color = $script:Theme.Dim })
    }

    $width = 100
    try { $width = [math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 2) } catch { $width = 100 }

    Write-Host ''
    Write-Host '  Path: ' -ForegroundColor $script:Theme.Text -NoNewline
    $column = 8
    $arrow = " {0}{1} " -f $s.H, $s.Right
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $piece = $segments[$i].Text
        if ($i -gt 0) {
            if ($column + $arrow.Length + $piece.Length -gt $width) {
                Write-Host ''
                Write-Host '        ' -NoNewline
                $column = 8
            }
            Write-Host $arrow -ForegroundColor $script:Theme.Line -NoNewline
            $column += $arrow.Length
        }
        Write-Host $piece -ForegroundColor $segments[$i].Color -NoNewline
        $column += $piece.Length
    }
    Write-Host ''
}

function Write-TraceSummary {
    param($Hops, [bool]$Reached)

    $answered = @($Hops | Where-Object { $_.Received -gt 0 })
    $biggest = $null
    $prev = $null
    foreach ($hop in $answered) {
        if ($null -ne $prev) {
            $delta = $hop.Avg - $prev.Avg
            if ($null -eq $biggest -or $delta -gt $biggest.Delta) {
                $biggest = @{ Delta = $delta; Hop = $hop; From = $prev }
            }
        }
        $prev = $hop
    }

    $zones = $answered | Group-Object Zone | ForEach-Object { "{0} {1}" -f $_.Name, $_.Count }

    Write-Host ''
    Write-Host '  Summary' -ForegroundColor $script:Theme.Gold
    $reachedText = 'no'
    $reachedColor = $script:Theme.Fire
    if ($Reached) { $reachedText = 'yes'; $reachedColor = $script:Theme.Gold }
    Write-Host '   Reached     : ' -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $reachedText -ForegroundColor $reachedColor
    Write-Host ("   Hops        : {0} ({1} answered, {2} silent)" -f $Hops.Count, $answered.Count, ($Hops.Count - $answered.Count)) -ForegroundColor $script:Theme.Muted
    if ($zones) { Write-Host ("   Zones (hops): {0}" -f ($zones -join ', ')) -ForegroundColor $script:Theme.Muted }
    if ($biggest -and $biggest.Delta -gt 0) {
        Write-Host ("   Biggest jump: +{0} ms between hop {1} and hop {2}" -f [math]::Round($biggest.Delta), $biggest.From.Ttl, $biggest.Hop.Ttl) -ForegroundColor $script:Theme.Muted
    }
    Write-Host '   Legend      : ' -ForegroundColor $script:Theme.Muted -NoNewline
    foreach ($z in 'LAN', 'CGNAT', 'PUBLIC') {
        Write-Host ("{0} {1}  " -f $script:Sym.Node, $z) -ForegroundColor $script:ZoneColor[$z] -NoNewline
    }
    Write-Host ("{0} no reply" -f $script:Sym.Miss) -ForegroundColor $script:Theme.Dim
    Write-Host ''
}

# ----------------------------------------------------------------------------
# Exported tool
# ----------------------------------------------------------------------------

function Invoke-NRVisualTrace {
    <#
    .SYNOPSIS
        Traceroute with a visual path.
    .EXAMPLE
        Invoke-NRVisualTrace -Target 8.8.8.8
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Target,

        [ValidateRange(1, 64)]
        [int]$MaxHops = 30,

        [ValidateRange(100, 10000)]
        [int]$Timeout = 1000,

        [ValidateRange(1, 10)]
        [int]$Probes = 3,

        [ValidateSet('on', 'off')]
        [string]$Resolve = 'on'
    )

    $targetIp = Resolve-TraceTarget -Target $Target
    $localIp = Get-TraceLocalAddress -Target $targetIp
    $doResolve = ($Resolve -eq 'on')

    Write-TraceStart -TargetLabel $Target -TargetIp $targetIp -LocalIp $localIp -MaxHops $MaxHops

    $ping = New-Object System.Net.NetworkInformation.Ping
    $buffer = [byte[]](,0x61 * 32)
    $hops = New-Object System.Collections.Generic.List[object]
    $reached = $false
    $stopReason = ''
    $silentInARow = 0
    $previousZone = 'LAN'
    if ($localIp) { $previousZone = Get-TraceZone $localIp }
    $previousAvg = $null

    try {
        for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
            Write-Progress -Activity "NetRing trace to $Target" -Status ("Hop {0} of max {1}" -f $ttl, $MaxHops) -PercentComplete ([int](($ttl - 1) * 100 / $MaxHops))

            $results = @()
            for ($p = 0; $p -lt $Probes; $p++) {
                $results += Send-TraceProbe -Ping $ping -Address $targetIp -Ttl $ttl -Timeout $Timeout -Buffer $buffer
            }

            $errors = @($results | Where-Object { $_.Status -eq 'Error' })
            if ($errors.Count -eq $results.Count) {
                if ($ttl -eq 1) { throw ("Ping failed: {0}" -f $errors[0].Message) }
                $stopReason = ("Stopped: ping failed at hop {0} ({1})." -f $ttl, $errors[0].Message)
                break
            }

            $answered = @($results | Where-Object { $null -ne $_.Address })
            $rtts = @($answered | ForEach-Object { $_.Rtt })
            $address = $null
            if ($answered.Count -gt 0) { $address = $answered[0].Address }

            $hop = [pscustomobject]@{
                Ttl      = $ttl
                Address  = $address
                HostName = ''
                Zone     = '?'
                Sent     = $Probes
                Received = $answered.Count
                Avg      = 0.0
                Min      = 0
                Max      = 0
                Note     = ''
            }

            if ($answered.Count -gt 0) {
                $stats = $rtts | Measure-Object -Average -Minimum -Maximum
                $hop.Avg = [double]$stats.Average
                $hop.Min = [int]$stats.Minimum
                $hop.Max = [int]$stats.Maximum
                $hop.Zone = Get-TraceZone $address
                if ($doResolve) { $hop.HostName = Resolve-TraceName -Address $address }

                if ($hop.Zone -ne $previousZone -and $hop.Zone -ne '?') {
                    Write-TraceZoneChange -From $previousZone -To $hop.Zone
                    $previousZone = $hop.Zone
                }
                $silentInARow = 0
            } else {
                $silentInARow++
            }

            $hops.Add($hop)
            Write-TraceHop -Hop $hop -PreviousAvg $previousAvg
            if ($hop.Received -gt 0) { $previousAvg = $hop.Avg }

            if (@($results | Where-Object { $_.Status -eq 'Success' }).Count -gt 0) {
                $reached = $true
                break
            }

            $unreachable = @($results | Where-Object { $_.Status -like 'Destination*Unreachable' -or $_.Status -eq 'DestinationProhibited' })
            if ($unreachable.Count -gt 0) {
                $stopReason = "Stopped: a router reports '$($unreachable[0].Status)'."
                break
            }

            if ($silentInARow -ge $script:MaxSilentHops) {
                $stopReason = ("Stopped after {0} silent hops in a row. The target or a firewall probably blocks ICMP." -f $silentInARow)
                break
            }
        }
        if (-not $reached -and -not $stopReason) {
            $stopReason = "Maximum of $MaxHops hops reached. Try a higher MaxHops."
        }
    } finally {
        Write-Progress -Activity "NetRing trace to $Target" -Completed
        $ping.Dispose()
    }

    Write-TraceEnd -Hops $hops -Reached $reached -TargetLabel $Target -TargetIp $targetIp -StopReason $stopReason
    Write-TracePathMap -Hops $hops
    Write-TraceSummary -Hops $hops -Reached $reached
}

Export-ModuleMember -Function 'Invoke-NRVisualTrace'
