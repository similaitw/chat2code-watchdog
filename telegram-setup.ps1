[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ConfigPath = Join-Path $PSScriptRoot "config.json"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "config.json not found. Run INSTALL.bat first."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host "=== Chat2Code Watchdog Telegram Setup ===" -ForegroundColor Cyan
Write-Host "Create a bot with @BotFather first, then paste its Bot Token here."

$secureToken = Read-Host "Bot Token" -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
try {
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
}

if (-not $token) { throw "Bot Token is empty." }

function Invoke-SetupTelegramApi {
    param([string]$Method, [hashtable]$Body = @{}, [int]$TimeoutSeconds = 15)
    $uri = "https://api.telegram.org/bot" + $token + "/" + $Method
    try {
        return Invoke-RestMethod -Method Post -Uri $uri -Body $Body -TimeoutSec $TimeoutSeconds -ErrorAction Stop
    }
    catch {
        throw "Telegram API request failed for method " + $Method + ". Check the Bot Token and network connection."
    }
}

$me = Invoke-SetupTelegramApi -Method "getMe"
if (-not $me.ok) { throw "Telegram Bot Token verification failed." }
$botUsername = [string]$me.result.username
Write-Host ("Bot verified: @" + $botUsername) -ForegroundColor Green

# Drain old updates so setup only accepts the next message sent intentionally.
$offset = 0
$existing = Invoke-SetupTelegramApi -Method "getUpdates" -Body @{ timeout = 0; allowed_updates = '["message"]' }
foreach ($u in @($existing.result)) {
    $candidate = [long]$u.update_id + 1
    if ($candidate -gt $offset) { $offset = $candidate }
}

Write-Host ""
Write-Host ("Open Telegram, find @" + $botUsername + ", and send /start now.") -ForegroundColor Yellow
Write-Host "Waiting up to 120 seconds..."

$deadline = (Get-Date).AddSeconds(120)
$selectedUserId = $null
$selectedChatId = $null
$selectedName = $null

while ((Get-Date) -lt $deadline -and -not $selectedUserId) {
    $body = @{ timeout = 5; allowed_updates = '["message"]' }
    if ($offset -gt 0) { $body.offset = $offset }
    $updates = Invoke-SetupTelegramApi -Method "getUpdates" -Body $body -TimeoutSeconds 15

    foreach ($u in @($updates.result)) {
        $offset = [long]$u.update_id + 1
        if (-not $u.message -or -not $u.message.from -or -not $u.message.chat) { continue }
        $text = [string]$u.message.text
        if ($text -notlike "/start*") { continue }

        $selectedUserId = [string]$u.message.from.id
        $selectedChatId = [string]$u.message.chat.id
        $selectedName = [string]$u.message.from.first_name
        break
    }
}

if (-not $selectedUserId) {
    throw "Timed out waiting for /start. Run telegram-setup.ps1 again."
}

$telegram = [pscustomobject]@{
    enabled = $true
    botToken = $token
    allowedUserIds = @($selectedUserId)
    notificationChatIds = @($selectedChatId)
    pollSeconds = 5
}

if ($config.PSObject.Properties.Name -contains "telegram") {
    $config.telegram = $telegram
}
else {
    $config | Add-Member -NotePropertyName telegram -NotePropertyValue $telegram
}

$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

$commandsJson = @(
    @{ command = "status"; description = "查看 Runner 狀態" },
    @{ command = "restart"; description = "重新啟動 Runner" },
    @{ command = "log"; description = "查看最近紀錄" },
    @{ command = "help"; description = "顯示操作按鈕" }
) | ConvertTo-Json -Depth 5 -Compress

try {
    [void](Invoke-SetupTelegramApi -Method "setMyCommands" -Body @{ commands = $commandsJson })
}
catch {
    Write-Warning "Bot command menu could not be registered; button menu will still work."
}

$keyboardJson = @{
    keyboard = @(
        @(
            @{ text = "📊 狀態" },
            @{ text = "📜 最近紀錄" }
        ),
        @(
            @{ text = "🔄 重啟" },
            @{ text = "❓ 說明" }
        )
    )
    resize_keyboard = $true
    is_persistent = $true
    input_field_placeholder = "點選下方按鈕"
} | ConvertTo-Json -Depth 8 -Compress

$nl = [Environment]::NewLine
$message = "Chat2Code Watchdog Telegram setup complete." + $nl +
    "Authorized user: " + $selectedName + " (" + $selectedUserId + ")" + $nl +
    "Available commands: /status /restart /log /help"

[void](Invoke-SetupTelegramApi -Method "sendMessage" -Body @{ chat_id = $selectedChatId; text = $message; reply_markup = $keyboardJson })

Write-Host ""
Write-Host ("Authorized Telegram user ID: " + $selectedUserId) -ForegroundColor Green
Write-Host "Saved locally to config.json (ignored by Git)." -ForegroundColor Green
Write-Host "Restarting Chat2Code Watchdog scheduled task..."

try {
    Stop-ScheduledTask -TaskName "Chat2Code Watchdog" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-ScheduledTask -TaskName "Chat2Code Watchdog" -ErrorAction Stop
    Write-Host "Watchdog restarted." -ForegroundColor Green
}
catch {
    Write-Warning "Telegram is configured, but the scheduled task could not be restarted automatically. Restart it manually."
}

Write-Host "Setup complete. Send /status to the bot." -ForegroundColor Cyan
