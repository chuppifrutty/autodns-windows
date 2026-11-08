$comssSourceUrl = 'https://www.comss.ru/page.php?id=7315'
$comssDohUrl = 'https://dns.comss.one/dns-query'

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
        $ip = $null
        $value = $label.Groups[1].Value
        if (-not [System.Net.IPAddress]::TryParse($value, [ref]$ip) -or
            $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Invalid IPv4 address: $value"
        }
        $bytes = $ip.GetAddressBytes()
        if ($bytes[0] -in @(0, 10, 127) -or $bytes[0] -ge 224 -or
            ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or
            ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168)) {
            throw "Non-public DNS address rejected: $value"
        }
        $addresses += $ip.ToString()
    }
    if ($addresses.Count -ne 2 -or $addresses[0] -eq $addresses[1]) {
        throw 'Expected exactly two different IPv4 DNS addresses; settings unchanged.'
    }
    return $addresses
}
