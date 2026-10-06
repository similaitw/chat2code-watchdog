$ErrorActionPreference = "Stop"
$statePath = Join-Path $PSScriptRoot "runtime\state.json"
$configPath = Join-Path $PSScriptRoot "config.json"

if (-not (Test-Path -LiteralPath $statePath)) {
    Write-Host "No state yet. Start the watchdog first." -ForegroundColor Yellow
    exit 1
}

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$telegramEnabled = $false
if (Test-Path -LiteralPath $configPath) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config.PSObject.Properties.Name -contains "telegram") {
            $telegramEnabled = [bool]$config.telegram.enabled -and [bool]$config.telegram.botToken
        }
    }
    catch {}
}

Write-Host "Chat2Code Watchdog" -ForegroundColor Cyan
Write-Host "Watchdog : $($state.watchdogStatus)"
Write-Host "Runner   : $($state.runnerStatus)"
Write-Host "PID(s)   : $(@($state.runnerPids) -join ', ')"
Write-Host "LastCheck: $($state.lastCheck)"
Write-Host "Restarts : $($state.restartCount)"
if ($state.lastRestart) { Write-Host "LastRestart: $($state.lastRestart)" }

if ($telegramEnabled) {
    Write-Host "Telegram : enabled" -ForegroundColor Green
    if ($state.PSObject.Properties.Name -contains "telegramLastError" -and $state.telegramLastError) {
        Write-Host "TelegramError: $($state.telegramLastError)" -ForegroundColor Yellow
    }
}
else {
    Write-Host "Telegram : disabled"
}

if ($state.lastError) { Write-Host "LastError: $($state.lastError)" -ForegroundColor Red }
