@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart.ps1"
if errorlevel 1 (
  echo.
  echo Restart failed. See the message above.
  pause
  exit /b 1
)
echo.
echo Restart complete.
pause
endlocal
