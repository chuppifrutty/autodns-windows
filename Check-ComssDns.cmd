@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-ComssDns.ps1" -OpenReport %*
if errorlevel 1 pause
