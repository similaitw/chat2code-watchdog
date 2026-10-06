Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\telegram.ps1")

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    if ($Actual -ne $Expected) {
        throw "$Name failed. Expected=[$Expected] Actual=[$Actual]"
    }
    Write-Host "PASS $Name"
}

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "$Name failed." }
    Write-Host "PASS $Name"
}

$config = [pscustomobject]@{
    telegram = [pscustomobject]@{
        enabled = $true
        botToken = "123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
        allowedUserIds = @("10001")
        pollSeconds = 5
    }
}

Assert-True (Test-TelegramConfigured -Config $config) "configured bot"
Assert-True (Test-TelegramAuthorized -Config $config -UserId "10001") "authorized user"
Assert-True (-not (Test-TelegramAuthorized -Config $config -UserId "99999")) "unauthorized user rejected"
Assert-Equal (Get-TelegramCommand -Text "/status") "/status" "status command"
Assert-Equal (Get-TelegramCommand -Text "/restart@mybot extra") "/restart" "group bot command"
Assert-Equal (Get-TelegramCommand -Text "hello") "" "non-command ignored"
Assert-Equal (Get-TelegramCommand -Text "📊 狀態") "/status" "status button mapping"
Assert-Equal (Get-TelegramCommand -Text "📋 任務") "/tasks" "tasks button mapping"
Assert-Equal (Get-TelegramCommand -Text "📜 最近紀錄") "/log" "log button mapping"
Assert-Equal (Get-TelegramCommand -Text "🔄 重啟") "/restart" "restart button mapping"
Assert-Equal (Get-TelegramCommand -Text ("🔄" + [char]0xFE0F + " 重啟")) "/restart" "restart button variation-selector mapping"
Assert-Equal (Get-TelegramCommand -Text "重啟") "/restart" "restart keyword mapping"
Assert-Equal (Get-TelegramCommand -Text "✅ 確認重啟") "/restart-confirm" "restart confirm mapping"
Assert-Equal (Get-TelegramCommand -Text "❌ 取消") "/cancel" "restart cancel mapping"

$mainKeyboard = Get-TelegramMainKeyboardJson | ConvertFrom-Json
Assert-True ($mainKeyboard.is_persistent) "main keyboard persistent"
Assert-Equal $mainKeyboard.keyboard.Count 3 "main keyboard row count"
Assert-Equal $mainKeyboard.keyboard[0].Count 2 "main keyboard first row width"
Assert-Equal $mainKeyboard.keyboard[1].Count 2 "main keyboard second row width"
Assert-Equal $mainKeyboard.keyboard[2].Count 1 "main keyboard third row width"
Assert-Equal $mainKeyboard.keyboard[0][0].text "📊 狀態" "main keyboard status label"
$confirmKeyboard = Get-TelegramRestartConfirmKeyboardJson | ConvertFrom-Json
Assert-Equal $confirmKeyboard.keyboard.Count 1 "confirm keyboard row count"
Assert-Equal $confirmKeyboard.keyboard[0].Count 2 "confirm keyboard row width"
Assert-Equal $confirmKeyboard.keyboard[0][0].text "✅ 確認重啟" "confirm keyboard label"

$tempLog = Join-Path $env:TEMP ("chat2code-watchdog-test-" + [guid]::NewGuid().ToString("N") + ".log")
try {
    $token = [string]$config.telegram.botToken
    Set-Content -LiteralPath $tempLog -Encoding UTF8 -Value @(
        "normal log line",
        ("token=" + $token),
        "ghp_123456789012345678901234567890"
    )
    $redacted = Get-RedactedRecentLog -Config $config -LogPath $tempLog -Lines 30
    Assert-True (-not $redacted.Contains($token)) "Telegram token redacted"
    Assert-True ($redacted.Contains("[REDACTED")) "redaction marker present"
}
finally {
    Remove-Item -LiteralPath $tempLog -Force -ErrorAction SilentlyContinue
}

Write-Host "All Telegram unit tests passed."
