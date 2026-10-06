@echo off
setlocal
cd /d "%~dp0"
echo Chat2Code Dashboard setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dashboard-setup.ps1"
if errorlevel 1 (
  echo.
  echo Dashboard setup failed. See the message above.
  pause
  exit /b 1
)
echo.
pause
endlocal
