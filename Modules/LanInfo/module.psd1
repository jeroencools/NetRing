@{
    Name         = 'LanInfo'
    Version      = '0.1.0'
    Author       = 'NetRing'
    Description  = 'Overview of the local network configuration of every adapter.'
    Category     = 'local'          # key from Core/Categories.psd1
    MinPSVersion = '5.1'

    Tools = @(
        @{
            Name        = 'LAN info per adapter'
            Alias       = 'lan'
            Command     = 'Show-NRLanInfo'
            Description = 'Shows IP, subnet, gateway, DHCP, DNS and more for every network adapter.'
            Parameters  = @(
                @{ Name = 'Filter'; Required = $false; Default = '*';    Description = 'Adapter name or part of it, wildcards allowed' }
                @{ Name = 'View';   Required = $false; Default = 'card'; Description = 'card (detailed) or table (one line per adapter)' }
                @{ Name = 'All';    Required = $false; Default = 'off';  Description = 'on = also show disconnected and loopback adapters' }
            )
            Examples    = @(
                'lan'
                'lan wi-fi'
                'lan -View table'
                'lan * table on'
            )
        }
    )
}
