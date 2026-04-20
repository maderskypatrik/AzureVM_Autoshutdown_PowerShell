# VM Auto-shutdown & Auto-startup

> Automated daily shutdown **and startup** for Azure VMs using Azure Automation — no stored credentials, tag-based filtering, and least-privilege access.

**PowerCloud Team · v1.4.1 · Internal use only**

---

## Overview

The solution runs entirely inside Azure Automation. A System-assigned Managed Identity authenticates the runbooks — no stored credentials. Each runbook is triggered daily by its own schedule and processes all accessible subscriptions in a single job.

| Component | Type | Purpose |
|---|---|---|
| `aa-autoshutdown` | Azure Automation Account | Hosts runbooks, schedules, and modules |
| System-assigned MI | Managed Identity | Authenticates runbooks to Azure — no passwords |
| `Invoke-AutoShutdown.ps1` | PowerShell 7.2 Runbook | Stops VMs tagged with `shutdown` |
| `Invoke-AutoStartup.ps1` | PowerShell 7.2 Runbook | Starts VMs tagged with `startup` |
| `sched-autoshutdown-daily` | Automation Schedule | Daily shutdown trigger (default 19:00 CET, DST-aware) |
| `sched-autostartup-daily` | Automation Schedule | Daily startup trigger (default 07:00 CET, DST-aware) |
| `Az.Accounts` / `Az.Compute` / `Az.ResourceGraph` | PS Modules | Required Az cmdlets imported into the account |

---

## Repository Structure

```
setup/
  _Helpers.ps1                  # Shared functions — auth, logging, state file, pickers
  Install-AutoShutdown.ps1      # Master orchestrator — runs all 7 setup steps
  New-AutoShutdownInfra.ps1     # Step 1 — creates Automation Account in existing RG
  Set-ManagedIdentity.ps1       # Step 2 — enables Managed Identity
  Set-RBACRoles.ps1             # Step 3 — assigns RBAC roles
  Import-Modules.ps1            # Step 4 — imports Az modules into Automation Account
  New-Runbook.ps1               # Step 5 — uploads shutdown runbook and creates schedule
  New-StartupRunbook.ps1        # Step 6 — uploads startup runbook and creates schedule
  Set-AlertRule.ps1             # Step 7 — creates Azure Monitor alerts for job failures
  Add-ShutdownTag.ps1           # Interactively tags VMs for auto-shutdown
  Remove-ShutdownTag.ps1        # Interactively offboards VMs from auto-shutdown
  Add-StartupTag.ps1            # Interactively tags VMs for auto-startup
  Remove-StartupTag.ps1         # Interactively offboards VMs from auto-startup

runbook/
  Invoke-AutoShutdown.ps1       # Shutdown runbook — deployed to Azure Automation
  Invoke-AutoStartup.ps1        # Startup runbook  — deployed to Azure Automation

docs/
  Technical-Documentation.md   # Engineering reference
  User-Guide.md                 # Guide for subscription owners
  Terms-of-Use.md               # Terms of Use — acceptance required at install time

version.txt                     # Current release version — checked by Install-AutoShutdown.ps1
```

---

## Setup

The `setup/` folder contains scripts that configure Azure — they run **once from your local machine**. The `runbook/` folder contains the runbooks — these get uploaded to Azure Automation and run in the cloud on their daily schedules. You never run them directly.

Setup scripts pass state to each other via `.autoshutdown-state.json`.

### Run full setup (shutdown + startup)

```powershell
.\Install-AutoShutdown.ps1
```

On startup the script will:
1. **Terms of Use** — display the Terms of Use URL and require explicit `y` acceptance before proceeding.
2. **Version check** — compare the local version against the latest GitHub release. If a newer version is available, offers to run `git pull` automatically (or shows the GitHub URL if not a git clone).

It then runs all 7 steps and sets up both runbooks and failure alerts. Both runbooks start in **WhatIf mode** — no VMs will be touched until you explicitly enable live mode.

### Custom schedule times and alert email

```powershell
.\Install-AutoShutdown.ps1 -ScheduleTime '18:00' -StartupScheduleTime '06:30' -AlertEmail 'myteam@company.com'
```

### Resume from a specific step

```powershell
.\Install-AutoShutdown.ps1 -StartFromStep 3
```

### Setup steps

| # | Script | Purpose |
|---|---|---|
| 1 | `New-AutoShutdownInfra.ps1` | Picks existing RG from menu, creates Automation Account |
| 2 | `Set-ManagedIdentity.ps1` | Enables System-assigned Managed Identity, saves Object ID |
| 3 | `Set-RBACRoles.ps1` | Assigns VM Contributor + Reader at subscription scope |
| 4 | `Import-Modules.ps1` | Imports Az.Accounts, Az.Compute, Az.ResourceGraph |
| 5 | `New-Runbook.ps1` | Uploads shutdown runbook (PS 7.2), creates daily schedule (default 19:00 CET) |
| 6 | `New-StartupRunbook.ps1` | Uploads startup runbook (PS 7.2), creates daily schedule (default 07:00 CET) |
| 7 | `Set-AlertRule.ps1` | Creates Azure Monitor alert rules — emails on any failed job |

### Enable live mode after validating WhatIf output

```powershell
# Enable live shutdowns
.\New-Runbook.ps1 -DisableWhatIf

# Enable live startups
.\New-StartupRunbook.ps1 -DisableWhatIf
```

---

## Tag Reference

All tag key matching is **case-insensitive**. Tag values are ignored — only the key presence matters.

| Tag | Runbook | Effect |
|---|---|---|
| `shutdown` | `Invoke-AutoShutdown` | VM is stopped (deallocated) on the daily schedule |
| `donotshutdown` | `Invoke-AutoShutdown` | VM is excluded from shutdown — takes priority over `shutdown` |
| `startup` | `Invoke-AutoStartup` | VM is started on the daily schedule |
| `donotstart` | `Invoke-AutoStartup` | VM is excluded from startup — takes priority over `startup` |

A VM can have both `shutdown` and `startup` tags to be automatically stopped in the evening and started in the morning.

---

## Runbook Logic

### Auto-shutdown (`Invoke-AutoShutdown.ps1`)

Evaluated in priority order for every VM:

| Priority | Condition | Action |
|---|---|---|
| 1 (highest) | Has `donotshutdown` tag | **SKIP** — always wins |
| 2 | No `shutdown` tag | **SKIP** |
| 3 | Already deallocated | **SKIP** |
| 4 | Has `shutdown` tag | **STOP** (deallocate) |

### Auto-startup (`Invoke-AutoStartup.ps1`)

Evaluated in priority order for every VM:

| Priority | Condition | Action |
|---|---|---|
| 1 (highest) | Has `donotstart` tag | **SKIP** — always wins |
| 2 | No `startup` tag | **SKIP** |
| 3 | Already running | **SKIP** |
| 4 | Has `startup` tag | **START** |

### Resource types (both runbooks)

| Resource Type | Shutdown method | Startup method |
|---|---|---|
| `Microsoft.Compute/virtualMachines` | `Stop-AzVM` | `Start-AzVM` |
| `Microsoft.AzureStackHCI/virtualMachineInstances` | REST `POST /stop` | REST `POST /start` |
| `Microsoft.AzureStackHCI/servers` | **Never touched** | **Never touched** |

### Parameters (both runbooks)

| Parameter | Default | Description |
|---|---|---|
| `SubscriptionIds` | `""` (all accessible) | Comma-separated subscription IDs to process |
| `WhatIf` | `$false` | Set `$true` for dry run — logs actions without touching VMs |

---

## Required Permissions

All permissions are assigned by `Set-RBACRoles.ps1` at subscription scope.

| Role | Purpose |
|---|---|
| Virtual Machine Contributor | Allows `Get-AzVM`, `Stop-AzVM`, and `Start-AzVM` |
| Reader | Allows `Search-AzGraph` for HCI VM queries |
| Azure Connected Machine Resource Manager | Optional — HCI clusters only |

> **Least privilege:** No Owner or broad Contributor roles are assigned. The Managed Identity can only start/stop VMs and read resources — nothing else.

---

## Common Operations

### Shutdown runbook

#### Change the shutdown time

```powershell
.\New-Runbook.ps1 -ScheduleTime '17:00'   # time in CET
```

#### Enable live shutdowns after WhatIf testing

```powershell
.\New-Runbook.ps1 -DisableWhatIf
```

#### Enroll a VM in auto-shutdown (interactive)

```powershell
.\Add-ShutdownTag.ps1
```

#### Offboard a VM from auto-shutdown (interactive)

```powershell
.\Remove-ShutdownTag.ps1
```

#### Tag a VM for auto-shutdown (manual)

```powershell
$vm = Get-AzVM -Name 'your-vm' -ResourceGroupName 'your-rg'
Update-AzTag -ResourceId $vm.Id -Tag @{ shutdown = 'true' } -Operation Merge
```

#### Exclude a VM from auto-shutdown (manual)

```powershell
$vm = Get-AzVM -Name 'your-vm' -ResourceGroupName 'your-rg'
Update-AzTag -ResourceId $vm.Id -Tag @{ donotshutdown = 'true' } -Operation Merge
```

#### Manually trigger a shutdown run in the Portal

**Automation Account → Runbooks → Invoke-AutoShutdown → Start → set `WhatIf = false` → OK**

---

### Startup runbook

#### Change the startup time

```powershell
.\New-StartupRunbook.ps1 -ScheduleTime '06:00'   # time in CET
```

#### Enable live startups after WhatIf testing

```powershell
.\New-StartupRunbook.ps1 -DisableWhatIf
```

#### Enroll a VM in auto-startup (interactive)

```powershell
.\Add-StartupTag.ps1
```

#### Offboard a VM from auto-startup (interactive)

```powershell
.\Remove-StartupTag.ps1
```

#### Tag a VM for auto-startup (manual)

```powershell
$vm = Get-AzVM -Name 'your-vm' -ResourceGroupName 'your-rg'
Update-AzTag -ResourceId $vm.Id -Tag @{ startup = 'true' } -Operation Merge
```

#### Exclude a VM from auto-startup (manual)

```powershell
$vm = Get-AzVM -Name 'your-vm' -ResourceGroupName 'your-rg'
Update-AzTag -ResourceId $vm.Id -Tag @{ donotstart = 'true' } -Operation Merge
```

#### Manually trigger a startup run in the Portal

**Automation Account → Runbooks → Invoke-AutoStartup → Start → set `WhatIf = false` → OK**

Monitor progress in **Jobs → Output**.

---

## Monitoring & Troubleshooting

Every run creates an Azure Automation Job. Navigate to:
**Automation Account → Jobs → select the job → Output tab**

Jobs are retained for 30 days.

- **Job status `Completed`** — all VMs processed successfully
- **Job status `Failed`** — at least one error occurred; check Output for `[ERROR]` lines

### Common errors

<details>
<summary><code>Search-AzGraph not recognized</code></summary>

`Az.ResourceGraph` module not imported. Go to **Automation Account → Modules → Browse Gallery → search `Az.ResourceGraph` → Import**. Wait for status `Succeeded`, then re-run.
</details>

<details>
<summary><code>403 Forbidden on Stop-AzVM / Start-AzVM</code></summary>

Managed Identity is missing the Virtual Machine Contributor role on that subscription. Re-run `Set-RBACRoles.ps1` for that subscription.
</details>

<details>
<summary><code>Authentication failed / InvalidAuthenticationToken</code></summary>

```powershell
Connect-AzAccount -DeviceCode -TenantId <your-tenant-id>
```
Then retry the setup script.
</details>

<details>
<summary><code>The property Count cannot be found</code></summary>

You have exactly one subscription or one Resource Group. Download the latest `_Helpers.ps1` and `New-AutoShutdownInfra.ps1` which fix this.
</details>

<details>
<summary><code>Script is not digitally signed</code></summary>

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
Get-ChildItem *.ps1 | Unblock-File
```
</details>

---

*PowerCloud Team · VM Auto-shutdown & Auto-startup Technical Reference · v1.4.1 · Internal use only*
