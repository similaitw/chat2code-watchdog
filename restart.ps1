[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path $PSScriptRoot "config.json"
$RunnerControlPath = Join-Path $PSScriptRoot "runner-control.ps1"
$TaskName = "Chat2Code Watchdog"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "config.json not found. Run INSTALL.bat first."
}
if (-not (Test-Path -LiteralPath $RunnerControlPath -PathType Leaf)) {
    throw "runner-control.ps1 not found."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
. $RunnerControlPath

$Logger = {
    param($Level, $Message)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host ($timestamp + " [" + $Level + "] " + $Message)
}

Write-Host "=== Chat2Code Runner Safe Restart ===" -ForegroundColor Cyan

$taskExists = $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
if ($taskExists) {
    Write-Host "Temporarily stopping Watchdog scheduled task..."
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$result = $null
try {
    $result = Restart-Chat2CodeRunner -Config $config -Logger $Logger
}
finally {
    if ($taskExists) {
        Write-Host "Starting Watchdog scheduled task..."
        try {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        }
        catch {
            Write-Warning "Runner restart finished, but Watchdog scheduled task could not be started automatically."
        }
    }
}

if (-not $result -or -not $result.Success) {
    $message = if ($result) { [string]$result.Message } else { "unknown failure" }
    Write-Host ("Runner restart failed: " + $message) -ForegroundColor Red
    exit 1
}

Write-Host ("Runner restarted successfully. PID(s): " + (@($result.Pids) -join ", ")) -ForegroundColor Green
exit 0
