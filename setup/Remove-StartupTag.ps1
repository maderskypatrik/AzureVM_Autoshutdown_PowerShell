<#
.SYNOPSIS
    Interactively offboards VMs from Auto-startup.

.DESCRIPTION
    Lists all VMs that currently have the 'startup' tag and lets you either:
      A) Add 'donotstart' tag   — VM stays excluded but can be re-enrolled easily
      B) Remove 'startup' tag   — VM is completely removed from auto-startup

.PARAMETER ResourceGroupName
    Optional. Filter VMs to a specific Resource Group.

.PARAMETER SubscriptionId
    Optional. Defaults to .autoshutdown-state.json.

.EXAMPLE
    .\Remove-StartupTag.ps1

.EXAMPLE
    .\Remove-StartupTag.ps1 -ResourceGroupName "rg-myproject"

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

Write-Banner "Offboard VMs from Auto-startup"

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
Write-Step "Fetching VMs with startup or donotstart tags..."

if ($ResourceGroupName -ne "") {
    $allVMs = @(Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
} else {
    $allVMs = @(Get-AzVM -ErrorAction Stop)
}

# Filter to only VMs that have startup or donotstart tag
$taggedVMs = @($allVMs | Where-Object {
    $t = $_.Tags
    ($t -and ($t.Keys | Where-Object { $_ -ieq "startup" })) -or
    ($t -and ($t.Keys | Where-Object { $_ -ieq "donotstart" }))
} | Sort-Object ResourceGroupName, Name)

if ($taggedVMs.Count -eq 0) {
    Write-Warn "No VMs with startup or donotstart tags found."
    exit 0
}

Write-Success "Found $($taggedVMs.Count) VM(s) with auto-startup tags."

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

    $hasStartup    = $tags -and ($tags.Keys | Where-Object { $_ -ieq "startup" })
    $hasDoNotStart = $tags -and ($tags.Keys | Where-Object { $_ -ieq "donotstart" })

    $status = if ($hasDoNotStart -and $hasStartup) { "excluded (donotstart + startup)" }
              elseif ($hasDoNotStart)               { "excluded (donotstart only)"      }
              else                                  { "enrolled (startup)"              }

    $color = if ($hasDoNotStart) { "Yellow" } else { "Green" }

    Write-Host ("  {0,4}  {1,-$padName}  {2,-$padRg}  {3}" -f `
        ($i + 1), $vm.Name, $vm.ResourceGroupName, $status) -ForegroundColor $color
}

Write-Host ""

# -- Selection -----------------------------------------------------------------
Write-Host "  Enter the numbers of the VMs you want to offboard." -ForegroundColor Cyan
Write-Host "  Separate multiple numbers with commas. e.g. 1,3,5" -ForegroundColor Gray
Write-Host "  Press Enter without typing to cancel." -ForegroundColor Gray
Write-Host ""

$selection = Read-Host "  Your selection"

if ($selection.Trim() -eq "") {
    Write-Info "No selection made. Exiting."
    exit 0
}

$selectedVMs = @()
foreach ($part in ($selection -split ",")) {
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
Write-Host "  [A]  Add 'donotstart' tag   — VM stays excluded but can be" -ForegroundColor White
Write-Host "       re-enrolled easily by removing the donotstart tag" -ForegroundColor Gray
Write-Host "       (recommended for temporary exclusions)" -ForegroundColor Gray
Write-Host ""
Write-Host "  [B]  Remove 'startup' tag   — VM is fully removed from" -ForegroundColor White
Write-Host "       auto-startup. Re-add the startup tag to re-enroll." -ForegroundColor Gray
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
$action = if ($method -eq "A") { "add 'donotstart' tag to" } else { "remove 'startup' tag from" }
Write-Host "  You are about to $action $($selectedVMs.Count) VM(s):" -ForegroundColor Cyan
foreach ($vm in $selectedVMs) {
    Write-Host "    - $($vm.Name)  (RG: $($vm.ResourceGroupName))" -ForegroundColor White
}
Write-Host ""

$confirmed = Read-Host "  Confirm? [Y/N]"
if ($confirmed -notmatch "^[Yy]") {
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
            # Add donotstart tag
            Update-AzTag `
                -ResourceId $vm.Id `
                -Tag        @{ donotstart = "true" } `
                -Operation  Merge `
                -ErrorAction Stop | Out-Null
            Write-Success "  Added 'donotstart' tag to $($vm.Name)"
        } else {
            # Remove startup tag
            Update-AzTag `
                -ResourceId $vm.Id `
                -Tag        @{ startup = "" } `
                -Operation  Delete `
                -ErrorAction Stop | Out-Null
            Write-Success "  Removed 'startup' tag from $($vm.Name)"
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
    Write-Host "  VMs with 'donotstart' tag will be skipped on all future runs." -ForegroundColor Gray
    Write-Host "  To re-enroll: remove the 'donotstart' tag or run Add-StartupTag.ps1" -ForegroundColor Gray
} else {
    Write-Host "  VMs without the 'startup' tag will be ignored on all future runs." -ForegroundColor Gray
    Write-Host "  To re-enroll: run Add-StartupTag.ps1" -ForegroundColor Gray
}
Write-Host ""
