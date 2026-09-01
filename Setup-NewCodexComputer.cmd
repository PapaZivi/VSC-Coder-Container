@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Validate-SetupSyntax.ps1" -ScriptPath "%~dp0Setup-NewCodexComputer.ps1"
if errorlevel 1 (
    echo.
    echo Setup wurde wegen eines Syntaxfehlers nicht gestartet.
    pause
    exit /b %ERRORLEVEL%
)

if /I "%~1"=="--logfile" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-NewCodexComputer.ps1" -LogFile
    exit /b %ERRORLEVEL%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-NewCodexComputer.ps1" %*
exit /b %ERRORLEVEL%
