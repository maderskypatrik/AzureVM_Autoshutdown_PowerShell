# VM Autoshutdown

> Automated daily shutdown for Azure VMs using Azure Automation — no stored credentials, tag-based filtering, and least-privilege access.

**PowerCloud Team · v1.0 · Internal use only**

---

## Overview

The solution runs entirely inside Azure Automation. A System-assigned Managed Identity authenticates the runbook — no stored credentials. The runbook is triggered daily by a schedule and processes all accessible subscriptions in a single job.

| Component | Type | Purpose |
|---|---|---|
| `aa-autoshutdown` | Azure Automation Account | Hosts the runbook, schedule, and modules |
| System-assigned MI | Managed Identity | Authenticates runbook to Azure — no passwords |
| `Invoke-AutoShutdown.ps1` | PowerShell 7.2 Runbook | Core shutdown logic with tag filtering |
| `sched-autoshutdown-daily` | Automation Schedule | Daily trigger at configured UTC time |
| `Az.Accounts` / `Az.Compute` / `Az.ResourceGraph` | PS Modules | Required Az cmdlets imported into the account |

---

## Repository Structure

```
setup/
  _Helpers.ps1                  # Shared functions — auth, logging, state file, pickers
  Install-AutoShutdown.ps1      # Master orchestrator — runs all 5 steps
  New-AutoShutdownInfra.ps1     # Step 1 — creates Automation Account in existing RG
  Set-ManagedIdentity.ps1       # Step 2 — enables Managed Identity
  Set-RBACRoles.ps1             # Step 3 — assigns RBAC roles
  Import-Modules.ps1            # Step 4 — imports Az modules into Automation Account
  New-Runbook.ps1               # Step 5 — uploads runbook and creates schedule

runbook/
  Invoke-AutoShutdown.ps1       # The runbook itself — deployed to Azure Automation
```

---

## Setup

The `setup/` folder contains scripts that configure Azure — they run **once from your local machine**. The `runbook/` folder contains `Invoke-AutoShutdown.ps1` — this gets uploaded to Azure Automation by step 5 and then runs in the cloud on the daily schedule. You never run `Invoke-AutoShutdown.ps1` directly.

Setup scripts pass state to each other via `.autoshutdown-state.json`.

### Run all steps at once

```powershell
.\Install-AutoShutdown.ps1
```

### Resume from a specific step

```powershell
.\Install-AutoShutdown.ps1 -StartFromStep 3
```

### Steps

| # | Script | Purpose |
|---|---|---|
| 1 | `New-AutoShutdownInfra.ps1` | Picks existing RG from menu, creates Automation Account |
| 2 | `Set-ManagedIdentity.ps1` | Enables System-assigned Managed Identity, saves Object ID |
| 3 | `Set-RBACRoles.ps1` | Assigns VM Contributor + Reader at subscription scope |
| 4 | `Import-Modules.ps1` | Imports Az.Accounts, Az.Compute, Az.ResourceGraph |
| 5 | `New-Runbook.ps1` | Uploads runbook to Azure Automation, publishes it (PS 7.2), creates daily schedule |

---

## Runbook Logic

### Tag filtering (case-insensitive key, value ignored)

Evaluated in priority order for every VM:

| Priority | Condition | Action |
|---|---|---|
| 1 (highest) | Has `donotshutdown` tag | **SKIP** — always wins |
| 2 | Has no shutdown tag | **SKIP** |
| 3 | Already deallocated | **SKIP** |
| 4 | Has `shutdown` tag | **STOP** (deallocate) |

### Resource types

| Resource Type | Method |
|---|---|
| `Microsoft.Compute/virtualMachines` | Stopped via `Stop-AzVM` |
| `Microsoft.AzureStackHCI/virtualMachineInstances` | Stopped via REST `POST /stop` |
| `Microsoft.AzureStackHCI/servers` | **Never touched** |

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `SubscriptionIds` | `""` (all accessible) | Comma-separated subscription IDs to process |
| `WhatIf` | `$false` | Set `$true` for dry run — logs actions without stopping VMs |

---

## Required Permissions

All permissions are assigned by `Set-RBACRoles.ps1` at subscription scope.

| Role | Purpose |
|---|---|
| Virtual Machine Contributor | Allows `Get-AzVM` and `Stop-AzVM` |
| Reader | Allows `Search-AzGraph` for HCI VM queries |
| Azure Connected Machine Resource Manager | Optional — HCI clusters only |

> **Least privilege:** No Owner or broad Contributor roles are assigned. The Managed Identity can only stop VMs and read resources — nothing else.

---

## Common Operations

### Change the shutdown time

```powershell
.\New-Runbook.ps1 -ScheduleTime '17:00'   # time in UTC
```

### Enable live shutdowns after WhatIf testing

```powershell
.\New-Runbook.ps1 -DisableWhatIf
```

### Tag a VM for autoshutdown

```powershell
$vm = Get-AzVM -Name 'your-vm' -ResourceGroupName 'your-rg'
Update-AzTag -ResourceId $vm.Id -Tag @{ shutdown = 'true' } -Operation Merge
```

### Exclude a VM from autoshutdown

```powershell
$vm = Get-AzVM -Name 'your-vm' -ResourceGroupName 'your-rg'
Update-AzTag -ResourceId $vm.Id -Tag @{ donotshutdown = 'true' } -Operation Merge
```

### Manually trigger a run in the Portal

**Automation Account → Runbooks → Invoke-AutoShutdown → Start → set `WhatIf = false` → OK**

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
<summary><code>403 Forbidden on Stop-AzVM</code></summary>

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

*PowerCloud Team · VM Autoshutdown Technical Reference · v1.0 · Internal use only*
