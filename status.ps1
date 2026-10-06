$ErrorActionPreference = "Stop"
$statePath = Join-Path $PSScriptRoot "runtime\state.json"
if (-not (Test-Path -LiteralPath $statePath)) {
    Write-Host "No state yet. Start the watchdog first." -ForegroundColor Yellow
    exit 1
}
$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "Chat2Code Watchdog" -ForegroundColor Cyan
Write-Host "Watchdog : $($state.watchdogStatus)"
Write-Host "Runner   : $($state.runnerStatus)"
Write-Host "PID(s)   : $(@($state.runnerPids) -join ', ')"
Write-Host "LastCheck: $($state.lastCheck)"
Write-Host "Restarts : $($state.restartCount)"
if ($state.lastRestart) { Write-Host "LastRestart: $($state.lastRestart)" }
if ($state.lastError) { Write-Host "LastError: $($state.lastError)" -ForegroundColor Red }
