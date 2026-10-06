Set-StrictMode -Version 2.0

function Test-DashboardConfigured {
    param([pscustomobject]$Config)

    if (-not ($Config.PSObject.Properties.Name -contains "dashboard")) { return $false }
    if (-not [bool]$Config.dashboard.enabled) { return $false }
    if (-not $Config.dashboard.statusIssueNumber) { return $false }
    return $true
}

function Get-DashboardControlRepo {
    param([pscustomobject]$Config)

    if ($Config.dashboard.PSObject.Properties.Name -contains "controlRepo" -and $Config.dashboard.controlRepo) {
        return [string]$Config.dashboard.controlRepo
    }

    $runnerConfigPath = Join-Path ([string]$Config.runner.workingDirectory) "config.json"
    if (Test-Path -LiteralPath $runnerConfigPath -PathType Leaf) {
        try {
            $runnerConfig = Get-Content -LiteralPath $runnerConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($runnerConfig.control_repo) { return [string]$runnerConfig.control_repo }
        }
        catch {}
    }

    return "similaitw/chat2code-control"
}

function Get-DashboardRunnerSettings {
    param([pscustomobject]$Config)

    $workers = $null
    $version = $null

    $runnerConfigPath = Join-Path ([string]$Config.runner.workingDirectory) "config.json"
    if (Test-Path -LiteralPath $runnerConfigPath -PathType Leaf) {
        try {
            $runnerConfig = Get-Content -LiteralPath $runnerConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($runnerConfig.PSObject.Properties.Name -contains "max_workers") {
                $workers = [int]$runnerConfig.max_workers
            }
        }
        catch {}
    }

    if ($Config.dashboard.PSObject.Properties.Name -contains "runnerVersion" -and $Config.dashboard.runnerVersion) {
        $version = [string]$Config.dashboard.runnerVersion
    }

    return [pscustomobject]@{
        Workers = $workers
        Version = $version
    }
}

function Invoke-GhCapture {
    param([string[]]$Arguments)

    $output = & gh @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $message = ($output | Out-String).Trim()
        if ($message.Length -gt 500) { $message = $message.Substring(0, 500) }
        throw ("gh command failed (exit " + $exitCode + "): " + $message)
    }
    return (($output | Out-String).Trim())
}

function Get-DashboardActiveWorkerCount {
    param(
        [Parameter(Mandatory = $true)][string]$ControlRepo
    )

    $raw = Invoke-GhCapture -Arguments @(
        "issue", "list",
        "--repo", $ControlRepo,
        "--state", "open",
        "--label", "chat2code:running",
        "--limit", "100",
        "--json", "number"
    )

    if (-not $raw) { return 0 }
    try {
        return @($raw | ConvertFrom-Json).Count
    }
    catch {
        throw "Unable to parse running issue count from gh"
    }
}

function Update-DashboardStatus {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [scriptblock]$Logger
    )

    if (-not (Test-DashboardConfigured -Config $Config)) { return $null }

    $controlRepo = Get-DashboardControlRepo -Config $Config
    $issueNumber = [int]$Config.dashboard.statusIssueNumber

    $auth = & gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated"
    }

    $settings = Get-DashboardRunnerSettings -Config $Config
    $activeWorkers = Get-DashboardActiveWorkerCount -ControlRepo $controlRepo

    $pidValue = $null
    if (@($State.runnerPids).Count -gt 0) {
        $pidValue = [int]@($State.runnerPids)[0]
    }

    $payload = [ordered]@{
        status = [string]$State.runnerStatus
        pid = $pidValue
        workers = $settings.Workers
        activeWorkers = $activeWorkers
        lastHeartbeat = (Get-Date).ToString("o")
        restartCount = [int]$State.restartCount
        machine = [string]$env:COMPUTERNAME
        version = $settings.Version
    }

    $json = $payload | ConvertTo-Json -Depth 5
    $body = "<!-- chat2code-runner-status" + [Environment]::NewLine +
        $json + [Environment]::NewLine +
        "-->" + [Environment]::NewLine + [Environment]::NewLine +
        "此 Issue 由 Chat2Code Watchdog 自動更新，提供 Dashboard 唯讀顯示 Runner 心跳與狀態。" + [Environment]::NewLine + [Environment]::NewLine +
        "請勿加上 `chat2code:ready` 標籤，避免被 Runner 當成工作票。"

    $tempPath = Join-Path $env:TEMP ("chat2code-dashboard-status-" + [guid]::NewGuid().ToString("N") + ".md")
    try {
        Set-Content -LiteralPath $tempPath -Value $body -Encoding UTF8
        [void](Invoke-GhCapture -Arguments @(
            "issue", "edit", [string]$issueNumber,
            "--repo", $controlRepo,
            "--body-file", $tempPath
        ))
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }

    $updated = (Get-Date).ToString("o")
    if ($Logger) {
        & $Logger "DEBUG" ("Dashboard heartbeat updated issue #" + $issueNumber + " activeWorkers=" + $activeWorkers)
    }
    return $updated
}
