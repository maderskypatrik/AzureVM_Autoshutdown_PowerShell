<#
.SYNOPSIS
    Shared helper functions for the Autoshutdown setup scripts.
    Dot-source this file at the top of each setup script:
        . "$PSScriptRoot\_Helpers.ps1"
#>

#region -- Logging --------------------------------------------------------------

function Write-Banner {
    param([string]$Title)
    $line = "=" * 60
    Write-Host ""
    Write-Host $line                  -ForegroundColor DarkCyan
    Write-Host "  $Title"            -ForegroundColor White
    Write-Host $line                  -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Message, [int]$Number = 0)
    $prefix = if ($Number -gt 0) { "  [$Number]" } else { "   >> " }
    Write-Host ""
    Write-Host "$prefix $Message"    -ForegroundColor Cyan
}

function Write-Success { param([string]$m); Write-Host "  [OK]   $m" -ForegroundColor Green   }
function Write-Info    { param([string]$m); Write-Host "         $m" -ForegroundColor Gray    }
function Write-Warn    { param([string]$m); Write-Host "  [WARN] $m" -ForegroundColor Yellow  }
function Write-Fail    { param([string]$m); Write-Host "  [FAIL] $m" -ForegroundColor Red     }

function Write-NextSteps {
    param([string[]]$Steps)
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        Write-Host "  $($i+1). $($Steps[$i])" -ForegroundColor White
    }
    Write-Host ""
}

#endregion

#region -- Prerequisites --------------------------------------------------------

function Assert-Modules {
    param([string[]]$Names)
    Write-Step "Checking required PowerShell modules..."
    $missing = @()
    foreach ($mod in $Names) {
        if (Get-Module -ListAvailable -Name $mod) {
            Write-Success "Module available: $mod"
        } else {
            Write-Fail "Module missing:   $mod"
            $missing += $mod
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host ""
        Write-Host "  Install missing modules with:" -ForegroundColor Yellow
        Write-Host "    Install-Module $($missing -join ', ') -Scope CurrentUser -Force" -ForegroundColor Yellow
        Write-Host ""
        throw "Missing required modules: $($missing -join ', ')"
    }
    Write-Success "All required modules are available."
}

#endregion

#region -- Authentication -------------------------------------------------------

function Connect-AutoShutdown {
    Write-Step "Connecting to Azure..."
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($ctx) {
        Write-Success "Already signed in as: $($ctx.Account.Id)"
    } else {
        Connect-AzAccount -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext
        Write-Success "Signed in as: $($ctx.Account.Id)"
    }
    return $ctx
}

#endregion

#region -- Subscription picker --------------------------------------------------

function Select-Subscription {
    <#
    .SYNOPSIS
        Interactive subscription picker.
        If the user has only one subscription, selects it automatically.
        If a SubscriptionId parameter was passed, validates and uses it.
        Otherwise shows a numbered menu.
    #>
    param(
        [string]$SubscriptionId = ""
    )

    Write-Step "Resolving target subscription..."

    # Get all accessible subscriptions
    $subs = @(Get-AzSubscription -ErrorAction Stop | Sort-Object Name)

    if ($subs.Count -eq 0) {
        throw "No accessible subscriptions found for the current account."
    }

    # If a specific ID was passed, validate it
    if ($SubscriptionId -ne "") {
        $match = $subs | Where-Object { $_.Id -eq $SubscriptionId }
        if (-not $match) {
            throw "Subscription '$SubscriptionId' not found or not accessible by your account."
        }
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        Write-Success "Using specified subscription: $($match.Name) ($($match.Id))"
        return $match
    }

    # Only one subscription - auto-select
    if ($subs.Count -eq 1) {
        Set-AzContext -SubscriptionId $subs[0].Id -ErrorAction Stop | Out-Null
        Write-Success "Only one subscription found - auto-selected: $($subs[0].Name) ($($subs[0].Id))"
        return $subs[0]
    }

    # Multiple subscriptions - show menu
    Write-Host ""
    Write-Host "  Multiple subscriptions found. Select one to use:" -ForegroundColor Cyan
    Write-Host ""

    $padName  = ($subs | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    $padState = 10

    Write-Host ("  {0,4}  {1,-$padName}  {2,-$padState}  {3}" -f "#", "Name", "State", "Subscription ID") -ForegroundColor DarkGray
    Write-Host ("  {0,4}  {1,-$padName}  {2,-$padState}  {3}" -f "----", ("-" * $padName), "----------", "------------------------------------") -ForegroundColor DarkGray

    for ($i = 0; $i -lt $subs.Count; $i++) {
        $sub   = $subs[$i]
        $color = if ($sub.State -eq "Enabled") { "White" } else { "DarkGray" }
        $line  = "  {0,4}  {1,-$padName}  {2,-$padState}  {3}" -f ($i + 1), $sub.Name, $sub.State, $sub.Id
        Write-Host $line -ForegroundColor $color
    }

    Write-Host ""

    # Input loop
    $selected = $null
    while (-not $selected) {
        $userInput = Read-Host "  Enter number [1-$($subs.Count)]"
        if ($userInput -match '^\d+$') {
            $idx = [int]$userInput - 1
            if ($idx -ge 0 -and $idx -lt $subs.Count) {
                $selected = $subs[$idx]
            }
        }
        if (-not $selected) {
            Write-Host "  Invalid selection. Enter a number between 1 and $($subs.Count)." -ForegroundColor Yellow
        }
    }

    Set-AzContext -SubscriptionId $selected.Id -ErrorAction Stop | Out-Null
    Write-Success "Selected: $($selected.Name) ($($selected.Id))"
    return $selected
}

#endregion

#region -- State file -----------------------------------------------------------
# Scripts pass state to each other via a local JSON file: .autoshutdown-state.json
# This avoids the user having to copy/paste GUIDs between scripts.

$StateFile = Join-Path $PSScriptRoot ".autoshutdown-state.json"

function Read-State {
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json
    }
    return [PSCustomObject]@{}
}

function Save-State {
    param([hashtable]$Values)
    $current = Read-State
    # Merge new values into existing state
    foreach ($key in $Values.Keys) {
        $current | Add-Member -NotePropertyName $key -NotePropertyValue $Values[$key] -Force
    }
    $current | ConvertTo-Json -Depth 5 | Out-File -FilePath $StateFile -Encoding utf8 -Force
    Write-Info "State saved to: $StateFile"
}

function Get-StateValue {
    param([string]$Key)
    $state = Read-State
    return $state.$Key
}

#endregion

#region -- Acceptance criteria runner -------------------------------------------

function Invoke-AcceptanceCriteria {
    param(
        [string]$StoryId,
        [scriptblock[]]$Criteria,
        [string[]]$CriteriaNames
    )
    Write-Banner "Acceptance Criteria Check"
    $passed = 0
    $failed = 0
    for ($i = 0; $i -lt $Criteria.Count; $i++) {
        $name   = $CriteriaNames[$i]
        $result = & $Criteria[$i]
        if ($result) {
            Write-Success $name
            $passed++
        } else {
            Write-Fail   $name
            $failed++
        }
    }
    Write-Host ""
    if ($failed -eq 0) {
        Write-Host "  All $passed criteria passed." -ForegroundColor Green
    } else {
        Write-Host "  $passed passed, $failed failed. Review output above." -ForegroundColor Yellow
    }
    return ($failed -eq 0)
}

#endregion
