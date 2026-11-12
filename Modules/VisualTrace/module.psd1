@{
    Name         = 'VisualTrace'
    Version      = '0.1.0'
    Author       = 'NetRing'
    Description  = 'Traceroute with a visual path, latency bars and network zones.'
    Category     = 'Diagnostics'
    MinPSVersion = '5.1'

    Tools = @(
        @{
            Name        = 'Visual traceroute'
            Alias       = 'trace'
            Command     = 'Invoke-NRVisualTrace'
            Description = 'Follows the route to a host hop by hop and draws the path.'
            Parameters  = @(
                @{ Name = 'Target';  Required = $true;  Description = 'Hostname or IP address' }
                @{ Name = 'MaxHops'; Required = $false; Default = 30;   Description = 'Maximum number of hops (1-64)' }
                @{ Name = 'Timeout'; Required = $false; Default = 1000; Description = 'Timeout per probe in ms (100-10000)' }
                @{ Name = 'Probes';  Required = $false; Default = 3;    Description = 'Probes per hop (1-10)' }
                @{ Name = 'Resolve'; Required = $false; Default = 'on'; Description = 'Look up hostnames: on or off' }
            )
            Examples    = @(
                'trace 8.8.8.8'
                'trace www.vibo.be 20'
                'trace 1.1.1.1 -Resolve off -Probes 1'
            )
        }
    )
}
