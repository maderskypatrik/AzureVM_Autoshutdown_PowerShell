<#
.SYNOPSIS
    US-01 (Step 2/2) | Enables System-assigned Managed Identity on the Automation Account.

.DESCRIPTION
    - Reads config from .autoshutdown-state.json (written by New-AutoShutdownInfra.ps1)
    - Enables System-assigned Managed Identity via REST PATCH
    - Waits for Entra ID propagation and retrieves the Object ID
    - Saves the Object ID back to state for Set-RBACRoles.ps1

.PARAMETER SubscriptionId
    Optional override. Defaults to value saved by New-AutoShutdownInfra.ps1.

.PARAMETER ResourceGroupName
    Optional override. Defaults to value saved by New-AutoShutdownInfra.ps1.

.PARAMETER AutomationAccountName
    Optional override. Defaults to value saved by New-AutoShutdownInfra.ps1.

.EXAMPLE
    # Uses saved state - no parameters needed if you ran New-AutoShutdownInfra.ps1 first
    .\Set-ManagedIdentity.ps1

.NOTES
    Permissions required : Contributor on the Automation Account resource
    Modules required     : Az.Accounts, Az.Automation, Az.Resources
    Run before this      : New-AutoShutdownInfra.ps1
    Run after this       : Set-RBACRoles.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $SubscriptionId        = "",
    [string] $ResourceGroupName     = "",
    [string] $AutomationAccountName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Helpers.ps1"

# -- Banner --------------------------------------------------------------------
Write-Banner "US-01 (2/2) | Enable Managed Identity"

# -- Prerequisites -------------------------------------------------------------
Assert-Modules @("Az.Accounts", "Az.Automation", "Az.Resources")

# -- Auth ----------------------------------------------------------------------
Connect-AutoShutdown | Out-Null

# -- Load state ----------------------------------------------------------------
Write-Step "Loading configuration..."

$state = Read-State

# Parameters override saved state; saved state overrides empty defaults
if ($SubscriptionId        -eq "") { $SubscriptionId        = $state.SubscriptionId }
if ($ResourceGroupName     -eq "") { $ResourceGroupName     = $state.ResourceGroupName }
if ($AutomationAccountName -eq "") { $AutomationAccountName = $state.AutomationAccountName }

# If still empty (no state file, no params), run subscription picker
if ($SubscriptionId -eq "") {
    Write-Warn "No saved state found. Running subscription picker..."
    $sub = Select-Subscription
    $SubscriptionId = $sub.Id
} else {
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Success "Using subscription: $($state.SubscriptionName) ($SubscriptionId)"
}

if ($ResourceGroupName -eq "" -or $AutomationAccountName -eq "") {
    throw "ResourceGroupName and AutomationAccountName could not be determined. " +
          "Run New-AutoShutdownInfra.ps1 first, or pass parameters explicitly."
}

Write-Info "Resource Group     : $ResourceGroupName"
Write-Info "Automation Account : $AutomationAccountName"

# -- Verify account exists -----------------------------------------------------
Write-Step "Verifying Automation Account exists..."

$aa = Get-AzAutomationAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name $AutomationAccountName `
        -ErrorAction SilentlyContinue

if (-not $aa) {
    Write-Fail "Automation Account '$AutomationAccountName' not found in '$ResourceGroupName'."
    Write-Host "  Did you run New-AutoShutdownInfra.ps1 first?" -ForegroundColor Yellow
    exit 1
}
Write-Success "Account found. State: $($aa.State)"

# -- Check current identity state ----------------------------------------------
Write-Step "Checking current Managed Identity state..."

# Use Get-AzResource to check identity - no manual token needed
$aaResource = Get-AzResource `
    -ResourceGroupName $ResourceGroupName `
    -ResourceType      "Microsoft.Automation/automationAccounts" `
    -ResourceName      $AutomationAccountName `
    -ErrorAction Stop

$currentType = if ($aaResource.Identity) { $aaResource.Identity.Type } else { $null }

if ($currentType -eq "SystemAssigned") {
    $objectId = if ($aaResource.Identity) { $aaResource.Identity.PrincipalId } else { $null }
    Write-Success "Managed Identity already enabled - skipping."
    Write-Info "Object ID: $objectId"
} else {
    $typeDisplay = if ($currentType) { $currentType } else { "None" }
    Write-Info "Current identity type: $typeDisplay - enabling now..."

    # -- Enable identity via Invoke-AzRestMethod (handles auth automatically) --
    Write-Step "Enabling System-assigned Managed Identity..."

    $aaPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
              "/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName" +
              "?api-version=2023-11-01"

    $body = '{"identity":{"type":"SystemAssigned"}}'

    $response = Invoke-AzRestMethod `
        -Path   $aaPath `
        -Method PATCH `
        -Payload $body `
        -ErrorAction Stop

    if ($response.StatusCode -notin @(200, 201, 202)) {
        throw "Failed to enable Managed Identity. HTTP $($response.StatusCode): $($response.Content)"
    }

    Write-Success "Managed Identity enabled."

    # -- Wait for propagation ---------------------------------------------------
    Write-Step "Waiting for Entra ID propagation..."
    Write-Info "Polling every 10 seconds (up to 2 minutes)..."

    $objectId = $null
    $attempts = 0
    $maxTries = 12

    while (-not $objectId -and $attempts -lt $maxTries) {
        Start-Sleep -Seconds 10
        $attempts++
        Write-Info "Attempt $attempts/$maxTries..."

        $updated = Get-AzResource `
            -ResourceGroupName $ResourceGroupName `
            -ResourceType      "Microsoft.Automation/automationAccounts" `
            -ResourceName      $AutomationAccountName `
            -ErrorAction SilentlyContinue

        if ($updated.Identity -and $updated.Identity.PrincipalId) {
            $objectId = $updated.Identity.PrincipalId
        }
    }

    if (-not $objectId) {
        Write-Fail "Object ID not available after $($maxTries * 10) seconds."
        Write-Host "  Wait 2-3 minutes then re-run: .\Install-AutoShutdown.ps1 -StartFromStep 2" -ForegroundColor Yellow
        exit 1
    }

    Write-Success "Object ID retrieved after $($attempts * 10) seconds."
}

# -- Verify service principal in Entra ID -------------------------------------
Write-Step "Verifying service principal in Entra ID..."

try {
    $sp = Get-AzADServicePrincipal -ObjectId $objectId -ErrorAction Stop
    Write-Success "Service principal confirmed."
    Write-Info "Display Name : $($sp.DisplayName)"
    Write-Info "App ID       : $($sp.AppId)"
    Write-Info "Object ID    : $objectId"
} catch {
    Write-Warn "Could not query Entra ID (may need Directory Reader role): $_"
    Write-Info "Object ID is $objectId - proceed anyway."
}

# -- Save Object ID to state ---------------------------------------------------
Write-Step "Saving Object ID to state..."
Save-State @{ ManagedIdentityObjectId = $objectId }

# -- Acceptance criteria -------------------------------------------------------
Invoke-AcceptanceCriteria -StoryId "US-01" -CriteriaNames @(
    "System-assigned Managed Identity is enabled and shows an Object ID"
) -Criteria @(
    { $objectId -ne $null -and $objectId -ne "" }
) | Out-Null

# -- Summary -------------------------------------------------------------------
Write-Banner "Done"
Write-Host ""
Write-Host "  Automation Account : $AutomationAccountName" -ForegroundColor White
Write-Host "  Object ID          : $objectId"              -ForegroundColor Green
Write-Host ""
Write-Host "  AC3 (PS 7.2 runtime): select Runtime version 7.2 when creating the runbook." -ForegroundColor Yellow

Write-NextSteps @(
    ".\Set-RBACRoles.ps1    - assign RBAC permissions to the identity above   (US-02)"
    ".\Import-Modules.ps1   - import Az modules into the Automation Account   (US-03)"
    ".\New-Runbook.ps1      - deploy the runbook and schedule                 (US-04+)"
)