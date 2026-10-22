<#PSScriptInfo
.VERSION 1.0.0
.GUID 3289288f-42a9-48a1-873e-5fa7222496a0
.AUTHOR Atliso
.COMPANYNAME Atliso
.COPYRIGHT (c) 2026 Atliso. MIT License.
.TAGS Intune Entra Stale Devices Cleanup Inactive Graph Audit ReadOnly
.LICENSEURI https://github.com/Atliso-Dev/stale-device-audit/blob/main/LICENSE
.PROJECTURI https://atliso.com/blog/intune-stale-devices-cleanup
.REQUIREDMODULES Microsoft.Graph.Authentication
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES First release.
#>

<#
.SYNOPSIS
  Atliso Stale Device Audit. Read-only.
.DESCRIPTION
  Lists Intune devices that haven't checked in for $StaleDays days, cross-checked against the
  Entra ID activity timestamp, plus Entra-only devices that have gone quiet. Flags duplicate
  records left behind by a re-enrolment, devices with BitLocker keys stored in Entra, Autopilot
  devices and hybrid joined devices, so you know what is safe to delete before you delete it.
  Exports a CSV. Changes nothing in your tenant, so there is no WhatIf switch.
  https://atliso.com/blog/intune-stale-devices-cleanup
.PARAMETER TenantId
  Optional. A tenant ID or domain to sign in to, for MSPs running it against customer tenants.
.NOTES
  Requires Microsoft.Graph.Authentication.
  Scopes: DeviceManagementManagedDevices.Read.All, Device.Read.All
          (+ BitlockerKey.ReadBasic.All when $CheckBitLockerKeys is on)
          (+ DeviceManagementServiceConfig.Read.All when $CheckAutopilot is on)
  Exit 0 = nothing stale. Exit 1 = stale, duplicate or broken devices found.
#>
[CmdletBinding()]
param(
  [string]$TenantId
)

# ===== CONFIG =====
$OutputPath         = Join-Path $env:USERPROFILE 'Desktop\Atliso-StaleDevices.csv'
$StaleDays          = 90     # no Intune check-in (or Entra sign-in) for this many days
$CheckBitLockerKeys = $true  # count recovery keys in Entra: deleting the device deletes them
$CheckAutopilot     = $true  # flag Autopilot devices: deleting their Entra object breaks reuse
$LogPath            = Join-Path $env:LOCALAPPDATA 'Atliso\StaleDeviceAudit.log'
# ==================

$ErrorActionPreference = 'Stop'

# Entra only rewrites the activity timestamp when it's 14 days (+/- 5) out of date, so anything
# under 21 days would flag devices that are in use.
if ($StaleDays -lt 21) {
  Write-Host "StaleDays is $StaleDays. Entra's activity timestamp can lag by up to 19 days, so using 21." -ForegroundColor Yellow
  $StaleDays = 21
}

function Write-Log([string]$Message) {
  try {
    $dir = Split-Path -Path $LogPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path $LogPath -Value ("{0}  {1}" -f (Get-Date -Format s), $Message)
  } catch { }
}

# HTTP status from a Graph error. PowerShell 7 and Windows PowerShell 5.1 throw different exception shapes.
function Get-HttpStatus($ErrorRecord) {
  $ex = $ErrorRecord.Exception
  try { if ($ex.Response -and $ex.Response.StatusCode) { return [int]$ex.Response.StatusCode } } catch { }
  if ([string]$ex.Message -match '\b(403|404|429)\b') { return [int]$Matches[1] }
  return $null
}

function Invoke-Graph([string]$Uri, [hashtable]$Headers = @{}) {
  for ($try = 1; $try -le 5; $try++) {
    try {
      return Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers $Headers -OutputType PSObject
    } catch {
      $status = Get-HttpStatus $_
      if ($status -eq 429 -and $try -lt 5) {
        $wait = 10
        try { $ra = $_.Exception.Response.Headers.RetryAfter.Delta; if ($ra) { $wait = [int][math]::Ceiling($ra.TotalSeconds) } } catch { }
        Write-Log "429 on $Uri, waiting $wait s"
        Start-Sleep -Seconds $wait
        continue
      }
      throw
    }
  }
}

function Get-GraphList([string]$Uri, [hashtable]$Headers = @{}) {
  $items = New-Object System.Collections.Generic.List[object]
  while ($Uri) {
    $page = Invoke-Graph $Uri $Headers
    if (-not $page) { break }
    foreach ($v in @($page.value)) { if ($null -ne $v) { $items.Add($v) } }
    $Uri = $page.'@odata.nextLink'
  }
  return ,$items
}

# Graph returns 0001-01-01 for dates that were never set. Treat anything before 2000 as no date.
function ConvertTo-UtcDate($Value) {
  if (-not $Value) { return $null }
  if ($Value -is [datetime]) { $d = $Value.ToUniversalTime() }
  else { $d = ([datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime }
  if ($d.Year -lt 2000) { return $null }
  return $d
}

$now = (Get-Date).ToUniversalTime()
function Get-DaysAgo($Date) { if ($Date) { [int][math]::Floor(($now - $Date).TotalDays) } else { $null } }
function Format-Date($Date) { if ($Date) { $Date.ToString('yyyy-MM-dd') } else { '' } }

# Serials that firmware ships blank or as a placeholder can't identify a device.
function Test-RealSerial([string]$Serial) {
  if (-not $Serial) { return $false }
  return -not ($Serial.Trim() -match '^(0+|default string|to be filled by o\.e\.m\.|system serial number|none|n/a)$')
}

Write-Log 'Run started'
$scopes = @('DeviceManagementManagedDevices.Read.All', 'Device.Read.All')
if ($CheckBitLockerKeys) { $scopes += 'BitlockerKey.ReadBasic.All' }
if ($CheckAutopilot)     { $scopes += 'DeviceManagementServiceConfig.Read.All' }
$connect = @{ Scopes = $scopes; NoWelcome = $true }
if ($TenantId) { $connect.TenantId = $TenantId }
Connect-MgGraph @connect

# 1. Intune and Entra device records
$intune = Get-GraphList 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,deviceName,azureADDeviceId,lastSyncDateTime,enrolledDateTime,operatingSystem,osVersion,serialNumber,userPrincipalName,managedDeviceOwnerType,complianceState'
$entra  = Get-GraphList 'https://graph.microsoft.com/v1.0/devices?$select=id,deviceId,displayName,approximateLastSignInDateTime,accountEnabled,operatingSystem,operatingSystemVersion,trustType&$top=999'
Write-Log ("Read {0} Intune devices, {1} Entra devices" -f $intune.Count, $entra.Count)

$entraById = @{}
foreach ($e in $entra) { if ($e.deviceId) { $entraById[[string]$e.deviceId] = $e } }

# 2. BitLocker recovery keys per Entra device. Lists key IDs only, never the keys themselves.
$keyCount = @{}
$keysRead = $false
if ($CheckBitLockerKeys) {
  try {
    $keys = Get-GraphList 'https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys?$select=id,deviceId' @{ 'ocp-client-name' = 'Atliso Stale Device Audit'; 'ocp-client-version' = '1.0.0' }
    foreach ($k in $keys) { if ($k.deviceId) { $keyCount[[string]$k.deviceId] = 1 + [int]$keyCount[[string]$k.deviceId] } }
    $keysRead = $true
  } catch {
    Write-Log "BitLocker key read failed: $($_.Exception.Message)"
    Write-Host "Could not read BitLocker recovery keys, so the BitLockerKeys column is blank. Your account needs a role such as Intune Administrator, Helpdesk Administrator or Security Reader." -ForegroundColor Yellow
  }
}

# 3. Autopilot registrations, keyed by Entra device ID
$autopilot = @{}
if ($CheckAutopilot) {
  try {
    foreach ($a in (Get-GraphList 'https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities')) {
      if ($a.azureActiveDirectoryDeviceId) { $autopilot[[string]$a.azureActiveDirectoryDeviceId] = $true }
    }
  } catch {
    Write-Log "Autopilot read failed: $($_.Exception.Message)"
    Write-Host "Could not read Autopilot devices: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# 4. Newest Intune enrolment per serial number, to spot records left behind by a re-enrolment
$newestBySerial = @{}
foreach ($d in $intune) {
  if (-not (Test-RealSerial $d.serialNumber)) { continue }
  $s = ([string]$d.serialNumber).Trim().ToUpper()
  $enrolled = ConvertTo-UtcDate $d.enrolledDateTime
  if (-not $newestBySerial.ContainsKey($s) -or ($enrolled -and $enrolled -gt $newestBySerial[$s].Enrolled)) {
    $newestBySerial[$s] = [pscustomobject]@{ Id = $d.id; Enrolled = $enrolled; Name = $d.deviceName }
  }
}

$rows = New-Object System.Collections.Generic.List[object]

function Add-Row {
  param($Status, $Name, $User, $Os, $OsVersion, $Ownership, $IntuneSync, $EntraSeen, $Serial, $EntraDevice, [string]$EntraDeviceId, $NextStep, [string[]]$Notes = @())
  $keys = ''
  $isAutopilot = $false
  $join = ''
  if ($EntraDeviceId) {
    if ($keysRead) { $keys = [int]$keyCount[$EntraDeviceId] }
    $isAutopilot = [bool]$autopilot[$EntraDeviceId]
  }
  if ($EntraDevice) {
    $join = switch ([string]$EntraDevice.trustType) { 'AzureAd' { 'Entra joined' } 'ServerAd' { 'Hybrid joined' } 'Workplace' { 'Entra registered' } default { [string]$EntraDevice.trustType } }
    if ($EntraDevice.accountEnabled -eq $false) { $Notes += 'Already disabled in Entra.' }
    if ([string]$EntraDevice.trustType -eq 'ServerAd') { $Notes += 'Hybrid joined: disable or delete it in on-prem AD and let Entra Connect sync the change.' }
  }
  if ($keys -is [int] -and $keys -gt 0) { $Notes += "$keys BitLocker recovery key(s) in Entra. Deleting the Entra device deletes them, so save them first." }
  if ($isAutopilot) { $Notes += "Registered in Autopilot. Deregister it in Intune first, and don't delete the Entra device if the hardware will be reused." }

  $rows.Add([pscustomobject]@{
    Status          = $Status
    DeviceName      = $Name
    User            = $User
    OS              = $Os
    OSVersion       = $OsVersion
    Ownership       = $Ownership
    IntuneLastSync  = Format-Date $IntuneSync
    IntuneDays      = Get-DaysAgo $IntuneSync
    EntraLastSeen   = Format-Date $EntraSeen
    EntraDays       = Get-DaysAgo $EntraSeen
    JoinType        = $join
    Serial          = $Serial
    BitLockerKeys   = $keys
    Autopilot       = $isAutopilot
    NextStep        = $NextStep
    Note            = ($Notes -join ' ')
  })
}

$inIntune = @{}
foreach ($d in $intune) {
  $entraId = [string]$d.azureADDeviceId
  if ($entraId -eq '00000000-0000-0000-0000-000000000000') { $entraId = '' }
  if ($entraId) { $inIntune[$entraId] = $true }
  $e = $null
  if ($entraId) { $e = $entraById[$entraId] }

  $sync = ConvertTo-UtcDate $d.lastSyncDateTime
  $seen = $null
  if ($e) { $seen = ConvertTo-UtcDate $e.approximateLastSignInDateTime }
  $syncDays = Get-DaysAgo $sync
  $seenDays = Get-DaysAgo $seen

  # A newer enrolment of the same serial after this record last synced: this is the old record.
  $status = $null; $next = $null; $notes = @()
  if (Test-RealSerial $d.serialNumber) {
    $newest = $newestBySerial[([string]$d.serialNumber).Trim().ToUpper()]
    if ($newest.Id -ne $d.id -and $newest.Enrolled -and (-not $sync -or $sync -lt $newest.Enrolled)) {
      $status = 'Duplicate'
      $next = 'Delete this Intune record. The same hardware re-enrolled as a newer record.'
      $notes += "Newer record '$($newest.Name)' enrolled $(Format-Date $newest.Enrolled)."
    }
  }
  if (-not $status -and ($null -eq $syncDays -or $syncDays -ge $StaleDays)) {
    if ($null -ne $seenDays -and $seenDays -lt $StaleDays) {
      $status = 'Check'
      $next = "Don't delete it. It still signs in to Entra, so it's probably in use with a broken Intune enrolment. Sync or re-enrol it."
    } else {
      $status = 'Stale'
      $next = 'Confirm with the user. If it is gone: retire or delete it in Intune, disable it in Entra, delete it from Entra after a grace period.'
    }
  }
  if (-not $status) { continue }

  Add-Row -Status $status -Name $d.deviceName -User $d.userPrincipalName -Os $d.operatingSystem -OsVersion $d.osVersion `
    -Ownership $d.managedDeviceOwnerType -IntuneSync $sync -EntraSeen $seen -Serial $d.serialNumber `
    -EntraDevice $e -EntraDeviceId $entraId -NextStep $next -Notes $notes
}

# 5. Entra devices with no Intune record that have gone quiet. A blank timestamp proves nothing, so skip those.
foreach ($e in $entra) {
  if (-not $e.deviceId -or $inIntune[[string]$e.deviceId]) { continue }
  $seen = ConvertTo-UtcDate $e.approximateLastSignInDateTime
  $days = Get-DaysAgo $seen
  if ($null -eq $days -or $days -lt $StaleDays) { continue }
  Add-Row -Status 'Stale (Entra only)' -Name $e.displayName -Os $e.operatingSystem -OsVersion $e.operatingSystemVersion `
    -EntraSeen $seen -EntraDevice $e -EntraDeviceId ([string]$e.deviceId) `
    -NextStep 'Disable it in Entra, then delete it after a grace period.'
}

# Output
$order = @{ 'Check' = 0; 'Duplicate' = 1; 'Stale' = 2; 'Stale (Entra only)' = 3 }
$sorted = @($rows | Sort-Object @{ Expression = { $order[$_.Status] } }, @{ Expression = { if ($null -eq $_.IntuneDays) { [int]::MaxValue } else { $_.IntuneDays } }; Descending = $true })

if ($sorted.Count -gt 0) {
  $outDir = Split-Path -Path $OutputPath -Parent
  if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
  $sorted | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
  $sorted | Format-Table Status, DeviceName, User, IntuneLastSync, EntraLastSeen, BitLockerKeys, Autopilot -AutoSize | Out-Host
}

$counts = $sorted | Group-Object Status | ForEach-Object { "{0} {1}" -f $_.Count, $_.Name }
Write-Host ("{0} Intune and {1} Entra devices checked against {2} days." -f $intune.Count, $entra.Count, $StaleDays)
if ($sorted.Count -gt 0) {
  Write-Host ("Found: {0}. CSV: {1}" -f ($counts -join ', '), $OutputPath)
  if (@($sorted | Where-Object Status -eq 'Check').Count) {
    Write-Host 'Check = still signing in to Entra but not to Intune. Fix these, do not delete them.' -ForegroundColor Yellow
  }
} else {
  Write-Host "Nothing stale. Every device has checked in within $StaleDays days."
}
Write-Host 'Catch devices going quiet every night instead: https://atliso.com/pro?ref=stale-device-audit' -ForegroundColor Cyan
Write-Log ("Run finished: {0} flagged" -f $sorted.Count)

if ($sorted.Count -gt 0) { exit 1 } else { exit 0 }
