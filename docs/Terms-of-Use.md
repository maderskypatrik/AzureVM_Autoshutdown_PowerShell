# VM Auto-shutdown & Auto-startup — Terms of Use

**PowerCloud Team · v1.1 · Internal use only**
**Last updated: 2026-04-20**

---

## 1. Overview

These Terms of Use govern the use of the VM Auto-shutdown & Auto-startup solution ("the Solution") operated by the PowerCloud Team. By enrolling a virtual machine into the Solution — whether by adding a tag directly in the Azure Portal or by requesting enrollment through the PowerCloud Team — the subscription owner ("the User") acknowledges and agrees to the terms set out below.

---

## 2. How the Solution Works

The Solution automatically stops (deallocates) and starts Azure virtual machines based on Azure resource tags applied to those machines. Any virtual machine tagged with `shutdown` will be stopped daily at the configured schedule time. Any virtual machine tagged with `startup` will be started daily at the configured schedule time.

The Solution operates fully automatically and does not perform any checks on the state of applications, services, or data running on the virtual machine at the time of shutdown.

---

## 3. User Responsibilities

By enrolling a virtual machine in the Solution, the User accepts full responsibility for the following:

### 3.1 Correct tagging

The User is responsible for ensuring that only appropriate virtual machines are enrolled by adding the `shutdown` and/or `startup` tags. The User must verify that enrolled VMs are suitable for automated shutdown at the scheduled time.

### 3.2 Application and data readiness

The User is responsible for ensuring that all applications, services, databases, and processes running on enrolled VMs are able to tolerate an automated shutdown. This includes but is not limited to:

- Ensuring that open transactions, in-progress writes, and running jobs are completed or safely interruptible before the scheduled shutdown time
- Configuring applications to start correctly and automatically when the VM is started by the Solution
- Verifying that any connected clients, dependent services, or downstream systems handle VM unavailability gracefully

### 3.3 Exclusion management

The User is responsible for temporarily excluding VMs from the schedule when required (e.g. overnight batch jobs, maintenance windows, deployments) by adding the `donotshutdown` or `donotstart` tag in advance of the scheduled run.

### 3.4 Schedule awareness

The User acknowledges the configured shutdown and startup schedule times and is responsible for planning workloads accordingly. Schedule times are communicated by the PowerCloud Team and are visible in the Azure Automation Account.

---

## 4. Disclaimer of Liability

### 4.1 No liability for data loss

**The PowerCloud Team accepts no responsibility or liability for any data loss, data corruption, service interruption, application failure, or any other damage — direct or indirect — resulting from the automated shutdown or startup of virtual machines enrolled in the Solution.**

This includes but is not limited to:

- Loss of unsaved data or in-progress transactions at the time of shutdown
- Application crashes or corruption caused by an ungraceful shutdown
- Failed startup of applications or services after an automated start
- Downstream system failures caused by VM unavailability

### 4.2 No guarantee of execution

The Solution operates on a best-effort basis. The PowerCloud Team does not guarantee that scheduled shutdowns or startups will execute at the exact configured time or at all. Factors outside the team's control — including Azure service outages, Automation Account failures, or network issues — may cause a scheduled run to be delayed, skipped, or fail.

### 4.3 No liability for incorrect tagging

The PowerCloud Team accepts no responsibility for VMs that are incorrectly enrolled or excluded due to tagging errors made by the User or any other party with tag write access to the subscription.

---

## 5. Acceptance

Acceptance of these Terms of Use occurs in any of the following ways:

- **Installation via script:** Confirming acceptance when prompted by `Install-AutoShutdown.ps1` during setup.
- **VM enrollment:** Adding the `shutdown` or `startup` tag to a virtual machine — directly in the Azure Portal or by any other means.

In all cases, acceptance is on behalf of the subscription owner.

If you do not agree with these terms, do not proceed with installation and do not enroll your virtual machines. Contact the PowerCloud Team to discuss alternative arrangements.

---

## 6. Changes to These Terms

The PowerCloud Team reserves the right to update these Terms of Use at any time. Updated terms will be published in Confluence and communicated to active users. Continued use of the Solution after an update constitutes acceptance of the revised terms.

---

## 7. Contact

For questions regarding these Terms of Use, contact the **PowerCloud Team** through the standard IT service desk.

---

*PowerCloud Team · VM Auto-shutdown & Auto-startup · Terms of Use · v1.1*
