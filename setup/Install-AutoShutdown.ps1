<#
.SYNOPSIS
    Master setup script - runs all Autoshutdown setup steps in the correct order.

.DESCRIPTION
    Runs the full setup chain:

      Step 1 - New-AutoShutdownInfra.ps1      Pick existing RG, create Automation Account
      Step 2 - Set-ManagedIdentity.ps1         Enable Managed Identity + capture Object ID
      Step 3 - Set-RBACRoles.ps1               Assign RBAC roles to the identity
      Step 4 - Import-Modules.ps1              Import Az modules into the account (~10 min)
      Step 5 - New-Runbook.ps1                 Upload runbook + create daily schedule

    No resources are created. Everything targets infrastructure that already exists.
    Each step saves state to .autoshutdown-state.json so you can run steps
    individually or resume from a specific step if one fails.

.PARAMETER SubscriptionId
    Optional. If omitted an interactive menu is shown (or auto-selected if
    you only have one subscription).

.PARAMETER ResourceGroupName
    Optional. If you know your RG name, pass it to skip the interactive picker.

.PARAMETER AutomationAccountName
    Optional. If you know your Automation Account name, pass it to skip the picker.

.PARAMETER ScheduleTime
    Daily shutdown time in UTC. Default: "19:00"

.PARAMETER StartupScheduleTime
    Daily startup time in UTC. Default: "07:00"

.PARAMETER SubscriptionIds
    Comma-separated list of subscription IDs for the runbook to process.
    Leave empty to process all subscriptions the Managed Identity can access.

.PARAMETER StartFromStep
    Resume from a specific step (1-6) if a previous run failed.
    Default: 1

.EXAMPLE
    # Fully interactive
    .\Install-AutoShutdown.ps1

.EXAMPLE
    # Known account, skip pickers
    .\Install-AutoShutdown.ps1 `
        -SubscriptionId        "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName     "rg-myproject" `
        -AutomationAccountName "aa-myautomation"

.EXAMPLE
    # Resume from step 3 after a failure
    .\Install-AutoShutdown.ps1 -StartFromStep 3

.EXAMPLE
    # Custom shutdown and startup times
    .\Install-AutoShutdown.ps1 -ScheduleTime '18:00' -StartupScheduleTime '06:30'

.NOTES
    Total runtime : ~15-20 minutes (module import is the slowest step)
    Permissions   : Reader (to list resources) + User Access Administrator
                    (to assign roles) on the subscription
#>

[CmdletBinding()]
param (
    [string] $SubscriptionId        = "",
    [string] $ResourceGroupName     = "",
    [string] $AutomationAccountName = "",
    [string] $ScheduleTime          = "19:00",
    [string] $StartupScheduleTime   = "07:00",
    [string] $SubscriptionIds       = "",
    [int]    $StartFromStep         = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Helpers.ps1"

# -- Title ---------------------------------------------------------------------
Clear-Host
Write-Host ""
Write-Host "  +======================================================+" -ForegroundColor DarkCyan
Write-Host "  |   Azure VM Auto-shutdown & Auto-startup - Setup      |" -ForegroundColor White
Write-Host "  |   PowerCloud Team                                    |" -ForegroundColor Gray
Write-Host "  +======================================================+" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Applies the Autoshutdown solution to an existing" -ForegroundColor Gray
Write-Host "  Azure Automation Account. No resources are created." -ForegroundColor Gray
Write-Host ""
Write-Host "  Estimated time: 15-20 minutes (module import takes longest)" -ForegroundColor Gray
Write-Host ""

if ($StartFromStep -gt 1) {
    Write-Host "  Resuming from step $StartFromStep." -ForegroundColor Yellow
    Write-Host ""
}

# -- Step runner ---------------------------------------------------------------
function Invoke-Step {
    param(
        [int]       $Number,
        [string]    $Title,
        [string]    $Script,
        [hashtable] $Params = @{}
    )

    if ($Number -lt $StartFromStep) {
        Write-Host "  [SKIP] Step $Number - $Title" -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "  +-----------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ("  |  Step {0}/6 - {1,-43}|" -f $Number, $Title)           -ForegroundColor White
    Write-Host "  +-----------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""

    $scriptPath = Join-Path $PSScriptRoot $Script

    try {
        & $scriptPath @Params
    } catch {
        Write-Host ""
        Write-Host "  +======================================================+" -ForegroundColor Red
        Write-Host "  |  Step $Number failed                                       |" -ForegroundColor Red
        Write-Host "  +======================================================+" -ForegroundColor Red
        Write-Host "  Error: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Fix the issue above then resume with:" -ForegroundColor Yellow
        Write-Host "    .\Install-AutoShutdown.ps1 -StartFromStep $Number" -ForegroundColor White
        Write-Host ""
        exit 1
    }

    Write-Host ""
    Write-Host "  Step $Number complete." -ForegroundColor Green

    if ($Number -lt 6) {
        Write-Host "  Continuing to step $($Number + 1) in 5 seconds..." -ForegroundColor Gray
        Start-Sleep -Seconds 5
    }
}

# -- Step 1 params (account selection) ----------------------------------------
$step1Params = @{}
if ($SubscriptionId        -ne "") { $step1Params["SubscriptionId"]        = $SubscriptionId }
if ($ResourceGroupName     -ne "") { $step1Params["ResourceGroupName"]     = $ResourceGroupName }
if ($AutomationAccountName -ne "") { $step1Params["AutomationAccountName"] = $AutomationAccountName }

# -- Step 5 params (shutdown runbook + schedule) ------------------------------
$step5Params = @{}
if ($ScheduleTime    -ne "") { $step5Params["ScheduleTime"]    = $ScheduleTime }
if ($SubscriptionIds -ne "") { $step5Params["SubscriptionIds"] = $SubscriptionIds }

# -- Step 6 params (startup runbook + schedule) --------------------------------
$step6Params = @{}
if ($StartupScheduleTime -ne "") { $step6Params["ScheduleTime"]    = $StartupScheduleTime }
if ($SubscriptionIds     -ne "") { $step6Params["SubscriptionIds"] = $SubscriptionIds }

# -- Run all steps -------------------------------------------------------------
Invoke-Step 1 "Select RG + Create Automation Account" "New-AutoShutdownInfra.ps1"      $step1Params
Invoke-Step 2 "Enable Managed Identity"               "Set-ManagedIdentity.ps1"        @{}
Invoke-Step 3 "Assign RBAC Roles"                     "Set-RBACRoles.ps1"              @{}
Invoke-Step 4 "Import Az Modules (~10 min)"           "Import-Modules.ps1"             @{}
Invoke-Step 5 "Deploy Shutdown Runbook + Schedule"    "New-Runbook.ps1"                $step5Params
Invoke-Step 6 "Deploy Startup Runbook + Schedule"     "New-StartupRunbook.ps1"         $step6Params

# -- Final summary -------------------------------------------------------------
$state = Read-State

Write-Host ""
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |            Setup Complete                            |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host ""
Write-Host "  Subscription       : $($state.SubscriptionName)"        -ForegroundColor White
Write-Host "  Resource Group     : $($state.ResourceGroupName)"       -ForegroundColor White
Write-Host "  Automation Account : $($state.AutomationAccountName)"   -ForegroundColor White
Write-Host "  Managed Identity   : $($state.ManagedIdentityObjectId)" -ForegroundColor White
Write-Host "  Shutdown schedule  : Daily at $ScheduleTime UTC"        -ForegroundColor White
Write-Host "  Startup schedule   : Daily at $StartupScheduleTime UTC" -ForegroundColor White
Write-Host "  WhatIf mode        : ON - no VMs will be started or stopped yet" -ForegroundColor Yellow
Write-Host ""
Write-Host "  What to do next:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Tag VMs for shutdown : .\Add-ShutdownTag.ps1"           -ForegroundColor White
Write-Host "  2. Tag VMs for startup  : .\Add-StartupTag.ps1"            -ForegroundColor White
Write-Host "  3. Trigger each runbook manually in Portal to verify WhatIf output" -ForegroundColor White
Write-Host "  4. When satisfied, enable live shutdowns:"                  -ForegroundColor White
Write-Host "       .\New-Runbook.ps1 -DisableWhatIf"                     -ForegroundColor Gray
Write-Host "  5. When satisfied, enable live startups:"                   -ForegroundColor White
Write-Host "       .\New-StartupRunbook.ps1 -DisableWhatIf"              -ForegroundColor Gray
Write-Host ""
Write-Host "  Tag reference:" -ForegroundColor Cyan
Write-Host "    shutdown      — VM is stopped on the daily shutdown schedule" -ForegroundColor Gray
Write-Host "    donotshutdown — VM is excluded from shutdown"                 -ForegroundColor Gray
Write-Host "    startup       — VM is started on the daily startup schedule"  -ForegroundColor Gray
Write-Host "    donotstart    — VM is excluded from startup"                  -ForegroundColor Gray
Write-Host ""
