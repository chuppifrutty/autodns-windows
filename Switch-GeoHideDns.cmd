@echo off
setlocal
set "GEOHIDE_SWITCH_SCRIPT=%~dp0Switch-GeoHideDns.ps1"
powershell.exe -NoProfile -Command "try { $arguments = '-NoProfile -ExecutionPolicy Bypass -File {0}{1}{0}' -f [char]34, $env:GEOHIDE_SWITCH_SCRIPT; $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop; exit $process.ExitCode } catch { Write-Error $_; exit 1 }"
if errorlevel 1 pause
