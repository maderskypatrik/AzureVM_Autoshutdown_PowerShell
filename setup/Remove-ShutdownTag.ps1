<#
.SYNOPSIS
    US-12 | Interactively offboards VMs from Autoshutdown.

.DESCRIPTION
    Lists all VMs that currently have the 'shutdown' tag and lets you either:
      A) Add 'donotshutdown' tag  — VM stays excluded but can be re-enrolled easily
      B) Remove 'shutdown' tag    — VM is completely removed from autoshutdown

.PARAMETER ResourceGroupName
    Optional. Filter VMs to a specific Resource Group.

.PARAMETER SubscriptionId
    Optional. Defaults to .autoshutdown-state.json.

.EXAMPLE
    .\Remove-ShutdownTag.ps1

.EXAMPLE
    .\Remove-ShutdownTag.ps1 -ResourceGroupName "rg-myproject"

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

Write-Banner "US-12 | Offboard VMs from Autoshutdown"

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

# -- Fetch tagged VMs ----------------------------------------------------------
Write-Step "Fetching VMs with shutdown or donotshutdown tags..."

if ($ResourceGroupName -ne "") {
    $allVMs = @(Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
} else {
    $allVMs = @(Get-AzVM -ErrorAction Stop)
}

# Filter to only VMs that have shutdown or donotshutdown tag
$taggedVMs = @($allVMs | Where-Object {
    $t = $_.Tags
    ($t -and ($t.Keys | Where-Object { $_ -ieq "shutdown" })) -or
    ($t -and ($t.Keys | Where-Object { $_ -ieq "donotshutdown" }))
} | Sort-Object ResourceGroupName, Name)

if ($taggedVMs.Count -eq 0) {
    Write-Warn "No VMs with shutdown or donotshutdown tags found."
    exit 0
}

Write-Success "Found $($taggedVMs.Count) VM(s) with autoshutdown tags."

# -- Display list --------------------------------------------------------------
Write-Host ""
Write-Host "  VMs currently enrolled or excluded:" -ForegroundColor Cyan
Write-Host ""

$padName = ($taggedVMs | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
$padRg   = ($taggedVMs | ForEach-Object { $_.ResourceGroupName.Length } | Measure-Object -Maximum).Maximum

Write-Host ("  {0,4}  {1,-$padName}  {2,-$padRg}  {3}" -f `
    "#", "VM Name", "Resource Group", "Current Status") -ForegroundColor DarkGray
Write-Host ("  {0,4}  {1,-$padName}  {2,-$padRg}  {3}" -f `
    "----", ("-" * $padName), ("-" * $padRg), "--------------") -ForegroundColor DarkGray

for ($i = 0; $i -lt $taggedVMs.Count; $i++) {
    $vm   = $taggedVMs[$i]
    $tags = $vm.Tags

    $hasShutdown      = $tags -and ($tags.Keys | Where-Object { $_ -ieq "shutdown" })
    $hasDoNotShutdown = $tags -and ($tags.Keys | Where-Object { $_ -ieq "donotshutdown" })

    $status = if ($hasDoNotShutdown -and $hasShutdown) { "excluded (donotshutdown + shutdown)" }
              elseif ($hasDoNotShutdown)                { "excluded (donotshutdown only)"       }
              else                                      { "enrolled (shutdown)"                 }

    $color = if ($hasDoNotShutdown) { "Yellow" } else { "Green" }

    Write-Host ("  {0,4}  {1,-$padName}  {2,-$padRg}  {3}" -f `
        ($i + 1), $vm.Name, $vm.ResourceGroupName, $status) -ForegroundColor $color
}

Write-Host ""

# -- Selection -----------------------------------------------------------------
Write-Host "  Enter the numbers of the VMs you want to offboard." -ForegroundColor Cyan
Write-Host "  Separate multiple numbers with commas. e.g. 1,3,5" -ForegroundColor Gray
Write-Host "  Press Enter without typing to cancel." -ForegroundColor Gray
Write-Host ""

$input = Read-Host "  Your selection"

if ($input.Trim() -eq "") {
    Write-Info "No selection made. Exiting."
    exit 0
}

$selectedVMs = @()
foreach ($part in ($input -split ",")) {
    $part = $part.Trim()
    if ($part -match '^\d+$') {
        $idx = [int]$part - 1
        if ($idx -ge 0 -and $idx -lt $taggedVMs.Count) {
            $selectedVMs += $taggedVMs[$idx]
        } else {
            Write-Warn "Number $part is out of range — skipped."
        }
    }
}

if ($selectedVMs.Count -eq 0) {
    Write-Warn "No valid VMs selected. Exiting."
    exit 0
}

# -- Choose offboarding method -------------------------------------------------
Write-Host ""
Write-Host "  How do you want to offboard these VMs?" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [A]  Add 'donotshutdown' tag  — VM stays excluded but can be" -ForegroundColor White
Write-Host "       re-enrolled easily by removing the donotshutdown tag" -ForegroundColor Gray
Write-Host "       (recommended for temporary exclusions)" -ForegroundColor Gray
Write-Host ""
Write-Host "  [B]  Remove 'shutdown' tag    — VM is fully removed from" -ForegroundColor White
Write-Host "       autoshutdown. Re-add the shutdown tag to re-enroll." -ForegroundColor Gray
Write-Host "       (recommended for permanent removal)" -ForegroundColor Gray
Write-Host ""

$method = $null
while (-not $method) {
    $methodInput = Read-Host "  Enter A or B"
    if ($methodInput -imatch "^[Aa]$") { $method = "A" }
    elseif ($methodInput -imatch "^[Bb]$") { $method = "B" }
    else { Write-Host "  Please enter A or B." -ForegroundColor Yellow }
}

# -- Confirm -------------------------------------------------------------------
Write-Host ""
$action = if ($method -eq "A") { "add 'donotshutdown' tag to" } else { "remove 'shutdown' tag from" }
Write-Host "  You are about to $action $($selectedVMs.Count) VM(s):" -ForegroundColor Cyan
foreach ($vm in $selectedVMs) {
    Write-Host "    - $($vm.Name)  (RG: $($vm.ResourceGroupName))" -ForegroundColor White
}
Write-Host ""

$confirm = Read-Host "  Confirm? [Y/N]"
if ($confirm -notmatch "^[Yy]") {
    Write-Info "Cancelled."
    exit 0
}

# -- Apply changes -------------------------------------------------------------
Write-Step "Applying changes..."

$success = 0
$failed  = 0

foreach ($vm in $selectedVMs) {
    Write-Info "Processing: $($vm.Name) (RG: $($vm.ResourceGroupName))..."

    try {
        if ($method -eq "A") {
            # Add donotshutdown tag
            Update-AzTag `
                -ResourceId $vm.Id `
                -Tag        @{ donotshutdown = "true" } `
                -Operation  Merge `
                -ErrorAction Stop | Out-Null
            Write-Success "  Added 'donotshutdown' tag to $($vm.Name)"
        } else {
            # Remove shutdown tag
            Update-AzTag `
                -ResourceId $vm.Id `
                -Tag        @{ shutdown = "" } `
                -Operation  Delete `
                -ErrorAction Stop | Out-Null
            Write-Success "  Removed 'shutdown' tag from $($vm.Name)"
        }
        $success++
    } catch {
        Write-Fail "  Failed to update $($vm.Name): $_"
        $failed++
    }
}

# -- Summary -------------------------------------------------------------------
Write-Banner "Done"
Write-Host ""
Write-Host "  Updated successfully : $success" -ForegroundColor Green
Write-Host "  Failed               : $failed"  -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Gray" })
Write-Host ""

if ($method -eq "A") {
    Write-Host "  VMs with 'donotshutdown' tag will be skipped on all future runs." -ForegroundColor Gray
    Write-Host "  To re-enroll: remove the 'donotshutdown' tag or run Add-ShutdownTag.ps1" -ForegroundColor Gray
} else {
    Write-Host "  VMs without the 'shutdown' tag will be ignored on all future runs." -ForegroundColor Gray
    Write-Host "  To re-enroll: run Add-ShutdownTag.ps1" -ForegroundColor Gray
}
Write-Host ""
