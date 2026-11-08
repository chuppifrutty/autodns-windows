#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InterfaceAlias = 'Ethernet',
    [ValidateSet('Comss','GeoHide')][string]$Provider = 'Comss',
    [switch]$ChooseProvider,
    [switch]$Uninstall,
    [switch]$Disable
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-ComssDns.ps1')
if ($ChooseProvider) {
    Write-Host '1. Comss'
    Write-Host '2. GeoHide EU'
    $choice = Read-Host 'DNS provider (1 or 2)'
    if ($choice -notin '1', '2') { return }
    if ($choice -eq '2') { $Provider = 'GeoHide' }
    else { $Provider = 'Comss' }
}
$taskName = $dnsTaskNames[$Provider]
$tasks = @(Get-DnsAutoUpdateTasks)
if ($Uninstall -or $Disable) {
    if ($Uninstall) {
        $tasks | Where-Object TaskName -eq $taskName | Unregister-ScheduledTask -Confirm:$false
    } else {
        $tasks | Where-Object { $_.Settings.Enabled } | Disable-ScheduledTask | Out-Null
        Write-Host 'DNS auto-update is disabled.'
    }
    return
}
$otherTask = $tasks | Where-Object { $_.TaskName -ne $taskName -and $_.Settings.Enabled }
if ($tasks.State -contains 'Running') { throw 'An update is running. Try again once it finishes.' }
$adapter = Get-NetAdapter -Name $InterfaceAlias
if (@($adapter).Count -ne 1 -or $adapter.Name -ne $InterfaceAlias) { throw 'Specify one exact adapter name.' }
$destination = Join-Path $env:ProgramFiles "${Provider}DnsUpdater"
New-Item -ItemType Directory -Path $destination -Force | Out-Null
# Only administrators and SYSTEM can modify code executed by SYSTEM.
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $destination -AclObject $acl
foreach ($file in @('Get-ComssDns.ps1', 'Update-ComssDns.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $destination $file) -Force
}
# Store the adapter name in a generated entrypoint instead of shell interpolation.
$escapedAlias = $InterfaceAlias.Replace("'", "''")
$entry = "& (Join-Path `$PSScriptRoot 'Update-ComssDns.ps1') -InterfaceAlias '$escapedAlias' -Provider '$Provider'"
$entryPath = Join-Path $destination 'Run.ps1'
Set-Content -LiteralPath $entryPath -Value $entry -Encoding UTF8
$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $entryPath)
# No duration means repetition continues indefinitely.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours 2)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
if ($otherTask) { $otherTask | Disable-ScheduledTask | Out-Null }
try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Sync IPv4 DNS with $Provider every two hours, using DoH." -Force | Out-Null
} catch {
    if ($otherTask) { $otherTask | Enable-ScheduledTask | Out-Null }
    throw
}
Write-Host "Installed: $taskName. First check in one minute, then every two hours."
Write-Host "Log: $destination\comss-dns.log"
