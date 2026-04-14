<#
.SYNOPSIS
    Auto-startup runbook for Azure VMs and Azure Local VMs.

.DESCRIPTION
    Starts up:
      - Classic Azure VMs (Microsoft.Compute/virtualMachines) tagged with "startup"
      - Azure Local VMs (Microsoft.AzureStackHCI/virtualMachineInstances) tagged with "startup"

    Skips:
      - Any resource tagged with "donotstart" (regardless of value)
      - Azure Local Servers (Microsoft.AzureStackHCI/servers) — never touched

    Tag logic:
      - Tag key matching is case-insensitive.
      - A VM is eligible if it has a tag key "startup" (any value).
      - A VM is excluded  if it has a tag key "donotstart" (any value).
      - "donotstart" takes priority over "startup" when both are present.

.PARAMETER SubscriptionIds
    Comma-separated list of Azure Subscription IDs to process.
    Defaults to all subscriptions accessible by the Automation Account's Managed Identity.

.PARAMETER WhatIf
    If set to $true, the script logs what it would do but performs no actual startups.

.NOTES
    Authentication : System-assigned Managed Identity on the Azure Automation Account.
    Required roles : Virtual Machine Contributor (or Reader + VM Operator) on each subscription.
    Logging        : All actions are written to the Automation Job output stream.
#>

param (
    [Parameter(Mandatory = $false)]
    [string] $SubscriptionIds = "",

    [Parameter(Mandatory = $false)]
    [bool] $WhatIf = $false
)

#region ── Helpers ──────────────────────────────────────────────────────────────

function Write-Log {
    param ([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Write-Output "[$timestamp][$Level] $Message"
}

function Has-Tag {
    param (
        [hashtable]$Tags,
        [string]$TagKey
    )
    if (-not $Tags) { return $false }
    return ($Tags.Keys | Where-Object { $_ -ieq $TagKey }).Count -gt 0
}

#endregion

#region ── Authentication ───────────────────────────────────────────────────────

Write-Log "Authenticating with Managed Identity..."

try {
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Write-Log "Authentication successful."
} catch {
    Write-Log "Authentication failed: $_" "ERROR"
    throw
}

#endregion

#region ── Subscription resolution ─────────────────────────────────────────────

if ($SubscriptionIds -ne "") {
    $subIds = $SubscriptionIds -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    Write-Log "Processing $($subIds.Count) subscription(s) provided as parameter."
} else {
    $subIds = (Get-AzSubscription -ErrorAction Stop).Id
    Write-Log "No subscriptions specified — processing all $($subIds.Count) accessible subscription(s)."
}

#endregion

#region ── Counters ─────────────────────────────────────────────────────────────

$stats = @{
    Subscriptions      = 0
    Evaluated          = 0
    Started            = 0
    SkippedDoNotStart  = 0
    SkippedNoTag       = 0
    SkippedAlreadyOn   = 0
    Errors             = 0
}

#endregion

#region ── Main loop ────────────────────────────────────────────────────────────

foreach ($subId in $subIds) {

    Write-Log "──────────────────────────────────────────────"
    Write-Log "Switching to subscription: $subId"

    try {
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
    } catch {
        Write-Log "Cannot set context for subscription $subId : $_" "ERROR"
        $stats.Errors++
        continue
    }

    $stats.Subscriptions++

    # ── 1. Classic Azure VMs ─────────────────────────────────────────────────
    Write-Log "Fetching classic Azure VMs (Microsoft.Compute/virtualMachines)..."

    try {
        $classicVMs = Get-AzVM -Status -ErrorAction Stop
    } catch {
        Write-Log "Failed to list classic VMs in $subId : $_" "ERROR"
        $stats.Errors++
        $classicVMs = @()
    }

    foreach ($vm in $classicVMs) {

        $stats.Evaluated++
        $name = $vm.Name
        $rg   = $vm.ResourceGroupName
        $tags = $vm.Tags

        Write-Log "Evaluating classic VM: $name (RG: $rg)"

        # Priority 1: donotstart tag
        if (Has-Tag -Tags $tags -TagKey "donotstart") {
            Write-Log "  SKIP — tagged 'donotstart'."
            $stats.SkippedDoNotStart++
            continue
        }

        # Priority 2: must have startup tag
        if (-not (Has-Tag -Tags $tags -TagKey "startup")) {
            Write-Log "  SKIP — no 'startup' tag."
            $stats.SkippedNoTag++
            continue
        }

        # Priority 3: already running?
        $powerState = ($vm.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
        if ($powerState -eq "VM running") {
            Write-Log "  SKIP — already running."
            $stats.SkippedAlreadyOn++
            continue
        }

        # Action
        if ($WhatIf) {
            Write-Log "  [WHATIF] Would start classic VM: $name"
        } else {
            Write-Log "  ACTION — Starting classic VM: $name ..."
            try {
                Start-AzVM -ResourceGroupName $rg -Name $name -ErrorAction Stop | Out-Null
                Write-Log "  SUCCESS — VM $name started."
                $stats.Started++
            } catch {
                Write-Log "  ERROR   — Failed to start VM $name : $_" "ERROR"
                $stats.Errors++
            }
        }
    }

    # -- 2. Azure Local VMs -------------------------------------------------------
    # Resource type: microsoft.azurestackhci/virtualmachineinstances
    # Azure Local *Servers* (microsoft.azurestackhci/servers) are explicitly excluded.
    #
    # Az.ResourceGraph is required for this section. If the module is missing or
    # cannot be loaded the query is skipped with a WARNING (not an error) so the
    # job does not fail -- classic Azure VMs are completely unaffected.

    Write-Log "Fetching Azure Local VMs (Microsoft.AzureStackHCI/virtualMachineInstances)..."

    $localVMs       = @()
    $graphAvailable = $false

    try {
        Import-Module Az.ResourceGraph -RequiredVersion "1.2.1" -ErrorAction Stop
        $graphAvailable = $true
    } catch {
        Write-Log "Az.ResourceGraph v1.2.1 could not be loaded -- Azure Local VM query skipped." "WARN"
        Write-Log "To enable HCI support: ensure Az.ResourceGraph v1.2.1 (runtime 7.2) is imported into the Automation Account." "WARN"
    }

    if ($graphAvailable) {
        try {
            $localVMs = Search-AzGraph -Query @"
Resources
| where subscriptionId == '$subId'
| where type =~ 'microsoft.azurestackhci/virtualmachineinstances'
| project id, name, resourceGroup, tags, properties
"@ -ErrorAction Stop
        } catch {
            Write-Log "Failed to query Azure Local VMs in $subId : $_" "WARN"
            $localVMs = @()
        }
    }

    foreach ($lvm in $localVMs) {

        $stats.Evaluated++
        $name = $lvm.name
        $rg   = $lvm.resourceGroup
        $id   = $lvm.id
        $tags = $lvm.tags

        Write-Log "Evaluating Azure Local VM: $name (RG: $rg)"

        # Convert PSCustomObject tags to hashtable for Has-Tag
        $tagsHT = @{}
        if ($tags) {
            $tags.PSObject.Properties | ForEach-Object { $tagsHT[$_.Name] = $_.Value }
        }

        # Priority 1: donotstart tag
        if (Has-Tag -Tags $tagsHT -TagKey "donotstart") {
            Write-Log "  SKIP — tagged 'donotstart'."
            $stats.SkippedDoNotStart++
            continue
        }

        # Priority 2: must have startup tag
        if (-not (Has-Tag -Tags $tagsHT -TagKey "startup")) {
            Write-Log "  SKIP — no 'startup' tag."
            $stats.SkippedNoTag++
            continue
        }

        # Priority 3: check power state from properties
        $powerState = $lvm.properties.instanceView.powerState
        if ($powerState -eq "Running") {
            Write-Log "  SKIP — already running (state: $powerState)."
            $stats.SkippedAlreadyOn++
            continue
        }

        # Action — Azure Local VMs are started via REST API
        if ($WhatIf) {
            Write-Log "  [WHATIF] Would start Azure Local VM: $name"
        } else {
            Write-Log "  ACTION — Starting Azure Local VM: $name ..."
            try {
                $token  = (Get-AzAccessToken).Token
                $apiUri = "https://management.azure.com$($id)/start?api-version=2023-09-01-preview"
                $response = Invoke-RestMethod -Uri $apiUri -Method POST `
                    -Headers @{ Authorization = "Bearer $token" } `
                    -ContentType "application/json" -ErrorAction Stop
                Write-Log "  SUCCESS — Azure Local VM $name start request accepted."
                $stats.Started++
            } catch {
                Write-Log "  ERROR   — Failed to start Azure Local VM $name : $_" "ERROR"
                $stats.Errors++
            }
        }
    }

    Write-Log "Finished subscription: $subId"
}

#endregion

#region ── Summary ──────────────────────────────────────────────────────────────

Write-Log "══════════════════════════════════════════════"
Write-Log "RUN SUMMARY"
Write-Log "══════════════════════════════════════════════"
Write-Log "Subscriptions processed  : $($stats.Subscriptions)"
Write-Log "VMs evaluated            : $($stats.Evaluated)"
Write-Log "VMs started              : $($stats.Started)"
Write-Log "Skipped (donotstart)     : $($stats.SkippedDoNotStart)"
Write-Log "Skipped (no tag)         : $($stats.SkippedNoTag)"
Write-Log "Skipped (already running): $($stats.SkippedAlreadyOn)"
Write-Log "Errors                   : $($stats.Errors)"
Write-Log "══════════════════════════════════════════════"

if ($stats.Errors -gt 0) {
    throw "Runbook completed with $($stats.Errors) error(s). Review output above."
}
