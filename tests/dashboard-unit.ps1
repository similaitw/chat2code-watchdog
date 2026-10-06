Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\dashboard.ps1")

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
    runner = [pscustomobject]@{
        workingDirectory = "Z:\does-not-exist"
    }
    dashboard = [pscustomobject]@{
        enabled = $true
        statusIssueNumber = 38
        controlRepo = "similaitw/chat2code-control"
        updateSeconds = 60
        runnerVersion = "0.4.1"
    }
}

Assert-True (Test-DashboardConfigured -Config $config) "dashboard configured"
Assert-Equal (Get-DashboardControlRepo -Config $config) "similaitw/chat2code-control" "explicit control repo"

$config.dashboard.enabled = $false
Assert-True (-not (Test-DashboardConfigured -Config $config)) "disabled dashboard rejected"

$config.dashboard.enabled = $true
$config.dashboard.statusIssueNumber = 0
Assert-True (-not (Test-DashboardConfigured -Config $config)) "missing issue rejected"

Write-Host "All Dashboard unit tests passed."
