# Template for a new NetRing module.
# 1. Copy this folder to Modules/<YourModuleName> (without the leading "_").
#    Folders starting with "_" are ignored by NetRing.
# 2. Fill in the metadata below and write the code in module.psm1.
# 3. Start NetRing (or type 'reload') and check 'modules'.
@{
    Name         = 'Template'
    Version      = '0.1.0'
    Author       = ''
    Description  = 'Short description of the module.'
    # Menu category: a Key from Core/Categories.psd1
    # local, discovery, connectivity, dns, services, web, calculators, security
    Category     = 'calculators'
    MinPSVersion = '5.1'

    Tools = @(
        @{
            Name        = 'Example tool'
            Alias       = 'example'      # unique, no spaces, not a number
            Command     = 'Invoke-NRExample'
            Description = 'What the tool does in one sentence.'
            Parameters  = @(
                # Order = order of positional arguments in alias mode.
                @{ Name = 'Target'; Required = $true;  Description = 'Hostname or IP address' }
                @{ Name = 'Count';  Required = $false; Default = 4; Description = 'Number of attempts' }
            )
            Examples    = @(
                'example 192.168.1.1'
                'example 192.168.1.1 -Count 2'
            )
        }
    )
}
