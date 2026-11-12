@{
    Name         = 'PortScan'
    Version      = '0.1.0'
    Author       = 'NetRing'
    Description  = 'TCP port scan of one host, a range or a subnet, with service explanations and CSV export.'
    Category     = 'services'       # key from Core/Categories.psd1
    MinPSVersion = '5.1'

    Tools = @(
        @{
            Name        = 'Port scan'
            Alias       = 'ports'
            Command     = 'Invoke-NRPortScan'
            Description = 'Which TCP ports are open, closed or filtered? Only scan hosts you own or may scan.'
            Parameters  = @(
                @{ Name = 'Target';  Required = $true;                    Description = 'Host, IP, range (192.168.1.10-20) or subnet (192.168.1.0/24)' }
                @{ Name = 'Ports';   Required = $false; Default = 'top';   Description = 'Port, list, range or preset: top, web, windows, mail, remote, all' }
                @{ Name = 'Timeout'; Required = $false; Default = 2500;    Description = 'Timeout per port in ms (200-10000). Below 2500 Windows shows closed ports as filtered' }
                @{ Name = 'Banner';  Required = $false; Default = 'off';   Description = 'Read the first line of open services: on or off' }
                @{ Name = 'Show';    Required = $false; Default = 'open';  Description = 'open = only open ports, all = also closed and filtered (on screen and in the CSV)' }
                @{ Name = 'Ask';     Required = $false; Default = 'on';    Description = 'Ask for confirmation: on or off' }
                @{ Name = 'Export';  Required = $false; Default = 'ask';   Description = 'CSV export: ask, off, or a file path' }
            )
            Examples    = @(
                'ports 192.168.1.10'
                'ports 192.168.1.10 22,80,443'
                'ports 192.168.1.10 1-1024 -Banner on'
                'ports 192.168.1.0/24 3389'
                'ports 192.168.1.100-150 windows -Export C:\Temp\scan.csv'
            )
        }
    )
}
