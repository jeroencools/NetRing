@{
    Name         = 'NetScan'
    Version      = '0.1.0'
    Author       = 'NetRing'
    Description  = 'Who is on my network? Ping sweep plus ARP table, vendor, hostname and a guess of the device type.'
    Category     = 'discovery'      # key from Core/Categories.psd1
    MinPSVersion = '5.1'

    Tools = @(
        @{
            Name        = 'Who is on my network?'
            Alias       = 'scan'
            Command     = 'Invoke-NRNetScan'
            Description = 'Pings every address of your subnet and combines it with the ARP table, vendor and hostname. No port scan. Only scan networks you own or may scan.'
            Parameters  = @(
                @{ Name = 'Subnet';  Required = $false; Default = 'auto'; Description = 'Subnet (192.168.1.0/24), range (192.168.1.100-200) or one address; auto = your own subnet' }
                @{ Name = 'Timeout'; Required = $false; Default = 500;    Description = 'Ping timeout in ms (100-5000)' }
                @{ Name = 'Resolve'; Required = $false; Default = 'on';   Description = 'Look up hostnames: on or off' }
                @{ Name = 'Ask';     Required = $false; Default = 'on';   Description = 'Ask for confirmation before scanning: on or off' }
            )
            Examples    = @(
                'scan'
                'scan 192.168.56.0/24'
                'scan 192.168.1.100-192.168.1.200'
                'scan 192.168.1.100-150'
                'scan -Timeout 300 -Resolve off'
            )
        }
    )
}
