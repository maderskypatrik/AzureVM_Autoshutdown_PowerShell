<#
.SYNOPSIS
    US-02 | Assigns required RBAC roles to the Automation Account Managed Identity.

.DESCRIPTION
    Assigns the following roles to the Managed Identity (least-privilege):
      - Virtual Machine Contributor   - on the target subscription (allows Stop-AzVM)
      - Reader                        - on the target subscription (allows Search-AzGraph)

    For Azure Local (HCI) VMs, an additional role is needed on the HCI cluster resource.
    This script handles the subscription-level assignments. HCI-specific assignments
    are optional and prompted interactively.

.PARAMETER SubscriptionId
    Optional. Defaults to value in .autoshutdown-state.json.

.PARAMETER ObjectId
    Optional. Managed Identity Object ID.
    Defaults to value in .autoshutdown-state.json (written by Set-ManagedIdentity.ps1).

.EXAMPLE
    .\Set-RBACRoles.ps1

.NOTES
    Permissions required : User Access Administrator or Owner on the subscription
    Modules required     : Az.Accounts, Az.Resources
    Run before this      : Set-ManagedIdentity.ps1
    Run after this       : Import-Modules.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $SubscriptionId = "",
    [string] $ObjectId       = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Helpers.ps1"

Write-Banner "Assign RBAC Roles"

# -- Prerequisites -------------------------------------------------------------
Assert-Modules @("Az.Accounts", "Az.Resources")

# -- Auth ----------------------------------------------------------------------
Connect-AutoShutdown | Out-Null

# -- Load state ----------------------------------------------------------------
Write-Step "Loading configuration..."
$state = Read-State

if ($SubscriptionId -eq "") { $SubscriptionId = $state.SubscriptionId }
if ($ObjectId       -eq "") { $ObjectId       = $state.ManagedIdentityObjectId }

if ($SubscriptionId -eq "") {
    $sub = Select-Subscription
    $SubscriptionId = $sub.Id
} else {
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Success "Subscription: $($state.SubscriptionName) ($SubscriptionId)"
}

if ($ObjectId -eq "" -or $null -eq $ObjectId) {
    Write-Fail "Managed Identity Object ID not found."
    Write-Host "  Run Set-ManagedIdentity.ps1 first, or pass -ObjectId explicitly." -ForegroundColor Yellow
    exit 1
}

Write-Info "Managed Identity Object ID: $ObjectId"

$scope = "/subscriptions/$SubscriptionId"

# -- Role assignment helper ----------------------------------------------------
function Set-RoleIfMissing {
    param(
        [string]$RoleName,
        [string]$Scope,
        [string]$ObjectId
    )

    Write-Info "Checking: '$RoleName' at scope '$Scope'..."

    $existing = Get-AzRoleAssignment `
        -ObjectId $ObjectId `
        -RoleDefinitionName $RoleName `
        -Scope $Scope `
        -ErrorAction SilentlyContinue

    if ($existing) {
        Write-Success "Already assigned: $RoleName - skipping."
        return $true
    }

    try {
        New-AzRoleAssignment `
            -ObjectId            $ObjectId `
            -RoleDefinitionName  $RoleName `
            -Scope               $Scope `
            -ErrorAction Stop | Out-Null
        Write-Success "Assigned: $RoleName"
        return $true
    } catch {
        if ($_ -match "already exists") {
            Write-Success "Already assigned (conflict): $RoleName"
            return $true
        }
        Write-Fail "Failed to assign '$RoleName': $_"
        return $false
    }
}

# -- Subscription-level assignments --------------------------------------------
Write-Step "Assigning subscription-level roles..."

$results = @{}
$results["VirtualMachineContributor"] = Set-RoleIfMissing `
    -RoleName "Virtual Machine Contributor" `
    -Scope    $scope `
    -ObjectId $ObjectId

$results["Reader"] = Set-RoleIfMissing `
    -RoleName "Reader" `
    -Scope    $scope `
    -ObjectId $ObjectId

# -- Optional: HCI cluster role ------------------------------------------------
Write-Step "Azure Local (HCI) VM support..."
Write-Host ""
Write-Host "  Do you have Azure Local (HCI) clusters in this subscription" -ForegroundColor Cyan
Write-Host "  that contain pre-production VMs to shut down?" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [Y] Yes - assign Azure Connected Machine Resource Manager on HCI clusters" -ForegroundColor White
Write-Host "  [N] No  - skip HCI role assignment" -ForegroundColor White
Write-Host ""

$hciAnswer = Read-Host "  Enter Y or N"

if ($hciAnswer -imatch "^y") {
    # List HCI clusters in the subscription
    $hciClusters = Get-AzResource `
        -ResourceType "Microsoft.AzureStackHCI/clusters" `
        -ErrorAction SilentlyContinue

    if (-not $hciClusters -or $hciClusters.Count -eq 0) {
        Write-Warn "No HCI clusters found in subscription '$SubscriptionId'. Skipping HCI roles."
    } else {
        Write-Host ""
        Write-Host "  Found $($hciClusters.Count) HCI cluster(s):" -ForegroundColor Cyan
        Write-Host ""
        for ($i = 0; $i -lt $hciClusters.Count; $i++) {
            Write-Host ("  [{0}]  {1}  (RG: {2})" -f ($i+1), $hciClusters[$i].Name, $hciClusters[$i].ResourceGroupName) -ForegroundColor White
        }
        Write-Host "  [A]  All clusters" -ForegroundColor White
        Write-Host ""

        $hciInput = Read-Host "  Enter number(s) comma-separated, or A for all"
        $selectedClusters = @()

        if ($hciInput -imatch "^a$") {
            $selectedClusters = $hciClusters
        } else {
            foreach ($part in ($hciInput -split ",")) {
                $idx = [int]$part.Trim() - 1
                if ($idx -ge 0 -and $idx -lt $hciClusters.Count) {
                    $selectedClusters += $hciClusters[$idx]
                }
            }
        }

        foreach ($cluster in $selectedClusters) {
            $hciScope = $cluster.ResourceId
            Write-Info "Assigning role on cluster: $($cluster.Name)"
            Set-RoleIfMissing `
                -RoleName "Azure Connected Machine Resource Manager" `
                -Scope    $hciScope `
                -ObjectId $ObjectId | Out-Null
        }
    }
} else {
    Write-Info "Skipping HCI role assignment."
}

# -- Role propagation wait -----------------------------------------------------
Write-Step "Waiting 30 seconds for role assignments to propagate..."
Start-Sleep -Seconds 30
Write-Success "Propagation wait complete."

# -- Acceptance criteria -------------------------------------------------------
Invoke-AcceptanceCriteria -StoryId "US-02" -CriteriaNames @(
    "Managed Identity has Virtual Machine Contributor on the subscription"
    "Managed Identity has Reader role on the subscription"
    "No Owner or broad Contributor roles assigned (least-privilege check)"
) -Criteria @(
    {
        $null -ne (Get-AzRoleAssignment -ObjectId $ObjectId `
            -RoleDefinitionName "Virtual Machine Contributor" `
            -Scope $scope -ErrorAction SilentlyContinue)
    }
    {
        $null -ne (Get-AzRoleAssignment -ObjectId $ObjectId `
            -RoleDefinitionName "Reader" `
            -Scope $scope -ErrorAction SilentlyContinue)
    }
    {
        $broadRoles = Get-AzRoleAssignment -ObjectId $ObjectId -Scope $scope -ErrorAction SilentlyContinue |
            Where-Object { $_.RoleDefinitionName -in @("Owner","Contributor") }
        $null -eq $broadRoles -or $broadRoles.Count -eq 0
    }
) | Out-Null

# -- Summary -------------------------------------------------------------------
Write-Banner "Done"
Write-Host ""
Write-Host "  Object ID    : $ObjectId"       -ForegroundColor White
Write-Host "  Subscription : $SubscriptionId" -ForegroundColor White
Write-Host ""

Write-NextSteps @(
    ".\Import-Modules.ps1   - import Az modules into the Automation Account"
    ".\New-Runbook.ps1      - deploy the runbook and schedule              "
)
