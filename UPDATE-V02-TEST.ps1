[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$Branch = "feature/telegram-v0.2"
$BaseUrl = "https://raw.githubusercontent.com/similaitw/chat2code-watchdog/" + $Branch + "/"
$TaskName = "Chat2Code Watchdog"
$TempRoot = Join-Path $env:TEMP ("chat2code-watchdog-update-" + [guid]::NewGuid().ToString("N"))

$files = @(
    "watchdog.ps1",
    "runner-control.ps1",
    "telegram.ps1",
    "telegram-setup.ps1",
    "status.ps1",
    "restart.ps1",
    "install.ps1",
    "install-task.ps1",
    "uninstall-task.ps1",
    "config.example.json",
    "README.md",
    "CHANGELOG.md",
    "VERSION",
    "TELEGRAM-SETUP.bat",
    "RESTART.bat",
    "INSTALL.bat",
    "start-watchdog.bat"
)

Write-Host "=== Chat2Code Watchdog v0.2 Test Updater ===" -ForegroundColor Cyan
Write-Host "This updater preserves config.json, runtime/, and logs/."

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

try {
    foreach ($file in $files) {
        $uri = $BaseUrl + $file
        $destination = Join-Path $TempRoot $file
        Write-Host ("Downloading " + $file + "...")
        Invoke-WebRequest -Uri $uri -OutFile $destination -UseBasicParsing -ErrorAction Stop
    }

    Write-Host "Validating downloaded PowerShell files..."
    foreach ($file in $files | Where-Object { $_ -like "*.ps1" }) {
        $path = Join-Path $TempRoot $file
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            throw ("Downloaded PowerShell validation failed for " + $file + ": " + ($errors -join "; "))
        }
    }

    Get-Content (Join-Path $TempRoot "config.example.json") -Raw | ConvertFrom-Json | Out-Null

    $taskExists = $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    if ($taskExists) {
        Write-Host "Stopping Watchdog scheduled task..."
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    foreach ($file in $files) {
        Copy-Item -LiteralPath (Join-Path $TempRoot $file) -Destination (Join-Path $PSScriptRoot $file) -Force
    }

    if ($taskExists) {
        Write-Host "Starting Watchdog scheduled task..."
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Start-Sleep -Seconds 3
    }

    Write-Host "v0.2 test files installed successfully." -ForegroundColor Green
    Write-Host "Next: run TELEGRAM-SETUP.bat"
}
finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
