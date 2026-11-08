#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InterfaceAlias = 'Ethernet',
    [switch]$CheckOnly,
    [string]$LogPath
)
$ErrorActionPreference = 'Stop'
if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'comss-dns.log' }
. (Join-Path $PSScriptRoot 'Get-ComssDns.ps1')

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

try {
    if (-not $CheckOnly) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Run PowerShell as Administrator, or use -CheckOnly.'
        }
    }
    $adapter = Get-NetAdapter -Name $InterfaceAlias
    if (@($adapter).Count -ne 1 -or $adapter.Name -ne $InterfaceAlias) {
        throw 'Specify one exact network adapter name.'
    }
    $response = Get-ComssDnsPage
    $desired = @(Get-ComssDnsFromHtml -Html $response.Content)
    $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
    $previous = @($dns.ServerAddresses)
    $different = ($previous -join ',') -ne ($desired -join ',')
    Write-Log "Adapter: $InterfaceAlias; current: $($previous -join ', '); website: $($desired -join ', '); different: $different"
    if ($CheckOnly) { return }

    # Register encryption before assigning new server IPs. No plaintext fallback.
    foreach ($ip in $desired) {
        $entry = @(Get-DnsClientDohServerAddress | Where-Object ServerAddress -eq $ip)
        if ($entry.Count -eq 0) {
            Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $comssDohUrl -AutoUpgrade $true -AllowFallbackToUdp $false | Out-Null
        } elseif ($entry[0].DohTemplate -ne $comssDohUrl -or -not $entry[0].AutoUpgrade -or $entry[0].AllowFallbackToUdp) {
            Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $comssDohUrl -AutoUpgrade $true -AllowFallbackToUdp $false | Out-Null
        }
    }
    if ($different) {
        # Invoke the IPv4 CIM instance to leave IPv6 configuration intact.
        $dns | Set-DnsClientServerAddress -ServerAddresses $desired
        $actual = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses)
        if (($actual -join ',') -ne ($desired -join ',')) { throw 'DNS verification failed after update.' }
        Clear-DnsClientCache
        Write-Log 'IPv4 DNS updated and verified.'
    } else {
        Write-Log 'IPv4 DNS already matches; no IP changes needed.'
    }
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
