$comssSourceUrl = 'https://www.comss.ru/page.php?id=7315'
$comssDohUrl = 'https://dns.comss.one/dns-query'
$geoHideDohUrl = 'https://eu.geohide.ru/dns-query'
$dnsTaskNames = @{
    Comss = 'Comss DNS - every 2 hours'
    GeoHide = 'GeoHide DNS - every 2 hours'
}

function Get-DnsAutoUpdateTasks {
    Get-ScheduledTask -TaskPath '\' | Where-Object { $_.TaskName -in $dnsTaskNames.Values }
}

function Test-PublicIpv4([string]$Address) {
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip) -or
        $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $bytes = $ip.GetAddressBytes()
    return ($bytes[0] -notin @(0, 10, 127) -and $bytes[0] -lt 224 -and
        -not ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -and
        -not ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -and
        -not ($bytes[0] -eq 192 -and $bytes[1] -eq 168))
}

function Get-GeoHideDnsAddresses([string[]]$Preferred) {
    $dohHost = ([uri]$geoHideDohUrl).DnsSafeHost
    $records = Resolve-DnsName -Name $dohHost -Type A -DnsOnly -NoHostsFile -QuickTimeout
    $published = @($records | Where-Object { $_.Type -eq 'A' -and (Test-PublicIpv4 $_.IPAddress) } |
        Select-Object -ExpandProperty IPAddress -Unique)
    $candidates = @($Preferred + $published | Where-Object { $_ -in $published } | Select-Object -Unique -First 12)
    $selected = @()
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $body = New-TemporaryFile
    try {
        # DNS wire query for example.com, type A, transaction ID 0.
        $query = 'AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE'
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        foreach ($ip in $candidates) {
            $response = & $curl -q --silent --noproxy '*' --max-time 5 --max-filesize 65535 `
                --resolve "${dohHost}:443:$ip" --header 'Accept: application/dns-message' `
                --output $body.FullName --write-out '%{http_code} %{content_type}' "${geoHideDohUrl}?dns=$query"
            if ($LASTEXITCODE -ne 0 -or $response -notmatch '^200 application/dns-message(?:\s*;.*)?$') { continue }
            $reply = [IO.File]::ReadAllBytes($body.FullName)
            if ($reply.Length -lt 12 -or $reply[0] -ne 0 -or $reply[1] -ne 0 -or
                -not ($reply[2] -band 0x80) -or ($reply[2] -band 0x02) -or
                ($reply[3] -band 0x0f) -ne 0 -or ($reply[6] -eq 0 -and $reply[7] -eq 0)) { continue }
            $selected += $ip
            if ($selected.Count -eq 2) { return $selected }
        }
    } finally {
        Remove-Item -LiteralPath $body.FullName
    }
    throw 'GeoHide did not provide two working IPv4 DoH servers. Settings unchanged.'
}

function Get-ComssDnsPage {
    # TLS 1.2 for Windows PowerShell 5.1; certificate verification stays enabled.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $comssSourceUrl -UseBasicParsing -TimeoutSec 45
}

# Extract only the standard IPv4 servers, never an IP from the DoH/router section.
function Get-ComssDnsFromHtml {
    param([Parameter(Mandatory)][string]$Html)
    $clean = [regex]::Replace($Html, '(?s)<!--.*?-->', '')
    $section = [regex]::Match($clean, '(?is)<div\b[^>]*\bid\s*=\s*["'']collapse2["''][^>]*>(.*?)</div>')
    if (-not $section.Success) { throw 'Standard DNS section (collapse2) not found; settings unchanged.' }
    $labels = [regex]::Matches($section.Groups[1].Value, '(?is)<span\b[^>]*\bclass\s*=\s*["''][^"'']*\blabel\b[^"'']*["''][^>]*>\s*(\d{1,3}(?:\.\d{1,3}){3})\s*</span>')
    $addresses = @()
    foreach ($label in $labels) {
        $value = $label.Groups[1].Value
        if (-not (Test-PublicIpv4 $value)) { throw "Invalid or non-public IPv4 address: $value" }
        $addresses += [System.Net.IPAddress]::Parse($value).ToString()
    }
    if ($addresses.Count -ne 2 -or $addresses[0] -eq $addresses[1]) {
        throw 'Expected exactly two different IPv4 DNS addresses; settings unchanged.'
    }
    return $addresses
}
