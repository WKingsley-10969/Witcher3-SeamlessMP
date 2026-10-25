@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Lan.ps1" -Mode Host %*
if errorlevel 1 pause
