<#
.SYNOPSIS
    US-01 (Step 1/2) | Creates an Automation Account inside an existing Resource Group.

.DESCRIPTION
    This script does NOT create a Resource Group - it lists the ones that
    already exist in your subscription and lets you pick one.

    It then creates the Azure Automation Account (PowerShell 7.2 runtime)
    inside that Resource Group.

    Saves all selections to .autoshutdown-state.json for subsequent scripts.

.PARAMETER SubscriptionId
    Optional. If omitted and you have multiple subscriptions, an interactive
    menu is shown. Single subscription is auto-selected.

.PARAMETER ResourceGroupName
    Optional. If passed, skips the Resource Group picker.

.PARAMETER AutomationAccountName
    Name for the new Automation Account. Must be globally unique in Azure.
    Default: aa-autoshutdown

.PARAMETER Location
    Azure region for the Automation Account.
    If omitted, defaults to the location of the selected Resource Group.

.EXAMPLE
    # Fully interactive - pick subscription, RG, and name the account
    .\New-AutoShutdownInfra.ps1

.EXAMPLE
    # Known RG, custom account name
    .\New-AutoShutdownInfra.ps1 `
        -SubscriptionId        "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName     "rg-myproject" `
        -AutomationAccountName "aa-autoshutdown-myteam"

.NOTES
    Permissions required : Contributor on the target Resource Group
    Modules required     : Az.Accounts, Az.Resources, Az.Automation
    Run after this       : Set-ManagedIdentity.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $SubscriptionId        = "",
    [string] $ResourceGroupName     = "",
    [string] $AutomationAccountName = "aa-autoshutdown",
    [string] $Location              = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Helpers.ps1"

# -- Banner --------------------------------------------------------------------
Write-Banner "Create Automation Account"

# -- Prerequisites -------------------------------------------------------------
Assert-Modules @("Az.Accounts", "Az.Resources", "Az.Automation")

# -- Auth ----------------------------------------------------------------------
Connect-AutoShutdown | Out-Null

# -- Subscription --------------------------------------------------------------
$sub = Select-Subscription -SubscriptionId $SubscriptionId
$SubscriptionId = $sub.Id

# -- Resource Group picker -----------------------------------------------------
Write-Step "Finding existing Resource Groups..."

$rgs = @(Get-AzResourceGroup -ErrorAction Stop | Sort-Object ResourceGroupName)

if ($rgs.Count -eq 0) {
    Write-Host "  [ERROR] No Resource Groups found in subscription '$($sub.Name)'." -ForegroundColor Red
    Write-Host "  At least one Resource Group must exist before running this script." -ForegroundColor Yellow
    exit 1
}

$selectedRg = $null

# If passed as parameter - validate and use
if ($ResourceGroupName -ne "") {
    $selectedRg = $rgs | Where-Object { $_.ResourceGroupName -eq $ResourceGroupName }
    if (-not $selectedRg) {
        Write-Host "  [ERROR] Resource Group '$ResourceGroupName' not found." -ForegroundColor Red
        Write-Host "  Available Resource Groups:" -ForegroundColor Yellow
        $rgs | ForEach-Object { Write-Host "    $($_.ResourceGroupName)  ($($_.Location))" -ForegroundColor Gray }
        exit 1
    }
    Write-Success "Using specified Resource Group: $ResourceGroupName"
}

# Single RG - auto-select
if (-not $selectedRg -and $rgs.Count -eq 1) {
    $selectedRg = $rgs[0]
    Write-Success "Only one Resource Group found - auto-selected: $($selectedRg.ResourceGroupName)"
    Write-Info "Location : $($selectedRg.Location)"
}

# Multiple RGs - show picker
if (-not $selectedRg) {
    Write-Host ""
    Write-Host "  Found $($rgs.Count) Resource Group(s). Select one to place the Automation Account in:" -ForegroundColor Cyan
    Write-Host ""

    $padName = ($rgs | ForEach-Object { $_.ResourceGroupName.Length } | Measure-Object -Maximum).Maximum

    Write-Host ("  {0,4}  {1,-$padName}  {2}" -f "#", "Resource Group", "Location") -ForegroundColor DarkGray
    Write-Host ("  {0,4}  {1,-$padName}  {2}" -f "----", ("-" * $padName), "--------") -ForegroundColor DarkGray

    for ($i = 0; $i -lt $rgs.Count; $i++) {
        Write-Host ("  {0,4}  {1,-$padName}  {2}" -f ($i + 1), $rgs[$i].ResourceGroupName, $rgs[$i].Location) -ForegroundColor White
    }

    Write-Host ""
    while (-not $selectedRg) {
        $rgInput = Read-Host "  Enter number [1-$($rgs.Count)]"
        if ($rgInput -match '^\d+$') {
            $idx = [int]$rgInput - 1
            if ($idx -ge 0 -and $idx -lt $rgs.Count) {
                $selectedRg = $rgs[$idx]
            }
        }
        if (-not $selectedRg) {
            Write-Host "  Invalid - enter a number between 1 and $($rgs.Count)." -ForegroundColor Yellow
        }
    }
    Write-Success "Selected Resource Group: $($selectedRg.ResourceGroupName)"
}

$ResourceGroupName = $selectedRg.ResourceGroupName

# Use RG location if not specified
if ($Location -eq "") {
    $Location = $selectedRg.Location
    Write-Info "Using Resource Group location: $Location"
}

# -- Automation Account name ---------------------------------------------------
Write-Step "Configuring Automation Account name..."

# Let the user confirm or change the default name
Write-Host ""
Write-Host "  Automation Account name: '$AutomationAccountName'" -ForegroundColor Cyan
Write-Host "  This name must be globally unique across all of Azure." -ForegroundColor Gray
Write-Host ""
$nameInput = Read-Host "  Press Enter to accept, or type a new name"
if ($nameInput.Trim() -ne "") {
    $AutomationAccountName = $nameInput.Trim()
}
Write-Info "Using name: $AutomationAccountName"

# -- Check if account already exists ------------------------------------------
Write-Step "Checking if Automation Account already exists..."

$existing = Get-AzAutomationAccount `
    -ResourceGroupName $ResourceGroupName `
    -Name $AutomationAccountName `
    -ErrorAction SilentlyContinue

if ($existing) {
    Write-Success "Automation Account '$AutomationAccountName' already exists - skipping creation."
    Write-Info "State    : $($existing.State)"
    Write-Info "Location : $($existing.Location)"
    $aa = $existing
} else {

    # -- Create Automation Account ---------------------------------------------
    Write-Step "Creating Automation Account: $AutomationAccountName"
    Write-Info "Resource Group : $ResourceGroupName"
    Write-Info "Location       : $Location"
    Write-Info "This may take up to 60 seconds..."

    try {
        $aa = New-AzAutomationAccount `
                -ResourceGroupName $ResourceGroupName `
                -Name              $AutomationAccountName `
                -Location          $Location `
                -ErrorAction Stop
        Write-Success "Automation Account created: $AutomationAccountName"
        Write-Info "State    : $($aa.State)"
        Write-Info "Location : $($aa.Location)"
    } catch {
        if ($_ -match "already exists" -or $_ -match "conflict") {
            Write-Host "  [ERROR] The name '$AutomationAccountName' is already taken globally in Azure." -ForegroundColor Red
            Write-Host "  Try a more specific name, e.g.: aa-autoshutdown-$($sub.Name -replace '\s','-')" -ForegroundColor Yellow
        }
        throw
    }
}

# -- Save state ----------------------------------------------------------------
Write-Step "Saving state for subsequent scripts..."

Save-State @{
    SubscriptionId        = $SubscriptionId
    SubscriptionName      = $sub.Name
    ResourceGroupName     = $ResourceGroupName
    AutomationAccountName = $AutomationAccountName
    Location              = $Location
}

# -- Acceptance criteria -------------------------------------------------------
Invoke-AcceptanceCriteria -StoryId "US-01" -CriteriaNames @(
    "Automation Account exists in the correct subscription and RG"
    "Account is reachable via Az PowerShell"
) -Criteria @(
    {
        $null -ne (Get-AzAutomationAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name              $AutomationAccountName `
            -ErrorAction SilentlyContinue)
    }
    {
        $check = Get-AzAutomationAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name              $AutomationAccountName `
            -ErrorAction SilentlyContinue
        $check.State -in @("Ok", "Started", "Running")
    }
) | Out-Null

# -- Summary -------------------------------------------------------------------
Write-Banner "Done"
Write-Host ""
Write-Host "  Subscription       : $($sub.Name)"    -ForegroundColor White
Write-Host "  Resource Group     : $ResourceGroupName"      -ForegroundColor White
Write-Host "  Automation Account : $AutomationAccountName"  -ForegroundColor White
Write-Host "  Location           : $Location"               -ForegroundColor White

Write-NextSteps @(
    ".\Set-ManagedIdentity.ps1   - enable Managed Identity on this account   (US-01 AC2)"
    ".\Set-RBACRoles.ps1         - assign RBAC permissions                    (US-02)"
    ".\Import-Modules.ps1        - import Az modules                          (US-03)"
    ".\New-Runbook.ps1           - deploy runbook + schedule                  (US-04+)"
)
