[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path $PSScriptRoot "config.json"
$TelegramPath = Join-Path $PSScriptRoot "telegram.ps1"
$TaskName = "Chat2Code Watchdog"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "config.json not found."
}
if (-not (Test-Path -LiteralPath $TelegramPath -PathType Leaf)) {
    throw "telegram.ps1 not found."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
. $TelegramPath

if (-not (Test-TelegramConfigured -Config $config)) {
    throw "Telegram is not configured."
}

$chatIds = @()
if ($config.telegram.PSObject.Properties.Name -contains "notificationChatIds") {
    $chatIds = @($config.telegram.notificationChatIds)
}
if ($chatIds.Count -eq 0) {
    $chatIds = @($config.telegram.allowedUserIds)
}
if ($chatIds.Count -eq 0) {
    throw "No Telegram chat target is configured."
}
$chatId = [string]$chatIds[0]

$taskExists = $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
$taskStoppedForTest = $false

Write-Host "=== Chat2Code Watchdog Telegram Diagnose ===" -ForegroundColor Cyan

function Run-DiagnosticStep {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    try {
        & $Action
        Write-Host ("PASS " + $Name) -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host ("FAIL " + $Name + ": " + $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

$allOk = $true

try {
    if ($taskExists) {
        Write-Host "Temporarily stopping Watchdog polling to avoid Telegram getUpdates conflicts..."
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $taskStoppedForTest = $true
        Start-Sleep -Seconds 3
    }

    $ok = Run-DiagnosticStep "getMe" {
        $result = Invoke-TelegramApi -Config $config -Method "getMe"
        if (-not $result.ok) { throw "getMe returned ok=false" }
        Write-Host ("Bot: @" + [string]$result.result.username)
    }
    if (-not $ok) { $allOk = $false }

    $ok = Run-DiagnosticStep "getUpdates" {
        $result = Invoke-TelegramApi -Config $config -Method "getUpdates" -Body @{
            timeout = 0
            allowed_updates = '["message"]'
        }
        if (-not $result.ok) { throw "getUpdates returned ok=false" }
    }
    if (-not $ok) { $allOk = $false }

    $ok = Run-DiagnosticStep "sendMessage plain text" {
        Send-TelegramMessage -Config $config -ChatId $chatId -Text "Chat2Code Telegram diagnostic: plain text OK"
    }
    if (-not $ok) { $allOk = $false }

    $ok = Run-DiagnosticStep "sendMessage main keyboard" {
        Send-TelegramMessage -Config $config -ChatId $chatId -Text "Chat2Code Telegram diagnostic: button menu OK" -ReplyMarkupJson (Get-TelegramMainKeyboardJson)
    }
    if (-not $ok) { $allOk = $false }

    $ok = Run-DiagnosticStep "sendMessage restart confirmation keyboard" {
        Send-TelegramMessage -Config $config -ChatId $chatId -Text "Chat2Code Telegram diagnostic: restart confirmation OK" -ReplyMarkupJson (Get-TelegramRestartConfirmKeyboardJson)
    }
    if (-not $ok) { $allOk = $false }
}
finally {
    if ($taskExists -and $taskStoppedForTest) {
        Write-Host "Restarting Watchdog scheduled task..."
        try {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Write-Host "Watchdog restarted." -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not restart Watchdog automatically. Run: Start-ScheduledTask -TaskName 'Chat2Code Watchdog'"
        }
    }
}

Write-Host ""
if ($allOk) {
    Write-Host "All Telegram diagnostics passed." -ForegroundColor Green
    exit 0
}

Write-Host "One or more Telegram diagnostics failed." -ForegroundColor Red
exit 1
