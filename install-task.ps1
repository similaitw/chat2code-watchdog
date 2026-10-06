[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$TaskName = "Chat2Code Watchdog"
$WatchdogPath = Join-Path $PSScriptRoot "watchdog.ps1"

if (-not (Test-Path -LiteralPath $WatchdogPath)) {
    throw "watchdog.ps1 not found: $WatchdogPath"
}

$userId = if ($env:USERDOMAIN) { "$($env:USERDOMAIN)\$($env:USERNAME)" } else { $env:USERNAME }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
$runLevel = if ($isAdmin) { "Highest" } else { "Limited" }

$actionArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatchdogPath`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArgs -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel $runLevel
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings
Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null

Write-Host "Scheduled task installed: $TaskName" -ForegroundColor Green
Write-Host "Trigger: Windows sign-in for $userId"
Write-Host "Run level: $runLevel"

try {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host "Task started. LastTaskResult=$($info.LastTaskResult)" -ForegroundColor Green
}
catch {
    Write-Warning "Task was installed but could not be started immediately: $($_.Exception.Message)"
}
