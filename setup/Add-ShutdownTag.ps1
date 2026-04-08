<#
.SYNOPSIS
    US-11 | Interactively onboards VMs to Autoshutdown by adding the shutdown tag.

.DESCRIPTION
    Lists all VMs in the subscription and lets you select which ones to tag
    with 'shutdown = true'. Already-tagged VMs are highlighted.
    VMs tagged with 'donotshutdown' are flagged.

.PARAMETER ResourceGroupName
    Optional. Filter VMs to a specific Resource Group.

.PARAMETER SubscriptionId
    Optional. Defaults to .autoshutdown-state.json.

.EXAMPLE
    # List all VMs in subscription and pick which to onboard
    .\Add-ShutdownTag.ps1

.EXAMPLE
    # Filter to a specific Resource Group
    .\Add-ShutdownTag.ps1 -ResourceGroupName "rg-myproject"

.NOTES
    Permissions required : Contributor on the VM resources
    Modules required     : Az.Accounts, Az.Compute
#>

[CmdletBinding()]
param (
    [string] $ResourceGroupName = "",
    [string] $SubscriptionId    = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Helpers.ps1"

Write-Banner "US-11 | Onboard VMs to Autoshutdown"

# -- Prerequisites -------------------------------------------------------------
Assert-Modules @("Az.Accounts", "Az.Compute")

# -- Auth & state --------------------------------------------------------------
Connect-AutoShutdown | Out-Null
$state = Read-State

if ($SubscriptionId -eq "") { $SubscriptionId = $state.SubscriptionId }

if ($SubscriptionId -eq "") {
    $sub = Select-Subscription; $SubscriptionId = $sub.Id
} else {
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Success "Subscription: $($state.SubscriptionName)"
}

# -- Fetch VMs -----------------------------------------------------------------
Write-Step "Fetching VMs..."

if ($ResourceGroupName -ne "") {
    $vms = @(Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop |
        Sort-Object ResourceGroupName, Name)
    Write-Success "Found $($vms.Count) VM(s) in Resource Group: $ResourceGroupName"
} else {
    $vms = @(Get-AzVM -ErrorAction Stop | Sort-Object ResourceGroupName, Name)
    Write-Success "Found $($vms.Count) VM(s) across all Resource Groups"
}

if ($vms.Count -eq 0) {
    Write-Warn "No VMs found."
    exit 0
}

# -- Display VM list -----------------------------------------------------------
Write-Host ""
Write-Host "  VM List — current tag status:" -ForegroundColor Cyan
Write-Host ""

$padName = ($vms | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
$padRg   = ($vms | ForEach-Object { $_.ResourceGroupName.Length } | Measure-Object -Maximum).Maximum

Write-Host ("  {0,4}  {1,-$padName}  {2,-$padRg}  {3}" -f `
    "#", "VM Name", "Resource Group", "Tag Status") -ForegroundColor DarkGray
Write-Host ("  {0,4}  {1,-$padName}  {2,-$padRg}  {3}" -f `
    "----", ("-" * $padName), ("-" * $padRg), "----------") -ForegroundColor DarkGray

for ($i = 0; $i -lt $vms.Count; $i++) {
    $vm   = $vms[$i]
    $tags = $vm.Tags

    $hasShutdown      = $tags -and ($tags.Keys | Where-Object { $_ -ieq "shutdown" })
    $hasDoNotShutdown = $tags -and ($tags.Keys | Where-Object { $_ -ieq "donotshutdown" })

    $status = if ($hasDoNotShutdown)      { "[donotshutdown]" }
              elseif ($hasShutdown)        { "[shutdown]      " }
              else                         { "not tagged      " }

    $color  = if ($hasDoNotShutdown)      { "Yellow" }
              elseif ($hasShutdown)        { "Green"  }
              else                         { "White"  }

    Write-Host ("  {0,4}  {1,-$padName}  {2,-$padRg}  {3}" -f `
        ($i + 1), $vm.Name, $vm.ResourceGroupName, $status) -ForegroundColor $color
}

Write-Host ""
Write-Host "  Legend: " -NoNewline
Write-Host "[shutdown] = already enrolled  " -ForegroundColor Green -NoNewline
Write-Host "[donotshutdown] = excluded  " -ForegroundColor Yellow -NoNewline
Write-Host "not tagged = not enrolled" -ForegroundColor White
Write-Host ""

# -- Selection -----------------------------------------------------------------
Write-Host "  Enter the numbers of the VMs you want to enroll (add shutdown tag)." -ForegroundColor Cyan
Write-Host "  Separate multiple numbers with commas. e.g. 1,3,5" -ForegroundColor Gray
Write-Host "  Press Enter without typing to cancel." -ForegroundColor Gray
Write-Host ""

$input = Read-Host "  Your selection"

if ($input.Trim() -eq "") {
    Write-Info "No selection made. Exiting."
    exit 0
}

# Parse selection
$selectedVMs = @()
foreach ($part in ($input -split ",")) {
    $part = $part.Trim()
    if ($part -match '^\d+$') {
        $idx = [int]$part - 1
        if ($idx -ge 0 -and $idx -lt $vms.Count) {
            $selectedVMs += $vms[$idx]
        } else {
            Write-Warn "Number $part is out of range — skipped."
        }
    }
}

if ($selectedVMs.Count -eq 0) {
    Write-Warn "No valid VMs selected. Exiting."
    exit 0
}

# -- Confirm -------------------------------------------------------------------
Write-Host ""
Write-Host "  You selected $($selectedVMs.Count) VM(s) to enroll:" -ForegroundColor Cyan
foreach ($vm in $selectedVMs) {
    Write-Host "    - $($vm.Name)  (RG: $($vm.ResourceGroupName))" -ForegroundColor White
}
Write-Host ""

$confirm = Read-Host "  Add 'shutdown = true' tag to these VMs? [Y/N]"
if ($confirm -notmatch "^[Yy]") {
    Write-Info "Cancelled."
    exit 0
}

# -- Tag VMs -------------------------------------------------------------------
Write-Step "Adding shutdown tags..."

$tagged  = 0
$skipped = 0
$failed  = 0

foreach ($vm in $selectedVMs) {
    Write-Info "Tagging: $($vm.Name) (RG: $($vm.ResourceGroupName))..."

    # Check if donotshutdown tag is present — warn but still allow
    $hasDoNotShutdown = $vm.Tags -and ($vm.Tags.Keys | Where-Object { $_ -ieq "donotshutdown" })
    if ($hasDoNotShutdown) {
        Write-Warn "  VM '$($vm.Name)' has a 'donotshutdown' tag. The shutdown tag will be added but the VM will still be excluded from shutdowns until 'donotshutdown' is removed."
    }

    # Check if already tagged
    $hasShutdown = $vm.Tags -and ($vm.Tags.Keys | Where-Object { $_ -ieq "shutdown" })
    if ($hasShutdown) {
        Write-Success "  Already has shutdown tag - skipping."
        $skipped++
        continue
    }

    try {
        Update-AzTag `
            -ResourceId $vm.Id `
            -Tag        @{ shutdown = "true" } `
            -Operation  Merge `
            -ErrorAction Stop | Out-Null
        Write-Success "  Tagged: $($vm.Name)"
        $tagged++
    } catch {
        Write-Fail "  Failed to tag $($vm.Name): $_"
        $failed++
    }
}

# -- Summary -------------------------------------------------------------------
Write-Banner "Done"
Write-Host ""
Write-Host "  Tagged successfully : $tagged"  -ForegroundColor Green
Write-Host "  Already tagged      : $skipped" -ForegroundColor Gray
Write-Host "  Failed              : $failed"  -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Gray" })
Write-Host ""
Write-Host "  Tagged VMs will be shut down at the next scheduled run." -ForegroundColor Gray
Write-Host ""
