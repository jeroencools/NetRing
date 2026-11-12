@{
    Name         = 'WebExplain'
    Version      = '0.1.0'
    Author       = 'NetRing'
    Description  = 'Shows step by step what happens when you open a website: DNS, TCP, TLS and HTTP.'
    Category     = 'web'            # key from Core/Categories.psd1
    MinPSVersion = '5.1'

    Tools = @(
        @{
            Name        = 'Explain a web request'
            Alias       = 'explain'
            Command     = 'Invoke-NRWebExplain'
            Description = 'Follows one web request from name to answer: DNS lookup, TCP handshake, TLS and certificate chain, HTTP request and response, with a timeline.'
            Parameters  = @(
                @{ Name = 'Url';     Required = $true;                   Description = 'Website or URL, for example www.vibo.be or http://example.com/page' }
                @{ Name = 'Follow';  Required = $false; Default = 'on';   Description = 'Follow redirects: on or off' }
                @{ Name = 'Timeout'; Required = $false; Default = 5000;   Description = 'Timeout per step in ms (500-30000)' }
                @{ Name = 'DnsServer'; Required = $false; Default = 'automatic'; Description = 'Ask this DNS server directly (IPv4), skipping hosts file and cache' }
            )
            Examples    = @(
                'explain www.vibo.be'
                'explain http://neverssl.com'
                'explain https://expired.badssl.com -Follow off'
                'explain www.vibo.be -DnsServer 1.1.1.1'
            )
        }
    )
}
