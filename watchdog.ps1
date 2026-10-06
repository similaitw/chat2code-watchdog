[CmdletBinding()]
param(
    [switch]$Once
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ScriptRoot = $PSScriptRoot
$ConfigPath = Join-Path $ScriptRoot "config.json"
$RuntimeDir = Join-Path $ScriptRoot "runtime"
$LogDir = Join-Path $ScriptRoot "logs"
$StatePath = Join-Path $RuntimeDir "state.json"
$LogPath = Join-Path $LogDir "watchdog.log"

New-Item -ItemType Directory -Force -Path $RuntimeDir, $LogDir | Out-Null

function Rotate-LogIfNeeded {
    param([string]$Path, [int]$MaxMB = 5, [int]$Keep = 5)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $file = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $file -or $file.Length -lt ($MaxMB * 1MB)) { return }

    for ($i = $Keep - 1; $i -ge 1; $i--) {
        $source = "$Path.$i"
        $target = "$Path.$($i + 1)"
        if (Test-Path -LiteralPath $source) {
            Move-Item -LiteralPath $source -Destination $target -Force -ErrorAction SilentlyContinue
        }
    }
    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param(
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")][string]$Level,
        [string]$Message
    )
    Rotate-LogIfNeeded -Path $LogPath
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp [$Level] $Message"
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

$Logger = {
    param($Level, $Message)
    Write-Log -Level $Level -Message $Message
}

function Save-State {
    param([pscustomobject]$State)
    $State.lastUpdated = (Get-Date).ToString("o")
    $json = $State | ConvertTo-Json -Depth 8
    $tmp = "$StatePath.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

function New-DefaultState {
    return [pscustomobject]@{
        watchdogStatus     = "starting"
        runnerStatus       = "unknown"
        runnerPids         = @()
        lastCheck          = $null
        lastUpdated        = $null
        lastRestart        = $null
        restartCount       = 0
        restartHistory     = @()
        manualRestartCount = 0
        telegramOffset     = 0
        telegramLastError  = $null
        dashboardLastUpdate = $null
        dashboardLastError  = $null
        lastError          = $null
    }
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return New-DefaultState }
    try {
        $loaded = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $defaults = New-DefaultState
        foreach ($name in $defaults.PSObject.Properties.Name) {
            if (-not ($loaded.PSObject.Properties.Name -contains $name)) {
                $loaded | Add-Member -NotePropertyName $name -NotePropertyValue $defaults.$name
            }
        }
        return $loaded
    }
    catch {
        Write-Log -Level "WARN" -Message ("state.json could not be read; starting fresh: " + $_.Exception.Message)
        return New-DefaultState
    }
}

function Get-RestartHistoryInWindow {
    param([object[]]$History, [int]$WindowMinutes)
    $cutoff = (Get-Date).AddMinutes(-1 * $WindowMinutes)
    $valid = @()
    foreach ($entry in @($History)) {
        if (-not $entry) { continue }
        try {
            $dt = [DateTimeOffset]::Parse([string]$entry).LocalDateTime
            if ($dt -ge $cutoff) { $valid += [string]$entry }
        }
        catch {}
    }
    return @($valid)
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-Host "Missing config.json. Run .\install.ps1 first." -ForegroundColor Red
    exit 2
}

try {
    $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Host ("Invalid config.json: " + $_.Exception.Message) -ForegroundColor Red
    exit 2
}

. (Join-Path $ScriptRoot "runner-control.ps1")
$telegramModule = Join-Path $ScriptRoot "telegram.ps1"
$telegramModuleAvailable = Test-Path -LiteralPath $telegramModule -PathType Leaf
if ($telegramModuleAvailable) { . $telegramModule }

$dashboardModule = Join-Path $ScriptRoot "dashboard.ps1"
$dashboardModuleAvailable = Test-Path -LiteralPath $dashboardModule -PathType Leaf
if ($dashboardModuleAvailable) { . $dashboardModule }

$mutex = New-Object System.Threading.Mutex($false, "Local\Chat2CodeWatchdog")
$hasMutex = $false
$state = $null
$hadHealthCheckError = $false

try {
    try {
        $hasMutex = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $hasMutex = $true
        Write-Log -Level "WARN" -Message "Recovered an abandoned Watchdog mutex"
    }

    if (-not $hasMutex) {
        Write-Host "Chat2Code Watchdog is already running." -ForegroundColor Yellow
        exit 0
    }

    $state = Load-State
    $state.watchdogStatus = "running"
    $state.lastError = $null
    Save-State -State $state
    Write-Log -Level "INFO" -Message ("Watchdog started (Once=" + [string]$Once + ")")

    $healthInterval = [Math]::Max(10, [int]$Config.runner.checkIntervalSeconds)
    $maxAttempts = [Math]::Max(1, [int]$Config.watchdog.maxRestartAttempts)
    $windowMinutes = [Math]::Max(1, [int]$Config.watchdog.restartWindowMinutes)
    $autoRestart = [bool]$Config.watchdog.autoRestart

    $pollSeconds = 5
    if ($Config.PSObject.Properties.Name -contains "telegram" -and
        $Config.telegram.PSObject.Properties.Name -contains "pollSeconds") {
        $pollSeconds = [Math]::Max(2, [Math]::Min(30, [int]$Config.telegram.pollSeconds))
    }

    $dashboardInterval = 60
    if ($Config.PSObject.Properties.Name -contains "dashboard" -and
        $Config.dashboard.PSObject.Properties.Name -contains "updateSeconds") {
        $dashboardInterval = [Math]::Max(30, [int]$Config.dashboard.updateSeconds)
    }

    $nextHealthCheck = Get-Date
    $nextDashboardUpdate = Get-Date

    do {
        $now = Get-Date

        if ($Once -or $now -ge $nextHealthCheck) {
            try {
                $runnerProcesses = @(Get-Chat2CodeRunnerProcesses -Config $Config)
                $state.lastCheck = $now.ToString("o")
                $state.restartHistory = @(Get-RestartHistoryInWindow -History @($state.restartHistory) -WindowMinutes $windowMinutes)
                $state.restartCount = @($state.restartHistory).Count

                if ($runnerProcesses.Count -gt 0) {
                    $state.runnerStatus = "running"
                    $state.runnerPids = @($runnerProcesses.ProcessId)
                    $state.lastError = $null
                    Write-Log -Level "DEBUG" -Message ("Runner healthy PID=" + [string]$runnerProcesses[0].ProcessId)
                }
                else {
                    $state.runnerStatus = "offline"
                    $state.runnerPids = @()
                    Write-Log -Level "WARN" -Message "Runner process missing"

                    if ($autoRestart) {
                        $attempts = @($state.restartHistory).Count
                        if ($attempts -ge $maxAttempts) {
                            $state.runnerStatus = "failed"
                            $state.lastError = "Automatic restart limit reached (" + $attempts + "/" + $maxAttempts + " within " + $windowMinutes + " minutes)"
                            Write-Log -Level "ERROR" -Message $state.lastError
                        }
                        else {
                            $attemptNumber = $attempts + 1
                            Write-Log -Level "INFO" -Message ("Restart attempt " + $attemptNumber + "/" + $maxAttempts)
                            $attemptTime = (Get-Date).ToString("o")
                            $state.restartHistory = @($state.restartHistory) + @($attemptTime)
                            $state.restartCount = @($state.restartHistory).Count
                            $state.lastRestart = $attemptTime
                            Save-State -State $state

                            $result = Start-Chat2CodeRunner -Config $Config -Logger $Logger
                            if ($result.Success) {
                                $state.runnerStatus = "running"
                                $state.runnerPids = @($result.Pids)
                                $state.lastError = $null
                                if ($telegramModuleAvailable -and (Test-TelegramConfigured -Config $Config)) {
                                    $message = "Chat2Code Runner was offline and Watchdog restarted it successfully." + [Environment]::NewLine +
                                        "PID(s): " + (@($result.Pids) -join ", ") + [Environment]::NewLine +
                                        "Attempt: " + $attemptNumber + "/" + $maxAttempts
                                    Send-TelegramNotification -Config $Config -Text $message
                                }
                            }
                            else {
                                $state.runnerStatus = "offline"
                                $state.runnerPids = @()
                                $state.lastError = "Runner start failed: " + [string]$result.Message
                                Write-Log -Level "ERROR" -Message $state.lastError
                                if ($telegramModuleAvailable -and (Test-TelegramConfigured -Config $Config)) {
                                    $message = "Chat2Code Runner automatic restart failed." + [Environment]::NewLine +
                                        "Attempt: " + $attemptNumber + "/" + $maxAttempts + [Environment]::NewLine +
                                        "Use /log for recent Watchdog events."
                                    Send-TelegramNotification -Config $Config -Text $message
                                }
                            }
                        }
                    }
                }
            }
            catch {
                $hadHealthCheckError = $true
                $state.lastError = $_.Exception.Message
                Write-Log -Level "ERROR" -Message ("Health check failed: " + $_.Exception.Message)
            }

            $nextHealthCheck = (Get-Date).AddSeconds($healthInterval)
            Save-State -State $state
        }

        if ($dashboardModuleAvailable -and (Test-DashboardConfigured -Config $Config) -and ($Once -or (Get-Date) -ge $nextDashboardUpdate)) {
            try {
                $updatedAt = Update-DashboardStatus -Config $Config -State $state -Logger $Logger
                $state.dashboardLastUpdate = $updatedAt
                $state.dashboardLastError = $null
            }
            catch {
                $state.dashboardLastError = $_.Exception.Message
                Write-Log -Level "WARN" -Message ("Dashboard heartbeat failed; will retry: " + $_.Exception.Message)
            }
            $nextDashboardUpdate = (Get-Date).AddSeconds($dashboardInterval)
            Save-State -State $state
        }

        if (-not $Once -and $telegramModuleAvailable -and (Test-TelegramConfigured -Config $Config)) {
            try {
                $updates = @(Get-TelegramUpdates -Config $Config -Offset ([long]$state.telegramOffset) -TimeoutSeconds 1)
                foreach ($update in $updates) {
                    $candidateOffset = [long]$update.update_id + 1
                    if ($candidateOffset -gt [long]$state.telegramOffset) {
                        $state.telegramOffset = $candidateOffset
                    }
                    $state = Invoke-TelegramCommand -Config $Config -State $state -Update $update -LogPath $LogPath -Logger $Logger
                }
                $state.telegramLastError = $null
            }
            catch {
                $state.telegramLastError = $_.Exception.Message
                Write-Log -Level "WARN" -Message ("Telegram polling failed; will retry: " + $_.Exception.Message)
            }
            Save-State -State $state
        }

        if (-not $Once) { Start-Sleep -Seconds $pollSeconds }
    } while (-not $Once)
}
finally {
    try {
        if ($state) {
            $state.watchdogStatus = if ($Once) { "stopped" } else { "stopping" }
            Save-State -State $state
        }
    }
    catch {}

    if ($hasMutex) { try { $mutex.ReleaseMutex() } catch {} }
    if ($mutex) { $mutex.Dispose() }
}

if ($Once -and $hadHealthCheckError) { exit 1 }
