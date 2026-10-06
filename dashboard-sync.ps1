[CmdletBinding()]
param(
    [switch]$Once
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path $PSScriptRoot "config.json"
$StatePath = Join-Path $PSScriptRoot "runtime\state.json"
$RunnerControlPath = Join-Path $PSScriptRoot "runner-control.ps1"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "config.json not found."
}
if (-not (Test-Path -LiteralPath $RunnerControlPath -PathType Leaf)) {
    throw "runner-control.ps1 not found."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
. $RunnerControlPath

function Test-DashboardConfigured {
    param([pscustomobject]$Config)

    if (-not ($Config.PSObject.Properties.Name -contains "dashboard")) { return $false }
    if (-not [bool]$Config.dashboard.enabled) { return $false }
    if (-not [string]$Config.dashboard.url) { return $false }
    if (-not [string]$Config.dashboard.ingestSecret) { return $false }
    return $true
}

function Get-TaskStatus {
    param([string[]]$Labels)

    if ($Labels -contains "chat2code:running") { return "running" }
    if ($Labels -contains "chat2code:ready") { return "ready" }
    if ($Labels -contains "chat2code:failed") { return "failed" }
    if ($Labels -contains "chat2code:done") { return "done" }
    return "other"
}

function Get-Chat2CodeMetadata {
    param([string]$Body)

    if (-not $Body) { return $null }

    $match = [regex]::Match(
        $Body,
        '<!--\s*chat2code\s*(\{[\s\S]*?\})\s*-->',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $match.Success) { return $null }

    try {
        return $match.Groups[1].Value | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-ControlIssues {
    param([string]$Repository)

    $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
    if (-not $gh) {
        $gh = Get-Command gh -ErrorAction SilentlyContinue
    }
    if (-not $gh) {
        throw "GitHub CLI (gh) not found."
    }

    $endpoint = "repos/" + $Repository + "/issues?state=open&per_page=100"
    $json = & $gh.Source api $endpoint 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh api failed while reading control queue."
    }

    $combined = ($json -join [Environment]::NewLine)
    $items = $combined | ConvertFrom-Json
    return @($items | Where-Object { -not $_.pull_request })
}

function Convert-ControlIssue {
    param($Issue)

    $labels = @()
    foreach ($label in @($Issue.labels)) {
        if ($label -is [string]) {
            $labels += $label
        }
        elseif ($label.name) {
            $labels += [string]$label.name
        }
    }

    $meta = Get-Chat2CodeMetadata -Body ([string]$Issue.body)
    $provider = $null
    $project = $null
    $repo = $null
    $baseBranch = $null

    if ($meta) {
        if ($meta.PSObject.Properties.Name -contains "provider") { $provider = [string]$meta.provider }
        if ($meta.PSObject.Properties.Name -contains "project") { $project = [string]$meta.project }
        if ($meta.PSObject.Properties.Name -contains "repo") { $repo = [string]$meta.repo }
        if ($meta.PSObject.Properties.Name -contains "base_branch") { $baseBranch = [string]$meta.base_branch }
    }

    if (-not $provider) {
        foreach ($label in $labels) {
            if ($label -like "provider=*") {
                $provider = $label.Substring("provider=".Length)
                break
            }
        }
    }

    return [ordered]@{
        number = [int]$Issue.number
        title = [string]$Issue.title
        url = [string]$Issue.html_url
        status = Get-TaskStatus -Labels $labels
        provider = $provider
        project = $project
        repo = $repo
        baseBranch = $baseBranch
        updatedAt = [string]$Issue.updated_at
        labels = @($labels)
    }
}

function Get-RunnerSnapshot {
    $runner = @(Get-Chat2CodeRunnerProcesses -Config $config)

    $state = $null
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {}
    }

    $workers = 2
    if ($config.dashboard.PSObject.Properties.Name -contains "workers") {
        $workers = [Math]::Max(1, [int]$config.dashboard.workers)
    }

    $pid = $null
    if ($runner.Count -gt 0) { $pid = [int]$runner[0].ProcessId }

    $restartCount = $null
    $lastHeartbeat = (Get-Date).ToString("o")
    if ($state) {
        if ($state.PSObject.Properties.Name -contains "restartCount") {
            $restartCount = [int]$state.restartCount
        }
        if ($state.PSObject.Properties.Name -contains "lastCheck" -and $state.lastCheck) {
            $lastHeartbeat = [string]$state.lastCheck
        }
    }

    $version = $null
    $runnerRoot = [string]$config.runner.workingDirectory
    $versionPath = Join-Path $runnerRoot "VERSION"
    if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
        try { $version = (Get-Content -LiteralPath $versionPath -Raw).Trim() } catch {}
    }
    if (-not $version) {
        $pyprojectPath = Join-Path $runnerRoot "pyproject.toml"
        if (Test-Path -LiteralPath $pyprojectPath -PathType Leaf) {
            try {
                $versionLine = Get-Content -LiteralPath $pyprojectPath | Where-Object { $_ -match '^version\s*=\s*"([^"]+)"' } | Select-Object -First 1
                if ($versionLine -and $versionLine -match '^version\s*=\s*"([^"]+)"') {
                    $version = $Matches[1]
                }
            }
            catch {}
        }
    }

    return [ordered]@{
        status = if ($runner.Count -gt 0) { "running" } else { "offline" }
        pid = $pid
        workers = $workers
        activeWorkers = $null
        lastHeartbeat = $lastHeartbeat
        restartCount = $restartCount
        machine = $env:COMPUTERNAME
        version = $version
    }
}

function Send-DashboardSnapshot {
    if (-not (Test-DashboardConfigured -Config $config)) {
        throw "Dashboard is not configured. Run DASHBOARD-SETUP.bat."
    }

    $repository = "similaitw/chat2code-control"
    if ($config.dashboard.PSObject.Properties.Name -contains "controlRepository" -and $config.dashboard.controlRepository) {
        $repository = [string]$config.dashboard.controlRepository
    }

    $issues = @(Get-ControlIssues -Repository $repository)
    $tasks = @($issues | ForEach-Object { Convert-ControlIssue -Issue $_ })

    $runningCount = @($tasks | Where-Object { $_.status -eq "running" }).Count
    $runner = Get-RunnerSnapshot
    $runner.activeWorkers = $runningCount

    $payload = [ordered]@{
        repository = $repository
        tasks = $tasks
        runner = $runner
    } | ConvertTo-Json -Depth 10

    $baseUrl = ([string]$config.dashboard.url).TrimEnd("/")
    $uri = $baseUrl + "/api/ingest"

    $headers = @{
        Authorization = "Bearer " + [string]$config.dashboard.ingestSecret
        "Content-Type" = "application/json"
    }

    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $payload -TimeoutSec 25 -ErrorAction Stop
        return $response
    }
    catch {
        throw "Dashboard upload failed."
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    if ($Once) {
        $result = Send-DashboardSnapshot
        Write-Host ("Dashboard sync OK. taskCount=" + [string]$result.taskCount) -ForegroundColor Green
        exit 0
    }

    $interval = 30
    if ($config.dashboard.PSObject.Properties.Name -contains "syncSeconds") {
        $interval = [Math]::Max(15, [int]$config.dashboard.syncSeconds)
    }

    while ($true) {
        try {
            $result = Send-DashboardSnapshot
            Write-Host ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + " Dashboard sync OK taskCount=" + [string]$result.taskCount)
        }
        catch {
            Write-Warning $_.Exception.Message
        }
        Start-Sleep -Seconds $interval
    }
}
