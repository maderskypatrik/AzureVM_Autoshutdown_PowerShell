# VM Auto-shutdown & Auto-startup — Technical Documentation

**PowerCloud Team · v1.1 · Internal use only**
**Last updated: 2026-04-14**

---

## 1. Purpose

This document describes the design, components, deployment, and maintenance of the Azure VM Auto-shutdown & Auto-startup solution. It is intended for engineers and administrators responsible for deploying, operating, or modifying the solution.

---

## 2. Architecture Overview

The solution is implemented entirely within **Azure Automation**. There are no custom APIs, no third-party tools, and no stored credentials. Authentication relies exclusively on a System-assigned Managed Identity attached to the Automation Account.

```
┌─────────────────────────────────────────────────────────┐
│  Azure Automation Account  (aa-autoshutdown)            │
│                                                         │
│  ┌──────────────────────┐  ┌──────────────────────────┐ │
│  │ Invoke-AutoShutdown  │  │  Invoke-AutoStartup      │ │
│  │ PowerShell 7.2       │  │  PowerShell 7.2          │ │
│  └──────────┬───────────┘  └────────────┬─────────────┘ │
│             │                            │               │
│  ┌──────────▼───────────┐  ┌────────────▼─────────────┐ │
│  │ sched-autoshutdown   │  │  sched-autostartup-daily  │ │
│  │ Daily at 19:00 CET   │  │  Daily at 07:00 CET       │ │
│  └──────────────────────┘  └──────────────────────────┘ │
│                                                         │
│  System-assigned Managed Identity                       │
└──────────────────────┬──────────────────────────────────┘
                       │  Virtual Machine Contributor
                       ▼
         ┌─────────────────────────┐
         │  Azure Subscriptions    │
         │  (one or multiple)      │
         │                         │
         │  VMs tagged: shutdown   │  ──► Stop-AzVM / REST /stop
         │  VMs tagged: startup    │  ──► Start-AzVM / REST /start
         └─────────────────────────┘
```

### Supported resource types

| Resource type | Shutdown | Startup |
|---|---|---|
| `Microsoft.Compute/virtualMachines` | `Stop-AzVM` (deallocate) | `Start-AzVM` |
| `Microsoft.AzureStackHCI/virtualMachineInstances` | REST `POST /stop` | REST `POST /start` |
| `Microsoft.AzureStackHCI/servers` | Never touched | Never touched |

---

## 3. Components

| Component | Type | Description |
|---|---|---|
| `aa-autoshutdown` | Azure Automation Account | Hosts all runbooks, schedules, and imported modules |
| System-assigned MI | Managed Identity | Authenticates runbooks to Azure ARM — no passwords or secrets |
| `Invoke-AutoShutdown.ps1` | PowerShell 7.2 Runbook | Deallocates VMs tagged `shutdown` |
| `Invoke-AutoStartup.ps1` | PowerShell 7.2 Runbook | Starts VMs tagged `startup` |
| `sched-autoshutdown-daily` | Automation Schedule | Daily trigger — default 19:00 CET (DST-aware) |
| `sched-autostartup-daily` | Automation Schedule | Daily trigger — default 07:00 CET (DST-aware) |
| `Az.Accounts` | PS Module (runtime 7.2) | Azure authentication |
| `Az.Compute` | PS Module (runtime 7.2) | VM management cmdlets |
| `Az.ResourceGraph` v1.2.1 | PS Module (runtime 7.2) | Required for Azure Local VM queries |

---

## 4. Repository Structure

```
setup/
  _Helpers.ps1                  # Shared functions: auth, logging, state, pickers
  Install-AutoShutdown.ps1      # Master orchestrator — runs all 6 setup steps
  New-AutoShutdownInfra.ps1     # Step 1 — picks RG, creates Automation Account
  Set-ManagedIdentity.ps1       # Step 2 — enables System-assigned Managed Identity
  Set-RBACRoles.ps1             # Step 3 — assigns RBAC roles at subscription scope
  Import-Modules.ps1            # Step 4 — imports Az modules into Automation Account
  New-Runbook.ps1               # Step 5 — uploads shutdown runbook, creates schedule
  New-StartupRunbook.ps1        # Step 6 — uploads startup runbook, creates schedule
  Add-ShutdownTag.ps1           # Utility — interactively tags VMs for auto-shutdown
  Remove-ShutdownTag.ps1        # Utility — interactively offboards VMs from shutdown
  Add-StartupTag.ps1            # Utility — interactively tags VMs for auto-startup
  Remove-StartupTag.ps1         # Utility — interactively offboards VMs from startup

runbook/
  Invoke-AutoShutdown.ps1       # Shutdown runbook — deployed to Azure Automation
  Invoke-AutoStartup.ps1        # Startup runbook  — deployed to Azure Automation

docs/
  Technical-Documentation.md   # This document
  User-Guide.md                 # Guide for subscription owners
```

State is persisted between setup steps via `setup/.autoshutdown-state.json`.

---

## 5. Prerequisites

### Azure requirements

| Requirement | Details |
|---|---|
| Azure subscription | At least one, with existing Resource Group |
| Permissions (installer) | Contributor + User Access Administrator on the subscription |
| Automation Account | Created by `New-AutoShutdownInfra.ps1` in an existing RG |

### Local machine requirements

| Requirement | Details |
|---|---|
| PowerShell | 7.2 or later recommended; 5.1 minimum |
| Az.Accounts | `Install-Module Az.Accounts -Scope CurrentUser` |
| Az.Automation | `Install-Module Az.Automation -Scope CurrentUser` |
| Az.Compute | `Install-Module Az.Compute -Scope CurrentUser` |
| Execution policy | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` |

---

## 6. Deployment

### 6.1 Full installation

Run from the `setup/` folder:

```powershell
.\Install-AutoShutdown.ps1
```

The orchestrator runs 6 steps in sequence. Each step saves state to `.autoshutdown-state.json` so a failed run can be resumed.

### 6.2 Setup steps

| Step | Script | What it does |
|---|---|---|
| 1 | `New-AutoShutdownInfra.ps1` | Interactive picker for subscription and RG; creates the Automation Account |
| 2 | `Set-ManagedIdentity.ps1` | Enables System-assigned Managed Identity; saves Object ID to state |
| 3 | `Set-RBACRoles.ps1` | Assigns **Virtual Machine Contributor** and **Reader** to the MI at subscription scope |
| 4 | `Import-Modules.ps1` | Imports `Az.Accounts`, `Az.Compute`, `Az.ResourceGraph` v1.2.1 into the account (takes ~10 min) |
| 5 | `New-Runbook.ps1` | Uploads `Invoke-AutoShutdown.ps1`, publishes with PS 7.2 runtime, creates daily schedule |
| 6 | `New-StartupRunbook.ps1` | Uploads `Invoke-AutoStartup.ps1`, publishes with PS 7.2 runtime, creates daily schedule |

### 6.3 Custom schedule times

```powershell
.\Install-AutoShutdown.ps1 -ScheduleTime '18:00' -StartupScheduleTime '06:30'
```

Times are expressed in **CET (DST-aware)**. The schedule timezone is set to `Central European Standard Time` — Azure automatically adjusts between CET (UTC+1) and CEST (UTC+2) across DST transitions.

### 6.4 Resume from a specific step

```powershell
.\Install-AutoShutdown.ps1 -StartFromStep 3
```

### 6.5 WhatIf mode

Both runbooks are deployed with `WhatIf = $true` by default. In this mode all actions are logged but no VMs are started or stopped. To enable live operation:

```powershell
.\New-Runbook.ps1        -DisableWhatIf   # enable live shutdowns
.\New-StartupRunbook.ps1 -DisableWhatIf   # enable live startups
```

---

## 7. Tag Reference

Tag key matching is **case-insensitive**. Tag values are ignored — only key presence is evaluated.

| Tag key | Runbook | Effect |
|---|---|---|
| `shutdown` | `Invoke-AutoShutdown` | VM is deallocated on the daily shutdown schedule |
| `donotshutdown` | `Invoke-AutoShutdown` | VM is excluded from shutdown (overrides `shutdown`) |
| `startup` | `Invoke-AutoStartup` | VM is started on the daily startup schedule |
| `donotstart` | `Invoke-AutoStartup` | VM is excluded from startup (overrides `startup`) |

A VM can carry both `shutdown` and `startup` tags to participate in both schedules.

---

## 8. Runbook Logic

### 8.1 Invoke-AutoShutdown

Evaluated per VM in priority order:

| Priority | Condition | Result |
|---|---|---|
| 1 | Has `donotshutdown` tag | Skip |
| 2 | No `shutdown` tag | Skip |
| 3 | Power state = deallocated | Skip |
| 4 | Has `shutdown` tag | `Stop-AzVM` / REST `/stop` |

### 8.2 Invoke-AutoStartup

Evaluated per VM in priority order:

| Priority | Condition | Result |
|---|---|---|
| 1 | Has `donotstart` tag | Skip |
| 2 | No `startup` tag | Skip |
| 3 | Power state = running | Skip |
| 4 | Has `startup` tag | `Start-AzVM` / REST `/start` |

### 8.3 Multi-subscription support

Both runbooks accept an optional `SubscriptionIds` parameter (comma-separated). If omitted, all subscriptions accessible to the Managed Identity are processed in a single job.

### 8.4 Azure Local VM support

Azure Local VMs (`microsoft.azurestackhci/virtualmachineinstances`) are queried via `Az.ResourceGraph`. If the module is unavailable the HCI section is skipped with a `WARN` log — classic Azure VMs are unaffected. Azure Local *Servers* (`microsoft.azurestackhci/servers`) are never touched.

---

## 9. RBAC and Security

### Roles assigned by Set-RBACRoles.ps1

| Role | Scope | Purpose |
|---|---|---|
| Virtual Machine Contributor | Subscription | `Get-AzVM`, `Stop-AzVM`, `Start-AzVM` |
| Reader | Subscription | `Search-AzGraph` for HCI VM queries |
| Azure Connected Machine Resource Manager | Subscription | Optional — required for HCI clusters only |

### Security notes

- No passwords, secrets, or certificates are stored anywhere.
- The Managed Identity has no Owner or broad Contributor rights.
- The Automation Account itself requires no public endpoint exposure.
- `.autoshutdown-state.json` contains only resource names and IDs — no credentials.

---

## 10. Monitoring

Every runbook execution creates an **Azure Automation Job**.

**Navigation:** Automation Account → Jobs → select job → Output tab

Jobs are retained for **30 days**.

### Job status meanings

| Status | Meaning |
|---|---|
| `Completed` | All VMs processed; check Output for action summary |
| `Failed` | At least one unhandled error; check Output for `[ERROR]` lines |
| `Running` | Job in progress |
| `Queued` | Waiting for a worker |

### Log format

```
[2026-04-14 19:00:05][INFO] Switching to subscription: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
[2026-04-14 19:00:08][INFO] Evaluating classic VM: my-vm-01 (RG: rg-prod)
[2026-04-14 19:00:08][INFO]   ACTION — Stopping (deallocating) classic VM: my-vm-01 ...
[2026-04-14 19:00:45][INFO]   SUCCESS — VM my-vm-01 deallocated.
```

### Run summary (end of each job)

```
Subscriptions processed  : 2
VMs evaluated            : 15
VMs shut down            : 4
Skipped (donotshutdown)  : 1
Skipped (no tag)         : 9
Skipped (already off)    : 1
Errors                   : 0
```

---

## 11. Utility Scripts

### Add-ShutdownTag.ps1 / Add-StartupTag.ps1

Interactive VM picker. Lists all VMs in the subscription with their current tag status and lets the operator select which to enroll.

```powershell
.\Add-ShutdownTag.ps1 [-ResourceGroupName <rg>] [-SubscriptionId <id>]
.\Add-StartupTag.ps1  [-ResourceGroupName <rg>] [-SubscriptionId <id>]
```

### Remove-ShutdownTag.ps1 / Remove-StartupTag.ps1

Interactive offboarding. Lists enrolled VMs and offers two options:

- **A** — Add `donotshutdown`/`donotstart` tag (temporary exclusion, easily reversed)
- **B** — Remove `shutdown`/`startup` tag entirely (permanent removal)

```powershell
.\Remove-ShutdownTag.ps1 [-ResourceGroupName <rg>] [-SubscriptionId <id>]
.\Remove-StartupTag.ps1  [-ResourceGroupName <rg>] [-SubscriptionId <id>]
```

### Get-JobHistory.ps1

Lists recent Automation job results for quick status checks.

---

## 12. Troubleshooting

### Az.ResourceGraph not recognized

Module not imported into the Automation Account runtime.
**Fix:** Automation Account → Modules → Browse Gallery → search `Az.ResourceGraph` → Import (runtime 7.2). Wait for `Succeeded`, then retry.

### 403 Forbidden on Stop-AzVM / Start-AzVM

Managed Identity is missing the Virtual Machine Contributor role on that subscription.
**Fix:** Re-run `Set-RBACRoles.ps1` targeting that subscription.

### Authentication failed / InvalidAuthenticationToken

Interactive authentication session expired.
**Fix:**
```powershell
Connect-AzAccount -DeviceCode -TenantId <your-tenant-id>
```

### Schedule not firing at expected time

Verify that the schedule timezone in the Portal shows `Central European Standard Time` and that the time displayed is the local CET/CEST time you intended. If the schedule was created before the CET fix was applied, delete `sched-autoshutdown-daily` / `sched-autostartup-daily` in the Portal and re-run `New-Runbook.ps1` / `New-StartupRunbook.ps1`.

### Script is not digitally signed

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
Get-ChildItem *.ps1 | Unblock-File
```

### The property Count cannot be found

You have exactly one subscription or one Resource Group. Ensure you are running the latest version of `_Helpers.ps1` and `New-AutoShutdownInfra.ps1`.

---

## 13. Maintenance

### Update a runbook after code changes

```powershell
.\New-Runbook.ps1        # re-uploads and republishes Invoke-AutoShutdown
.\New-StartupRunbook.ps1 # re-uploads and republishes Invoke-AutoStartup
```

### Change schedule times

```powershell
.\New-Runbook.ps1        -ScheduleTime '18:00'   # shutdown at 18:00 CET
.\New-StartupRunbook.ps1 -ScheduleTime '06:30'   # startup at 06:30 CET
```

> Note: Changing the schedule time requires deleting and recreating the schedule link. The scripts handle this automatically.

### Add a new subscription

Re-run `Set-RBACRoles.ps1` with the new subscription ID to grant the Managed Identity access. The runbooks will pick it up automatically on the next run (when `SubscriptionIds` is left empty).

### Disable the solution temporarily

In the Portal: Automation Account → Schedules → select schedule → **Disable**.
Re-enable the same way. No tags or infrastructure need to change.

---

*PowerCloud Team · VM Auto-shutdown & Auto-startup · Technical Documentation · v1.1*
