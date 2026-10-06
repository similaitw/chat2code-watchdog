@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0telegram-diagnose.ps1"
echo.
pause
endlocal
