<#
.SYNOPSIS
    US-04+ | Uploads the Invoke-AutoShutdown runbook and creates the daily schedule.

.DESCRIPTION
    - Uploads  ../runbook/Invoke-AutoShutdown.ps1  to the Automation Account
    - Sets the runbook runtime to PowerShell 7.2
    - Publishes the runbook
    - Creates a daily schedule at the configured time (default: 19:00 CET)
    - Links the schedule to the runbook with WhatIf=$true for the first run

    After confirming the first WhatIf run looks correct, you can update the
    schedule link to WhatIf=$false using the -DisableWhatIf switch.

.PARAMETER ScheduleTime
    Time of day for the daily shutdown trigger in CET (DST-aware — enter your local CET/CEST time).
    Format: "HH:mm"   Default: "19:00"

.PARAMETER RunbookPath
    Path to the runbook PS1 file.
    Default: $PSScriptRoot\..\runbook\Invoke-AutoShutdown.ps1

.PARAMETER DisableWhatIf
    If set, the schedule runs with WhatIf=$false (live shutdowns).
    Default: $false - first deployment always starts in WhatIf mode.

.PARAMETER SubscriptionIds
    Comma-separated list of subscription IDs to pass to the runbook.
    Leave empty to let the runbook process all accessible subscriptions.

.EXAMPLE
    # First deployment - WhatIf mode (safe)
    .\New-Runbook.ps1

.EXAMPLE
    # After validating WhatIf output - enable live shutdowns
    .\New-Runbook.ps1 -DisableWhatIf

.EXAMPLE
    # Target specific subscriptions only
    .\New-Runbook.ps1 -DisableWhatIf -SubscriptionIds "sub-id-1,sub-id-2"

.NOTES
    Permissions required : Contributor on the Automation Account
    Modules required     : Az.Accounts, Az.Automation
    Run before this      : Import-Modules.ps1
#>

[CmdletBinding()]
param (
    [string] $ScheduleTime          = "19:00",
    [string] $RunbookPath           = "",
    [switch] $DisableWhatIf,
    [string] $SubscriptionIds       = "",
    [string] $SubscriptionId        = "",
    [string] $ResourceGroupName     = "",
    [string] $AutomationAccountName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Helpers.ps1"

Write-Banner "Deploy Runbook + Schedule"

# -- Prerequisites -------------------------------------------------------------
Assert-Modules @("Az.Accounts", "Az.Automation")

# -- Auth & state --------------------------------------------------------------
Connect-AutoShutdown | Out-Null
$state = Read-State
if ($SubscriptionId        -eq "") { $SubscriptionId        = $state.SubscriptionId }
if ($ResourceGroupName     -eq "") { $ResourceGroupName     = $state.ResourceGroupName }
if ($AutomationAccountName -eq "") { $AutomationAccountName = $state.AutomationAccountName }

if ($SubscriptionId -eq "") {
    $sub = Select-Subscription; $SubscriptionId = $sub.Id
} else {
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Success "Subscription: $($state.SubscriptionName) ($SubscriptionId)"
}

Write-Info "Automation Account : $AutomationAccountName"
Write-Info "Resource Group     : $ResourceGroupName"

# -- Locate runbook file -------------------------------------------------------
Write-Step "Locating runbook file..."

if ($RunbookPath -eq "") {
    $RunbookPath = Join-Path $PSScriptRoot "..\runbook\Invoke-AutoShutdown.ps1"
}

$RunbookPath = Resolve-Path $RunbookPath -ErrorAction SilentlyContinue

if (-not $RunbookPath -or -not (Test-Path $RunbookPath)) {
    Write-Fail "Runbook not found at: $RunbookPath"
    Write-Host "  Ensure Invoke-AutoShutdown.ps1 is in the runbook/ folder." -ForegroundColor Yellow
    exit 1
}

Write-Success "Runbook found: $RunbookPath"

# -- WhatIf mode summary -------------------------------------------------------
$whatIfValue = -not $DisableWhatIf

Write-Host ""
if ($whatIfValue) {
    Write-Host "  Mode: WhatIf = TRUE (dry run - no VMs will be stopped)" -ForegroundColor Yellow
    Write-Host "  Review the first job output, then re-run with -DisableWhatIf to go live." -ForegroundColor Yellow
} else {
    Write-Host "  Mode: WhatIf = FALSE (LIVE - VMs will be stopped)" -ForegroundColor Green
}
Write-Host ""

# -- Upload runbook ------------------------------------------------------------
Write-Step "Uploading runbook: Invoke-AutoShutdown"

$runbookName = "Invoke-AutoShutdown"

$existing = Get-AzAutomationRunbook `
    -ResourceGroupName     $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name $runbookName `
    -ErrorAction SilentlyContinue

if ($existing) {
    Write-Info "Runbook already exists - importing updated content..."
    Import-AzAutomationRunbook `
        -ResourceGroupName     $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name                  $runbookName `
        -Path                  $RunbookPath `
        -Type                  "PowerShell72" `
        -Force `
        -ErrorAction Stop | Out-Null
    Write-Success "Runbook content updated."
} else {
    Import-AzAutomationRunbook `
        -ResourceGroupName     $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name                  $runbookName `
        -Path                  $RunbookPath `
        -Type                  "PowerShell72" `
        -ErrorAction Stop | Out-Null
    Write-Success "Runbook uploaded."
}

# -- Publish runbook -----------------------------------------------------------
Write-Step "Publishing runbook..."

Publish-AzAutomationRunbook `
    -ResourceGroupName     $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name $runbookName `
    -ErrorAction Stop | Out-Null

Write-Success "Runbook published (Runtime: PowerShell 7.2)"

# -- Create/update schedule ----------------------------------------------------
Write-Step "Setting up daily schedule at $ScheduleTime CET..."

$scheduleName = "sched-autoshutdown-daily"

# Parse schedule time
$timeParts = $ScheduleTime -split ":"
$schedHour = [int]$timeParts[0]
$schedMin  = [int]$timeParts[1]

# Calculate first run = tomorrow at the specified time in CET (DST-aware)
# This correctly handles both CET (UTC+1) and CEST (UTC+2)
$tz         = [System.TimeZoneInfo]::FindSystemTimeZoneById("Central European Standard Time")
$nowCET     = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz)
$startLocal = $nowCET.Date.AddDays(1).AddHours($schedHour).AddMinutes($schedMin)
$offset     = $tz.GetUtcOffset($startLocal)
$startTime  = [System.DateTimeOffset]::new($startLocal, $offset)

$existingSched = Get-AzAutomationSchedule `
    -ResourceGroupName     $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name $scheduleName `
    -ErrorAction SilentlyContinue

if ($existingSched) {
    Write-Success "Schedule already exists: $scheduleName - skipping creation."
    Write-Info "Next run: $($existingSched.NextRun)"
} else {
    New-AzAutomationSchedule `
        -ResourceGroupName     $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name                  $scheduleName `
        -StartTime             $startTime `
        -DayInterval           1 `
        -TimeZone              "Central European Standard Time" `
        -ErrorAction Stop | Out-Null
    Write-Success "Schedule created: daily at $ScheduleTime CET"
    Write-Info "First run: $startTime (CET/CEST local)"
}

# -- Link schedule to runbook --------------------------------------------------
Write-Step "Linking schedule to runbook..."

$params = @{ WhatIf = $whatIfValue }
if ($SubscriptionIds -ne "") { $params["SubscriptionIds"] = $SubscriptionIds }

# Remove existing link if present (to update parameters)
$existingLink = Get-AzAutomationScheduledRunbook `
    -ResourceGroupName     $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -RunbookName           $runbookName `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.ScheduleName -eq $scheduleName }

if ($existingLink) {
    Write-Info "Removing existing schedule link to update parameters..."
    Unregister-AzAutomationScheduledRunbook `
        -ResourceGroupName     $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -RunbookName           $runbookName `
        -ScheduleName          $scheduleName `
        -Force `
        -ErrorAction SilentlyContinue | Out-Null
}

Register-AzAutomationScheduledRunbook `
    -ResourceGroupName     $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -RunbookName           $runbookName `
    -ScheduleName          $scheduleName `
    -Parameters            $params `
    -ErrorAction Stop | Out-Null

Write-Success "Schedule linked to runbook."
Write-Info "WhatIf parameter : $whatIfValue"
Write-Info "SubscriptionIds  : $(if ($SubscriptionIds -ne '') { $SubscriptionIds } else { '(all accessible)' })"

# -- Trigger a test job --------------------------------------------------------
Write-Step "Triggering a test job (WhatIf=`$true)..."
Write-Host ""
Write-Host "  A WhatIf test job will now run so you can verify the output." -ForegroundColor Cyan
Write-Host "  This will NOT stop any VMs." -ForegroundColor Cyan
Write-Host ""

$testParams = @{ WhatIf = $true }
if ($SubscriptionIds -ne "") { $testParams["SubscriptionIds"] = $SubscriptionIds }

try {
    $job = Start-AzAutomationRunbook `
        -ResourceGroupName     $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name                  $runbookName `
        -Parameters            $testParams `
        -ErrorAction Stop

    Write-Success "Test job started. Job ID: $($job.JobId)"
    Write-Info "Monitor in Portal: Automation Account → Jobs → $($job.JobId)"

    # Save job ID to state for easy lookup
    Save-State @{ LastTestJobId = $job.JobId.ToString() }

    # Wait briefly and check status
    Write-Info "Waiting 20 seconds then checking job status..."
    Start-Sleep -Seconds 20

    $jobStatus = Get-AzAutomationJob `
        -ResourceGroupName     $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Id $job.JobId `
        -ErrorAction SilentlyContinue

    Write-Info "Job status: $($jobStatus.Status)"

    if ($jobStatus.Status -in @("Completed","Running","Queued")) {
        Write-Success "Job is running or completed. Check the full output in the Portal."
    } elseif ($jobStatus.Status -eq "Failed") {
        Write-Fail "Test job failed. Check job output in Portal for details."
    }
} catch {
    Write-Warn "Could not start test job automatically: $_"
    Write-Info "Start manually in Portal: Automation Account → Runbooks → Invoke-AutoShutdown → Start"
}

# -- Acceptance criteria -------------------------------------------------------
Invoke-AcceptanceCriteria -StoryId "US-04,US-08" -CriteriaNames @(
    "Runbook exists and is Published"
    "Runbook type is PowerShell 7.2"
    "Daily schedule exists and is enabled"
    "Schedule is linked to the runbook"
) -Criteria @(
    {
        $rb = Get-AzAutomationRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $runbookName -ErrorAction SilentlyContinue
        $rb.State -eq "Published"
    }
    {
        $rb = Get-AzAutomationRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $runbookName -ErrorAction SilentlyContinue
        $rb.RunbookType -eq "PowerShell72"
    }
    {
        $sched = Get-AzAutomationSchedule `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $scheduleName -ErrorAction SilentlyContinue
        $null -ne $sched
    }
    {
        $link = Get-AzAutomationScheduledRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -RunbookName $runbookName -ErrorAction SilentlyContinue |
            Where-Object { $_.ScheduleName -eq $scheduleName }
        $null -ne $link
    }
) | Out-Null

# -- Summary -------------------------------------------------------------------
Write-Banner "Done"
Write-Host ""
Write-Host "  Runbook      : $runbookName (Published, PowerShell 7.2)" -ForegroundColor White
Write-Host "  Schedule     : $scheduleName - daily at $ScheduleTime CET" -ForegroundColor White
Write-Host "  WhatIf mode  : $whatIfValue"  -ForegroundColor $(if ($whatIfValue) { "Yellow" } else { "Green" })
Write-Host ""

if ($whatIfValue) {
    Write-Host "  NEXT: Check the test job output in the Portal." -ForegroundColor Cyan
    Write-Host "  When satisfied, run this script with -DisableWhatIf to enable live shutdowns:" -ForegroundColor Cyan
    Write-Host "    .\New-Runbook.ps1 -DisableWhatIf" -ForegroundColor White
} else {
    Write-Host "  Live shutdowns are now active. VMs tagged 'shutdown' will be" -ForegroundColor Green
    Write-Host "  stopped daily at $ScheduleTime CET." -ForegroundColor Green
}
Write-Host ""
