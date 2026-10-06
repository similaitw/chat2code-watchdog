[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path $PSScriptRoot "config.json"
$SyncPath = Join-Path $PSScriptRoot "dashboard-sync.ps1"
$TaskName = "Chat2Code Watchdog"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "config.json not found. Run INSTALL.bat first."
}
if (-not (Test-Path -LiteralPath $SyncPath -PathType Leaf)) {
    throw "dashboard-sync.ps1 not found."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host "=== Chat2Code Dashboard Setup ===" -ForegroundColor Cyan
$url = (Read-Host "Dashboard URL (example: https://chat2code-dashboard.vercel.app)").Trim()
if (-not $url.StartsWith("https://")) {
    throw "Dashboard URL must use https://"
}

$secureSecret = Read-Host "INGEST_SECRET" -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
try {
    $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
}
if (-not $secret) { throw "INGEST_SECRET is empty." }

$dashboard = [pscustomobject]@{
    enabled = $true
    url = $url.TrimEnd("/")
    ingestSecret = $secret
    controlRepository = "similaitw/chat2code-control"
    syncSeconds = 30
    workers = 2
}

if ($config.PSObject.Properties.Name -contains "dashboard") {
    $config.dashboard = $dashboard
}
else {
    $config | Add-Member -NotePropertyName dashboard -NotePropertyValue $dashboard
}

$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Write-Host "Saved locally to config.json (ignored by Git)." -ForegroundColor Green

Write-Host "Testing first Dashboard upload..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SyncPath -Once
if ($LASTEXITCODE -ne 0) {
    throw "Dashboard upload test failed."
}

Write-Host "Restarting Watchdog..."
try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
}
catch {
    Write-Warning "Dashboard is configured, but Watchdog task could not be restarted automatically."
}

Write-Host "Dashboard connected successfully." -ForegroundColor Green
