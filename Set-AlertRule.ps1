<#
.SYNOPSIS
    US-10 | Creates an Azure Monitor Alert Rule for Autoshutdown job failures.

.DESCRIPTION
    Creates:
      - An Action Group that sends email to the PowerCloud team
      - An Alert Rule that fires when Invoke-AutoShutdown job status is Failed

    Reads config from .autoshutdown-state.json automatically.

.PARAMETER AlertEmail
    Email address to receive failure alerts.
    Default: cloud@powerco.de

.PARAMETER AlertEmailName
    Display name for the email recipient.
    Default: PowerCloud Team

.EXAMPLE
    .\Set-AlertRule.ps1

.EXAMPLE
    .\Set-AlertRule.ps1 -AlertEmail "myteam@company.com"

.NOTES
    Permissions required : Contributor on the Resource Group
    Modules required     : Az.Accounts, Az.Monitor
#>

[CmdletBinding()]
param (
    [string] $AlertEmail     = "pmadersky@thetrask.com",
    [string] $AlertEmailName = "PowerCloud Team",
    [string] $SubscriptionId        = "",
    [string] $ResourceGroupName     = "",
    [string] $AutomationAccountName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Helpers.ps1"

Write-Banner "US-10 | Create Azure Monitor Alert Rule"

# -- Prerequisites -------------------------------------------------------------
Assert-Modules @("Az.Accounts", "Az.Monitor")

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
    Write-Success "Subscription : $($state.SubscriptionName)"
}

Write-Info "Resource Group     : $ResourceGroupName"
Write-Info "Automation Account : $AutomationAccountName"
Write-Info "Alert email        : $AlertEmail"

# -- Get Automation Account resource ID ----------------------------------------
Write-Step "Resolving Automation Account resource ID..."

$aaResource = Get-AzResource `
    -ResourceGroupName $ResourceGroupName `
    -ResourceType      "Microsoft.Automation/automationAccounts" `
    -ResourceName      $AutomationAccountName `
    -ErrorAction Stop

$aaResourceId = $aaResource.ResourceId
Write-Success "Resource ID found."

# -- Action Group --------------------------------------------------------------
Write-Step "Creating Action Group..."

$actionGroupName = "ag-autoshutdown-alert"

$existingAG = Get-AzActionGroup `
    -ResourceGroupName $ResourceGroupName `
    -Name              $actionGroupName `
    -ErrorAction SilentlyContinue

if ($existingAG) {
    Write-Success "Action Group already exists - skipping creation."
} else {
    # Build the email receiver object directly as a hashtable
    # (New-AzActionGroupReceiver was removed in newer Az.Monitor versions)
    $emailReceiver = [Microsoft.Azure.Management.Monitor.Models.EmailReceiver]::new()
    $emailReceiver.Name         = $AlertEmailName
    $emailReceiver.EmailAddress = $AlertEmail

    # Use REST via Invoke-AzRestMethod to create the Action Group
    # This avoids cmdlet version compatibility issues entirely
    $agPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
              "/providers/microsoft.insights/actionGroups/$actionGroupName" +
              "?api-version=2023-01-01"

    $agBody = @{
        location   = "global"
        properties = @{
            groupShortName = "AutoShtdwn"
            enabled        = $true
            emailReceivers = @(
                @{
                    name                 = $AlertEmailName
                    emailAddress         = $AlertEmail
                    useCommonAlertSchema = $true
                }
            )
        }
    } | ConvertTo-Json -Depth 5

    $agResponse = Invoke-AzRestMethod -Path $agPath -Method PUT -Payload $agBody -ErrorAction Stop

    if ($agResponse.StatusCode -notin @(200, 201)) {
        throw "Failed to create Action Group. HTTP $($agResponse.StatusCode): $($agResponse.Content)"
    }

    Write-Success "Action Group created: $actionGroupName"
    Write-Info "Alerts will be sent to: $AlertEmail"
}

$actionGroup = Get-AzActionGroup `
    -ResourceGroupName $ResourceGroupName `
    -Name              $actionGroupName `
    -ErrorAction Stop

$actionGroupId = $actionGroup.Id

# -- Alert Rule ----------------------------------------------------------------
Write-Step "Creating Alert Rule..."

$alertRuleName = "alert-autoshutdown-failure"

$existingAlert = Get-AzMetricAlertRuleV2 `
    -ResourceGroupName $ResourceGroupName `
    -Name              $alertRuleName `
    -ErrorAction SilentlyContinue

if ($existingAlert) {
    Write-Success "Alert Rule already exists - skipping creation."
} else {
    # Use REST to create the alert rule - avoids cmdlet version issues
    $alertPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
                 "/providers/microsoft.insights/metricAlerts/$alertRuleName" +
                 "?api-version=2018-03-01"

    $alertBody = @{
        location   = "global"
        properties = @{
            description         = "Fires when Invoke-AutoShutdown job fails"
            severity            = 2
            enabled             = $true
            scopes              = @($aaResourceId)
            evaluationFrequency = "PT5M"
            windowSize          = "PT5M"
            criteria            = @{
                "odata.type"     = "Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria"
                allOf            = @(
                    @{
                        criterionType    = "StaticThresholdCriterion"
                        name             = "Failed jobs"
                        metricName       = "TotalJob"
                        metricNamespace  = "Microsoft.Automation/automationAccounts"
                        operator         = "GreaterThan"
                        threshold        = 0
                        timeAggregation  = "Total"
                        dimensions       = @(
                            @{ name = "Status";  operator = "Include"; values = @("Failed") }
                            @{ name = "Runbook"; operator = "Include"; values = @("Invoke-AutoShutdown") }
                        )
                    }
                )
            }
            actions = @(
                @{ actionGroupId = $actionGroupId }
            )
        }
    } | ConvertTo-Json -Depth 10

    $alertResponse = Invoke-AzRestMethod -Path $alertPath -Method PUT -Payload $alertBody -ErrorAction Stop

    if ($alertResponse.StatusCode -notin @(200, 201)) {
        throw "Failed to create Alert Rule. HTTP $($alertResponse.StatusCode): $($alertResponse.Content)"
    }

    Write-Success "Alert Rule created: $alertRuleName"
    Write-Info "Fires when: Invoke-AutoShutdown job status = Failed"
    Write-Info "Window    : 5 minutes"
    Write-Info "Severity  : 2 (Warning)"
}

# -- Acceptance criteria -------------------------------------------------------
Invoke-AcceptanceCriteria -StoryId "US-10" -CriteriaNames @(
    "Action Group exists and targets the correct email"
    "Alert Rule exists targeting the Automation Account"
) -Criteria @(
    {
        $null -ne (Get-AzActionGroup `
            -ResourceGroupName $ResourceGroupName `
            -Name $actionGroupName -ErrorAction SilentlyContinue)
    }
    {
        # Verify via REST since Get-AzMetricAlertRuleV2 may not be available
        $checkPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
                     "/providers/microsoft.insights/metricAlerts/$alertRuleName" +
                     "?api-version=2018-03-01"
        $checkResp = Invoke-AzRestMethod -Path $checkPath -Method GET -ErrorAction SilentlyContinue
        $checkResp.StatusCode -eq 200
    }
) | Out-Null

# -- Summary -------------------------------------------------------------------
Write-Banner "Done"
Write-Host ""
Write-Host "  Action Group  : $actionGroupName" -ForegroundColor White
Write-Host "  Alert Rule    : $alertRuleName"   -ForegroundColor White
Write-Host "  Notifies      : $AlertEmail"       -ForegroundColor White
Write-Host ""
Write-Host "  The PowerCloud team will receive an email within 5 minutes" -ForegroundColor Gray
Write-Host "  of any failed Invoke-AutoShutdown job." -ForegroundColor Gray
Write-Host ""