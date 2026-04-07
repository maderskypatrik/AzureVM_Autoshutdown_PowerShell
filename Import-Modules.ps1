<#
.SYNOPSIS
    US-03 | Imports required Az PowerShell modules into the Automation Account.

.DESCRIPTION
    Imports the following modules from the PowerShell Gallery into the
    Automation Account's module store:
      - Az.Accounts      (authentication - must be imported first)
      - Az.Compute       (Stop-AzVM, Get-AzVM)
      - Az.ResourceGraph (Search-AzGraph for HCI VMs)

    Modules are imported sequentially because Az.Compute and Az.ResourceGraph
    depend on Az.Accounts.

.PARAMETER SubscriptionId
    Optional. Defaults to .autoshutdown-state.json.

.PARAMETER ResourceGroupName
    Optional. Defaults to .autoshutdown-state.json.

.PARAMETER AutomationAccountName
    Optional. Defaults to .autoshutdown-state.json.

.EXAMPLE
    .\Import-Modules.ps1

.NOTES
    Permissions required : Contributor on the Automation Account
    Modules required     : Az.Accounts, Az.Automation
    Run before this      : Set-RBACRoles.ps1
    Run after this       : New-Runbook.ps1
    Import takes         : ~5-10 minutes per module
#>

[CmdletBinding()]
param (
    [string] $SubscriptionId        = "",
    [string] $ResourceGroupName     = "",
    [string] $AutomationAccountName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Helpers.ps1"

Write-Banner "US-03 | Import Az Modules into Automation Account"

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

# -- Module list (order matters - Az.Accounts must be first) -------------------
# ContentLink points to the PowerShell Gallery
$modules = @(
    @{
        Name        = "Az.Accounts"
        Version     = "3.0.5"
        Description = "Authentication - required by all other Az modules"
    },
    @{
        Name        = "Az.Compute"
        Version     = "8.3.0"
        Description = "Stop-AzVM / Get-AzVM"
    },
    @{
        Name        = "Az.ResourceGraph"
        Version     = "1.0.0"
        Description = "Search-AzGraph - queries HCI VM resources"
    }
)

function Get-PSGalleryModuleUri {
    param([string]$Name, [string]$Version)
    return "https://www.powershellgallery.com/api/v2/package/$Name/$Version"
}

function Get-ModuleStatus {
    param([string]$Name)
    $mod = Get-AzAutomationModule `
        -ResourceGroupName     $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $Name `
        -ErrorAction SilentlyContinue
    return $mod
}

function Wait-ModuleReady {
    param([string]$Name, [int]$MaxMinutes = 15)
    $deadline  = (Get-Date).AddMinutes($MaxMinutes)
    $dotCount  = 0
    Write-Host "         Waiting for '$Name'" -NoNewline -ForegroundColor Gray
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $mod = Get-ModuleStatus -Name $Name
        Write-Host "." -NoNewline -ForegroundColor Gray
        $dotCount++
        if ($mod.ProvisioningState -eq "Succeeded") {
            Write-Host " ready." -ForegroundColor Green
            return $true
        }
        if ($mod.ProvisioningState -eq "Failed") {
            Write-Host " FAILED." -ForegroundColor Red
            return $false
        }
    }
    Write-Host " timed out." -ForegroundColor Yellow
    return $false
}

# -- Import loop ---------------------------------------------------------------
$allOk = $true

foreach ($mod in $modules) {
    Write-Step "Module: $($mod.Name) - $($mod.Description)"

    $existing = Get-ModuleStatus -Name $mod.Name

    if ($existing -and $existing.ProvisioningState -eq "Succeeded") {
        Write-Success "Already imported (v$($existing.Version)) - skipping."
        continue
    }

    if ($existing -and $existing.ProvisioningState -eq "Creating") {
        Write-Info "Import already in progress - waiting for completion..."
        $ok = Wait-ModuleReady -Name $mod.Name
        if (-not $ok) { $allOk = $false }
        continue
    }

    $uri = Get-PSGalleryModuleUri -Name $mod.Name -Version $mod.Version
    Write-Info "Importing from PowerShell Gallery v$($mod.Version)..."
    Write-Info "URI: $uri"

    try {
        New-AzAutomationModule `
            -ResourceGroupName     $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name                  $mod.Name `
            -ContentLink           $uri `
            -ErrorAction Stop | Out-Null

        $ok = Wait-ModuleReady -Name $mod.Name
        if ($ok) {
            Write-Success "Module imported: $($mod.Name)"
        } else {
            Write-Fail "Module import failed or timed out: $($mod.Name)"
            $allOk = $false
        }
    } catch {
        Write-Fail "Error importing $($mod.Name): $_"
        $allOk = $false
    }
}

# -- Acceptance criteria -------------------------------------------------------
Invoke-AcceptanceCriteria -StoryId "US-03" -CriteriaNames @(
    "Az.Accounts module status is Succeeded"
    "Az.Compute module status is Succeeded"
    "Az.ResourceGraph module status is Succeeded"
) -Criteria @(
    { (Get-ModuleStatus "Az.Accounts").ProvisioningState     -eq "Succeeded" }
    { (Get-ModuleStatus "Az.Compute").ProvisioningState      -eq "Succeeded" }
    { (Get-ModuleStatus "Az.ResourceGraph").ProvisioningState -eq "Succeeded" }
) | Out-Null

# -- Summary -------------------------------------------------------------------
Write-Banner "Done"
Write-Host ""
if ($allOk) {
    Write-Host "  All modules imported successfully." -ForegroundColor Green
} else {
    Write-Host "  Some modules failed - review output above." -ForegroundColor Yellow
}
Write-Host ""

Write-NextSteps @(
    ".\New-Runbook.ps1   - upload the runbook script and create the schedule   (US-04+)"
)
