$ErrorActionPreference = "Stop"
$TaskName = "Chat2Code Watchdog"
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task: $TaskName" -ForegroundColor Green
}
else {
    Write-Host "Scheduled task not found: $TaskName" -ForegroundColor Yellow
}
