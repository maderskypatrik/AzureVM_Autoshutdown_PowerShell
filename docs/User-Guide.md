# VM Auto-shutdown & Auto-startup — User Guide for Subscription Owners

**PowerCloud Team · v1.1 · Internal use only**
**Last updated: 2026-04-14**

---

## What is this?

The VM Auto-shutdown & Auto-startup solution automatically **stops** and **starts** your Azure virtual machines on a daily schedule. This helps reduce Azure costs by ensuring VMs are not running unnecessarily outside business hours.

| Schedule | Default time | What happens |
|---|---|---|
| Auto-shutdown | Every day at **19:00 CET** | Tagged VMs are deallocated (stopped + billing paused) |
| Auto-startup | Every day at **07:00 CET** | Tagged VMs are started automatically |

> The schedule is **opt-in**. A VM is only affected if it has been tagged. If your VM has no tags, nothing will happen to it.

---

## How does it work?

The solution uses **Azure tags** on your VMs to decide what to do. You control participation simply by adding or removing tags — no access to the Automation Account is needed.

---

## Tag Reference

| Tag to add | Effect |
|---|---|
| `shutdown` | VM will be **stopped** every evening at 19:00 CET |
| `startup` | VM will be **started** every morning at 07:00 CET |
| `donotshutdown` | VM will **never be stopped** by the automation (overrides `shutdown`) |
| `donotstart` | VM will **never be started** by the automation (overrides `startup`) |

**Tips:**
- A VM can have **both** `shutdown` and `startup` tags — it will be stopped in the evening and started in the morning automatically.
- Tag values do not matter — only the tag key is checked. You can set the value to anything (e.g. `true`).
- Tag names are **not case-sensitive** (`Shutdown`, `SHUTDOWN`, and `shutdown` all work the same).

---

## How to enroll a VM (add tags)

### Option A — Use the interactive script (recommended)

Ask your Azure administrator to run one of the following scripts on your behalf:

```
Add-ShutdownTag.ps1   →   enrolls VMs for auto-shutdown
Add-StartupTag.ps1    →   enrolls VMs for auto-startup
```

The script shows a numbered list of all VMs in the subscription. You simply pick the ones you want to enroll.

### Option B — Add tags manually in the Azure Portal

1. Go to the **Azure Portal** → **Virtual Machines**
2. Click the VM you want to enroll
3. In the left menu, click **Tags**
4. Add a new tag:
   - **Name:** `shutdown` (and/or `startup`)
   - **Value:** `true`
5. Click **Apply**

The VM will be included in the next scheduled run.

---

## How to exclude a VM temporarily

If you need a VM to stay running (e.g. for an overnight job or maintenance), add the `donotshutdown` tag:

1. Go to the **Azure Portal** → **Virtual Machines** → select your VM
2. Click **Tags** in the left menu
3. Add tag: **Name** = `donotshutdown`, **Value** = `true`
4. Click **Apply**

The VM will be skipped on all future shutdown runs until you remove this tag.

> **Note:** `donotshutdown` always wins — even if the VM also has a `shutdown` tag, it will not be stopped.

---

## How to offboard a VM (remove tags)

### Option A — Use the interactive script (recommended)

Ask your Azure administrator to run:

```
Remove-ShutdownTag.ps1   →   offboards VMs from auto-shutdown
Remove-StartupTag.ps1    →   offboards VMs from auto-startup
```

The script offers two options:
- **Temporary exclusion** — adds a `donotshutdown`/`donotstart` tag (VM is skipped but stays enrolled, easy to re-enable)
- **Permanent removal** — removes the `shutdown`/`startup` tag entirely

### Option B — Remove tags manually in the Azure Portal

1. Go to the **Azure Portal** → **Virtual Machines** → select your VM
2. Click **Tags** in the left menu
3. Click the **...** next to the `shutdown` (or `startup`) tag and select **Delete**
4. Click **Apply**

---

## What to expect

### On a normal evening (shutdown)

At 19:00 CET the automation runs and:
- Checks all VMs in your subscription
- Stops (deallocates) any VM tagged `shutdown` that is currently running
- Skips VMs tagged `donotshutdown` or VMs that are already stopped

The VM will appear as **Stopped (deallocated)** in the Portal. Billing for compute stops at this point.

### On a normal morning (startup)

At 07:00 CET the automation runs and:
- Checks all VMs in your subscription
- Starts any VM tagged `startup` that is currently stopped
- Skips VMs tagged `donotstart` or VMs that are already running

The VM will be **Running** within a few minutes.

### If the automation is in WhatIf mode

During initial rollout, both runbooks may be running in **WhatIf mode**. In this mode the automation logs what it *would* do but does not actually start or stop any VMs. Your Azure administrator will inform you when live mode is enabled.

---

## Checking the automation results

You can see what happened in the last run in the Azure Portal:

1. Go to **Azure Automation Account** (`aa-autoshutdown`)
2. Click **Jobs** in the left menu
3. Click the most recent job for `Invoke-AutoShutdown` or `Invoke-AutoStartup`
4. Click the **Output** tab

You will see a log of every VM that was evaluated, what action was taken, and a run summary at the bottom.

---

## Common questions

**My VM was stopped unexpectedly — what happened?**
Check if the VM has a `shutdown` tag. Go to the VM in the Portal → Tags. If it has `shutdown` and you don't want it stopped, either remove the tag or add a `donotshutdown` tag.

**My VM was not started at 07:00 as expected.**
Check that the VM has a `startup` tag and does not have a `donotstart` tag. Also verify in the Automation Account → Jobs that the startup job ran and completed successfully.

**Can I change the shutdown/startup time for my VM only?**
No — the schedule is global. All VMs with the `shutdown` tag are stopped at the same time. If you need a different schedule for a specific VM, contact your Azure administrator.

**I need a VM to stay on for the entire weekend.**
Add a `donotshutdown` tag before Friday evening. Remove it on Monday morning (or when the VM can return to the normal schedule).

**Will the automation start a VM that I manually stopped?**
Yes — if the VM has a `startup` tag and is stopped at 07:00 CET, the automation will start it regardless of how it was stopped. If you want to keep it stopped, add a `donotstart` tag.

**Does this affect my data or disks?**
No. The VM is **deallocated** (stopped), not deleted. All disks, data, and configuration are preserved. The VM starts back exactly as you left it.

---

## Failure notifications

The PowerCloud Team has set up automatic failure alerts. If a scheduled shutdown or startup job fails for any reason, the team will receive an email notification within 5 minutes and will investigate.

**You do not need to monitor the automation yourself.** However, if you notice that a VM was not stopped or started as expected and have not heard from the PowerCloud Team, please raise a ticket through the IT service desk.

> Alerts are failure-only — no email is sent when everything runs normally.

---

## Updating the solution (for administrators)

When a new version is released, `Install-AutoShutdown.ps1` will display a warning at startup:

```
[!] Update available: v1.2  (you have v1.1)
    To update: git pull  then re-run this script
```

**Update procedure:**

1. Open a terminal in the repository folder
2. Pull the latest changes:
   ```
   git pull
   ```
3. Re-run the installer to apply any new or changed steps:
   ```
   .\setup\Install-AutoShutdown.ps1
   ```

> If only specific steps changed, you can use `-StartFromStep` to re-run only those steps instead of the full setup.

---

## Contact

For issues, tag changes, or schedule modifications, contact the **PowerCloud Team** or raise a request through your standard IT service desk.

---

*PowerCloud Team · VM Auto-shutdown & Auto-startup · User Guide · v1.1*
