@echo off
setlocal
cd /d "%~dp0"
echo Chat2Code Watchdog installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 (
  echo.
  echo Installation failed. See the message above.
  pause
  exit /b 1
)
echo.
echo Installation finished.
pause
endlocal
