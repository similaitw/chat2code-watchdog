[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$Branch = "feature/telegram-v0.2"
$BaseUrl = "https://raw.githubusercontent.com/similaitw/chat2code-watchdog/" + $Branch + "/"
$TaskName = "Chat2Code Watchdog"
$SessionId = [guid]::NewGuid().ToString("N")
$TempRoot = Join-Path $env:TEMP ("chat2code-watchdog-update-" + $SessionId)
$BackupRoot = Join-Path $env:TEMP ("chat2code-watchdog-backup-" + $SessionId)

$files = @(
    "watchdog.ps1",
    "runner-control.ps1",
    "telegram.ps1",
    "telegram-setup.ps1",
    "telegram-diagnose.ps1",
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
    "TELEGRAM-DIAGNOSE.bat",
    "RESTART.bat",
    "INSTALL.bat",
    "start-watchdog.bat"
)

Write-Host "=== Chat2Code Watchdog v0.2 Test Updater ===" -ForegroundColor Cyan
Write-Host "Preserved: config.json, runtime/, logs/"

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

$taskExists = $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
$taskWasStopped = $false
$applyStarted = $false

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

    Write-Host "Backing up current program files..."
    foreach ($file in $files) {
        $current = Join-Path $PSScriptRoot $file
        if (Test-Path -LiteralPath $current -PathType Leaf) {
            Copy-Item -LiteralPath $current -Destination (Join-Path $BackupRoot $file) -Force
        }
    }

    if ($taskExists) {
        Write-Host "Stopping Watchdog scheduled task..."
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $taskWasStopped = $true
        Start-Sleep -Seconds 2
    }

    $applyStarted = $true
    foreach ($file in $files) {
        Copy-Item -LiteralPath (Join-Path $TempRoot $file) -Destination (Join-Path $PSScriptRoot $file) -Force
    }

    Write-Host "v0.2 test files installed successfully." -ForegroundColor Green
}
catch {
    Write-Host ("Update failed: " + $_.Exception.Message) -ForegroundColor Red

    if ($applyStarted) {
        Write-Warning "Rolling back program files..."
        foreach ($file in $files) {
            $backup = Join-Path $BackupRoot $file
            $target = Join-Path $PSScriptRoot $file
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue
            }
        }
    }
    throw
}
finally {
    if ($taskExists -and $taskWasStopped) {
        Write-Host "Starting Watchdog scheduled task..."
        try {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Start-Sleep -Seconds 3
        }
        catch {
            Write-Warning "Could not restart the Watchdog scheduled task automatically. Start it manually with Start-ScheduledTask."
        }
    }

    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $BackupRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Update complete." -ForegroundColor Cyan
Write-Host "If Telegram is already configured, run TELEGRAM-DIAGNOSE.bat only when troubleshooting."
