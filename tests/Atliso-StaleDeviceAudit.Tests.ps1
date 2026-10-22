# Pester 5+. Graph is mocked, so these run anywhere without a tenant or the Graph module:
#   Invoke-Pester ./tests

BeforeAll {
  $script:Script = Join-Path (Join-Path $PSScriptRoot '..') 'Atliso-StaleDeviceAudit.ps1'

  # Stand-ins so the mocks have something to replace when Microsoft.Graph.Authentication isn't installed.
  if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) { function global:Connect-MgGraph { param($Scopes, $TenantId, [switch]$NoWelcome) } }
  if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) { function global:Invoke-MgGraphRequest { param($Method, $Uri, $Headers, $OutputType) } }

  $script:Iso = { param([double]$Days) (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('o') }

  # Runs the script against a fake tenant. $Graph maps a URI fragment to a response, a scriptblock, or 403.
  function script:Invoke-Audit([System.Collections.IDictionary]$Graph) {
    $env:USERPROFILE  = Join-Path $TestDrive 'home'
    $env:LOCALAPPDATA = Join-Path $TestDrive 'appdata'
    $global:AtlisoTestGraph = $Graph
    Mock Connect-MgGraph { }
    Mock Invoke-MgGraphRequest {
      foreach ($key in $global:AtlisoTestGraph.Keys) {
        if ($Uri -like "*$key*") {
          $v = $global:AtlisoTestGraph[$key]
          if ($v -eq 403) { throw 'Response status code does not indicate success: 403 (Forbidden).' }
          if ($v -is [scriptblock]) { return & $v $Uri }
          return $v
        }
      }
      return [pscustomobject]@{ value = @() }
    }
    $out = & $script:Script 6>&1 | Out-String
    $csvPath = Join-Path $env:USERPROFILE 'Desktop\Atliso-StaleDevices.csv'
    $rows = @()
    if (Test-Path $csvPath) { $rows = @(Import-Csv $csvPath) }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $out; Rows = $rows }
  }

  function script:List([object[]]$Items) { [pscustomobject]@{ value = $Items } }

  # An Intune device. $Sync and $Enrolled are days ago.
  function script:Mdm($Name, $Sync, $EntraId, $Serial = $null, $Enrolled = 400) {
    [pscustomobject]@{
      id = "mdm-$Name"; deviceName = $Name; azureADDeviceId = $EntraId; lastSyncDateTime = (& $script:Iso $Sync)
      enrolledDateTime = (& $script:Iso $Enrolled); operatingSystem = 'Windows'; osVersion = '10.0.26100.1'
      serialNumber = $Serial; userPrincipalName = "$Name@contoso.com"; managedDeviceOwnerType = 'company'; complianceState = 'compliant'
    }
  }
  # An Entra device. $Seen is days ago, or $null for a blank timestamp.
  function script:Aad($Name, $DeviceId, $Seen, $Trust = 'AzureAd', $Enabled = $true) {
    $ts = $null; if ($null -ne $Seen) { $ts = (& $script:Iso $Seen) }
    [pscustomobject]@{
      id = "obj-$DeviceId"; deviceId = $DeviceId; displayName = $Name; approximateLastSignInDateTime = $ts
      accountEnabled = $Enabled; operatingSystem = 'Windows'; operatingSystemVersion = '10.0.26100.1'; trustType = $Trust
    }
  }
}

Describe 'Atliso-StaleDeviceAudit' {

  AfterEach {
    Remove-Item (Join-Path $TestDrive 'home') -Recurse -Force -ErrorAction SilentlyContinue
  }

  It 'everything active: no CSV, exit 0' {
    $r = Invoke-Audit @{
      'managedDevices' = (List @(Mdm 'PC1' 2 'e1'))
      '/devices?'      = (List @(Aad 'PC1' 'e1' 3))
    }
    $r.Rows.Count | Should -Be 0
    $r.Output | Should -Match 'Nothing stale'
    $r.Exit | Should -Be 0
  }

  It 'no Intune check-in and no Entra sign-in for 120 days: Stale, exit 1' {
    $r = Invoke-Audit @{
      'managedDevices' = (List @(Mdm 'OLD1' 120 'e1'))
      '/devices?'      = (List @(Aad 'OLD1' 'e1' 118))
    }
    $r.Rows.Count | Should -Be 1
    $r.Rows[0].Status | Should -Be 'Stale'
    $r.Rows[0].IntuneDays | Should -Be 120
    $r.Exit | Should -Be 1
  }

  It 'stale in Intune but still signing in to Entra: Check, not Stale' {
    $r = Invoke-Audit @{
      'managedDevices' = (List @(Mdm 'BROKEN' 100 'e1'))
      '/devices?'      = (List @(Aad 'BROKEN' 'e1' 5))
    }
    $r.Rows[0].Status | Should -Be 'Check'
    $r.Rows[0].NextStep | Should -Match "Don't delete it"
  }

  It 'stale in Intune with a blank Entra timestamp: Stale' {
    $r = Invoke-Audit @{
      'managedDevices' = (List @(Mdm 'BLANK' 100 'e1'))
      '/devices?'      = (List @(Aad 'BLANK' 'e1' $null))
    }
    $r.Rows[0].Status | Should -Be 'Stale'
  }

  It 'same serial re-enrolled: the old record is a Duplicate even inside StaleDays, the new one is fine' {
    $r = Invoke-Audit @{
      'managedDevices' = (List @((Mdm 'LAP-OLD' 20 'e1' 'SN123' 300), (Mdm 'LAP-NEW' 1 'e2' 'SN123' 10)))
      '/devices?'      = (List @((Aad 'LAP-OLD' 'e1' 25), (Aad 'LAP-NEW' 'e2' 1)))
    }
    $r.Rows.Count | Should -Be 1
    $r.Rows[0].DeviceName | Should -Be 'LAP-OLD'
    $r.Rows[0].Status | Should -Be 'Duplicate'
    $r.Rows[0].Note | Should -Match "Newer record 'LAP-NEW'"
  }

  It 'placeholder serials never count as duplicates' {
    $r = Invoke-Audit @{
      'managedDevices' = (List @((Mdm 'VM1' 20 'e1' 'Default string' 300), (Mdm 'VM2' 1 'e2' 'Default string' 10)))
      '/devices?'      = (List @((Aad 'VM1' 'e1' 20), (Aad 'VM2' 'e2' 1)))
    }
    $r.Rows.Count | Should -Be 0
  }

  It 'Entra-only device quiet for 200 days: Stale (Entra only); blank timestamp is skipped' {
    $r = Invoke-Audit @{
      'managedDevices' = (List @())
      '/devices?'      = (List @((Aad 'GHOST' 'e9' 200), (Aad 'UNKNOWN' 'e8' $null)))
    }
    $r.Rows.Count | Should -Be 1
    $r.Rows[0].Status | Should -Be 'Stale (Entra only)'
    $r.Rows[0].DeviceName | Should -Be 'GHOST'
  }

  It 'BitLocker keys and Autopilot are counted and called out' {
    $r = Invoke-Audit @{
      'managedDevices'                     = (List @(Mdm 'OLD1' 120 'e1'))
      '/devices?'                          = (List @(Aad 'OLD1' 'e1' 120))
      'bitlocker/recoveryKeys'             = (List @(([pscustomobject]@{ id = 'k1'; deviceId = 'e1' }), ([pscustomobject]@{ id = 'k2'; deviceId = 'e1' })))
      'windowsAutopilotDeviceIdentities'   = (List @([pscustomobject]@{ id = 'ap1'; azureActiveDirectoryDeviceId = 'e1' }))
    }
    $r.Rows[0].BitLockerKeys | Should -Be '2'
    $r.Rows[0].Autopilot | Should -Be 'True'
    $r.Rows[0].Note | Should -Match 'save them first'
    $r.Rows[0].Note | Should -Match 'Registered in Autopilot'
  }

  It 'hybrid joined and already-disabled devices get the right notes' {
    $r = Invoke-Audit @{
      'managedDevices' = (List @(Mdm 'HYB' 150 'e1'))
      '/devices?'      = (List @(Aad 'HYB' 'e1' 150 'ServerAd' $false))
    }
    $r.Rows[0].JoinType | Should -Be 'Hybrid joined'
    $r.Rows[0].Note | Should -Match 'on-prem AD'
    $r.Rows[0].Note | Should -Match 'Already disabled'
  }

  It 'no permission to read BitLocker keys: keeps going with a blank column' {
    $r = Invoke-Audit @{
      'managedDevices'         = (List @(Mdm 'OLD1' 120 'e1'))
      '/devices?'              = (List @(Aad 'OLD1' 'e1' 120))
      'bitlocker/recoveryKeys' = 403
    }
    $r.Rows[0].Status | Should -Be 'Stale'
    $r.Rows[0].BitLockerKeys | Should -Be ''
    $r.Output | Should -Match 'Could not read BitLocker recovery keys'
  }

  It 'follows @odata.nextLink across pages' {
    $r = Invoke-Audit @{
      'page=2'         = (List @(Mdm 'P2' 200 'e2'))
      'managedDevices' = ([pscustomobject]@{ value = @(Mdm 'P1' 200 'e1'); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/x?page=2' })
      '/devices?'      = (List @((Aad 'P1' 'e1' 200), (Aad 'P2' 'e2' 200)))
    }
    ($r.Rows | Select-Object -ExpandProperty DeviceName) | Should -Contain 'P2'
  }
}
