function Measure-DnsProviders {
    param([Parameter(Mandatory)]$Adapter)

    $localAddresses = @((Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4).IPAddress)
    $sites = @('https://ya.ru/', 'https://store.steampowered.com/', 'https://chatgpt.com/')
    $providers = @([pscustomobject]@{
        Name = 'Pereval'
        Template = $perevalDohUrl
        Addresses = @('153.80.200.170')
    })
    try {
        $dns = Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4
        $providers += [pscustomobject]@{
            Name = 'GeoHide EU'
            Template = $geoHideDohUrl
            Addresses = @(Get-GeoHideDnsAddresses -Preferred $dns.ServerAddresses)
        }
    } catch {
        Write-Host "GeoHide unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
    }
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
        $passedSiteChecks = 0
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
                $attempts = if ($site -eq $sites[0]) { 1 } else { 2 }
                $sitePassed = $false
                foreach ($attempt in 1..$attempts) {
                    $result = curl.exe -q --silent --ipv4 --noproxy '*' --max-time 8 --output NUL `
                        --doh-url $provider.Template --resolve "${dohHost}:443:$ip" `
                        --write-out '%{http_code} %{local_ip} %{time_total} %{remote_ip}' $site
                    $curlExit = $LASTEXITCODE
                    Write-Host "$($provider.Name) DNS=$ip $site [$attempt/$attempts] HTTP/local/seconds/remote: $result (curl $curlExit)"
                    if ($curlExit -ne 0 -or $result -notmatch '^([23]\d\d) (\S+) (\d+\.\d+) (\S+)$' -or
                        $Matches[2] -notin $localAddresses) { continue }
                    if ($site -eq $sites[0]) {
                        $baseline++
                    } else {
                        $sitePassed = $true
                        $score++
                        $times += [double]::Parse($Matches[3], [Globalization.CultureInfo]::InvariantCulture)
                    }
                }
                if ($sitePassed) { $passedSiteChecks++ }
            }
        }
        if ($baseline -eq $provider.Addresses.Count -and
            $passedSiteChecks -eq $provider.Addresses.Count * ($sites.Count - 1)) {
            $provider | Add-Member NoteProperty Score $score
            $maxScore = $provider.Addresses.Count * ($sites.Count - 1) * 2
            $provider | Add-Member NoteProperty MaxScore $maxScore
            $provider | Add-Member NoteProperty SuccessRate ($score / $maxScore)
            $provider | Add-Member NoteProperty AverageSeconds (($times | Measure-Object -Average).Average)
            $provider
        } else {
            Write-Host "$($provider.Name) skipped: each DNS must reach the control site, Steam and ChatGPT."
        }
    }
}
