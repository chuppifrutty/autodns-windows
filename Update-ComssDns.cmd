@echo off
setlocal
set "COMSS_DNS_UPDATE_SCRIPT=%~dp0Update-ComssDns.ps1"

powershell.exe -NoProfile -Command "try { $arguments = '-NoProfile -ExecutionPolicy Bypass -File {0}{1}{0}' -f [char]34, $env:COMSS_DNS_UPDATE_SCRIPT; $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop; exit $process.ExitCode } catch { Write-Error $_; exit 1 }"
set "UPDATE_EXIT_CODE=%ERRORLEVEL%"

if "%UPDATE_EXIT_CODE%"=="0" (
    echo Comss DNS check completed successfully.
) else (
    echo Comss DNS update failed or was cancelled. Exit code %UPDATE_EXIT_CODE%.
)
echo Log: "%~dp0comss-dns.log"
pause
exit /b %UPDATE_EXIT_CODE%
