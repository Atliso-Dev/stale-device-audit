# Stale Device Audit for Intune and Entra ID

[![Tests](https://github.com/Atliso-Dev/stale-device-audit/actions/workflows/test.yml/badge.svg)](https://github.com/Atliso-Dev/stale-device-audit/actions/workflows/test.yml) [![PowerShell Gallery](https://img.shields.io/powershellgallery/v/Atliso-StaleDeviceAudit?label=PowerShell%20Gallery)](https://www.powershellgallery.com/packages/Atliso-StaleDeviceAudit)

Read-only PowerShell script that finds Intune devices that stopped checking in, matches each one to its Entra ID device, and tells you what deleting it would cost before you delete it.

Intune and Entra keep separate device records. Clean up one and the other stays. Delete the Entra record and its BitLocker recovery keys go with it, for good. Delete an Autopilot device's Entra object and that hardware can't be redeployed the normal way. This script puts all of that in one list.

## What it does

- Reads every Intune managed device and every Entra ID device through Microsoft Graph, with your own account
- Flags devices with no Intune check-in for `$StaleDays` days (90 by default), and Entra-only devices that have gone quiet
- Marks devices that stopped syncing with Intune but still sign in to Entra as `Check`: they're in use with a broken enrolment, so fix them rather than delete them
- Finds duplicate Intune records left behind when the same hardware re-enrolled, by serial number (placeholder serials like `Default string` are ignored)
- Counts the BitLocker recovery keys Entra holds for each flagged device (key IDs only, never the keys)
- Flags Autopilot-registered, hybrid joined and already-disabled devices
- Exports a CSV with a next step per device and exits 1 when anything is flagged, so it can run on a schedule
- Changes nothing in your tenant: no delete, disable or retire. There is no WhatIf switch because nothing is written
- Logs to `%LOCALAPPDATA%\Atliso\StaleDeviceAudit.log`

## Quick start

1. Install the Graph authentication module once:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

2. Install the script from the [PowerShell Gallery](https://www.powershellgallery.com/packages/Atliso-StaleDeviceAudit), or download [`Atliso-StaleDeviceAudit.ps1`](Atliso-StaleDeviceAudit.ps1) from this repo:

```powershell
Install-Script Atliso-StaleDeviceAudit -Scope CurrentUser
```

   Then check the config at the top:

```powershell
# ===== CONFIG =====
$OutputPath         = Join-Path $env:USERPROFILE 'Desktop\Atliso-StaleDevices.csv'
$StaleDays          = 90     # no Intune check-in (or Entra sign-in) for this many days
$CheckBitLockerKeys = $true  # count recovery keys in Entra: deleting the device deletes them
$CheckAutopilot     = $true  # flag Autopilot devices: deleting their Entra object breaks reuse
$LogPath            = Join-Path $env:LOCALAPPDATA 'Atliso\StaleDeviceAudit.log'
# ==================
```

3. Run it and sign in when prompted:

```powershell
.\Atliso-StaleDeviceAudit.ps1
```

MSPs can point it at a customer tenant:

```powershell
.\Atliso-StaleDeviceAudit.ps1 -TenantId contoso.onmicrosoft.com
```

## Output

One CSV row per flagged device:

`Status, DeviceName, User, OS, OSVersion, Ownership, IntuneLastSync, IntuneDays, EntraLastSeen, EntraDays, JoinType, Serial, BitLockerKeys, Autopilot, NextStep, Note`

| Status | Meaning |
|---|---|
| `Check` | No Intune check-in for `$StaleDays` days, but Entra saw it recently. In use with a broken enrolment. Don't delete it |
| `Duplicate` | The same serial number enrolled again after this record last synced. Safe to delete this Intune record |
| `Stale` | No Intune check-in and no recent Entra activity |
| `Stale (Entra only)` | In Entra, not in Intune, no activity for `$StaleDays` days |

Devices that are fine aren't listed. Exit code 0 when nothing is flagged, 1 when anything is.

The Entra activity timestamp only updates when it's more than about 14 days old (Microsoft quotes 14 days, give or take 5), so `$StaleDays` below 21 is raised to 21. Entra devices with a blank timestamp are skipped rather than guessed at.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- The `Microsoft.Graph.Authentication` module
- Delegated, read-only Graph permissions:
  - `DeviceManagementManagedDevices.Read.All` (Intune devices)
  - `Device.Read.All` (Entra devices)
  - `BitlockerKey.ReadBasic.All` (only when `$CheckBitLockerKeys` is on). Your account also needs a role that can read key metadata, such as Intune Administrator, Helpdesk Administrator, Security Reader or Global Reader. Without it the script carries on and leaves the column blank
  - `DeviceManagementServiceConfig.Read.All` (only when `$CheckAutopilot` is on)

## What it doesn't do

It doesn't delete, disable or retire anything. Disabling Entra devices needs the broad `Directory.AccessAsUser.All` permission, and deleting is a decision to make with the list in front of you. It doesn't read on-prem Active Directory, so hybrid joined devices are flagged, not cleaned up: disable those in AD and let Entra Connect sync the change.

## Tests

Pester tests mock Microsoft Graph, so they run without a tenant:

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester ./tests
```

CI runs them on Windows PowerShell 5.1 and PowerShell 7.

## Guide

What cleanup rules do and don't do, and the safe order to clean up Intune and Entra: [Intune stale devices: clean up without losing BitLocker keys](https://atliso.com/blog/intune-stale-devices-cleanup)

Want to catch devices going quiet before they're 90 days stale? [Atliso Pro](https://atliso.com/pro?ref=stale-device-audit) checks every device every night and flags anything that hasn't checked in for 14 days. The first scan is free.

## License

MIT. See [LICENSE](LICENSE).
