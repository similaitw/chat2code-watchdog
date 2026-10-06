@echo off
setlocal
cd /d "%~dp0"
echo Chat2Code Watchdog Telegram setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0telegram-setup.ps1"
if errorlevel 1 (
  echo.
  echo Telegram setup failed. See the message above.
  pause
  exit /b 1
)
echo.
echo Telegram setup finished.
pause
endlocal
