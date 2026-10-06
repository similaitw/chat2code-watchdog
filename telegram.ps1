Set-StrictMode -Version 2.0

function Test-TelegramConfigured {
    param([pscustomobject]$Config)

    if (-not ($Config.PSObject.Properties.Name -contains "telegram")) { return $false }
    if (-not [bool]$Config.telegram.enabled) { return $false }
    if (-not [string]$Config.telegram.botToken) { return $false }
    if (@($Config.telegram.allowedUserIds).Count -eq 0) { return $false }
    return $true
}

function Invoke-TelegramApi {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$Method,
        [hashtable]$Body = @{},
        [int]$TimeoutSeconds = 15
    )

    $token = [string]$Config.telegram.botToken
    if (-not $token) { throw "Telegram Bot Token is not configured" }
    $uri = "https://api.telegram.org/bot" + $token + "/" + $Method

    try {
        return Invoke-RestMethod -Method Post -Uri $uri -Body $Body -TimeoutSec $TimeoutSeconds -ErrorAction Stop
    }
    catch {
        throw "Telegram API request failed for method " + $Method
    }
}

function Send-TelegramMessage {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$ChatId,
        [Parameter(Mandatory = $true)][string]$Text
    )

    if ($Text.Length -gt 3900) {
        $Text = $Text.Substring(0, 3900) + [Environment]::NewLine + "... (truncated)"
    }

    [void](Invoke-TelegramApi -Config $Config -Method "sendMessage" -Body @{
        chat_id = $ChatId
        text = $Text
        disable_web_page_preview = "true"
    })
}


function Send-TelegramNotification {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $targets = @()
    if ($Config.telegram.PSObject.Properties.Name -contains "notificationChatIds") {
        $targets = @($Config.telegram.notificationChatIds)
    }
    if ($targets.Count -eq 0) {
        $targets = @($Config.telegram.allowedUserIds)
    }

    foreach ($chatId in $targets) {
        if (-not $chatId) { continue }
        try {
            Send-TelegramMessage -Config $Config -ChatId ([string]$chatId) -Text $Text
        }
        catch {
            # Keep notification failure isolated from Watchdog health recovery.
        }
    }
}
function Get-TelegramUpdates {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [long]$Offset = 0,
        [int]$TimeoutSeconds = 2
    )

    $body = @{
        timeout = $TimeoutSeconds
        allowed_updates = '["message"]'
    }
    if ($Offset -gt 0) { $body.offset = $Offset }

    $response = Invoke-TelegramApi -Config $Config -Method "getUpdates" -Body $body -TimeoutSeconds ($TimeoutSeconds + 10)
    if (-not $response.ok) { throw "Telegram getUpdates returned ok=false" }
    return @($response.result)
}

function Test-TelegramAuthorized {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$UserId
    )

    foreach ($allowed in @($Config.telegram.allowedUserIds)) {
        if ([string]$allowed -eq $UserId) { return $true }
    }
    return $false
}

function Get-TelegramCommand {
    param([string]$Text)

    if (-not $Text) { return "" }
    $firstToken = ($Text.Trim() -split "\s+")[0]
    if (-not $firstToken.StartsWith("/")) { return "" }
    return (($firstToken -split "@")[0]).ToLowerInvariant()
}

function Get-Chat2CodeStatusText {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][pscustomobject]$State
    )

    $runner = @(Get-Chat2CodeRunnerProcesses -Config $Config)
    $runnerStatus = if ($runner.Count -gt 0) { "RUNNING" } else { "OFFLINE" }
    $pids = if ($runner.Count -gt 0) { (@($runner.ProcessId) -join ", ") } else { "-" }
    $lastCheck = if ($State.lastCheck) { [string]$State.lastCheck } else { "-" }
    $lastRestart = if ($State.lastRestart) { [string]$State.lastRestart } else { "-" }
    $nl = [Environment]::NewLine

    return "Chat2Code Watchdog" + $nl + $nl +
        "PC: ONLINE" + $nl +
        "Watchdog: RUNNING" + $nl +
        "Runner: " + $runnerStatus + $nl +
        "PID(s): " + $pids + $nl + $nl +
        "Last check: " + $lastCheck + $nl +
        "Auto restarts: " + [string]$State.restartCount + $nl +
        "Last restart: " + $lastRestart
}

function Get-RedactedRecentLog {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [int]$Lines = 30
    )

    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return "No watchdog log exists yet." }

    $nl = [Environment]::NewLine
    $text = (Get-Content -LiteralPath $LogPath -Tail $Lines -Encoding UTF8) -join $nl
    $token = [string]$Config.telegram.botToken
    if ($token) { $text = $text.Replace($token, "[REDACTED_TELEGRAM_TOKEN]") }

    $patterns = @(
        '(?i)\b\d{6,}:[A-Za-z0-9_-]{20,}\b',
        '(?i)\bghp_[A-Za-z0-9]{20,}\b',
        '(?i)\bgithub_pat_[A-Za-z0-9_]{20,}\b',
        '(?i)\bsk-[A-Za-z0-9_-]{20,}\b'
    )
    foreach ($pattern in $patterns) { $text = [regex]::Replace($text, $pattern, "[REDACTED]") }

    if ($text.Length -gt 3500) {
        $text = "... (truncated)" + $nl + $text.Substring($text.Length - 3500)
    }
    return $text
}

function Invoke-TelegramCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)]$Update,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [scriptblock]$Logger
    )

    if (-not $Update.message -or -not $Update.message.from -or -not $Update.message.chat) { return $State }

    $userId = [string]$Update.message.from.id
    $chatId = [string]$Update.message.chat.id
    $command = Get-TelegramCommand -Text ([string]$Update.message.text)
    if (-not $command) { return $State }

    if (-not (Test-TelegramAuthorized -Config $Config -UserId $userId)) {
        if ($Logger) { & $Logger "WARN" ("Unauthorized Telegram command ignored userId=" + $userId + " command=" + $command) }
        return $State
    }

    if ($Logger) { & $Logger "INFO" ("Authorized Telegram command userId=" + $userId + " command=" + $command) }
    $nl = [Environment]::NewLine

    switch ($command) {
        "/status" {
            Send-TelegramMessage -Config $Config -ChatId $chatId -Text (Get-Chat2CodeStatusText -Config $Config -State $State)
        }
        "/restart" {
            Send-TelegramMessage -Config $Config -ChatId $chatId -Text "Restarting Chat2Code Runner..."
            $result = Restart-Chat2CodeRunner -Config $Config -Logger $Logger
            $State.lastRestart = (Get-Date).ToString("o")
            if (-not ($State.PSObject.Properties.Name -contains "manualRestartCount")) {
                $State | Add-Member -NotePropertyName manualRestartCount -NotePropertyValue 0
            }
            $State.manualRestartCount = [int]$State.manualRestartCount + 1

            if ($result.Success) {
                $State.runnerStatus = "running"
                $State.runnerPids = @($result.Pids)
                $State.lastError = $null
                Send-TelegramMessage -Config $Config -ChatId $chatId -Text ("Chat2Code Runner restarted successfully." + $nl + "PID(s): " + (@($result.Pids) -join ", "))
            }
            else {
                $State.runnerStatus = "offline"
                $State.runnerPids = @()
                $State.lastError = "Manual restart failed: " + [string]$result.Message
                Send-TelegramMessage -Config $Config -ChatId $chatId -Text ("Chat2Code Runner restart failed." + $nl + "Use /log to inspect recent watchdog events.")
            }
        }
        "/log" {
            $logText = Get-RedactedRecentLog -Config $Config -LogPath $LogPath -Lines 30
            Send-TelegramMessage -Config $Config -ChatId $chatId -Text ("Recent Watchdog log:" + $nl + $nl + $logText)
        }
        "/start" {
            $helpText = "/status - view Runner status" + $nl + "/restart - restart Chat2Code Runner" + $nl + "/log - last 30 Watchdog log lines" + $nl + "/help - show this help"
            Send-TelegramMessage -Config $Config -ChatId $chatId -Text ("Chat2Code Watchdog" + $nl + $nl + $helpText)
        }
        "/help" {
            $helpText = "/status - view Runner status" + $nl + "/restart - restart Chat2Code Runner" + $nl + "/log - last 30 Watchdog log lines" + $nl + "/help - show this help"
            Send-TelegramMessage -Config $Config -ChatId $chatId -Text ("Chat2Code Watchdog" + $nl + $nl + $helpText)
        }
        default {
            Send-TelegramMessage -Config $Config -ChatId $chatId -Text "Unknown command. Use /help."
        }
    }

    return $State
}
