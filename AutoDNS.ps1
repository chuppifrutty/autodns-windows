#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InterfaceAlias = 'Ethernet',
    [ValidateRange(0, 8)][int]$Action = 0
)

$ErrorActionPreference = 'Stop'
$powershell = Join-Path $PSHOME 'powershell.exe'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$actions = @{
    1 = @('Check-ComssDns.ps1', '-OpenReport')
    2 = @('Switch-GeoHideDns.ps1', '-CheckOnly')
    3 = @('Switch-GeoHideDns.ps1', '-Choice', '3')
    4 = @('Switch-GeoHideDns.ps1', '-Choice', '4')
    5 = @('Switch-GeoHideDns.ps1', '-Choice', '1')
    6 = @('Switch-GeoHideDns.ps1', '-Choice', '2')
    7 = @('Install-ComssDnsTask.ps1')
    8 = @('Install-ComssDnsTask.ps1', '-Disable')
}

function Invoke-MenuAction([int]$Selection) {
    if ($Selection -ge 3 -and -not $isAdmin) {
        if ($InterfaceAlias.Contains('"')) { throw 'Имя адаптера не должно содержать кавычек.' }
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -InterfaceAlias "{1}" -Action {2}' -f
            $PSCommandPath, $InterfaceAlias, $Selection
        $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        return $process.ExitCode
    }

    $command = $actions[$Selection]
    $scriptPath = Join-Path $PSScriptRoot $command[0]
    $options = @($command | Select-Object -Skip 1)
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -InterfaceAlias $InterfaceAlias @options | Out-Host
    return $LASTEXITCODE
}

if ($Action) {
    $exitCode = 1
    try {
        $exitCode = Invoke-MenuAction $Action
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    [void](Read-Host 'Нажмите Enter, чтобы закрыть окно')
    exit $exitCode
}

while ($true) {
    Write-Host ""
    Write-Host "AutoDNS Windows · адаптер $InterfaceAlias" -ForegroundColor Cyan
    Write-Host '1. Открыть отчёт диагностики'
    Write-Host '2. Сравнить Comss и GeoHide без изменения DNS'
    Write-Host '3. Сравнить и применить лучший DNS'
    Write-Host '4. Подключить Comss'
    Write-Host '5. Подключить GeoHide'
    Write-Host '6. Восстановить прежние настройки DNS'
    Write-Host '7. Включить автообновление Comss'
    Write-Host '8. Отключить автообновление'
    Write-Host '0. Выход'
    $selection = Read-Host 'Выберите пункт'
    if ($null -eq $selection) { break }
    $selection = $selection.Trim()
    if ($selection -eq '0') { break }
    if ($selection -notmatch '^[1-8]$') { continue }

    try {
        $code = Invoke-MenuAction ([int]$selection)
        if ($code -ne 0) { Write-Host "Операция завершилась с кодом $code." -ForegroundColor Red }
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}
