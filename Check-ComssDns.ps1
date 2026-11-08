#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InterfaceAlias = 'Ethernet',
    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-ComssDns.ps1')
$started = Get-Date
$results = [System.Collections.Generic.List[object]]::new()
$statusLabels = @{ ok = 'ОК'; warn = 'Внимание'; fail = 'Сбой'; skip = 'Не проверено' }

function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
    $results.Add([pscustomobject]@{ Status = $Status; Name = $Name; Detail = $Detail })
    Write-Host "[$($statusLabels[$Status])] $Name"
}

function Get-RouteName([string]$IP) {
    try {
        $route = Find-NetRoute -RemoteIPAddress $IP | Where-Object DestinationPrefix | Select-Object -First 1
        if ($route) { return "$($route.InterfaceAlias) ($($route.DestinationPrefix))" }
    } catch {
        return "не определён ($($_.Exception.Message))"
    }
    return 'не найден'
}

function Test-Doh([string]$IP) {
    $body = New-TemporaryFile
    try {
        $dohHost = ([uri]$comssDohUrl).DnsSafeHost
        # Wire-format DNS query for example.com, type A, with transaction ID 0.
        $query = 'AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE'
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $output = curl.exe -q --silent --show-error --noproxy '*' --resolve "${dohHost}:443:$IP" `
            --max-time 10 --header 'Accept: application/dns-message' --output $body.FullName `
            --write-out '%{http_code} %{content_type}' "${comssDohUrl}?dns=$query" 2>&1
        $curlExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($curlExit -ne 0) { throw "curl ($curlExit) — $($output -join ' ')" }
        if ($output -notmatch '^200 application/dns-message(?:\s*;.*)?$') {
            throw "Неожиданный HTTP-ответ — $output"
        }
        $reply = [IO.File]::ReadAllBytes($body.FullName)
        if ($reply.Length -lt 12 -or $reply[0] -ne 0 -or $reply[1] -ne 0 -or
            -not ($reply[2] -band 0x80) -or ($reply[2] -band 0x02)) {
            throw 'Сервер вернул неполный или некорректный DNS-ответ.'
        }
        $rcode = $reply[3] -band 0x0f
        $answers = 256 * $reply[6] + $reply[7]
        if ($rcode -ne 0 -or $answers -eq 0) {
            throw "DNS-ответ без результата (RCODE $rcode, записей $answers)."
        }
        return "HTTPS 200, DNS-записей в ответе — $answers."
    } finally {
        Remove-Item -LiteralPath $body.FullName
    }
}

$current = @()
$adapterRead = $false
try {
    $adapter = @(Get-NetAdapter | Where-Object Name -eq $InterfaceAlias)
    if ($adapter.Count -ne 1) {
        $available = (Get-NetAdapter).Name -join ', '
        throw "Адаптер «$InterfaceAlias» не найден. Доступны $available."
    }
    $current = @((Get-DnsClientServerAddress -InterfaceIndex $adapter[0].ifIndex -AddressFamily IPv4).ServerAddresses)
    $adapterRead = $true
    $currentText = if ($current.Count) { $current -join ', ' } else { 'нет адресов' }
    $status = if ($adapter[0].Status -eq 'Up') { 'ok' } else { 'warn' }
    Add-Result $status "Адаптер $InterfaceAlias" "Состояние $($adapter[0].Status). IPv4 DNS — $currentText."
} catch {
    Add-Result fail "Адаптер $InterfaceAlias" $_.Exception.Message
}

$desired = @()
try {
    $page = Get-ComssDnsPage
    Add-Result ok 'Сайт Comss' "HTTP $($page.StatusCode) — $comssSourceUrl"
    try {
        $desired = @(Get-ComssDnsFromHtml -Html $page.Content)
        Add-Result ok 'Адреса на сайте' ($desired -join ', ')
    } catch {
        Add-Result fail 'Адреса на сайте' $_.Exception.Message
    }
} catch {
    Add-Result fail 'Сайт Comss' $_.Exception.Message
    Add-Result skip 'Адреса на сайте' 'Страница Comss недоступна.'
}

if (-not $adapterRead -or $desired.Count -eq 0) {
    Add-Result skip 'Сравнение DNS' 'Для сравнения нужны данные адаптера и сайта.'
} elseif (($current -join ',') -eq ($desired -join ',')) {
    Add-Result ok 'Сравнение DNS' 'На адаптере указаны оба актуальных адреса в нужном порядке.'
} else {
    Add-Result warn 'Сравнение DNS' "На $InterfaceAlias — $currentText.`nНа сайте Comss — $($desired -join ', ')."
}

$probeIPs = if ($desired.Count) { $desired } else { $current }
if ($probeIPs) {
    try {
        $dohEntries = @(Get-DnsClientDohServerAddress)
    } catch {
        Add-Result skip 'Настройки DoH в Windows' $_.Exception.Message
        $dohEntries = $null
    }
    foreach ($ip in $probeIPs) {
        if ($null -ne $dohEntries) {
            $entry = $dohEntries | Where-Object ServerAddress -eq $ip | Select-Object -First 1
            if (-not $entry) {
                Add-Result warn "Настройки DoH · $ip" 'Для этого IP нет записи DoH в Windows.'
            } elseif ($entry.DohTemplate -ne $comssDohUrl -or -not $entry.AutoUpgrade -or $entry.AllowFallbackToUdp) {
                Add-Result warn "Настройки DoH · $ip" "Шаблон — $($entry.DohTemplate).`nАвтопереход на DoH — $($entry.AutoUpgrade). Разрешён обычный DNS — $($entry.AllowFallbackToUdp)."
            } else {
                Add-Result ok "Настройки DoH · $ip" 'Шаблон Comss совпадает. Автопереход на DoH включён, обычный DNS отключён.'
            }
        }
        $route = Get-RouteName $ip
        $routeDetail = "Маршрут Windows — $route."
        if ($route -notlike "$InterfaceAlias (*)") {
            $routeDetail += " Проверка по $InterfaceAlias отдельно не выполнена."
        }
        try {
            $answer = Test-Doh $ip
            Add-Result ok "Ответ DoH · $ip" "$answer`n$routeDetail"
        } catch {
            Add-Result fail "Ответ DoH · $ip" "$($_.Exception.Message)`n$routeDetail"
        }
    }
} else {
    Add-Result skip 'Ответ DoH' 'Нет адресов для проверки.'
}

try {
    $answers = @(Resolve-DnsName -Name 'example.com' -Type A -DnsOnly -NoHostsFile -QuickTimeout |
        Where-Object { $_.Section -eq 'Answer' -and $_.IPAddress })
    if (-not $answers.Count) { throw 'DNS-клиент Windows не вернул A-записи для example.com.' }
    Add-Result ok 'DNS-клиент Windows' "example.com — $($answers.IPAddress -join ', ').`nКакой сервер выбрала Windows, этот запрос не показывает."
} catch {
    Add-Result fail 'DNS-клиент Windows' $_.Exception.Message
}

$taskName = 'Comss DNS - every 2 hours'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
try {
    $task = Get-ScheduledTask -TaskName $taskName
    $info = Get-ScheduledTaskInfo -InputObject $task
    $detail = "Состояние $($task.State). Последний запуск — $($info.LastRunTime). Код — $('0x{0:X8}' -f $info.LastTaskResult). Следующий запуск — $($info.NextRunTime)."
    $taskLog = Join-Path $env:ProgramFiles 'ComssDnsUpdater\comss-dns.log'
    if (Test-Path -LiteralPath $taskLog) {
        $detail += "`n`nПоследние строки журнала`n$((Get-Content -LiteralPath $taskLog -Tail 5) -join "`n")"
    }
    $status = if ($task.State -eq 'Disabled' -or $info.LastTaskResult -ne 0) { 'warn' } else { 'ok' }
    Add-Result $status 'Задание Windows' $detail
} catch {
    if ($isAdmin) {
        Add-Result fail 'Задание Windows' $_.Exception.Message
    } else {
        Add-Result skip 'Задание Windows' 'Из обычного сеанса статус недоступен. Для проверки запустите этот отчёт от имени администратора.'
    }
}

$cards = for ($index = 0; $index -lt $results.Count; $index++) {
    $row = $results[$index]
    $name = [Net.WebUtility]::HtmlEncode($row.Name)
    $detail = [Net.WebUtility]::HtmlEncode($row.Detail)
    "<li class='$($row.Status)'><span class='number'>$($index + 1)</span><div><h2>$name</h2><p>$detail</p></div><strong>$($statusLabels[$row.Status])</strong></li>"
}
$summary = foreach ($status in 'fail', 'warn', 'skip', 'ok') {
    $count = @($results | Where-Object Status -eq $status).Count
    "<span class='$status'>$($statusLabels[$status]) <b>$count</b></span>"
}
$report = Join-Path $PSScriptRoot 'comss-dns-report.html'
@"
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Диагностика Comss DNS</title>
<style>
:root { color-scheme: light dark; font: 16px/1.5 system-ui, sans-serif; }
body { margin: 0; background: light-dark(#f3f5f9, #131720); color: light-dark(#182238, #e7edf8); }
main { max-width: 850px; margin: auto; padding: 32px 20px; }
h1 { margin: 0; font-size: clamp(1.65rem, 5vw, 2.5rem); }
header p { margin: 6px 0 18px; }
.summary { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 22px; }
.summary span, li strong { color: var(--status); background: var(--badge); border-radius: 6px; padding: 3px 9px; font-size: .85rem; white-space: nowrap; }
.summary b { margin-inline-start: 4px; }
.ok { --status: light-dark(#11633f, #90e6b4); --badge: light-dark(#e4f5eb, #1e392c); }
.warn { --status: light-dark(#794600, #ffcf83); --badge: light-dark(#fff0d4, #442e15); }
.fail { --status: light-dark(#a21f32, #ffa7b0); --badge: light-dark(#fce7ea, #50222a); }
.skip { --status: light-dark(#46536a, #c3cde0); --badge: light-dark(#e8edf5, #303747); }
ol { padding: 0; margin: 0; list-style: none; display: grid; gap: 9px; }
li { display: grid; grid-template-columns: 2rem minmax(0, 1fr) auto; align-items: start; gap: 10px; padding: 13px; border-inline-start: 4px solid var(--status); border-radius: 8px; background: light-dark(#fff, #202633); }
.number { color: var(--status); font-weight: 700; text-align: center; }
h2 { margin: 0; font-size: 1rem; }
li p { margin: 3px 0 0; white-space: pre-wrap; overflow-wrap: anywhere; font-size: .9rem; }
@media (max-width: 480px) {
    li { grid-template-columns: 1.5rem minmax(0, 1fr); }
    li strong { grid-column: 2; justify-self: start; }
}
</style>
</head>
<body>
<main>
<header>
<h1>Диагностика Comss DNS</h1>
<p>$($started.ToString('dd.MM.yyyy HH:mm:ss')) · Проверка без изменения настроек</p>
</header>
<div class="summary">$($summary -join "`n")</div>
<ol>$($cards -join "`n")</ol>
</main>
</body>
</html>
"@ | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "Отчёт — $report"
if ($OpenReport) { Start-Process -FilePath $report }
