#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InterfaceAlias = 'Ethernet',
    [switch]$CheckOnly,
    [ValidateSet('1', '2', '3')][string]$Choice
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-ComssDns.ps1')
. (Join-Path $PSScriptRoot 'Measure-DnsProviders.ps1')
$backupPath = Join-Path $PSScriptRoot 'geohide-dns-backup.json'
$template = 'https://eu.geohide.ru/dns-query'
$geoAddresses = @('5.175.161.3', '37.221.93.141')
$taskName = 'Comss DNS - every 2 hours'

function Set-EthernetDns([string[]]$Addresses) {
    $dns | Set-DnsClientServerAddress -ServerAddresses $Addresses
    $actual = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses
    if (($actual -join ',') -ne ($Addresses -join ',')) {
        throw 'Windows did not report the expected IPv4 DNS addresses.'
    }
    Clear-DnsClientCache
    Write-Host "Ethernet DNS: $($actual -join ', ')"
}

try {
    $adapter = @(Get-NetAdapter | Where-Object Name -eq $InterfaceAlias)
    if ($adapter.Count -ne 1) { throw 'Specify one exact network adapter name.' }
    $adapter = $adapter[0]
    if ($CheckOnly) {
        Measure-DnsProviders -Adapter $adapter |
            Sort-Object @{Expression='Score';Descending=$true}, AverageSeconds |
            Format-Table Name,Score,AverageSeconds
        return
    }

    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the CMD launcher or use -CheckOnly.'
    }
    $interactive = -not $Choice
    if ($interactive) {
        Write-Host '1. Switch to GeoHide EU (DoH)'
        Write-Host '2. Restore previous DNS and Comss task'
        Write-Host '3. Test Comss and GeoHide EU and apply the winner'
        $selection = Read-Host 'Choose 1, 2 or 3'
        if ($selection -notin '1', '2', '3') { return }
        $Choice = $selection
    }
    if ($choice -notin '1', '2', '3') { return }
    $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
    $task = Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $taskName
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($adapter.InterfaceGuid)"

    if ($choice -ne '2') {
        if (Test-Path -LiteralPath $backupPath) {
            throw 'A backup already exists. Choose 2 to restore it before switching again.'
        }
        if ($choice -eq '3') {
            $winner = Measure-DnsProviders -Adapter $adapter |
                Sort-Object @{Expression='Score';Descending=$true}, AverageSeconds | Select-Object -First 1
            if (-not $winner) { throw 'No provider passed. DNS settings were not changed.' }
            $geoAddresses = $winner.Addresses
            $template = $winner.Template
            Write-Host "Selected $($winner.Name): $($winner.Score) of 4 site checks passed."
        }
        $task = Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $taskName
        if ($task.State -eq 'Running') { throw 'Comss is updating now. Try again once it finishes.' }
        $configured = (Get-ItemProperty -LiteralPath $key).NameServer
        $staticAddresses = @(([string]$configured -split '[,\s]+') | Where-Object { $_ })
        $entries = @(Get-DnsClientDohServerAddress)
        $newEntries = @()
        foreach ($ip in $geoAddresses) {
            $entry = $entries | Where-Object ServerAddress -eq $ip
            if (-not $entry) {
                $newEntries += $ip
            } elseif ($entry.DohTemplate -ne $template -or -not $entry.AutoUpgrade -or $entry.AllowFallbackToUdp) {
                throw "Conflicting DoH settings already exist for $ip."
            }
        }

        $backup = [pscustomobject]@{
            InterfaceGuid = [string]$adapter.InterfaceGuid
            Addresses = $staticAddresses
            TaskEnabled = [bool]($task -and $task.Settings.Enabled)
            AddedDoh = $newEntries
            DohTemplate = $template
        }
        New-Item -ItemType File -Path $backupPath -ErrorAction Stop | Out-Null
        $backup | ConvertTo-Json | Set-Content -LiteralPath $backupPath -Encoding UTF8
        if ($backup.TaskEnabled) { $task | Disable-ScheduledTask | Out-Null }
        foreach ($ip in $newEntries) {
            Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $template -AutoUpgrade $true -AllowFallbackToUdp $false
        }
        Set-EthernetDns $geoAddresses
        Write-Host 'DNS applied. Choose 2 to restore the previous setup.'
    } else {
        if (-not (Test-Path -LiteralPath $backupPath)) { throw 'There is no saved DNS setup to restore.' }
        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
        if ($backup.InterfaceGuid -ne [string]$adapter.InterfaceGuid) {
            throw 'The saved DNS setup does not match this Ethernet adapter.'
        }
        if ($backup.Addresses) {
            Set-EthernetDns $backup.Addresses
        } else {
            netsh.exe interface ipv4 set dnsservers "name=$($adapter.ifIndex)" source=dhcp
            if ($LASTEXITCODE -ne 0 -or (Get-ItemProperty -LiteralPath $key).NameServer) {
                throw 'Failed to restore automatic IPv4 DNS.'
            }
            Clear-DnsClientCache
        }
        $entries = @(Get-DnsClientDohServerAddress)
        foreach ($ip in $backup.AddedDoh) {
            $entry = $entries | Where-Object ServerAddress -eq $ip
            if ($entry.DohTemplate -eq $backup.DohTemplate -and $entry.AutoUpgrade -and -not $entry.AllowFallbackToUdp) {
                Remove-DnsClientDohServerAddress -ServerAddress $ip
            }
        }
        if ($backup.TaskEnabled) {
            if (-not $task) { throw 'DNS restored, but the saved Comss task is missing.' }
            $task | Enable-ScheduledTask | Out-Null
        }
        Remove-Item -LiteralPath $backupPath
        Write-Host 'Previous Ethernet DNS and Comss task state restored.'
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if (Test-Path -LiteralPath $backupPath) {
        Write-Host 'Backup available. Choose 2 to restore the previous setup.'
    }
    exit 1
} finally {
    if ($interactive) { [void](Read-Host 'Press Enter to close') }
}
