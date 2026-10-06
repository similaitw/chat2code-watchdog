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
    if (-not $file) { return }
    if ($file.Length -lt ($MaxMB * 1MB)) { return }

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
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")]
        [string]$Level,
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
        watchdogStatus = "starting"
        runnerStatus   = "unknown"
        runnerPids     = @()
        lastCheck      = $null
        lastUpdated    = $null
        lastRestart    = $null
        restartCount   = 0
        restartHistory = @()
        lastError      = $null
    }
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return New-DefaultState
    }

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
        Write-Log -Level "WARN" -Message "state.json could not be read; starting with a fresh state: $($_.Exception.Message)"
        return New-DefaultState
    }
}

function Get-RestartHistoryInWindow {
    param(
        [object[]]$History,
        [int]$WindowMinutes
    )

    $cutoff = (Get-Date).AddMinutes(-1 * $WindowMinutes)
    $valid = @()
    foreach ($entry in @($History)) {
        if (-not $entry) { continue }
        try {
            $dt = [DateTimeOffset]::Parse([string]$entry).LocalDateTime
            if ($dt -ge $cutoff) {
                $valid += [string]$entry
            }
        }
        catch {
            # Ignore malformed legacy entries.
        }
    }
    return @($valid)
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-Host "Missing config.json. Run .\install.ps1 first or copy config.example.json to config.json." -ForegroundColor Red
    exit 2
}

try {
    $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Host "Invalid config.json: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

. (Join-Path $ScriptRoot "runner-control.ps1")

# Prevent two watchdog loops from racing and restarting the same Runner.
$mutex = New-Object System.Threading.Mutex($false, "Local\Chat2CodeWatchdog")
$hasMutex = $false
try {
    try {
        $hasMutex = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        # Previous Watchdog crashed without releasing the mutex. Ownership is granted to us.
        $hasMutex = $true
        Write-Log -Level "WARN" -Message "Recovered an abandoned Watchdog mutex"
    }

    if (-not $hasMutex) {
        Write-Host "Chat2Code Watchdog is already running." -ForegroundColor Yellow
        exit 0
    }

    $hadHealthCheckError = $false
    $state = Load-State
    $state.watchdogStatus = "running"
    $state.lastError = $null
    Save-State -State $state
    Write-Log -Level "INFO" -Message "Watchdog started (Once=$Once)"

    $interval = [Math]::Max(10, [int]$Config.runner.checkIntervalSeconds)
    $maxAttempts = [Math]::Max(1, [int]$Config.watchdog.maxRestartAttempts)
    $windowMinutes = [Math]::Max(1, [int]$Config.watchdog.restartWindowMinutes)
    $autoRestart = [bool]$Config.watchdog.autoRestart

    do {
        try {
            $now = Get-Date
            $runnerProcesses = @(Get-Chat2CodeRunnerProcesses -Config $Config)

            $state.lastCheck = $now.ToString("o")
            $state.restartHistory = @(Get-RestartHistoryInWindow -History @($state.restartHistory) -WindowMinutes $windowMinutes)
            $state.restartCount = @($state.restartHistory).Count

            if ($runnerProcesses.Count -gt 0) {
                $state.runnerStatus = "running"
                $state.runnerPids = @($runnerProcesses.ProcessId)
                $state.lastError = $null
                Write-Log -Level "DEBUG" -Message "Runner healthy PID=$($runnerProcesses[0].ProcessId)"
            }
            else {
                $state.runnerStatus = "offline"
                $state.runnerPids = @()
                Write-Log -Level "WARN" -Message "Runner process missing"

                if ($autoRestart) {
                    $attempts = @($state.restartHistory).Count
                    if ($attempts -ge $maxAttempts) {
                        $state.runnerStatus = "failed"
                        $state.lastError = "Automatic restart limit reached ($attempts/$maxAttempts within $windowMinutes minutes)"
                        Write-Log -Level "ERROR" -Message $state.lastError
                    }
                    else {
                        $attemptNumber = $attempts + 1
                        Write-Log -Level "INFO" -Message "Restart attempt $attemptNumber/$maxAttempts"

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
                        }
                        else {
                            $state.runnerStatus = "offline"
                            $state.runnerPids = @()
                            $state.lastError = "Runner start failed: $($result.Message)"
                            Write-Log -Level "ERROR" -Message $state.lastError
                        }
                    }
                }
            }
        }
        catch {
            $hadHealthCheckError = $true
            $state.lastError = $_.Exception.Message
            Write-Log -Level "ERROR" -Message "Health check failed: $($_.Exception.Message)"
        }

        Save-State -State $state

        if (-not $Once) {
            Start-Sleep -Seconds $interval
        }
    } while (-not $Once)
}
finally {
    try {
        if ($state) {
            if ($Once) {
                $state.watchdogStatus = "stopped"
            }
            else {
                $state.watchdogStatus = "stopping"
            }
            Save-State -State $state
        }
    } catch {}

    if ($hasMutex) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    if ($mutex) { $mutex.Dispose() }
}

if ($Once -and $hadHealthCheckError) {
    exit 1
}
