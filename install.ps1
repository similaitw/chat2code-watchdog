[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ConfigExample = Join-Path $PSScriptRoot "config.example.json"
$ConfigPath = Join-Path $PSScriptRoot "config.json"
$ExpectedRunner = "H:\AI_Project\chat2code-runner\start.ps1"

Write-Host "=== Chat2Code Watchdog Installer ===" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Copy-Item -LiteralPath $ConfigExample -Destination $ConfigPath
    Write-Host "Created config.json" -ForegroundColor Green
}
else {
    Write-Host "config.json already exists; keeping it unchanged." -ForegroundColor Yellow
}

if (-not (Test-Path -LiteralPath $ExpectedRunner)) {
    Write-Warning "Expected Runner entry was not found: $ExpectedRunner"
    Write-Warning "Edit config.json if your Runner is elsewhere."
}
else {
    Write-Host "Runner entry found: $ExpectedRunner" -ForegroundColor Green
}

Write-Host "Running one health check..." -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "watchdog.ps1") -Once
if ($LASTEXITCODE -ne 0) {
    throw "One-time Watchdog health check failed with exit code $LASTEXITCODE"
}

Write-Host "Installing Windows scheduled task..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "install-task.ps1")

Write-Host ""
Write-Host "Installation complete." -ForegroundColor Green
Write-Host "Use .\status.ps1 to view local status."
Write-Host "Log: .\logs\watchdog.log"
