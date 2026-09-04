@echo off
setlocal

if /I "%~1"=="--logfile" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Setup.ps1" -LogFile
    exit /b %ERRORLEVEL%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Setup.ps1" %*
exit /b %ERRORLEVEL%
