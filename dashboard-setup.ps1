[CmdletBinding()]
param(
    [int]$StatusIssueNumber = 38
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path $PSScriptRoot "config.json"
$TaskName = "Chat2Code Watchdog"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "config.json not found. Run INSTALL.bat first."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$controlRepo = "similaitw/chat2code-control"
$runnerConfigPath = Join-Path ([string]$config.runner.workingDirectory) "config.json"
if (Test-Path -LiteralPath $runnerConfigPath -PathType Leaf) {
    try {
        $runnerConfig = Get-Content -LiteralPath $runnerConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($runnerConfig.control_repo) { $controlRepo = [string]$runnerConfig.control_repo }
    }
    catch {}
}

Write-Host "=== Chat2Code Dashboard Heartbeat Setup ===" -ForegroundColor Cyan
Write-Host ("Control repo: " + $controlRepo)
Write-Host ("Status issue: #" + $StatusIssueNumber)

& gh auth status | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI is not authenticated. Run gh auth login first."
}

$dashboard = [pscustomobject]@{
    enabled = $true
    statusIssueNumber = $StatusIssueNumber
    controlRepo = $controlRepo
    updateSeconds = 60
    runnerVersion = "0.4.1"
}

if ($config.PSObject.Properties.Name -contains "dashboard") {
    $config.dashboard = $dashboard
}
else {
    $config | Add-Member -NotePropertyName dashboard -NotePropertyValue $dashboard
}

$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Write-Host "Dashboard heartbeat enabled in config.json." -ForegroundColor Green

try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Write-Host "Watchdog restarted." -ForegroundColor Green
}
catch {
    Write-Warning "Dashboard is configured, but Watchdog could not be restarted automatically."
}

Write-Host "Setup complete. Heartbeat should appear within about 60 seconds." -ForegroundColor Cyan
