function Measure-DnsProviders {
    param([Parameter(Mandatory)]$Adapter)

    $localAddresses = @((Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4).IPAddress)
    $sites = @('https://example.com/', 'https://store.steampowered.com/', 'https://chatgpt.com/')
    $providers = @([pscustomobject]@{
        Name = 'GeoHide EU'
        Template = 'https://eu.geohide.ru/dns-query'
        Addresses = @('5.175.161.3', '37.221.93.141')
    })
    try {
        $page = Get-ComssDnsPage
        $providers += [pscustomobject]@{
            Name = 'Comss'
            Template = $comssDohUrl
            Addresses = @(Get-ComssDnsFromHtml -Html $page.Content)
        }
    } catch {
        Write-Host "Comss unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    foreach ($provider in $providers) {
        $baseline = 0
        $score = 0
        $times = @()
        $dohHost = ([uri]$provider.Template).DnsSafeHost
        foreach ($ip in $provider.Addresses) {
            $route = Find-NetRoute -RemoteIPAddress $ip -ErrorAction SilentlyContinue |
                Where-Object DestinationPrefix | Select-Object -First 1
            if ($route.InterfaceIndex -ne $Adapter.ifIndex) {
                Write-Host "$($provider.Name) $ip skipped: route does not use $($Adapter.Name)."
                continue
            }
            foreach ($site in $sites) {
                $result = curl.exe -q --silent --ipv4 --noproxy '*' --max-time 8 --output NUL `
                    --doh-url $provider.Template --resolve "${dohHost}:443:$ip" `
                    --write-out '%{http_code} %{local_ip} %{time_total}' $site
                $curlExit = $LASTEXITCODE
                Write-Host "$($provider.Name) $ip $site : $result"
                if ($curlExit -ne 0 -or $result -notmatch '^([23]\d\d) (\S+) (\d+\.\d+)$' -or
                    $Matches[2] -notin $localAddresses) { continue }
                if ($site -eq $sites[0]) {
                    $baseline++
                } else {
                    $score++
                    $times += [double]::Parse($Matches[3], [Globalization.CultureInfo]::InvariantCulture)
                }
            }
        }
        if ($baseline -eq $provider.Addresses.Count -and $score -gt 0) {
            $provider | Add-Member NoteProperty Score $score
            $provider | Add-Member NoteProperty AverageSeconds (($times | Measure-Object -Average).Average)
            $provider
        }
    }
}
