@{
    Name         = 'AdapterControl'
    Version      = '0.1.0'
    Author       = 'NetRing'
    Description  = 'Pick an adapter and manage it: enable, disable, restart, release and renew the IP, flush DNS.'
    Category     = 'local'          # key from Core/Categories.psd1
    MinPSVersion = '5.1'

    Tools = @(
        @{
            Name        = 'Adapter manager'
            Alias       = 'nic'
            Command     = 'Invoke-NRAdapterManager'
            Description = 'Choose an adapter and get the actions that fit it. Most actions need administrator rights.'
            Interactive = $true   # asks for its own input in menu mode
            Parameters  = @(
                @{ Name = 'Adapter'; Required = $false; Description = 'Adapter name or part of it (empty = choose from a list)' }
                @{ Name = 'Action';  Required = $false; Description = 'renew, release, restart, off, on or flushdns (empty = choose from a menu)' }
            )
            Examples    = @(
                'nic'
                'nic wifi'
                'nic wifi renew'
                'nic ethernet off'
                'nic flushdns'
            )
        }
    )
}
