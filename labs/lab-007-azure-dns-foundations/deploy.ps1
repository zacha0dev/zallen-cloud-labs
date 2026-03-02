# labs/lab-007-azure-dns-foundations/deploy.ps1
# Azure DNS Foundations Lab
#
# This lab creates:
#   - Resource Group
#   - VNet + Subnet
#   - NSG (no public inbound)
#   - Linux VM (Standard_B1s) — no public IP
#   - Private DNS Zone (internal.lab)
#   - VNet Link with auto-registration
#   - Static A record (webserver.internal.lab)
#   - Validates zone resolution via az network private-dns record-set

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location     = "centralus",
  [string]$Owner        = "",
  [string]$AdminPassword,
  [string]$AdminUser    = "azureuser",
  [switch]$Force
)

# ============================================
# GUARDRAILS
# ============================================
$AllowedLocations = @("centralus","eastus","eastus2","westus2","westus3","northeurope","westeurope")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot   = $PSScriptRoot
$RepoRoot  = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
$LogsDir   = Join-Path $LabRoot "logs"
$InfraDir  = Join-Path $LabRoot "infra"
$OutputsPath = Join-Path $RepoRoot ".data\lab-007\outputs.json"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# Lab configuration
$ResourceGroup   = "rg-lab-007-dns-foundations"
$VnetName        = "vnet-lab-007"
$VnetCidr        = "10.70.0.0/16"
$SubnetName      = "snet-workload-007"
$SubnetCidr      = "10.70.1.0/24"
$VmName          = "vm-test-007"
$DnsZoneName     = "internal.lab"
$VnetLinkName    = "link-vnet-lab-007"
$ARecordName     = "webserver"
$DeploymentName  = "lab-007-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# ============================================
# HELPER FUNCTIONS
# ============================================

function Require-Command($name, $installHint) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $name. $installHint"
  }
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-Phase {
  param([int]$Number, [string]$Title)
  Write-Host ""
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host "PHASE $Number : $Title" -ForegroundColor Cyan
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host ""
}

function Write-Validation {
  param([string]$Check, [bool]$Passed, [string]$Details = "")
  if ($Passed) {
    Write-Host "  [PASS] $Check" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] $Check" -ForegroundColor Red
  }
  if ($Details) {
    Write-Host "         $Details" -ForegroundColor DarkGray
  }
}

function Write-Log {
  param([string]$Message, [string]$Level = "INFO")
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $logLine   = "[$timestamp] [$Level] $Message"
  Add-Content -Path $script:LogFile -Value $logLine
  switch ($Level) {
    "ERROR"   { Write-Host $Message -ForegroundColor Red }
    "WARN"    { Write-Host $Message -ForegroundColor Yellow }
    "SUCCESS" { Write-Host $Message -ForegroundColor Green }
    default   { Write-Host $Message }
  }
}

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

function Assert-LocationAllowed {
  param([string]$Location, [string[]]$AllowedLocations)
  if ($AllowedLocations -notcontains $Location) {
    Write-Host ""
    Write-Host "HARD STOP: Location '$Location' is not in the allowlist." -ForegroundColor Red
    Write-Host "Allowed locations: $($AllowedLocations -join ', ')" -ForegroundColor Yellow
    throw "Location '$Location' not allowed."
  }
}

# ============================================
# MAIN DEPLOYMENT
# ============================================

Write-Host ""
Write-Host "Lab 007: Azure DNS Foundations" -ForegroundColor Cyan
Write-Host "===============================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Purpose: Learn Azure Private DNS Zones, VNet links, auto-registration," -ForegroundColor White
Write-Host "         and static A records within a single-VNet topology." -ForegroundColor White
Write-Host ""

$deploymentStartTime = Get-Date

# ============================================
# PHASE 0: Preflight
# ============================================
Write-Phase -Number 0 -Title "Preflight Checks"
$phase0Start = Get-Date

Ensure-Directory $LogsDir
$ts              = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFile  = Join-Path $LogsDir "lab-007-$ts.log"
Write-Log "Deployment started"
Write-Log "Location: $Location"

Require-Command az "Install Azure CLI: https://aka.ms/installazurecli"
Write-Validation -Check "Azure CLI installed" -Passed $true

Assert-LocationAllowed -Location $Location -AllowedLocations $AllowedLocations
Write-Validation -Check "Location '$Location' allowed" -Passed $true

if (-not $AdminPassword) {
  throw "Provide -AdminPassword (temporary lab password for VM)."
}
Write-Validation -Check "AdminPassword provided" -Passed $true

Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Write-Validation -Check "Subscription resolved" -Passed $true -Details $SubscriptionId

Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
$subName = az account show --query name -o tsv
Write-Validation -Check "Azure authenticated" -Passed $true -Details $subName

if (-not $Owner) {
  $Owner = $env:USERNAME
  if (-not $Owner) { $Owner = $env:USER }
  if (-not $Owner) { $Owner = "unknown" }
}

Write-Log "Preflight checks passed" "SUCCESS"

# Cost warning
Write-Host ""
Write-Host "Cost estimate: ~`$0.02/hour" -ForegroundColor Yellow
Write-Host "  VM (Standard_B1s):     ~`$0.01/hr" -ForegroundColor Gray
Write-Host "  Private DNS Zone:      ~`$0.004/hr (per zone + queries)" -ForegroundColor Gray
Write-Host "  VNet, NSG, NIC:        minimal" -ForegroundColor Gray
Write-Host ""

if (-not $Force) {
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

$portalUrl = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/overview"
Write-Host ""
Write-Host "Azure Portal:  $portalUrl" -ForegroundColor Cyan
Write-Host ""

$phase0Elapsed = Get-ElapsedTime -StartTime $phase0Start
Write-Log "Phase 0 completed in $phase0Elapsed" "SUCCESS"

# ============================================
# PHASE 1: Resource Group
# ============================================
Write-Phase -Number 1 -Title "Core Fabric (Resource Group)"
$phase1Start = Get-Date

$tagsString = "project=azure-labs lab=lab-007 owner=$Owner environment=lab cost-center=learning"

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($existingRg) {
  Write-Host "  Resource group already exists, skipping..." -ForegroundColor DarkGray
} else {
  az group create --name $ResourceGroup --location $Location --tags $tagsString --output none
  Write-Log "Resource group created: $ResourceGroup"
}
Write-Validation -Check "Resource group exists" -Passed $true -Details $ResourceGroup

$phase1Elapsed = Get-ElapsedTime -StartTime $phase1Start
Write-Log "Phase 1 completed in $phase1Elapsed" "SUCCESS"

# ============================================
# PHASE 2: Deploy Bicep (VNet + VM + DNS Zone)
# ============================================
Write-Phase -Number 2 -Title "Primary Resources (Bicep deployment)"
$phase2Start = Get-Date

Write-Host "Deploying Bicep template..." -ForegroundColor Gray
Write-Host "  VNet ($VnetName), Subnet ($SubnetName)" -ForegroundColor DarkGray
Write-Host "  NSG (no public inbound)" -ForegroundColor DarkGray
Write-Host "  VM ($VmName, Standard_B1s, no public IP)" -ForegroundColor DarkGray
Write-Host "  Private DNS Zone ($DnsZoneName)" -ForegroundColor DarkGray
Write-Host "  VNet Link + auto-registration" -ForegroundColor DarkGray
Write-Host "  Static A record: $ARecordName.$DnsZoneName" -ForegroundColor DarkGray
Write-Host ""

$bicepResult = az deployment group create `
  --resource-group $ResourceGroup `
  --name $DeploymentName `
  --template-file (Join-Path $InfraDir "main.bicep") `
  --parameters `
      location=$Location `
      adminUser=$AdminUser `
      adminPassword=$AdminPassword `
      owner=$Owner `
  --output json 2>&1

if ($LASTEXITCODE -ne 0) {
  $bicepOutput = $bicepResult -join "`n"
  Write-Host $bicepOutput -ForegroundColor Red
  Write-Host ""
  # Emit targeted error guidance for common DNS lab failures
  if ($bicepOutput -match "PrivateDnsZone.*Conflict|ZoneName.*already exist") {
    Write-Host "[ERROR] DNS zone conflict: '$DnsZoneName' already exists or has a conflicting link." -ForegroundColor Red
    Write-Host "        Check:  az network private-dns zone show -g $ResourceGroup -n $DnsZoneName" -ForegroundColor Yellow
    Write-Host "        Fix:    Delete conflicting zone/link, then re-run deploy." -ForegroundColor Yellow
  } elseif ($bicepOutput -match "VirtualNetworkLink.*Conflict|LinkAlreadyExists") {
    Write-Host "[ERROR] VNet link conflict: A link for this zone/VNet combination already exists." -ForegroundColor Red
    Write-Host "        Check:  az network private-dns link vnet list -g $ResourceGroup --zone-name $DnsZoneName -o table" -ForegroundColor Yellow
  } elseif ($bicepOutput -match "AuthorizationFailed|does not have authorization|Forbidden") {
    Write-Host "[ERROR] Authorization failure: current principal lacks required RBAC permissions." -ForegroundColor Red
    Write-Host "        Required: Contributor or Network Contributor on the subscription/RG." -ForegroundColor Red
    Write-Host "        Principal: $(az account show --query user.name -o tsv 2>$null)" -ForegroundColor Yellow
  } elseif ($bicepOutput -match "InvalidTemplate|schema|BicepCompile") {
    Write-Host "[ERROR] Bicep template error. Check infra/main.bicep for syntax issues." -ForegroundColor Red
  }
  throw "Bicep deployment failed. See output above."
}

# az output may include WARNING/progress lines before the JSON block (due to 2>&1).
# Extract the JSON object directly to avoid ConvertFrom-Json choking on non-JSON lines.
$bicepText = $bicepResult -join "`n"
$jsonStart  = $bicepText.IndexOf('{')
if ($jsonStart -lt 0) {
  throw "Bicep deployment succeeded but output contained no JSON.`nRaw output:`n$bicepText"
}
$deployOutput = $bicepText.Substring($jsonStart) | ConvertFrom-Json
Write-Log "Bicep deployment succeeded: $DeploymentName" "SUCCESS"
Write-Validation -Check "Bicep deployment succeeded" -Passed $true -Details $DeploymentName

$phase2Elapsed = Get-ElapsedTime -StartTime $phase2Start
Write-Log "Phase 2 completed in $phase2Elapsed" "SUCCESS"

# ============================================
# PHASE 3: (No additional connections needed for lab-007)
# ============================================
# Skipped — single-VNet topology, all bindings handled by Bicep

# ============================================
# PHASE 4: (No cross-VNet bindings)
# ============================================
# Skipped

# ============================================
# PHASE 5: Validation
# ============================================
Write-Phase -Number 5 -Title "Validation"
$phase5Start = Get-Date

$allValid = $true

# VNet
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vnet = az network vnet show -g $ResourceGroup -n $VnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$vnetValid = ($null -ne $vnet)
Write-Validation -Check "VNet exists" -Passed $vnetValid -Details "$VnetName ($VnetCidr)"
if (-not $vnetValid) { $allValid = $false }

# VM
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vm = az vm show -g $ResourceGroup -n $VmName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$vmValid = ($null -ne $vm)
Write-Validation -Check "Test VM exists" -Passed $vmValid -Details $VmName
if (-not $vmValid) { $allValid = $false }

# VM power state
if ($vmValid) {
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $vmPower = az vm get-instance-view -g $ResourceGroup -n $VmName `
    --query "instanceView.statuses[?code=='PowerState/running']" -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $vmRunning = ($vmPower -and $vmPower.Count -gt 0)
  Write-Validation -Check "VM is running" -Passed $vmRunning -Details "PowerState/running"
  if (-not $vmRunning) { $allValid = $false }
}

# Private DNS Zone
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$zone = az network private-dns zone show -g $ResourceGroup -n $DnsZoneName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$zoneValid = ($null -ne $zone)
Write-Validation -Check "Private DNS Zone exists" -Passed $zoneValid -Details $DnsZoneName
if (-not $zoneValid) { $allValid = $false }

# VNet Link
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$link = az network private-dns link vnet show -g $ResourceGroup --zone-name $DnsZoneName -n $VnetLinkName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$linkValid = ($null -ne $link -and $link.registrationEnabled -eq $true)
Write-Validation -Check "VNet Link exists (auto-registration ON)" -Passed $linkValid -Details $VnetLinkName
if (-not $linkValid) { $allValid = $false }

# Static A record
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$aRec = az network private-dns record-set a show -g $ResourceGroup --zone-name $DnsZoneName -n $ARecordName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$aRecValid = ($null -ne $aRec -and $aRec.aRecords.Count -gt 0)
Write-Validation -Check "Static A record exists ($ARecordName.$DnsZoneName)" -Passed $aRecValid `
  -Details "IP: $($aRec.aRecords[0].ipv4Address)"
if (-not $aRecValid) { $allValid = $false }

# Tags
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$rg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$tagsValid = ($rg.tags.project -eq "azure-labs" -and $rg.tags.lab -eq "lab-007")
Write-Validation -Check "Tags applied correctly" -Passed $tagsValid -Details "project=azure-labs, lab=lab-007"
if (-not $tagsValid) { $allValid = $false }

# DNS resolution summary (offline — actual test requires VM SSH or Bastion)
Write-Host ""
Write-Host "DNS Resolution Notes:" -ForegroundColor Yellow
Write-Host "  Zone:         $DnsZoneName" -ForegroundColor Gray
Write-Host "  A record:     $ARecordName.$DnsZoneName -> $($aRec.aRecords[0].ipv4Address)" -ForegroundColor Gray
Write-Host "  Auto-reg:     VMs in linked VNet auto-register <hostname>.$DnsZoneName" -ForegroundColor Gray
Write-Host "  Test from VM: nslookup $ARecordName.$DnsZoneName" -ForegroundColor Gray
Write-Host "                nslookup $VmName.$DnsZoneName" -ForegroundColor Gray
Write-Host ""
Write-Host "  To test, connect via Azure Bastion or Serial Console:" -ForegroundColor DarkGray
Write-Host "  az serial-console connect -g $ResourceGroup --name $VmName" -ForegroundColor DarkGray

# Attempt DNS data-plane test via Run-Command and write test-results.json
Write-Host ""
Write-Host "Attempting DNS data-plane validation via Run-Command..." -ForegroundColor Yellow
Write-Host "  (Runs nslookup inside the VM to confirm actual resolution)" -ForegroundColor DarkGray

$TestResultsPath = Join-Path $RepoRoot ".data/lab-007/test-results.json"
$testResults = [pscustomobject]@{
  lab       = "lab-007"
  testedAt  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
  method    = "az vm run-command"
  tests     = @()
  summary   = "PENDING"
}

$testScript = "nslookup $ARecordName.$DnsZoneName 168.63.129.16 ; echo '###'; nslookup $VmName.$DnsZoneName 168.63.129.16 ; echo '###'; cat /etc/resolv.conf"

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$runCmdResult = az vm run-command invoke `
  -g $ResourceGroup -n $VmName `
  --command-id RunShellScript `
  --scripts $testScript `
  -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($runCmdResult -and $runCmdResult.value -and $runCmdResult.value.Count -gt 0) {
  $rawOutput = $runCmdResult.value[0].message
  $sections  = $rawOutput -split '###'

  $webserverOutput = if ($sections.Count -ge 1) { $sections[0].Trim() } else { "" }
  $vmHostOutput    = if ($sections.Count -ge 2) { $sections[1].Trim() } else { "" }
  $resolvOutput    = if ($sections.Count -ge 3) { $sections[2].Trim() } else { "" }

  $webserverResolved  = ($webserverOutput -match "10\.70\.1\.4")
  $platformResolver   = ($resolvOutput    -match "168\.63\.129\.16")

  $testResults.tests = @(
    [pscustomobject]@{
      name     = "$ARecordName.$DnsZoneName (static A record)"
      command  = "nslookup $ARecordName.$DnsZoneName 168.63.129.16"
      expected = "10.70.1.4"
      passed   = $webserverResolved
      output   = $webserverOutput
    },
    [pscustomobject]@{
      name     = "Azure platform resolver present"
      command  = "cat /etc/resolv.conf"
      expected = "nameserver 168.63.129.16"
      passed   = $platformResolver
      output   = $resolvOutput
    }
  )

  $allTestsPassed = $webserverResolved -and $platformResolver
  $testResults.summary = if ($allTestsPassed) { "PASS" } else { "PARTIAL" }

  Write-Validation -Check "DNS: $ARecordName.$DnsZoneName resolves to 10.70.1.4" -Passed $webserverResolved
  Write-Validation -Check "DNS: Platform resolver 168.63.129.16 present in resolv.conf" -Passed $platformResolver

  if (-not $allTestsPassed) { $allValid = $false }
} else {
  Write-Host "  [WARN] Run-Command did not return output (VM may still be booting)." -ForegroundColor Yellow
  Write-Host "         Re-run manually: az vm run-command invoke -g $ResourceGroup -n $VmName --command-id RunShellScript --scripts 'nslookup $ARecordName.$DnsZoneName'" -ForegroundColor DarkGray
  $testResults.summary = "SKIPPED"
  $testResults.note    = "VM not ready at deploy time. Run manually after VM boots."
}

Ensure-Directory (Split-Path -Parent $TestResultsPath)
$testResults | ConvertTo-Json -Depth 10 | Set-Content -Path $TestResultsPath -Encoding UTF8
Write-Host "  Test results written to: $TestResultsPath" -ForegroundColor DarkGray

$phase5Elapsed = Get-ElapsedTime -StartTime $phase5Start
Write-Log "Phase 5 completed in $phase5Elapsed" "SUCCESS"

# ============================================
# PHASE 6: Summary + Outputs
# ============================================
Write-Phase -Number 6 -Title "Summary + Outputs"
$phase6Start  = Get-Date
$totalElapsed = Get-ElapsedTime -StartTime $deploymentStartTime

# Get VM private IP from NIC
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vmPrivateIp = az vm list-ip-addresses -g $ResourceGroup -n $VmName `
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>$null
$ErrorActionPreference = $oldEP

Ensure-Directory (Split-Path -Parent $OutputsPath)

$outputs = [pscustomobject]@{
  metadata = [pscustomobject]@{
    lab          = "lab-007"
    deployedAt   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    deploymentTime = $totalElapsed
    status       = if ($allValid) { "PASS" } else { "PARTIAL" }
    bicepDeployment = $DeploymentName
    tags         = @{
      project        = "azure-labs"
      lab            = "lab-007"
      owner          = $Owner
      environment    = "lab"
      "cost-center"  = "learning"
    }
  }
  azure = [pscustomobject]@{
    subscriptionId   = $SubscriptionId
    subscriptionName = $subName
    location         = $Location
    resourceGroup    = $ResourceGroup
    vnet = [pscustomobject]@{
      name   = $VnetName
      cidr   = $VnetCidr
      subnet = $SubnetCidr
    }
    vm = [pscustomobject]@{
      name      = $VmName
      privateIp = $vmPrivateIp
      size      = "Standard_B1s"
      noPublicIp = $true
    }
    dns = [pscustomobject]@{
      zoneName       = $DnsZoneName
      vnetLink       = $VnetLinkName
      autoRegistration = $true
      aRecord        = [pscustomobject]@{
        name = $ARecordName
        fqdn = "$ARecordName.$DnsZoneName"
        ip   = "10.70.1.4"
      }
    }
  }
  validationTests = [pscustomobject]@{
    fromVm = @(
      "nslookup $ARecordName.$DnsZoneName",
      "nslookup $VmName.$DnsZoneName",
      "dig $ARecordName.$DnsZoneName",
      "dig $VmName.$DnsZoneName"
    )
    expected = @(
      "$ARecordName.$DnsZoneName -> 10.70.1.4",
      "$VmName.$DnsZoneName   -> $vmPrivateIp (auto-registered)"
    )
  }
}

$outputs | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputsPath -Encoding UTF8

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "DEPLOYMENT SUMMARY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "Total deployment time:  $totalElapsed" -ForegroundColor White
Write-Host "Resource Group:         $ResourceGroup" -ForegroundColor Gray
Write-Host "Location:               $Location" -ForegroundColor Gray
Write-Host ""
Write-Host "VNet:                   $VnetName ($VnetCidr)" -ForegroundColor Gray
Write-Host "VM:                     $VmName (IP: $vmPrivateIp, no public IP)" -ForegroundColor Gray
Write-Host "Private DNS Zone:       $DnsZoneName" -ForegroundColor Gray
Write-Host "VNet Link:              $VnetLinkName (auto-registration ON)" -ForegroundColor Gray
Write-Host "Static A record:        $ARecordName.$DnsZoneName -> 10.70.1.4" -ForegroundColor Gray
Write-Host ""

if ($allValid) {
  Write-Host "STATUS: PASS" -ForegroundColor Green
  Write-Host "  All resources validated successfully." -ForegroundColor Green
} else {
  Write-Host "STATUS: PARTIAL" -ForegroundColor Yellow
  Write-Host "  Some validations failed. Check above for details." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Outputs saved to: $OutputsPath" -ForegroundColor Gray
Write-Host "Log saved to:     $script:LogFile" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  - DNS test (from VM):  nslookup webserver.internal.lab" -ForegroundColor Gray
Write-Host "  - Check records:       az network private-dns record-set list -g $ResourceGroup --zone-name $DnsZoneName -o table" -ForegroundColor Gray
Write-Host "  - Cost check:          .\..\..\tools\cost-check.ps1 -Lab lab-007" -ForegroundColor Gray
Write-Host "  - Cleanup:             .\destroy.ps1" -ForegroundColor Gray
Write-Host ""

$phase6Elapsed = Get-ElapsedTime -StartTime $phase6Start
Write-Log "Phase 6 completed in $phase6Elapsed" "SUCCESS"
Write-Log "Deployment completed with status: $(if ($allValid) { 'PASS' } else { 'PARTIAL' })" "SUCCESS"
