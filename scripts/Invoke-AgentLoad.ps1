#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^https://')][string]$ApiUrl,
    [ValidateRange(30, 600)][int]$DurationSeconds = 180,
    [ValidateRange(1, 100)][int]$Parallelism = 50,
    [ValidateRange(0, 30000)][int]$DelayMilliseconds = 10000
)

$ErrorActionPreference = 'Stop'
$endpoint = "$($ApiUrl.TrimEnd('/'))/api/process"
$deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
$watch = [System.Diagnostics.Stopwatch]::StartNew()

$results = 1..$Parallelism | ForEach-Object -Parallel {
    $succeeded = 0
    $failed = 0
    $machines = [System.Collections.Generic.HashSet[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    while ([DateTime]::UtcNow -lt $using:deadline) {
        try {
            $body = @{
                prompt = 'bounded scaling test'
                delayMilliseconds = $using:DelayMilliseconds
            } | ConvertTo-Json
            $response = Invoke-RestMethod -Method Post -Uri $using:endpoint `
                -ContentType 'application/json' -Body $body -TimeoutSec 90
            $succeeded++
            [void]$machines.Add([string]$response.machine)
        } catch {
            $failed++
            if ($errors.Count -lt 3) {
                [void]$errors.Add($_.Exception.Message)
            }
            Start-Sleep -Milliseconds 500
        }
    }

    [pscustomobject]@{
        Succeeded = $succeeded
        Failed = $failed
        Machines = @($machines)
        Errors = @($errors)
    }
} -ThrottleLimit $Parallelism

$watch.Stop()
$successes = ($results | Measure-Object Succeeded -Sum).Sum
$failures = ($results | Measure-Object Failed -Sum).Sum
$machineNames = @($results | ForEach-Object { $_.Machines } | Sort-Object -Unique)
$elapsedSeconds = [Math]::Round($watch.Elapsed.TotalSeconds, 2)

[pscustomobject]@{
    Succeeded = $successes
    Failed = $failures
    Parallelism = $Parallelism
    RequestedDurationSeconds = $DurationSeconds
    ElapsedSeconds = $elapsedSeconds
    SuccessfulRequestsPerSecond = if ($elapsedSeconds -gt 0) {
        [Math]::Round($successes / $elapsedSeconds, 2)
    } else {
        0
    }
    MachinesObserved = $machineNames.Count
    Machines = $machineNames -join ', '
}

if ($failures -gt 0) {
    $results | ForEach-Object { $_.Errors } | Select-Object -First 5
    throw 'Some load requests failed. Inspect errors before accepting the test.'
}
if ($successes -eq 0) {
    throw 'No requests succeeded.'
}