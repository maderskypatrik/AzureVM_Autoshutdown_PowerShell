<#
.SYNOPSIS
    US-09 | Queries and displays historical Autoshutdown job runs.

.DESCRIPTION
    Retrieves the last N jobs for the Invoke-AutoShutdown runbook and displays
    a summary table showing status, start time, duration, and VMs shut down.

    Reads config from .autoshutdown-state.json automatically.

.PARAMETER Last
    Number of recent jobs to display. Default: 10

.PARAMETER ShowOutput
    If set, prints the full job output for each job.

.EXAMPLE
    # Show last 10 jobs
    .\Get-JobHistory.ps1

.EXAMPLE
    # Show last 20 jobs
    .\Get-JobHistory.ps1 -Last 20

.EXAMPLE
    # Show last 5 jobs with full output
    .\Get-JobHistory.ps1 -Last 5 -ShowOutput

.NOTES
    Permissions required : Reader on the Automation Account
    Modules required     : Az.Accounts, Az.Automation
#>

[CmdletBinding()]
param (
    [int]    $Last       = 10,
    [switch] $ShowOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Helpers.ps1"

Write-Banner "Autoshutdown Job History"

# -- Prerequisites -------------------------------------------------------------
Assert-Modules @("Az.Accounts", "Az.Automation")

# -- Auth & state --------------------------------------------------------------
Connect-AutoShutdown | Out-Null
$state = Read-State

if (-not $state.SubscriptionId) {
    Write-Warn "No saved state found. Run Install-AutoShutdown.ps1 first."
    exit 1
}

Set-AzContext -SubscriptionId $state.SubscriptionId -ErrorAction Stop | Out-Null
Write-Success "Subscription : $($state.SubscriptionName)"
Write-Info    "Account      : $($state.AutomationAccountName)"
Write-Info    "Showing last : $Last jobs"

# -- Fetch jobs ----------------------------------------------------------------
Write-Step "Fetching job history..."

$jobs = @(Get-AzAutomationJob `
    -ResourceGroupName     $state.ResourceGroupName `
    -AutomationAccountName $state.AutomationAccountName `
    -RunbookName           "Invoke-AutoShutdown" `
    -ErrorAction Stop |
    Sort-Object StartTime -Descending |
    Select-Object -First $Last)

if ($jobs.Count -eq 0) {
    Write-Warn "No jobs found for Invoke-AutoShutdown."
    exit 0
}

Write-Success "Found $($jobs.Count) job(s)."

# -- Display summary table -----------------------------------------------------
Write-Host ""
Write-Host ("  {0,-38}  {1,-12}  {2,-22}  {3,-10}  {4}" -f `
    "Job ID", "Status", "Start Time (UTC)", "Duration", "VMs shut down") `
    -ForegroundColor DarkGray
Write-Host ("  {0,-38}  {1,-12}  {2,-22}  {3,-10}  {4}" -f `
    ("-" * 38), ("-" * 12), ("-" * 22), ("-" * 10), ("-" * 13)) `
    -ForegroundColor DarkGray

foreach ($job in $jobs) {

    # Duration
    $duration = if ($job.EndTime -and $job.StartTime) {
        $span = $job.EndTime - $job.StartTime
        "{0:mm}m {0:ss}s" -f $span
    } else { "running..." }

    # Colour by status
    $color = switch ($job.Status) {
        "Completed" { "Green"  }
        "Failed"    { "Red"    }
        "Running"   { "Cyan"   }
        default     { "Yellow" }
    }

    # Try to extract VMs shut down count from output
    $shutdownCount = "-"
    try {
        $output = Get-AzAutomationJobOutput `
            -ResourceGroupName     $state.ResourceGroupName `
            -AutomationAccountName $state.AutomationAccountName `
            -Id                    $job.JobId `
            -Stream                Output `
            -ErrorAction SilentlyContinue

        $summaryLine = $output | Where-Object { $_.Summary -like "*VMs shut down*" }
        if ($summaryLine) {
            $match = $summaryLine.Summary | Select-String -Pattern "VMs shut down\s+:\s+(\d+)"
            if ($match) { $shutdownCount = $match.Matches[0].Groups[1].Value }
        }
    } catch { }

    Write-Host ("  {0,-38}  {1,-12}  {2,-22}  {3,-10}  {4}" -f `
        $job.JobId,
        $job.Status,
        $job.StartTime.ToString("yyyy-MM-dd HH:mm:ss"),
        $duration,
        $shutdownCount) -ForegroundColor $color

    # Full output if requested
    if ($ShowOutput) {
        Write-Host ""
        Write-Host "  --- Output for job $($job.JobId) ---" -ForegroundColor DarkGray
        try {
            $fullOutput = Get-AzAutomationJobOutput `
                -ResourceGroupName     $state.ResourceGroupName `
                -AutomationAccountName $state.AutomationAccountName `
                -Id                    $job.JobId `
                -Stream                Output `
                -ErrorAction SilentlyContinue

            foreach ($line in $fullOutput) {
                Write-Host "  $($line.Summary)" -ForegroundColor Gray
            }
        } catch {
            Write-Host "  Could not retrieve output: $_" -ForegroundColor Yellow
        }
        Write-Host ""
    }
}

Write-Host ""
Write-Host "  Legend: " -NoNewline
Write-Host "Completed " -ForegroundColor Green -NoNewline
Write-Host "Failed " -ForegroundColor Red -NoNewline
Write-Host "Running " -ForegroundColor Cyan -NoNewline
Write-Host "Other" -ForegroundColor Yellow
Write-Host ""
Write-Host "  To see full output for a specific job, run:" -ForegroundColor Gray
Write-Host "    .\Get-JobHistory.ps1 -Last 1 -ShowOutput" -ForegroundColor Gray
Write-Host ""
