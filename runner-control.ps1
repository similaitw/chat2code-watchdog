Set-StrictMode -Version 2.0

function Get-Chat2CodeRunnerProcesses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config
    )

    $marker = "chat2code_runner"
    if ($Config.runner.PSObject.Properties.Name -contains "commandLineMarker" -and $Config.runner.commandLineMarker) {
        $marker = [string]$Config.runner.commandLineMarker
    }

    try {
        $processes = Get-CimInstance Win32_Process -ErrorAction Stop
    }
    catch {
        throw "Unable to query Windows processes: $($_.Exception.Message)"
    }

    $matches = @()
    foreach ($proc in $processes) {
        $name = [string]$proc.Name
        $cmd = [string]$proc.CommandLine
        if (-not $cmd) { continue }

        # The real runner is the Python process created by:
        #   py -3 -m chat2code_runner run
        # Restrict matching to Python launchers and require both package marker and run verb.
        $isPython = $name -match '^(?i:python(?:w)?(?:\d+(?:\.\d+)*)?\.exe)$'
        $hasMarker = $cmd.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        $hasRunVerb = $cmd -match '(?i)(?:^|\s)run(?:\s|$)'

        if ($isPython -and $hasMarker -and $hasRunVerb) {
            $matches += [pscustomobject]@{
                ProcessId       = [int]$proc.ProcessId
                ParentProcessId = [int]$proc.ParentProcessId
                Name            = $name
                CommandLine     = $cmd
                CreationDate    = $proc.CreationDate
            }
        }
    }

    return @($matches)
}

function Stop-Chat2CodeRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config,
        [scriptblock]$Logger
    )

    $runnerProcesses = @(Get-Chat2CodeRunnerProcesses -Config $Config)
    if ($runnerProcesses.Count -eq 0) {
        if ($Logger) { & $Logger "INFO" "Runner already stopped" }
        return $true
    }

    $success = $true
    foreach ($proc in $runnerProcesses) {
        $pidValue = [int]$proc.ProcessId
        if ($Logger) { & $Logger "INFO" "Stopping runner process tree PID=$pidValue" }

        try {
            # /T terminates only this runner's descendants.
            # It does NOT target all python.exe / powershell.exe processes.
            $taskkill = Join-Path $env:SystemRoot "System32\taskkill.exe"
            $result = & $taskkill /PID $pidValue /T /F 2>&1
            if ($LASTEXITCODE -ne 0) {
                if ($Logger) { & $Logger "WARN" "taskkill PID=$pidValue returned exit=$LASTEXITCODE: $($result -join ' ')" }
                $success = $false
            }
        }
        catch {
            if ($Logger) { & $Logger "ERROR" "Failed to stop PID=$pidValue: $($_.Exception.Message)" }
            $success = $false
        }
    }

    return $success
}

function Start-Chat2CodeRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config,
        [scriptblock]$Logger
    )

    $workingDirectory = [string]$Config.runner.workingDirectory
    $startScript = [string]$Config.runner.startScript
    $startPath = if ([System.IO.Path]::IsPathRooted($startScript)) {
        $startScript
    }
    else {
        Join-Path $workingDirectory $startScript
    }

    if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
        throw "Runner working directory not found: $workingDirectory"
    }
    if (-not (Test-Path -LiteralPath $startPath -PathType Leaf)) {
        throw "Runner start script not found: $startPath"
    }

    $existing = @(Get-Chat2CodeRunnerProcesses -Config $Config)
    if ($existing.Count -gt 0) {
        if ($Logger) { & $Logger "INFO" "Runner already running PID=$($existing[0].ProcessId)" }
        return [pscustomobject]@{
            Success = $true
            Pids    = @($existing.ProcessId)
            Message = "already-running"
        }
    }

    $windowStyle = "Minimized"
    if ($Config.runner.PSObject.Properties.Name -contains "windowStyle" -and $Config.runner.windowStyle) {
        $candidate = [string]$Config.runner.windowStyle
        if ($candidate -in @("Normal", "Hidden", "Minimized", "Maximized")) {
            $windowStyle = $candidate
        }
    }

    if ($Logger) { & $Logger "INFO" "Starting runner via $startPath" }

    try {
        $launcher = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"' + $startPath + '"')) `
            -WorkingDirectory $workingDirectory `
            -WindowStyle $windowStyle `
            -PassThru `
            -ErrorAction Stop

        if ($Logger) { & $Logger "INFO" "Runner launcher started PID=$($launcher.Id)" }
    }
    catch {
        if ($Logger) { & $Logger "ERROR" "Runner launcher failed: $($_.Exception.Message)" }
        return [pscustomobject]@{
            Success = $false
            Pids    = @()
            Message = $_.Exception.Message
        }
    }

    $verifySeconds = 20
    if ($Config.runner.PSObject.Properties.Name -contains "startupVerifySeconds") {
        $verifySeconds = [Math]::Max(3, [int]$Config.runner.startupVerifySeconds)
    }

    $deadline = (Get-Date).AddSeconds($verifySeconds)
    do {
        Start-Sleep -Seconds 1
        $running = @(Get-Chat2CodeRunnerProcesses -Config $Config)
        if ($running.Count -gt 0) {
            if ($Logger) { & $Logger "INFO" "Runner healthy PID=$($running[0].ProcessId)" }
            return [pscustomobject]@{
                Success = $true
                Pids    = @($running.ProcessId)
                Message = "started"
            }
        }
    } while ((Get-Date) -lt $deadline)

    if ($Logger) { & $Logger "ERROR" "Runner did not become healthy within $verifySeconds seconds" }
    return [pscustomobject]@{
        Success = $false
        Pids    = @()
        Message = "startup-timeout"
    }
}

function Restart-Chat2CodeRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config,
        [scriptblock]$Logger
    )

    [void](Stop-Chat2CodeRunner -Config $Config -Logger $Logger)

    $delay = 5
    if ($Config.watchdog.PSObject.Properties.Name -contains "restartDelaySeconds") {
        $delay = [Math]::Max(1, [int]$Config.watchdog.restartDelaySeconds)
    }
    Start-Sleep -Seconds $delay

    return Start-Chat2CodeRunner -Config $Config -Logger $Logger
}
