# NetRing module: WebExplain
# Shows step by step what happens when you open a website:
#   [1] DNS   name -> IP address
#   [2] TCP   three-way handshake
#   [3] TLS   encryption and the certificate chain
#   [4] HTTP  the request and the answer
# followed by a timeline, and the same again for every redirect.
#
# Works on Windows PowerShell 5.1 and PowerShell 7. Uses plain .NET sockets,
# so every step is done (and timed) separately, like a browser does it.
# This file only contains ASCII characters: symbols are built with [char].

Set-StrictMode -Version 2.0

$script:Sym = @{
    H2    = [string][char]0x2550   # double line
    H     = [string][char]0x2500   # line
    Right = [string][char]0x25BA   # arrow right
    Left  = [string][char]0x25C4   # arrow left
    Arrow = [string][char]0x2192   # ->
    Tree  = [string][char]0x2514   # tree branch
    Full  = [string][char]0x2588   # bar
    Light = [string][char]0x2591   # empty bar
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
    Send  = 'Yellow'       # what we send
    Recv  = 'DarkYellow'   # what we receive
}

# One color per phase, used in the step headers and the timeline.
$script:PhaseColor = @{
    DNS  = 'Yellow'
    TCP  = 'DarkYellow'
    TLS  = 'White'
    HTTP = 'Red'
}

$script:MaxHops = 5
$script:TlsCapture = $null

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------

function Get-InnerMessage {
    # .NET wraps errors (AggregateException, MethodInvocationException); get the real one.
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    return $ex.Message
}

function ConvertTo-ExplainUri {
    param([string]$Url)
    $text = $Url.Trim()
    if ($text -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $text = "https://$text" }
    $uri = $null
    if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri)) {
        throw "'$Url' is not a valid website or URL."
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        throw "Only http:// and https:// are supported, not $($uri.Scheme)://."
    }
    return $uri
}

function Write-StepHeader {
    param([int]$Number, [string]$Phase, [string]$Title, [string]$Explain)
    Write-Host ''
    Write-Host ("  [{0}] " -f $Number) -ForegroundColor $script:Theme.Key -NoNewline
    Write-Host ("{0,-5}" -f $Phase) -ForegroundColor $script:PhaseColor[$Phase] -NoNewline
    Write-Host $Title -ForegroundColor $script:Theme.Text
    if ($Explain) { Write-Host ("      {0}" -f $Explain) -ForegroundColor $script:Theme.Dim }
}

function Write-StepTime {
    param([double]$Ms)
    Write-Host ("      Time      {0} ms" -f [math]::Round($Ms)) -ForegroundColor $script:Theme.Muted
}

function Write-Field {
    param([string]$Label, [string]$Value, [string]$Color = '', [string]$Note = '', [string]$NoteColor = '')
    if (-not $Color) { $Color = $script:Theme.Text }
    if (-not $NoteColor) { $NoteColor = $script:Theme.Dim }
    Write-Host ("      {0,-10}" -f $Label) -ForegroundColor $script:Theme.Muted -NoNewline
    Write-Host $Value -ForegroundColor $Color -NoNewline
    if ($Note) { Write-Host ("   {0}" -f $Note) -ForegroundColor $NoteColor } else { Write-Host '' }
}

function Write-StepError {
    param([string]$Message, [string]$Hint = '')
    Write-Host ("      [x] {0}" -f $Message) -ForegroundColor $script:Theme.Fire
    if ($Hint) { Write-Host ("          {0}" -f $Hint) -ForegroundColor $script:Theme.Dim }
}

# ----------------------------------------------------------------------------
# [1] DNS
# ----------------------------------------------------------------------------
# A computer looks a name up in this order: the hosts file, its own DNS cache,
# and only then a DNS server. We check each place so we can show where the
# answer really came from. To see which server answers, NetRing also sends
# its own DNS question over UDP port 53 (a tiny DNS client below).

function Get-ExplainHostName {
    param([Uri]$Uri)
    try { if ($Uri.IdnHost) { return $Uri.IdnHost } } catch { }
    return $Uri.DnsSafeHost
}

function Get-ExplainDnsServers {
    # The DNS servers of the adapter with the default route (Windows),
    # or the nameservers in /etc/resolv.conf (Linux, macOS).
    $list = @()
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object { [int]$_.RouteMetric } | Select-Object -First 1
        $list = @(Get-DnsClientServerAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
            ForEach-Object { $_.ServerAddresses })
    } catch { }
    if ($list.Count -eq 0 -and (Test-Path -LiteralPath '/etc/resolv.conf')) {
        try {
            foreach ($line in (Get-Content -LiteralPath '/etc/resolv.conf')) {
                if ($line -match '^\s*nameserver\s+(\d{1,3}(\.\d{1,3}){3})\s*$') { $list += $Matches[1] }
            }
        } catch { }
    }
    return $list
}

function Get-ServerNote {
    # Short explanation of what kind of DNS server an address probably is.
    param([string]$Address)
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) { return '' }
    $b = $ip.GetAddressBytes()
    if ($b[0] -eq 127) { return 'a resolver on your own computer' }
    if ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168)) {
        return 'private address: often your router or a school server, which passes the question on'
    }
    switch ($Address) {
        '8.8.8.8' { return 'Google Public DNS' }
        '8.8.4.4' { return 'Google Public DNS' }
        '1.1.1.1' { return 'Cloudflare DNS' }
        '1.0.0.1' { return 'Cloudflare DNS' }
        '9.9.9.9' { return 'Quad9 DNS' }
    }
    return 'public DNS server'
}

function Find-HostsEntry {
    # Returns the IPv4 address from the hosts file for this name, or ''.
    param([string]$Name)
    $paths = @()
    if ($env:SystemRoot) { $paths += (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') }
    $paths += '/etc/hosts'
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            foreach ($line in (Get-Content -LiteralPath $path)) {
                $clean = ($line -replace '#.*$', '').Trim()
                if (-not $clean) { continue }
                $parts = @($clean -split '\s+')
                if ($parts.Count -lt 2) { continue }
                $ip = $null
                if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ip)) { continue }
                if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                foreach ($n in ($parts | Select-Object -Skip 1)) {
                    if ($n -eq $Name) { return @{ Address = $parts[0]; Path = $path } }
                }
            }
        } catch { }
    }
    return $null
}

function Get-DnsCacheHit {
    # Windows only: what the DNS Client cache knows about this name, or $null.
    # Returns @{ Addresses; Cnames; Ttl } ; $null when not cached or not available.
    param([string]$Name)
    if (-not (Get-Command Get-DnsClientCache -ErrorAction SilentlyContinue)) { return $null }
    try {
        $entries = @(Get-DnsClientCache -Entry $Name -ErrorAction SilentlyContinue |
            Where-Object { [int]$_.Status -eq 0 })
    } catch { return $null }
    if ($entries.Count -eq 0) { return $null }
    $hit = @{ Addresses = @(); Cnames = @(); Ttl = $null }
    foreach ($e in $entries) {
        $type = [int]$e.Type
        if ($type -eq 1) {
            $hit.Addresses += [string]$e.Data
            if ($null -eq $hit.Ttl) { $hit.Ttl = [int]$e.TimeToLive }
        } elseif ($type -eq 5) {
            $hit.Cnames += ("{0} {1} {2}" -f $e.Name, $script:Sym.Arrow, $e.Data)
        }
    }
    if ($hit.Addresses.Count -eq 0) { return $null }
    return $hit
}

# --- a tiny DNS client (UDP port 53) -----------------------------------------

function New-DnsQuery {
    # Builds a DNS question: "which A record (IPv4) has this name?"
    param([string]$Name, [int]$Id)
    $bytes = New-Object System.Collections.Generic.List[byte]
    $bytes.Add([byte](($Id -shr 8) -band 0xFF))
    $bytes.Add([byte]($Id -band 0xFF))
    foreach ($b in @(0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0)) { $bytes.Add([byte]$b) }   # recursion desired, 1 question
    foreach ($label in $Name.TrimEnd('.').Split('.')) {
        $labelBytes = [System.Text.Encoding]::ASCII.GetBytes($label)
        $bytes.Add([byte]$labelBytes.Length)
        $bytes.AddRange($labelBytes)
    }
    foreach ($b in @(0, 0, 1, 0, 1)) { $bytes.Add([byte]$b) }   # end of name, type A, class IN
    return , $bytes.ToArray()
}

function Read-DnsName {
    # Reads a name from a DNS message, following compression pointers.
    param([byte[]]$Data, [int]$Offset)
    $labels = @()
    $pos = $Offset
    $next = -1
    $jumps = 0
    while ($true) {
        if ($pos -ge $Data.Length) { throw 'damaged DNS answer' }
        $len = [int]$Data[$pos]
        if ($len -eq 0) { $pos++; break }
        if (($len -band 0xC0) -eq 0xC0) {
            if ($next -lt 0) { $next = $pos + 2 }
            $pos = (($len -band 0x3F) -shl 8) -bor [int]$Data[$pos + 1]
            $jumps++
            if ($jumps -gt 30) { throw 'damaged DNS answer' }
            continue
        }
        $labels += [System.Text.Encoding]::ASCII.GetString($Data, $pos + 1, $len)
        $pos += 1 + $len
    }
    if ($next -lt 0) { $next = $pos }
    return @{ Name = ($labels -join '.'); Next = $next }
}

function Read-DnsResponse {
    param([byte[]]$Data)
    if ($Data.Length -lt 12) { throw 'DNS answer too short' }
    $flags = ([int]$Data[2] -shl 8) -bor [int]$Data[3]
    $qdCount = ([int]$Data[4] -shl 8) -bor [int]$Data[5]
    $anCount = ([int]$Data[6] -shl 8) -bor [int]$Data[7]
    $response = @{
        Authoritative = (($flags -band 0x0400) -ne 0)
        RCode         = ($flags -band 0x000F)
        Addresses     = @()
        Cnames        = @()
        Ttl           = $null
        From          = ''
        Ms            = 0.0
    }
    $pos = 12
    for ($i = 0; $i -lt $qdCount; $i++) { $pos = (Read-DnsName $Data $pos).Next + 4 }
    for ($i = 0; $i -lt $anCount; $i++) {
        $owner = Read-DnsName $Data $pos
        $pos = $owner.Next
        $type = ([int]$Data[$pos] -shl 8) -bor [int]$Data[$pos + 1]
        $ttl = ([int64]$Data[$pos + 4] -shl 24) -bor ([int64]$Data[$pos + 5] -shl 16) -bor ([int64]$Data[$pos + 6] -shl 8) -bor [int64]$Data[$pos + 7]
        $rdLength = ([int]$Data[$pos + 8] -shl 8) -bor [int]$Data[$pos + 9]
        $rd = $pos + 10
        if ($type -eq 1 -and $rdLength -eq 4) {
            $response.Addresses += ("{0}.{1}.{2}.{3}" -f $Data[$rd], $Data[$rd + 1], $Data[$rd + 2], $Data[$rd + 3])
            if ($null -eq $response.Ttl) { $response.Ttl = $ttl }
        } elseif ($type -eq 5) {
            $response.Cnames += ("{0} {1} {2}" -f $owner.Name, $script:Sym.Arrow, (Read-DnsName $Data $rd).Name)
        }
        $pos = $rd + $rdLength
    }
    return $response
}

function Invoke-DnsQuery {
    # Sends one DNS question to a server and returns the parsed answer.
    param([string]$Server, [string]$Name, [int]$Timeout)

    $id = Get-Random -Minimum 1 -Maximum 65535
    $query = New-DnsQuery -Name $Name -Id $id
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $Timeout
        $target = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($Server), 53)
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        [void]$udp.Send($query, $query.Length, $target)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        while ($true) {
            try {
                $data = $udp.Receive([ref]$remote)
            } catch {
                throw ("no answer within {0} ms" -f $Timeout)
            }
            $rid = ([int]$data[0] -shl 8) -bor [int]$data[1]
            if ($data.Length -ge 12 -and $rid -eq $id) { break }
            if ($watch.ElapsedMilliseconds -gt $Timeout) { throw ("no answer within {0} ms" -f $Timeout) }
        }
        $watch.Stop()
        $answer = Read-DnsResponse -Data $data
        $answer.From = $remote.Address.ToString()
        $answer.Ms = $watch.Elapsed.TotalMilliseconds
        return $answer
    } finally {
        $udp.Dispose()
    }
}

function Get-RCodeText {
    param([int]$RCode)
    switch ($RCode) {
        1 { return 'FORMERR: the server did not understand the question' }
        2 { return 'SERVFAIL: the server could not find an answer' }
        3 { return 'NXDOMAIN: this name does not exist' }
        5 { return 'REFUSED: the server does not want to answer you' }
        default { return "error code $RCode" }
    }
}

function Write-DnsServerAnswer {
    # Shows who answered and what. Returns $true when there is an IPv4 address.
    param($Answer)
    $who = 'not authoritative: a resolver that looked it up for you (or had it cached)'
    if ($Answer.Authoritative) { $who = 'authoritative: the server that manages this domain itself' }
    Write-Field 'Answered' $Answer.From $script:Theme.Key $who
    if ($Answer.RCode -ne 0) {
        Write-StepError ("The DNS server says {0}." -f (Get-RCodeText $Answer.RCode))
        return $false
    }
    foreach ($c in $Answer.Cnames) { Write-Field 'CNAME' $c '' 'alias: the name points to another name' }
    if (@($Answer.Addresses).Count -eq 0) {
        Write-StepError 'The answer contains no IPv4 address.' 'NetRing only follows IPv4 for now.'
        return $false
    }
    $note = ''
    if ($null -ne $Answer.Ttl) { $note = "TTL $($Answer.Ttl) s: may be cached that long" }
    Write-Field 'Answer' (@($Answer.Addresses) -join ', ') $script:Theme.Key $note
    return $true
}

function Write-DnsSource {
    param([string]$Text, [string]$Note = '')
    Write-Field 'Source' $Text $script:Theme.Ok $Note
}

function Resolve-ViaOs {
    # What a browser does: ask the operating system. Returns @{ Addresses; Cnames; Ttl; Ms }
    param([string]$Name, [int]$Timeout)
    $out = @{ Addresses = @(); Cnames = @(); Ttl = $null; Ms = 0.0 }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        $records = @(Resolve-DnsName -Name $Name -Type A -ErrorAction Stop)
        $watch.Stop()
        foreach ($r in $records) {
            if ([string]$r.Type -eq 'CNAME') { $out.Cnames += ("{0} {1} {2}" -f $r.Name, $script:Sym.Arrow, $r.NameHost) }
            elseif ([string]$r.Type -eq 'A') {
                $out.Addresses += [string]$r.IPAddress
                if ($null -eq $out.Ttl) { $out.Ttl = [int]$r.TTL }
            }
        }
    } else {
        $task = [System.Net.Dns]::GetHostAddressesAsync($Name)
        if (-not $task.Wait($Timeout)) { throw 'no answer in time' }
        $watch.Stop()
        $out.Addresses = @($task.Result |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            ForEach-Object { $_.ToString() })
    }
    $out.Ms = $watch.Elapsed.TotalMilliseconds
    return $out
}

function Invoke-ExplainDns {
    # Returns @{ Ok; Address; Ms }
    param([Uri]$Uri, [int]$Timeout, [string]$DnsServer = '')

    $result = @{ Ok = $false; Address = $null; Ms = 0.0 }
    $hostName = Get-ExplainHostName $Uri

    $literal = $null
    if ([System.Net.IPAddress]::TryParse($hostName, [ref]$literal)) {
        Write-StepHeader 1 'DNS' 'Name to IP address' 'Not needed: the URL already contains an IP address.'
        $result.Ok = $true
        $result.Address = $literal
        return $result
    }

    # --- a DNS server chosen with -DnsServer: ask it directly -----------------
    if ($DnsServer) {
        Write-StepHeader 1 'DNS' 'Name to IP address' 'NetRing asks the chosen DNS server directly; the hosts file and local cache are skipped.'
        Write-Field 'Question' ("Which IPv4 address has {0}?" -f $hostName)
        Write-Field 'Asked' ("{0} port 53 (UDP)" -f $DnsServer) '' (Get-ServerNote $DnsServer)
        try {
            $answer = Invoke-DnsQuery -Server $DnsServer -Name $hostName -Timeout $Timeout
        } catch {
            Write-StepError ("No answer from {0}: {1}" -f $DnsServer, (Get-InnerMessage $_)) 'Is it a DNS server? Some networks block DNS to outside servers.'
            return $result
        }
        if (-not (Write-DnsServerAnswer $answer)) { return $result }
        Write-DnsSource ("DNS server {0}" -f $answer.From) 'chosen with -DnsServer'
        $result.Ms = $answer.Ms
        Write-StepTime $result.Ms
        $result.Ok = $true
        $result.Address = [System.Net.IPAddress]::Parse(@($answer.Addresses)[0])
        return $result
    }

    # --- the normal way: hosts file, cache, then a DNS server ----------------
    Write-StepHeader 1 'DNS' 'Name to IP address' 'Your computer looks in the hosts file, then in its DNS cache, and only then asks a DNS server.'
    Write-Field 'Question' ("Which IPv4 address has {0}?" -f $hostName)

    # 1. hosts file
    $hosts = Find-HostsEntry -Name $hostName
    if ($hosts) {
        Write-Field 'hosts' ("listed: {0}" -f $hosts.Address) $script:Theme.Key $hosts.Path
        Write-DnsSource 'hosts file on your computer' 'no DNS server was asked'
        $result.Ok = $true
        $result.Address = [System.Net.IPAddress]::Parse($hosts.Address)
        return $result
    }
    Write-Field 'hosts' 'not listed' $script:Theme.Dim
    if ($hostName -eq 'localhost' -or $hostName -like '*.localhost') {
        Write-DnsSource 'your own computer' 'localhost always means 127.0.0.1'
        $result.Ok = $true
        $result.Address = [System.Net.IPAddress]::Loopback
        return $result
    }

    # 2. local DNS cache (checked BEFORE resolving, because resolving fills it)
    $cacheKnown = [bool](Get-Command Get-DnsClientCache -ErrorAction SilentlyContinue)
    $cached = $null
    if ($cacheKnown) { $cached = Get-DnsCacheHit -Name $hostName }

    # What the browser really gets: ask the operating system.
    try {
        $os = Resolve-ViaOs -Name $hostName -Timeout $Timeout
    } catch {
        if ($cacheKnown) { Write-Field 'Cache' 'not in the local DNS cache' $script:Theme.Dim }
        Write-StepError ("No answer: {0}" -f (Get-InnerMessage $_)) 'Check the name, or your DNS server. Without an IP address the browser cannot go on.'
        return $result
    }
    $result.Ms = $os.Ms
    if (@($os.Addresses).Count -eq 0) {
        Write-StepError 'The name exists, but has no IPv4 address.' 'NetRing only follows IPv4 for now.'
        return $result
    }
    $result.Address = [System.Net.IPAddress]::Parse(@($os.Addresses)[0])
    $result.Ok = $true

    if ($cached) {
        Write-Field 'Cache' ("found: {0}" -f ($cached.Addresses -join ', ')) $script:Theme.Key ("still valid for {0} s" -f $cached.Ttl)
        foreach ($c in $cached.Cnames) { Write-Field 'CNAME' $c '' 'alias: the name points to another name' }
        Write-DnsSource 'local DNS cache of your computer' 'no DNS server was asked: it was looked up earlier'
        Write-StepTime $result.Ms
        return $result
    }
    if ($cacheKnown) {
        Write-Field 'Cache' 'not in the local DNS cache' $script:Theme.Dim
    } else {
        Write-Field 'Cache' 'this system does not show its DNS cache' $script:Theme.Dim
    }

    # 3. a DNS server: find out which one answers by asking them in order,
    #    the same order your computer uses.
    $servers = @(Get-ExplainDnsServers)
    $answer = $null
    foreach ($server in $servers) {
        Write-Field 'Asked' ("{0} port 53 (UDP)" -f $server) '' (Get-ServerNote $server)
        try {
            $answer = Invoke-DnsQuery -Server $server -Name $hostName -Timeout $Timeout
            break
        } catch {
            Write-Field '' ("no answer: {0}, trying the next one" -f (Get-InnerMessage $_)) $script:Theme.Warn
        }
    }

    if ($answer -and $answer.RCode -eq 0 -and @($answer.Addresses).Count -gt 0) {
        [void](Write-DnsServerAnswer $answer)
        Write-DnsSource ("DNS server {0}" -f $answer.From)
    } else {
        # The server could not confirm it: show what the operating system found.
        if ($answer) { [void](Write-DnsServerAnswer $answer) }
        foreach ($c in $os.Cnames) { Write-Field 'CNAME' $c '' 'alias: the name points to another name' }
        $note = ''
        if ($null -ne $os.Ttl) { $note = "TTL $($os.Ttl) s" }
        Write-Field 'Answer' (@($os.Addresses) -join ', ') $script:Theme.Key $note
        Write-DnsSource 'your operating system' 'found it another way (local name, VPN or a DNS server NetRing cannot reach)'
    }
    Write-StepTime $result.Ms
    return $result
}

# ----------------------------------------------------------------------------
# [2] TCP
# ----------------------------------------------------------------------------

function Invoke-ExplainTcp {
    # Returns @{ Ok; Client; Ms }
    param([System.Net.IPAddress]$Address, [int]$Port, [int]$Timeout)

    $result = @{ Ok = $false; Client = $null; Ms = 0.0 }
    Write-StepHeader 2 'TCP' ("Three-way handshake to port {0}" -f $Port) 'Before any data is sent, both sides agree to talk: SYN, SYN-ACK, ACK.'

    $client = New-Object System.Net.Sockets.TcpClient($Address.AddressFamily)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $task = $client.ConnectAsync($Address, $Port)
        if (-not $task.Wait($Timeout)) {
            $client.Dispose()
            Write-StepError ("No answer within {0} ms." -f $Timeout) 'A firewall drops the packets, or the server is down.'
            return $result
        }
        $watch.Stop()
    } catch {
        $watch.Stop()
        $client.Dispose()
        Write-StepError ("Connection failed: {0}" -f (Get-InnerMessage $_)) ("'Refused' means the server is there, but nothing listens on port {0}." -f $Port)
        return $result
    }
    $result.Ms = $watch.Elapsed.TotalMilliseconds

    $s = $script:Sym
    $local = $client.Client.LocalEndPoint
    $you = ("YOU     {0}:{1}" -f $local.Address, $local.Port)
    $server = ("SERVER  {0}:{1}" -f $Address, $Port)
    $wire = 34
    Write-Host ("      {0,-38}{1}" -f $you, $server) -ForegroundColor $script:Theme.Muted
    Write-Host ("              {0}{0}{0}{0} SYN {1}{2}" -f $s.H, ($s.H * ($wire - 9)), $s.Right) -ForegroundColor $script:Theme.Send
    Write-Host ("              {0}{1}{1}{1} SYN-ACK {2}" -f $s.Left, $s.H, ($s.H * ($wire - 12))) -ForegroundColor $script:Theme.Recv
    Write-Host ("              {0}{0}{0}{0} ACK {1}{2}" -f $s.H, ($s.H * ($wire - 9)), $s.Right) -ForegroundColor $script:Theme.Send
    Write-Field 'Result' 'Connection open' $script:Theme.Ok ("your port {0} is picked at random by the OS" -f $local.Port)
    Write-StepTime $result.Ms

    $result.Ok = $true
    $result.Client = $client
    return $result
}

# ----------------------------------------------------------------------------
# [3] TLS
# ----------------------------------------------------------------------------

function Get-CertName {
    # "CN=www.vibo.be, O=..." -> "www.vibo.be"
    param($Cert)
    $name = ''
    try { $name = $Cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } catch { }
    if (-not $name) { $name = [string]$Cert.Subject }
    return $name
}

function Format-TlsProtocol {
    param([string]$Protocol)
    switch -Regex ($Protocol) {
        '^Tls13$' { return 'TLS 1.3' }
        '^Tls12$' { return 'TLS 1.2' }
        '^Tls11$' { return 'TLS 1.1 (outdated)' }
        '^Tls$'   { return 'TLS 1.0 (outdated)' }
        '^Ssl3$'  { return 'SSL 3.0 (insecure)' }
        default   { return $Protocol }
    }
}

function Invoke-ExplainTls {
    # Returns @{ Ok; Stream; Ms }
    param($Client, [string]$HostName, [int]$Timeout)

    $result = @{ Ok = $false; Stream = $null; Ms = 0.0 }
    Write-StepHeader 3 'TLS' 'Encryption and identity check' 'Client and server agree on keys, and the server proves who it is with a certificate.'

    $script:TlsCapture = @{ Errors = 'None'; Chain = @() }
    $callback = [System.Net.Security.RemoteCertificateValidationCallback] {
        param($sender, $certificate, $chain, $errors)
        $script:TlsCapture.Errors = [string]$errors
        $list = @()
        if ($chain) {
            foreach ($element in $chain.ChainElements) {
                $list += New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($element.Certificate)
            }
        }
        $script:TlsCapture.Chain = $list
        return $true   # accept, so we can show the problem instead of only failing
    }

    $netStream = $Client.GetStream()
    $netStream.ReadTimeout = $Timeout
    $netStream.WriteTimeout = $Timeout
    $ssl = New-Object System.Net.Security.SslStream($netStream, $false, $callback)

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # SslProtocols.None = let the operating system pick the best version.
        $ssl.AuthenticateAsClient($HostName, $null, [System.Security.Authentication.SslProtocols]::None, $false)
        $watch.Stop()
    } catch {
        $watch.Stop()
        Write-StepError ("Handshake failed: {0}" -f (Get-InnerMessage $_)) 'The server does not speak TLS on this port, or uses a version your system refuses.'
        return $result
    }
    $result.Ms = $watch.Elapsed.TotalMilliseconds

    Write-Field 'Protocol' (Format-TlsProtocol ([string]$ssl.SslProtocol)) $script:Theme.Key
    $cipher = ''
    try { $cipher = [string]$ssl.NegotiatedCipherSuite } catch {
        $cipher = ("{0} {1}-bit, {2}, key exchange {3}" -f $ssl.CipherAlgorithm, $ssl.CipherStrength, $ssl.HashAlgorithm, $ssl.KeyExchangeAlgorithm)
    }
    Write-Field 'Cipher' $cipher

    # The certificate chain, from the root down to the server.
    $chain = @($script:TlsCapture.Chain)
    $leaf = $null
    if ($ssl.RemoteCertificate) {
        $leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
    }
    if ($chain.Count -eq 0 -and $leaf) { $chain = @($leaf) }

    Write-Host '      Certificate chain' -ForegroundColor $script:Theme.Muted
    $ordered = @($chain)
    [array]::Reverse($ordered)
    $depth = 0
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $cert = $ordered[$i]
        $role = 'intermediate'
        if ($i -eq 0 -and $ordered.Count -gt 1) { $role = 'root, trusted by your computer' }
        if ($i -eq $ordered.Count - 1) { $role = 'the server itself' }
        if ($ordered.Count -eq 1) { $role = 'the server itself, no chain' }
        $prefix = '        '
        if ($depth -gt 0) { $prefix = ('        ' + ('   ' * ($depth - 1)) + $script:Sym.Tree + $script:Sym.H + ' ') }
        $name = Get-CertName $cert
        Write-Host $prefix -ForegroundColor $script:Theme.Title -NoNewline
        Write-Host ("{0,-34}" -f $name) -ForegroundColor $script:Theme.Text -NoNewline
        Write-Host $role -ForegroundColor $script:Theme.Dim
        $depth++
    }

    if ($leaf) {
        $now = Get-Date
        $days = [int][math]::Floor(($leaf.NotAfter - $now).TotalDays)
        $validColor = $script:Theme.Ok
        $validNote = "$days days left"
        if ($days -lt 0) { $validColor = $script:Theme.Fire; $validNote = 'EXPIRED' }
        elseif ($days -lt 14) { $validColor = $script:Theme.Warn; $validNote = "only $days days left" }
        Write-Field 'Valid' ("{0:yyyy-MM-dd} until {1:yyyy-MM-dd}" -f $leaf.NotBefore, $leaf.NotAfter) $validColor $validNote $validColor

        $san = $leaf.Extensions | Where-Object { $_.Oid -and $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
        if ($san) {
            $names = @(($san.Format($false) -split ',\s*') | ForEach-Object { ($_ -replace '^[^=:]+[=:]', '').Trim() } | Where-Object { $_ })
            $shown = ($names | Select-Object -First 4) -join ', '
            if ($names.Count -gt 4) { $shown += (" and {0} more" -f ($names.Count - 4)) }
            Write-Field 'Names' $shown '' 'names this certificate is valid for'
        }
    }

    $errors = [string]$script:TlsCapture.Errors
    if ($errors -eq 'None') {
        Write-Field 'Check' ("[ok] Trusted certificate, valid for {0}" -f $HostName) $script:Theme.Ok
    } else {
        $reasons = @()
        if ($errors -match 'RemoteCertificateNameMismatch') { $reasons += "not made for $HostName" }
        if ($errors -match 'RemoteCertificateChainErrors') { $reasons += 'chain not trusted (self-signed, expired or unknown CA)' }
        if ($errors -match 'RemoteCertificateNotAvailable') { $reasons += 'no certificate sent' }
        Write-Field 'Check' ("[!] A browser would show a warning: {0}" -f ($reasons -join '; ')) $script:Theme.Fire
    }
    Write-StepTime $result.Ms

    $result.Ok = $true
    $result.Stream = $ssl
    return $result
}

# ----------------------------------------------------------------------------
# [4] HTTP
# ----------------------------------------------------------------------------

$script:StatusText = @{
    200 = 'OK: here is the page'
    204 = 'No content'
    301 = 'Moved permanently: go to Location'
    302 = 'Found: temporarily somewhere else'
    303 = 'See other: go to Location'
    304 = 'Not modified: use your cached copy'
    307 = 'Temporary redirect'
    308 = 'Permanent redirect'
    400 = 'Bad request'
    401 = 'Login required'
    403 = 'Forbidden: you may not see this'
    404 = 'Not found'
    405 = 'Method not allowed'
    429 = 'Too many requests'
    500 = 'Server error'
    502 = 'Bad gateway: a server behind this one failed'
    503 = 'Service unavailable'
    504 = 'Gateway timeout'
}

$script:HeaderNotes = [ordered]@{
    'location'                  = 'where to go next'
    'server'                    = 'software of the web server'
    'content-type'              = 'kind of content'
    'strict-transport-security' = 'browser must always use HTTPS here'
    'content-security-policy'   = 'limits which scripts may run'
    'x-frame-options'           = 'protects against clickjacking'
    'set-cookie'                = 'the server stores a cookie'
    'cache-control'             = 'how long the page may be cached'
    'alt-svc'                   = 'also reachable over another protocol (e.g. HTTP/3)'
}

function Read-HttpHead {
    # Reads from the stream until the end of the headers (empty line).
    # Returns @{ Text; FirstByteMs } ; the body is not needed.
    param($Stream, [System.Diagnostics.Stopwatch]$Watch)

    $buffer = New-Object byte[] 4096
    $data = New-Object System.Collections.Generic.List[byte]
    $firstByte = $null
    while ($data.Count -lt 65536) {
        $n = $Stream.Read($buffer, 0, $buffer.Length)
        if ($n -le 0) { break }
        if ($null -eq $firstByte) { $firstByte = $Watch.Elapsed.TotalMilliseconds }
        for ($i = 0; $i -lt $n; $i++) { $data.Add($buffer[$i]) }
        $text = [System.Text.Encoding]::ASCII.GetString($data.ToArray())
        if ($text.Contains("`r`n`r`n")) { break }
    }
    $all = [System.Text.Encoding]::ASCII.GetString($data.ToArray())
    $end = $all.IndexOf("`r`n`r`n")
    if ($end -ge 0) { $all = $all.Substring(0, $end) }
    return @{ Text = $all; FirstByteMs = $firstByte }
}

function Invoke-ExplainHttp {
    # Returns @{ Ok; Status; Location; Ms }
    param($Stream, [Uri]$Uri, [int]$Timeout)

    $result = @{ Ok = $false; Status = 0; Location = ''; Ms = 0.0 }
    Write-StepHeader 4 'HTTP' 'Request and response' 'The browser asks for the page; the server answers with a status code and headers.'

    $path = $Uri.PathAndQuery
    if (-not $path) { $path = '/' }
    $request = "GET $path HTTP/1.1`r`nHost: $($Uri.Authority)`r`nUser-Agent: NetRing/0.1 (PowerShell)`r`nAccept: */*`r`nConnection: close`r`n`r`n"

    foreach ($line in @("GET $path HTTP/1.1", "Host: $($Uri.Authority)")) {
        Write-Host '      >> ' -ForegroundColor $script:Theme.Send -NoNewline
        Write-Host $line -ForegroundColor $script:Theme.Text
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($request)
        $Stream.Write($bytes, 0, $bytes.Length)
        $Stream.Flush()
        $head = Read-HttpHead -Stream $Stream -Watch $watch
        $watch.Stop()
    } catch {
        $watch.Stop()
        Write-StepError ("No answer: {0}" -f (Get-InnerMessage $_)) 'The server accepted the connection but did not answer in time.'
        return $result
    }
    $result.Ms = $watch.Elapsed.TotalMilliseconds

    $lines = @($head.Text -split "`r`n" | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0 -or $lines[0] -notmatch '^HTTP/\S+\s+(\d{3})') {
        Write-StepError 'The answer is not HTTP.' 'Maybe this port speaks another protocol, or needs https://.'
        return $result
    }
    $status = [int]$Matches[1]
    $result.Status = $status

    $statusColor = $script:Theme.Ok
    if ($status -ge 300 -and $status -lt 400) { $statusColor = $script:Theme.Key }
    if ($status -ge 400) { $statusColor = $script:Theme.Fire }
    $statusNote = ''
    if ($script:StatusText.ContainsKey($status)) { $statusNote = $script:StatusText[$status] }
    Write-Host '      << ' -ForegroundColor $script:Theme.Recv -NoNewline
    Write-Host $lines[0] -ForegroundColor $statusColor -NoNewline
    Write-Host ("   {0}" -f $statusNote) -ForegroundColor $script:Theme.Dim

    # Headers: show the interesting ones, with a short explanation.
    $headers = @{}
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        $colon = $line.IndexOf(':')
        if ($colon -le 0) { continue }
        $name = $line.Substring(0, $colon).Trim().ToLowerInvariant()
        $value = $line.Substring($colon + 1).Trim()
        if (-not $headers.ContainsKey($name)) { $headers[$name] = New-Object System.Collections.Generic.List[string] }
        $headers[$name].Add($value)
    }
    foreach ($name in $script:HeaderNotes.Keys) {
        if (-not $headers.ContainsKey($name)) { continue }
        $value = $headers[$name][0]
        if ($name -eq 'set-cookie') { $value = ("{0} cookie(s)" -f $headers[$name].Count) }
        if ($value.Length -gt 60) { $value = $value.Substring(0, 57) + '...' }
        $display = (Get-Culture).TextInfo.ToTitleCase($name)
        Write-Host '      << ' -ForegroundColor $script:Theme.Recv -NoNewline
        Write-Host ("{0}: " -f $display) -ForegroundColor $script:Theme.Muted -NoNewline
        Write-Host $value -ForegroundColor $script:Theme.Text -NoNewline
        Write-Host ("   {0}" -f $script:HeaderNotes[$name]) -ForegroundColor $script:Theme.Dim
    }
    $hidden = @($headers.Keys | Where-Object { -not $script:HeaderNotes.Contains($_) }).Count
    if ($hidden -gt 0) { Write-Host ("      << ... and {0} other header(s)" -f $hidden) -ForegroundColor $script:Theme.Dim }

    if ($headers.ContainsKey('location')) { $result.Location = $headers['location'][0] }
    if ($null -ne $head.FirstByteMs) {
        Write-Field 'Waiting' ("{0} ms until the first byte" -f [math]::Round($head.FirstByteMs)) '' 'time the server needed to think'
    }
    Write-StepTime $result.Ms

    $result.Ok = $true
    return $result
}

# ----------------------------------------------------------------------------
# Timeline
# ----------------------------------------------------------------------------

function Write-ExplainTimeline {
    # Waterfall like the network tab of a browser: each phase starts where the previous ended.
    param($Phases)

    $total = 0.0
    foreach ($p in $Phases) { $total += $p.Ms }
    if ($total -le 0) { return }

    $width = 40
    $s = $script:Sym
    Write-Host ''
    Write-Host '  Timeline' -ForegroundColor $script:Theme.Title
    $start = 0.0
    foreach ($p in $Phases) {
        # Start and end are rounded the same way, so bars never overlap.
        $from = [int][math]::Round($start / $total * $width)
        $to = [int][math]::Round(($start + $p.Ms) / $total * $width)
        if ($from -ge $width) { $from = $width - 1 }
        $len = [math]::Max(1, $to - $from)
        if ($from + $len -gt $width) { $len = $width - $from }
        $after = $width - $from - $len
        Write-Host ("    {0,-5} " -f $p.Name) -ForegroundColor $script:PhaseColor[$p.Name] -NoNewline
        Write-Host ($s.Light * $from) -ForegroundColor $script:Theme.Dim -NoNewline
        Write-Host ($s.Full * $len) -ForegroundColor $script:PhaseColor[$p.Name] -NoNewline
        Write-Host ($s.Light * $after) -ForegroundColor $script:Theme.Dim -NoNewline
        Write-Host ("{0,7} ms" -f [math]::Round($p.Ms)) -ForegroundColor $script:Theme.Text
        $start += $p.Ms
    }
    Write-Host ("    {0,-5} {1}{2,7} ms" -f 'Total', (' ' * $width), [math]::Round($total)) -ForegroundColor $script:Theme.Key
}

# ----------------------------------------------------------------------------
# One full request
# ----------------------------------------------------------------------------

function Invoke-ExplainHop {
    # Runs DNS, TCP, TLS and HTTP for one URL. Returns @{ Status; Location }.
    param([Uri]$Uri, [int]$Timeout, [string]$DnsServer = '')

    $phases = New-Object System.Collections.Generic.List[object]
    $outcome = @{ Status = 0; Location = '' }
    $client = $null
    $stream = $null

    try {
        $dns = Invoke-ExplainDns -Uri $Uri -Timeout $Timeout -DnsServer $DnsServer
        if (-not $dns.Ok) { return $outcome }
        if ($dns.Ms -gt 0) { $phases.Add(@{ Name = 'DNS'; Ms = $dns.Ms }) }

        $tcp = Invoke-ExplainTcp -Address $dns.Address -Port $Uri.Port -Timeout $Timeout
        if (-not $tcp.Ok) { Write-ExplainTimeline $phases; return $outcome }
        $client = $tcp.Client
        $phases.Add(@{ Name = 'TCP'; Ms = $tcp.Ms })

        if ($Uri.Scheme -eq 'https') {
            $tls = Invoke-ExplainTls -Client $client -HostName $Uri.DnsSafeHost -Timeout $Timeout
            if (-not $tls.Ok) { Write-ExplainTimeline $phases; return $outcome }
            $stream = $tls.Stream
            $phases.Add(@{ Name = 'TLS'; Ms = $tls.Ms })
        } else {
            Write-StepHeader 3 'TLS' 'Skipped: http:// is not encrypted' ''
            Write-Host '      [!] Everything that follows travels as plain text: anyone on the' -ForegroundColor $script:Theme.Fire
            Write-Host '          network path can read and change it.' -ForegroundColor $script:Theme.Fire
            $stream = $client.GetStream()
            $stream.ReadTimeout = $Timeout
            $stream.WriteTimeout = $Timeout
        }

        $http = Invoke-ExplainHttp -Stream $stream -Uri $Uri -Timeout $Timeout
        if ($http.Ok) {
            $phases.Add(@{ Name = 'HTTP'; Ms = $http.Ms })
            $outcome.Status = $http.Status
            $outcome.Location = $http.Location
        }
        Write-ExplainTimeline $phases
    } finally {
        if ($stream) { try { $stream.Dispose() } catch { } }
        if ($client) { try { $client.Dispose() } catch { } }
    }
    return $outcome
}

# ----------------------------------------------------------------------------
# Exported tool
# ----------------------------------------------------------------------------

function Invoke-NRWebExplain {
    <#
    .SYNOPSIS
        Shows step by step what happens when you open a website.
    .EXAMPLE
        Invoke-NRWebExplain -Url www.vibo.be
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter(Position = 1)]
        [ValidateSet('on', 'off')]
        [string]$Follow = 'on',

        [Parameter(Position = 2)]
        [ValidateRange(500, 30000)]
        [int]$Timeout = 5000,

        [Parameter(Position = 3)]
        [string]$DnsServer = ''
    )

    if ($DnsServer) {
        $check = $null
        if (-not [System.Net.IPAddress]::TryParse($DnsServer, [ref]$check) -or
            $check.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "DnsServer must be an IPv4 address, for example 1.1.1.1"
        }
    }

    $uri = ConvertTo-ExplainUri -Url $Url
    $s = $script:Sym
    $visited = @{}

    for ($hop = 1; $hop -le $script:MaxHops; $hop++) {
        $title = "Explaining $($uri.AbsoluteUri)"
        if ($hop -gt 1) { $title = "Redirect $($hop - 1): $($uri.AbsoluteUri)" }
        Write-Host ''
        Write-Host ("  {0}" -f $title) -ForegroundColor $script:Theme.Key
        Write-Host ("  {0}" -f ($s.H2 * [math]::Min(76, $title.Length))) -ForegroundColor $script:Theme.Title
        $visited[$uri.AbsoluteUri] = $true

        $outcome = Invoke-ExplainHop -Uri $uri -Timeout $Timeout -DnsServer $DnsServer

        $isRedirect = ($outcome.Status -ge 300 -and $outcome.Status -lt 400 -and $outcome.Location)
        if (-not $isRedirect) { break }

        $next = $null
        try { $next = New-Object Uri($uri, $outcome.Location) } catch { break }
        if ($Follow -eq 'off') {
            Write-Host ''
            Write-Host ("  The server sends you on to {0}" -f $next.AbsoluteUri) -ForegroundColor $script:Theme.Muted
            Write-Host ("  Follow it with: explain {0}" -f $next.AbsoluteUri) -ForegroundColor $script:Theme.Dim
            break
        }
        if ($visited.ContainsKey($next.AbsoluteUri)) {
            Write-Host ''
            Write-Host '  [!] Redirect loop: this URL was already visited.' -ForegroundColor $script:Theme.Fire
            break
        }
        if ($hop -eq $script:MaxHops) {
            Write-Host ''
            Write-Host ("  [!] Stopped after {0} redirects." -f $script:MaxHops) -ForegroundColor $script:Theme.Warn
            break
        }
        if ($next.Scheme -notin @('http', 'https')) { break }

        Write-Host ''
        Write-Host ("  {0} The server sends the browser on: everything starts again for the new URL." -f $s.Arrow) -ForegroundColor $script:Theme.Muted
        $uri = $next
    }
    Write-Host ''
}

Export-ModuleMember -Function 'Invoke-NRWebExplain'
