#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InterfaceAlias = 'Ethernet',
    [switch]$CheckOnly,
    [ValidateSet('1', '2', '3', '4')][string]$Choice
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-ComssDns.ps1')
. (Join-Path $PSScriptRoot 'Measure-DnsProviders.ps1')
$backupPath = Join-Path $PSScriptRoot 'geohide-dns-backup.json'
$template = 'https://eu.geohide.ru/dns-query'
$addresses = @('5.175.161.3', '37.221.93.141')
$taskName = 'Comss DNS - every 2 hours'

function Set-AdapterDns([string[]]$Addresses) {
    $dns | Set-DnsClientServerAddress -ServerAddresses $Addresses
    $actual = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses
    if (($actual -join ',') -ne ($Addresses -join ',')) {
        throw 'Windows did not report the expected IPv4 DNS addresses.'
    }
    Clear-DnsClientCache
    Write-Host "$($adapter.Name) DNS: $($actual -join ', ')"
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
        Write-Host '4. Connect to Comss'
        $selection = Read-Host 'Choose 1, 2, 3 or 4'
        if ($selection -notin '1', '2', '3', '4') { return }
        $Choice = $selection
    }
    $switchLock = [Threading.Mutex]::new($false, 'Local\AutoDnsWindows-ProviderSwitch')
    try { $locked = $switchLock.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another DNS switch is already running.' }

    $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($adapter.InterfaceGuid)"
    $hasBackup = Test-Path -LiteralPath $backupPath
    $addedDoh = @()
    if ($hasBackup) {
        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
        if ($backup.InterfaceGuid -ne [string]$adapter.InterfaceGuid) {
            throw 'The saved DNS setup belongs to another adapter.'
        }
        $addedDoh = @($backup.AddedDohEntries | Where-Object { $_ })
        foreach ($ip in $backup.AddedDoh) {
            $addedDoh += [pscustomobject]@{ Address = $ip; Template = $backup.DohTemplate }
        }
    }

    if ($choice -ne '2') {
        if ($choice -eq '3') {
            $winner = Measure-DnsProviders -Adapter $adapter |
                Sort-Object @{Expression='Score';Descending=$true}, AverageSeconds | Select-Object -First 1
            if (-not $winner) { throw 'No provider passed. DNS settings were not changed.' }
            $addresses = $winner.Addresses
            $template = $winner.Template
            Write-Host "Selected $($winner.Name): $($winner.Score) of 4 site checks passed."
        } elseif ($choice -eq '4') {
            $page = Get-ComssDnsPage
            $addresses = @(Get-ComssDnsFromHtml -Html $page.Content)
            $template = $comssDohUrl
        }
        $task = Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $taskName
        if ($task.State -eq 'Running') { throw 'Comss is updating now. Try again once it finishes.' }
        if (-not $hasBackup) {
            $configured = (Get-ItemProperty -LiteralPath $key).NameServer
            $backup = [pscustomobject]@{
                InterfaceGuid = [string]$adapter.InterfaceGuid
                Addresses = @(([string]$configured -split '[,\s]+') | Where-Object { $_ })
                TaskEnabled = [bool]($task -and $task.Settings.Enabled)
            }
        }
        $entries = @(Get-DnsClientDohServerAddress)
        $newEntries = @()
        foreach ($ip in $addresses) {
            $entry = $entries | Where-Object ServerAddress -eq $ip
            if (-not $entry) {
                $newEntries += $ip
            } elseif ($entry.DohTemplate -ne $template -or -not $entry.AutoUpgrade -or $entry.AllowFallbackToUdp) {
                throw "Conflicting DoH settings already exist for $ip."
            }
        }

        if (-not $hasBackup -or $newEntries.Count) {
            $addedDoh = @($addedDoh | Where-Object Address -notin $newEntries)
            foreach ($ip in $newEntries) {
                $addedDoh += [pscustomobject]@{ Address = $ip; Template = $template }
            }
            $savedState = [pscustomobject]@{
                InterfaceGuid = $backup.InterfaceGuid
                Addresses = $backup.Addresses
                TaskEnabled = $backup.TaskEnabled
                AddedDohEntries = $addedDoh
            }
            $pendingBackup = "$backupPath.tmp"
            $savedState | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $pendingBackup -Encoding UTF8
            if ($hasBackup) { [IO.File]::Replace($pendingBackup, $backupPath, [NullString]::Value) }
            else { [IO.File]::Move($pendingBackup, $backupPath) }
        }
        if ($task.Settings.Enabled) { $task | Disable-ScheduledTask | Out-Null }
        foreach ($ip in $newEntries) {
            Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $template -AutoUpgrade $true -AllowFallbackToUdp $false
        }
        Set-AdapterDns $addresses
        Write-Host 'DNS applied. Use Restore in the menu to undo the changes.'
    } else {
        if (-not $hasBackup) { throw 'There is no saved DNS setup to restore.' }
        if ($backup.Addresses) {
            Set-AdapterDns $backup.Addresses
        } else {
            netsh.exe interface ipv4 set dnsservers "name=$($adapter.ifIndex)" source=dhcp
            if ($LASTEXITCODE -ne 0 -or (Get-ItemProperty -LiteralPath $key).NameServer) {
                throw 'Failed to restore automatic IPv4 DNS.'
            }
            Clear-DnsClientCache
        }
        $entries = @(Get-DnsClientDohServerAddress)
        foreach ($registration in $addedDoh) {
            $entry = $entries | Where-Object ServerAddress -eq $registration.Address
            if ($entry.DohTemplate -eq $registration.Template -and $entry.AutoUpgrade -and -not $entry.AllowFallbackToUdp) {
                Remove-DnsClientDohServerAddress -ServerAddress $registration.Address
            }
        }
        if ($backup.TaskEnabled) {
            $task = Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $taskName
            if (-not $task) { throw 'DNS restored, but the saved Comss task is missing.' }
            $task | Enable-ScheduledTask | Out-Null
        }
        Remove-Item -LiteralPath $backupPath
        Write-Host 'Previous DNS and Comss task state restored.'
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if (Test-Path -LiteralPath $backupPath) {
        Write-Host 'Backup available. Use Restore in the menu to undo the changes.'
    }
    exit 1
} finally {
    if ($locked) { $switchLock.ReleaseMutex() }
    if ($switchLock) { $switchLock.Dispose() }
    if ($interactive) { [void](Read-Host 'Press Enter to close') }
}
