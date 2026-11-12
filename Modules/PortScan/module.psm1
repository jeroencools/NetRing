# NetRing module: PortScan
# Which TCP ports are open, closed or filtered on a host, a range or a subnet?
#   open      the connection succeeds: a service listens
#   closed    a refusal (TCP RST): host is there, nothing listens
#             Note: Windows tries again after a refusal and only reports it
#             after about 2 s. That is why the default timeout is 2500 ms:
#             a lower timeout makes closed ports look filtered on Windows.
#   filtered  no answer at all: a firewall drops the packets
#
# A TCP connect scan with many connections in parallel. Works without admin
# rights on Windows PowerShell 5.1 and PowerShell 7. No SYN/stealth scan,
# no UDP, no OS detection: that is what nmap is for.
# This file only contains ASCII characters: symbols are built with [char].

Set-StrictMode -Version 2.0

$script:Sym = @{
    Open     = [string][char]0x25CF   # filled circle
    Closed   = [string][char]0x25CB   # open circle
    Filtered = [string][char]0x00D7   # multiplication sign
    H        = [string][char]0x2500
    Arrow    = [string][char]0x2192
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

$script:Parallel   = 200      # connections at the same time
$script:SafeProbes = 5000     # above this: extra warning and confirmation
$script:MaxProbes  = 100000   # hard limit (hosts x ports)
$script:MaxHosts   = 65534
$script:GridPorts  = 8        # several hosts and at most this many ports: show a grid

# Port presets.
$script:Presets = [ordered]@{
    top     = @(21, 22, 23, 25, 53, 80, 88, 110, 111, 135, 139, 143, 389, 443, 445, 465, 587, 631, 636, 993, 995, 1433, 1723, 3306, 3389, 5432, 5900, 5985, 8000, 8080, 8443, 9100)
    web     = @(80, 443, 8000, 8080, 8443)
    windows = @(88, 135, 139, 389, 445, 3389, 5985, 5986)
    mail    = @(25, 110, 143, 465, 587, 993, 995)
    remote  = @(22, 23, 3389, 5900, 5985, 5986)
}

# Well-known services: name, short explanation, and a risk note when it is open.
$script:Services = @{
    20   = @{ Name = 'FTP-data';   Desc = 'file transfer (data)';                  Risk = '' }
    21   = @{ Name = 'FTP';        Desc = 'file transfer';                         Risk = 'sends passwords in plain text' }
    22   = @{ Name = 'SSH';        Desc = 'secure remote shell (encrypted)';       Risk = '' }
    23   = @{ Name = 'Telnet';     Desc = 'remote shell without encryption';       Risk = 'everything, passwords too, travels in plain text' }
    25   = @{ Name = 'SMTP';       Desc = 'mail between servers';                  Risk = '' }
    53   = @{ Name = 'DNS';        Desc = 'name resolution';                       Risk = '' }
    80   = @{ Name = 'HTTP';       Desc = 'website without encryption';            Risk = '' }
    88   = @{ Name = 'Kerberos';   Desc = 'Windows domain login';                  Risk = '' }
    110  = @{ Name = 'POP3';       Desc = 'fetch mail, unencrypted';               Risk = 'mail and password in plain text' }
    111  = @{ Name = 'rpcbind';    Desc = 'Unix RPC portmapper';                   Risk = 'often abused, close it if not needed' }
    135  = @{ Name = 'MS-RPC';     Desc = 'Windows remote procedure calls';        Risk = '' }
    139  = @{ Name = 'NetBIOS';    Desc = 'old Windows file sharing';              Risk = 'outdated, should not be reachable from outside' }
    143  = @{ Name = 'IMAP';       Desc = 'mail, unencrypted';                     Risk = 'mail and password in plain text' }
    389  = @{ Name = 'LDAP';       Desc = 'directory, e.g. Active Directory';      Risk = '' }
    443  = @{ Name = 'HTTPS';      Desc = 'website with encryption';               Risk = '' }
    445  = @{ Name = 'SMB';        Desc = 'Windows file sharing';                  Risk = 'never open towards the internet' }
    465  = @{ Name = 'SMTPS';      Desc = 'send mail, encrypted';                  Risk = '' }
    587  = @{ Name = 'Submission'; Desc = 'send mail from a mail client';          Risk = '' }
    631  = @{ Name = 'IPP';        Desc = 'printing';                              Risk = '' }
    636  = @{ Name = 'LDAPS';      Desc = 'directory, encrypted';                  Risk = '' }
    993  = @{ Name = 'IMAPS';      Desc = 'mail, encrypted';                       Risk = '' }
    995  = @{ Name = 'POP3S';      Desc = 'fetch mail, encrypted';                 Risk = '' }
    1433 = @{ Name = 'MSSQL';      Desc = 'Microsoft SQL Server';                  Risk = 'a database should not be reachable for everyone' }
    1723 = @{ Name = 'PPTP';       Desc = 'old VPN protocol';                      Risk = 'weak encryption, outdated' }
    3306 = @{ Name = 'MySQL';      Desc = 'MySQL / MariaDB database';              Risk = 'a database should not be reachable for everyone' }
    3389 = @{ Name = 'RDP';        Desc = 'remote desktop';                        Risk = 'should never be open towards the internet' }
    5432 = @{ Name = 'PostgreSQL'; Desc = 'PostgreSQL database';                   Risk = 'a database should not be reachable for everyone' }
    5900 = @{ Name = 'VNC';        Desc = 'remote screen';                         Risk = 'often weakly protected' }
    5985 = @{ Name = 'WinRM';      Desc = 'PowerShell remoting (HTTP)';            Risk = '' }
    5986 = @{ Name = 'WinRM-S';    Desc = 'PowerShell remoting (HTTPS)';           Risk = '' }
    8000 = @{ Name = 'HTTP-alt';   Desc = 'alternative web port (test servers)';   Risk = '' }
    8080 = @{ Name = 'HTTP-alt';   Desc = 'alternative web port, proxies';         Risk = '' }
    8443 = @{ Name = 'HTTPS-alt';  Desc = 'alternative HTTPS port';                Risk = '' }
    9100 = @{ Name = 'JetDirect';  Desc = 'raw printing (printers)';               Risk = '' }
}

$script:HttpPorts = @(80, 8000, 8080, 5985)

# ----------------------------------------------------------------------------
# Targets (same formats as 'scan'; copied on purpose: modules stay independent)
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

function Resolve-PortTarget {
    # Returns @{ Hosts = string[]; Label; Single = bool }
    param([string]$Target)

    $text = $Target.Trim()

    # Subnet: 192.168.1.0/24 (all hosts, without network and broadcast address)
    if ($text -match '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($Matches[1], [ref]$ip)) { throw "'$($Matches[1])' is not a valid IPv4 address." }
        $prefix = [int]$Matches[2]
        if ($prefix -lt 16 -or $prefix -gt 32) { throw 'Choose a prefix between /16 and /32.' }
        $all = [uint64]4294967295
        $mask = ($all -shl (32 - $prefix)) -band $all
        $net = [uint64](ConvertTo-UInt32 $ip) -band $mask
        $broadcast = $net + ($all - $mask)
        $first = $net + 1; $last = $broadcast - 1
        if ($prefix -ge 31) { $first = $net; $last = $broadcast }
        $hosts = for ($n = $first; $n -le $last; $n++) { ConvertFrom-UInt32 ([uint32]$n) }
        return @{ Hosts = @($hosts); Label = ("{0}/{1}" -f (ConvertFrom-UInt32 ([uint32]$net)), $prefix); Single = ($first -eq $last) }
    }

    # Range: 192.168.1.10-192.168.1.20 or 192.168.1.10-20
    $startText = ''; $endText = ''
    if ($text -match '^(\d{1,3}(?:\.\d{1,3}){3})\s*-\s*(\d{1,3}(?:\.\d{1,3}){3})$') {
        $startText = $Matches[1]; $endText = $Matches[2]
    } elseif ($text -match '^((\d{1,3}\.\d{1,3}\.\d{1,3}\.)\d{1,3})\s*-\s*(\d{1,3})$') {
        $startText = $Matches[1]; $endText = $Matches[2] + $Matches[3]
    }
    if ($startText) {
        $a = $null; $b = $null
        if (-not [System.Net.IPAddress]::TryParse($startText, [ref]$a)) { throw "'$startText' is not a valid IPv4 address." }
        if (-not [System.Net.IPAddress]::TryParse($endText, [ref]$b)) { throw "'$endText' is not a valid IPv4 address." }
        foreach ($octet in ($startText.Split('.') + $endText.Split('.'))) { if ([int]$octet -gt 255) { throw "'$text' contains a number above 255." } }
        $first = [uint64](ConvertTo-UInt32 $a); $last = [uint64](ConvertTo-UInt32 $b)
        if ($last -lt $first) { throw "The range must go from low to high." }
        if ($last - $first + 1 -gt $script:MaxHosts) { throw ("At most {0} hosts." -f $script:MaxHosts) }
        $hosts = for ($n = $first; $n -le $last; $n++) { ConvertFrom-UInt32 ([uint32]$n) }
        return @{ Hosts = @($hosts); Label = ("{0} - {1}" -f $startText, $endText); Single = ($first -eq $last) }
    }

    # One IP address
    $single = $null
    if ($text -match '^\d{1,3}(?:\.\d{1,3}){3}$') {
        if (-not [System.Net.IPAddress]::TryParse($text, [ref]$single)) { throw "'$text' is not a valid IPv4 address." }
        foreach ($octet in $text.Split('.')) { if ([int]$octet -gt 255) { throw "'$text' contains a number above 255." } }
        return @{ Hosts = @($text); Label = $text; Single = $true }
    }

    # A hostname
    try {
        $addresses = @([System.Net.Dns]::GetHostAddresses($text) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
    } catch {
        throw "Could not resolve '$text'. Give an IP address, a range or a subnet."
    }
    if ($addresses.Count -eq 0) { throw "'$text' has no IPv4 address." }
    $ipText = $addresses[0].ToString()
    return @{ Hosts = @($ipText); Label = ("{0} ({1})" -f $text, $ipText); Single = $true }
}

# ----------------------------------------------------------------------------
# Ports
# ----------------------------------------------------------------------------

function Resolve-PortList {
    # "top", "22,80,443", "1-1024", "22,80,8000-8100", "all". Returns @{ Ports = int[]; Label }
    param([string]$Text)

    $value = ([string]$Text).Trim().ToLowerInvariant()
    if (-not $value) { $value = 'top' }
    if ($value -eq 'all') { return @{ Ports = @(1..65535); Label = 'all ports (1-65535)' } }
    if ($script:Presets.Contains($value)) {
        return @{ Ports = @($script:Presets[$value]); Label = ("preset '{0}' ({1} ports)" -f $value, @($script:Presets[$value]).Count) }
    }

    $set = New-Object 'System.Collections.Generic.SortedSet[int]'
    foreach ($part in ($value -split '[,;\s]+' | Where-Object { $_ })) {
        if ($part -match '^(\d+)-(\d+)$') {
            $from = [int]$Matches[1]; $to = [int]$Matches[2]
            if ($from -lt 1 -or $to -gt 65535 -or $from -gt $to) { throw "'$part' is not a valid port range (1-65535, low to high)." }
            for ($p = $from; $p -le $to; $p++) { [void]$set.Add($p) }
        } elseif ($part -match '^\d+$') {
            $p = [int]$part
            if ($p -lt 1 -or $p -gt 65535) { throw "Port $p does not exist (1-65535)." }
            [void]$set.Add($p)
        } else {
            throw ("'{0}' is not a port. Use e.g. 443, 22,80,443, 1-1024 or a preset: {1}, all." -f $part, ($script:Presets.Keys -join ', '))
        }
    }
    $ports = @($set)
    if ($ports.Count -eq 0) { throw 'No ports given.' }
    # Show what the user typed, e.g. "22,80,8000-8100 (103 ports)".
    $label = ($value -replace '\s', '')
    if ($label.Length -gt 50) { $label = $label.Substring(0, 47) + '...' }
    if ($ports.Count -gt 1) { $label = "$label ($($ports.Count) ports)" }
    return @{ Ports = $ports; Label = $label }
}

function Get-ServiceInfo {
    param([int]$Port)
    if ($script:Services.ContainsKey($Port)) { return $script:Services[$Port] }
    return @{ Name = '?'; Desc = ''; Risk = '' }
}

# ----------------------------------------------------------------------------
# Scanning
# ----------------------------------------------------------------------------

function Get-ConnectState {
    # Translates a finished ConnectAsync task into open / closed / filtered.
    param($Task)
    if ($Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { return 'open' }
    $ex = $null
    try { $ex = $Task.Exception } catch { }
    while ($ex -and $ex.InnerException) { $ex = $ex.InnerException }
    if ($ex -is [System.Net.Sockets.SocketException]) {
        if ($ex.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) { return 'closed' }
    }
    return 'filtered'
}

function Invoke-PortProbes {
    # Probes every (host, port) pair, at most $script:Parallel at the same time.
    # Returns a list of @{ Host; Port; State }.
    param([string[]]$Hosts, [int[]]$Ports, [int]$Timeout)

    $total = [int64]$Hosts.Count * $Ports.Count
    $results = New-Object System.Collections.Generic.List[object]
    $active = New-Object System.Collections.Generic.List[object]
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $hostIndex = 0
    $portIndex = 0
    $started = [int64]0
    $lastProgress = -1

    while ($started -lt $total -or $active.Count -gt 0) {
        # Fill up the window.
        while ($active.Count -lt $script:Parallel -and $started -lt $total) {
            $ip = $Hosts[$hostIndex]
            $port = $Ports[$portIndex]
            $portIndex++
            if ($portIndex -ge $Ports.Count) { $portIndex = 0; $hostIndex++ }
            $started++
            $client = New-Object System.Net.Sockets.TcpClient([System.Net.Sockets.AddressFamily]::InterNetwork)
            try {
                $task = $client.ConnectAsync($ip, $port)
                $active.Add(@{ Host = $ip; Port = $port; Client = $client; Task = $task; Start = $clock.ElapsedMilliseconds })
            } catch {
                $client.Dispose()
                $results.Add(@{ Host = $ip; Port = $port; State = 'filtered' })
            }
        }

        Start-Sleep -Milliseconds 10
        $now = $clock.ElapsedMilliseconds
        for ($i = $active.Count - 1; $i -ge 0; $i--) {
            $a = $active[$i]
            $state = ''
            if ($a.Task.IsCompleted) { $state = Get-ConnectState $a.Task }
            elseif ($now - $a.Start -gt $Timeout) { $state = 'filtered' }
            if ($state) {
                try { $a.Client.Dispose() } catch { }
                $results.Add(@{ Host = $a.Host; Port = $a.Port; State = $state })
                $active.RemoveAt($i)
            }
        }

        $percent = [int]($results.Count * 100 / [math]::Max(1, $total))
        if ($percent -ne $lastProgress) {
            Write-Progress -Activity 'NetRing port scan' -Status ("{0} of {1} ports checked" -f $results.Count, $total) -PercentComplete $percent
            $lastProgress = $percent
        }
    }
    Write-Progress -Activity 'NetRing port scan' -Completed
    return , $results
}

function Get-Banners {
    # Reads the first line that open services send. For web ports we ask
    # with HEAD and keep the Server header. Returns hashtable "host:port" -> text.
    param($OpenResults, [int]$Timeout)

    $banners = @{}
    $jobs = @()
    foreach ($r in ($OpenResults | Select-Object -First 100)) {
        $client = New-Object System.Net.Sockets.TcpClient([System.Net.Sockets.AddressFamily]::InterNetwork)
        try { $jobs += @{ Key = "$($r.Host):$($r.Port)"; Port = $r.Port; Client = $client; Connect = $client.ConnectAsync($r.Host, $r.Port) } }
        catch { $client.Dispose() }
    }
    if ($jobs.Count -eq 0) { return $banners }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($jobs | ForEach-Object { $_.Connect }), $Timeout) } catch { }

    $reads = @()
    foreach ($job in $jobs) {
        if ($job.Connect.Status -ne [System.Threading.Tasks.TaskStatus]::RanToCompletion) { continue }
        try {
            $stream = $job.Client.GetStream()
            if ($script:HttpPorts -contains $job.Port) {
                $probe = [System.Text.Encoding]::ASCII.GetBytes("HEAD / HTTP/1.0`r`nHost: $($job.Key.Split(':')[0])`r`n`r`n")
                $stream.Write($probe, 0, $probe.Length)
            }
            $buffer = New-Object byte[] 1024
            $reads += @{ Job = $job; Buffer = $buffer; Read = $stream.ReadAsync($buffer, 0, $buffer.Length) }
        } catch { }
    }
    if ($reads.Count -gt 0) {
        try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($reads | ForEach-Object { $_.Read }), 2000) } catch { }
    }
    foreach ($r in $reads) {
        try {
            if ($r.Read.Status -ne [System.Threading.Tasks.TaskStatus]::RanToCompletion -or $r.Read.Result -le 0) { continue }
            $text = [System.Text.Encoding]::ASCII.GetString($r.Buffer, 0, $r.Read.Result)
            $lines = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $line = ''
            $server = @($lines | Where-Object { $_ -match '^Server:\s*(.+)$' } | Select-Object -First 1)
            if ($server.Count -gt 0) { $line = $server[0] }
            elseif ($lines.Count -gt 0) { $line = $lines[0] }
            $line = ($line -replace '[^\x20-\x7E]', '')
            if ($line.Length -gt 70) { $line = $line.Substring(0, 67) + '...' }
            if ($line) { $banners[$r.Job.Key] = $line }
        } catch { }
    }
    foreach ($job in $jobs) { try { $job.Client.Dispose() } catch { } }
    return $banners
}

# ----------------------------------------------------------------------------
# Rendering
# ----------------------------------------------------------------------------

function Get-StateLook {
    param([string]$State)
    switch ($State) {
        'open'   { return @{ Sym = $script:Sym.Open;     Color = $script:Theme.Ok } }
        'closed' { return @{ Sym = $script:Sym.Closed;   Color = $script:Theme.Muted } }
        default  { return @{ Sym = $script:Sym.Filtered; Color = $script:Theme.Dim } }
    }
}

function Write-ScanWarning {
    Write-Host ''
    Write-Host '  [!] Only scan hosts you own or have permission for. A port scan is easily' -ForegroundColor $script:Theme.Warn
    Write-Host '      noticed by firewalls and intrusion detection, and scanning other' -ForegroundColor $script:Theme.Warn
    Write-Host '      networks (school, work, internet) without permission can be illegal.' -ForegroundColor $script:Theme.Warn
}

function Confirm-PortScan {
    param([string]$Question)
    Write-Host ("      {0} (y/N): " -f $Question) -ForegroundColor $script:Theme.Text -NoNewline
    $answer = Read-Host
    return ($null -ne $answer -and $answer.Trim().ToLowerInvariant() -in @('y', 'yes', 'j', 'ja'))
}

function Write-SingleHost {
    param([string]$Label, $Results, $Banners, [string]$Show)

    $open = @($Results | Where-Object { $_.State -eq 'open' } | Sort-Object { $_.Port })
    $closed = @($Results | Where-Object { $_.State -eq 'closed' }).Count
    $filtered = @($Results | Where-Object { $_.State -eq 'filtered' }).Count
    $rows = $open
    if ($Show -eq 'all') { $rows = @($Results | Sort-Object { $_.Port }) }

    Write-Host ''
    Write-Host ("  {0}" -f $Label) -ForegroundColor $script:Theme.Title
    Write-Host ("     {0,-11}{1,-10}{2,-12}{3}" -f 'Port', 'State', 'Service', 'What it is') -ForegroundColor $script:Theme.Dim
    Write-Host ("     {0}" -f ($script:Sym.H * 66)) -ForegroundColor $script:Theme.Dim
    foreach ($r in $rows) {
        $look = Get-StateLook $r.State
        $svc = Get-ServiceInfo $r.Port
        Write-Host ("   {0} " -f $look.Sym) -ForegroundColor $look.Color -NoNewline
        Write-Host ("{0,-11}" -f "$($r.Port)/tcp") -ForegroundColor $script:Theme.Key -NoNewline
        Write-Host ("{0,-10}" -f $r.State) -ForegroundColor $look.Color -NoNewline
        Write-Host ("{0,-12}" -f $svc.Name) -ForegroundColor $script:Theme.Text -NoNewline
        Write-Host $svc.Desc -ForegroundColor $script:Theme.Muted
        $key = "$($r.Host):$($r.Port)"
        if ($Banners.ContainsKey($key)) { Write-Host ("                 banner: {0}" -f $Banners[$key]) -ForegroundColor $script:Theme.Dim }
        if ($r.State -eq 'open' -and $svc.Risk) { Write-Host ("                 [!] {0}" -f $svc.Risk) -ForegroundColor $script:Theme.Warn }
    }
    if ($rows.Count -eq 0) { Write-Host '     no open ports' -ForegroundColor $script:Theme.Dim }

    Write-Host ''
    Write-Host ("  {0} open   {1} closed   {2} filtered" -f $open.Count, $closed, $filtered) -ForegroundColor $script:Theme.Muted
    if ($open.Count -eq 0 -and $closed -eq 0) {
        Write-Host '  No answer on any port: the host is down, or a firewall drops everything.' -ForegroundColor $script:Theme.Dim
    } elseif ($open.Count -eq 0) {
        Write-Host '  The host is up (it refuses connections), but nothing is open.' -ForegroundColor $script:Theme.Dim
    }
}

function Write-HostGrid {
    # Hosts down, ports across. Only hosts that answered at all.
    param($Results, [int[]]$Ports)

    $byHost = @{}
    foreach ($r in $Results) {
        if (-not $byHost.ContainsKey($r.Host)) { $byHost[$r.Host] = @{} }
        $byHost[$r.Host][$r.Port] = $r.State
    }
    $alive = @($byHost.Keys | Where-Object { @($byHost[$_].Values | Where-Object { $_ -ne 'filtered' }).Count -gt 0 } |
        Sort-Object { ConvertTo-UInt32 ([System.Net.IPAddress]::Parse($_)) })

    Write-Host ''
    Write-Host ("     {0,-17}" -f 'Host') -ForegroundColor $script:Theme.Dim -NoNewline
    foreach ($p in $Ports) {
        $name = (Get-ServiceInfo $p).Name
        if ($name -eq '?') { $name = '' }
        Write-Host ("{0,-11}" -f ("{0} {1}" -f $p, $name).Trim()) -ForegroundColor $script:Theme.Dim -NoNewline
    }
    Write-Host ''
    Write-Host ("     {0}" -f ($script:Sym.H * (17 + 11 * $Ports.Count))) -ForegroundColor $script:Theme.Dim
    foreach ($h in $alive) {
        Write-Host ("     {0,-17}" -f $h) -ForegroundColor $script:Theme.Key -NoNewline
        foreach ($p in $Ports) {
            $state = $byHost[$h][$p]
            $look = Get-StateLook $state
            Write-Host ("{0,-11}" -f "$($look.Sym) $state") -ForegroundColor $look.Color -NoNewline
        }
        Write-Host ''
    }
    return $alive.Count
}

function Write-HostList {
    # One line per host with its open ports.
    param($Results)

    $byHost = @{}
    foreach ($r in $Results) {
        if (-not $byHost.ContainsKey($r.Host)) { $byHost[$r.Host] = New-Object System.Collections.Generic.List[object] }
        $byHost[$r.Host].Add($r)
    }
    $shown = 0
    $upNothingOpen = 0
    foreach ($h in ($byHost.Keys | Sort-Object { ConvertTo-UInt32 ([System.Net.IPAddress]::Parse($_)) })) {
        $list = $byHost[$h]
        $open = @($list | Where-Object { $_.State -eq 'open' } | Sort-Object { $_.Port })
        if ($open.Count -eq 0) {
            if (@($list | Where-Object { $_.State -eq 'closed' }).Count -gt 0) { $upNothingOpen++ }
            continue
        }
        $shown++
        Write-Host ("   {0} " -f $script:Sym.Open) -ForegroundColor $script:Theme.Ok -NoNewline
        Write-Host ("{0,-17}" -f $h) -ForegroundColor $script:Theme.Key -NoNewline
        $parts = $open | ForEach-Object {
            $name = (Get-ServiceInfo $_.Port).Name
            if ($name -eq '?') { "$($_.Port)" } else { "$($_.Port) $name" }
        }
        Write-Host ($parts -join ', ') -ForegroundColor $script:Theme.Text
    }
    return @{ Shown = $shown; UpNothingOpen = $upNothingOpen; Total = $byHost.Count }
}

# ----------------------------------------------------------------------------
# CSV export
# ----------------------------------------------------------------------------

function Get-DefaultExportPath {
    $docs = ''
    try { $docs = [Environment]::GetFolderPath('MyDocuments') } catch { }
    if (-not $docs) { $docs = $HOME }
    $folder = Join-Path $docs 'NetRing'
    return (Join-Path $folder ("ports-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date)))
}

function Export-PortResults {
    # Writes all results to CSV, with the list separator of this computer
    # (';' on a Belgian Windows), so Excel opens it in columns.
    # $Show 'open' writes only the open ports (what you saw on screen),
    # 'all' writes every port that was checked.
    param($Results, $Banners, [string]$Path, [string]$Show = 'open')

    if ($Show -eq 'all') { $selected = @($Results | ForEach-Object { $_ }) }
    else { $selected = @($Results | Where-Object { $_.State -eq 'open' }) }
    if ($selected.Count -eq 0) { return 0 }

    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $rows = foreach ($r in ($selected | Sort-Object @{ Expression = { ConvertTo-UInt32 ([System.Net.IPAddress]::Parse($_.Host)) } }, @{ Expression = { $_.Port } })) {
        $svc = Get-ServiceInfo $r.Port
        $key = "$($r.Host):$($r.Port)"
        $banner = ''
        if ($Banners.ContainsKey($key)) { $banner = $Banners[$key] }
        $risk = ''
        if ($r.State -eq 'open') { $risk = $svc.Risk }
        [pscustomobject]@{
            Host        = $r.Host
            Port        = $r.Port
            Protocol    = 'tcp'
            State       = $r.State
            Service     = $(if ($svc.Name -eq '?') { '' } else { $svc.Name })
            Description = $svc.Desc
            Risk        = $risk
            Banner      = $banner
            Scanned     = $time
        }
    }
    $encoding = 'UTF8'
    if ($PSVersionTable.PSVersion.Major -ge 6) { $encoding = 'utf8BOM' }   # BOM: Excel reads it correctly
    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -UseCulture -Encoding $encoding
    return @($rows).Count
}

# ----------------------------------------------------------------------------
# Exported tool
# ----------------------------------------------------------------------------

function Invoke-NRPortScan {
    <#
    .SYNOPSIS
        TCP port scan of a host, a range or a subnet.
    .EXAMPLE
        Invoke-NRPortScan -Target 192.168.1.10 -Ports 1-1024 -Banner on
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Target,

        [Parameter(Position = 1)]
        [string]$Ports = 'top',

        [Parameter(Position = 2)]
        [ValidateRange(200, 10000)]
        [int]$Timeout = 2500,

        [Parameter(Position = 3)]
        [ValidateSet('on', 'off')]
        [string]$Banner = 'off',

        [Parameter(Position = 4)]
        [ValidateSet('open', 'all')]
        [string]$Show = 'open',

        [Parameter(Position = 5)]
        [ValidateSet('on', 'off')]
        [string]$Ask = 'on',

        [Parameter(Position = 6)]
        [string]$Export = 'ask'
    )

    $s = $script:Sym
    $targets = Resolve-PortTarget -Target $Target
    $portList = Resolve-PortList -Text $Ports
    $hostCount = $targets.Hosts.Count
    $probes = [int64]$hostCount * $portList.Ports.Count
    if ($probes -gt $script:MaxProbes) {
        throw ("{0} hosts x {1} ports = {2} checks; the maximum is {3}. Scan fewer hosts or ports." -f $hostCount, $portList.Ports.Count, $probes, $script:MaxProbes)
    }

    Write-Host ''
    Write-Host '  Port scan' -ForegroundColor $script:Theme.Key
    Write-Host ("  {0}" -f ($s.H * 9)) -ForegroundColor $script:Theme.Title
    Write-Host ("  Target    {0}   {1} host(s)" -f $targets.Label, $hostCount) -ForegroundColor $script:Theme.Text
    Write-Host ("  Ports     {0}" -f $portList.Label) -ForegroundColor $script:Theme.Text
    $estimate = [math]::Ceiling($probes / $script:Parallel) * ($Timeout / 1000.0)
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or ((Test-Path variable:IsWindows) -and $IsWindows)
    $estimateText = ("at most about {0:0} s" -f [math]::Max(1, $estimate))
    if ($estimate -ge 90) { $estimateText = ("at most about {0:0.#} minutes" -f ($estimate / 60)) }
    Write-Host ("  Checks    {0}   {1}, {2} ms timeout" -f $probes, $estimateText, $Timeout) -ForegroundColor $script:Theme.Muted
    if ($onWindows -and $Timeout -lt 2500) {
        Write-Host '  [!] Below 2500 ms Windows may show closed ports as filtered (it waits about 2 s before reporting a refusal).' -ForegroundColor $script:Theme.Warn
    }

    Write-ScanWarning
    if ($Ask -eq 'on' -and -not (Confirm-PortScan 'Start the port scan?')) {
        Write-Host '  Cancelled.' -ForegroundColor $script:Theme.Dim
        Write-Host ''
        return
    }
    if ($probes -gt $script:SafeProbes) {
        Write-Host ''
        Write-Host ("  [!] Large scan: {0} checks, {1}." -f $probes, $estimateText) -ForegroundColor $script:Theme.Fire
        Write-Host '      This is very visible on the network. Tip: fewer ports or a lower -Timeout.' -ForegroundColor $script:Theme.Warn
        if ($Ask -eq 'on' -and -not (Confirm-PortScan 'Are you sure?')) {
            Write-Host '  Cancelled.' -ForegroundColor $script:Theme.Dim
            Write-Host ''
            return
        }
    }

    # --- scan ---------------------------------------------------------------
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $results = Invoke-PortProbes -Hosts $targets.Hosts -Ports $portList.Ports -Timeout $Timeout
    $banners = @{}
    $openResults = @($results | Where-Object { $_.State -eq 'open' })
    if ($Banner -eq 'on' -and $openResults.Count -gt 0) {
        Write-Host ''
        Write-Host '  Reading banners of open services...' -ForegroundColor $script:Theme.Muted
        $banners = Get-Banners -OpenResults $openResults -Timeout $Timeout
    }
    $watch.Stop()

    # --- results ------------------------------------------------------------
    if ($targets.Single) {
        Write-SingleHost -Label $targets.Label -Results $results -Banners $banners -Show $Show
    } else {
        Write-Host ''
        Write-Host ("  {0}" -f $targets.Label) -ForegroundColor $script:Theme.Title
        if ($portList.Ports.Count -le $script:GridPorts) {
            $alive = Write-HostGrid -Results $results -Ports $portList.Ports
            $silent = $hostCount - $alive
            if ($alive -eq 0) { Write-Host '     no host answered on these ports' -ForegroundColor $script:Theme.Dim }
            Write-Host ''
            Write-Host ("  {0} host(s) answered, {1} gave no answer at all (down, or everything filtered)." -f $alive, $silent) -ForegroundColor $script:Theme.Muted
        } else {
            Write-Host ''
            $info = Write-HostList -Results $results
            if ($info.Shown -eq 0) { Write-Host '     no open ports found' -ForegroundColor $script:Theme.Dim }
            $silent = $info.Total - $info.Shown - $info.UpNothingOpen
            Write-Host ''
            Write-Host ("  {0} host(s) with open ports, {1} up but nothing open, {2} no answer at all." -f $info.Shown, $info.UpNothingOpen, $silent) -ForegroundColor $script:Theme.Muted
        }
        $risky = @($openResults | Where-Object { (Get-ServiceInfo $_.Port).Risk } | ForEach-Object { $_.Port } | Sort-Object -Unique)
        if ($risky.Count -gt 0) {
            Write-Host ("  [!] Open ports with a risk note: {0}. Details: scan one host." -f ($risky -join ', ')) -ForegroundColor $script:Theme.Warn
        }
    }

    Write-Host ("  Done in {0:0.0} s." -f $watch.Elapsed.TotalSeconds) -ForegroundColor $script:Theme.Dim
    Write-Host ''
    Write-Host ("  {0} open: a service answers   {1} closed: refused, nothing listens   {2} filtered: no answer, firewall" -f $s.Open, $s.Closed, $s.Filtered) -ForegroundColor $script:Theme.Dim

    # --- export -------------------------------------------------------------
    $path = ''
    $exportValue = [string]$Export
    if ($exportValue -eq 'ask') {
        if ($Ask -eq 'on') {
            Write-Host ''
            if (Confirm-PortScan 'Export the results to CSV?') {
                $default = Get-DefaultExportPath
                Write-Host ("      File [{0}]: " -f $default) -ForegroundColor $script:Theme.Text -NoNewline
                $typed = Read-Host
                if ($null -ne $typed -and $typed.Trim()) { $path = $typed.Trim().Trim('"') } else { $path = $default }
            }
        }
    } elseif ($exportValue -ne 'off' -and $exportValue) {
        $path = $exportValue.Trim('"')
    }
    if ($path) {
        if ($path -notmatch '\.csv$') { $path = "$path.csv" }
        try {
            $count = Export-PortResults -Results $results -Banners $banners -Path $path -Show $Show
            if ($count -eq 0) {
                Write-Host '  [*] No open ports, so no CSV written. Use -Show all to export every port.' -ForegroundColor $script:Theme.Muted
            } else {
                $full = $path
                try { $full = (Resolve-Path -LiteralPath $path).Path } catch { }
                $what = 'open ports'
                if ($Show -eq 'all') { $what = 'ports (open, closed and filtered)' }
                Write-Host ("  [*] {0} {1} written to {2}" -f $count, $what, $full) -ForegroundColor $script:Theme.Ok
            }
        } catch {
            Write-Host ("  [x] Could not write the CSV: {0}" -f $_.Exception.Message) -ForegroundColor $script:Theme.Fire
        }
    }
    Write-Host ''
}

Export-ModuleMember -Function 'Invoke-NRPortScan'
