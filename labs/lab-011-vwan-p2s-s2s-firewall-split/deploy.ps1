# labs/lab-011-vwan-p2s-s2s-firewall-split/deploy.ps1
# vWAN hub with S2S + P2S on the Default route table, Azure Firewall in a spoke
# (reached by a VNet-connection static route) and Azure Firewall in the hub.
# Question: can P2S be steered to the hub firewall while S2S keeps using the
# spoke firewall, when both branches share the Default route table?
#
# PHASES:
#   0 - Preflight (tools, auth, cost estimate, DEPLOY prompt)
#   1 - Core Fabric (resource group, P2S test client VM, P2S certificates)
#   2 - Primary Resources (main.bicep: vWAN, hub, gateways, firewalls, spokes, on-prem sim)
#   3 - Secondary (none - all in Bicep)
#   4 - Connections (wait for the S2S tunnel and BGP)
#   5 - Validation (inspect.ps1, Baseline scenario)
#   6 - Summary

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location = "eastus2",
  [string]$AdminPassword,
  [string]$Owner,
  [ValidateSet("Basic", "Standard")]
  [string]$FirewallTier = "Basic",
  [string]$VmSize = "Standard_B1s",
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path

. (Join-Path (Join-Path $RepoRoot "scripts") "labs-common.ps1")
. (Join-Path (Join-Path $LabRoot "scripts") "lab-011-helpers.ps1")

$InfraDir = Join-Path $LabRoot "infra"
$ScriptsDir = Join-Path $LabRoot "scripts"
$AdminUsername = "azureuser"
$AllowedRegions = @("eastus", "eastus2", "centralus", "westus2", "westus3", "northeurope", "westeurope")

$LogsDir = Join-Path $LabRoot "logs"
if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null }
$script:LogFile = Join-Path $LogsDir ("lab-011-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")

function Write-Log {
  param([string]$Message)
  $line = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] $Message"
  Add-Content -Path $script:LogFile -Value $line
  Write-Host $line -ForegroundColor DarkGray
}

function Invoke-BicepDeployment {
  param([string]$Name, [string]$TemplateFile, [hashtable]$Parameters, [string]$DataDir)
  # Parameters go through a file: passwords and keys never touch the command line.
  $paramDoc = @{
    '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters     = @{}
  }
  foreach ($k in $Parameters.Keys) { $paramDoc.parameters[$k] = @{ value = $Parameters[$k] } }
  $paramFile = Join-Path $DataDir "$Name.parameters.json"
  Write-LfFile -Path $paramFile -Content ($paramDoc | ConvertTo-Json -Depth 10)

  $result = $null
  $code = 1
  # Continue (not Stop): on PS5.1 any stderr line from az would otherwise throw
  # before the exit code and the hints below are reached.
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  try {
    $result = az deployment group create `
      --resource-group $script:ResourceGroup `
      --name $Name `
      --template-file $TemplateFile `
      --parameters "@$paramFile" `
      --output json `
      --only-show-errors 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldEap
    Remove-Item -Path $paramFile -Force -ErrorAction SilentlyContinue
  }
  $text = $result -join "`n"
  if ($code -ne 0) {
    Write-Host $text -ForegroundColor Red
    if ($text -match "AnotherOperationInProgress|OperationNotAllowed.*in progress") {
      Write-Host "[HINT] The hub was busy with another operation. Wait 5 minutes and re-run deploy (it is idempotent)." -ForegroundColor Yellow
    }
    if ($text -match "SkuNotAvailable|NotAvailableForSubscription|QuotaExceeded") {
      Write-Host "[HINT] SKU or quota not available in $Location for this subscription. Try -Location eastus or -VmSize Standard_B2ats_v2." -ForegroundColor Yellow
    }
    if ($text -match "AZFW_Hub|Basic" -and $text -match "not supported|NotSupported") {
      Write-Host "[HINT] Basic tier was rejected for a firewall. Re-run with -FirewallTier Standard (higher cost)." -ForegroundColor Yellow
    }
    throw "Deployment '$Name' failed. See output above."
  }
  $start = $text.IndexOf('{')
  if ($start -lt 0) { throw "Deployment '$Name' returned no JSON." }
  return ($text.Substring($start) | ConvertFrom-Json)
}

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Magenta
Write-Host "  Lab 011: vWAN P2S + S2S on Default RT, hub vs spoke firewall" -ForegroundColor Magenta
Write-Host ("=" * 60) -ForegroundColor Magenta
Write-Host ""

$deployStart = Get-Date

# =============================================================================
# PHASE 0 : Preflight
# =============================================================================
Write-Phase -Number 0 -Title "Preflight Checks"

Write-Step "Checking tools..."
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI not found. Run: .\setup.ps1 -Azure"
}
Write-SubStep "az found"
foreach ($ext in @("virtual-wan", "log-analytics")) {
  $installed = Invoke-AzJson -AzArgs @("extension", "show", "-n", $ext)
  if (-not $installed) {
    Write-SubStep "Installing az extension: $ext (local CLI only)"
    az extension add -n $ext --only-show-errors | Out-Null
  } else {
    Write-SubStep "az extension $ext present"
  }
}

if ($AllowedRegions -notcontains $Location) {
  throw "Location '$Location' is not in this lab's allowlist: $($AllowedRegions -join ', ')"
}

Write-Step "Loading configuration..."
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot

Write-Step "Authenticating..."
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
Write-SubStep "Subscription: $SubscriptionId"

if (-not $Owner) {
  $Owner = $env:USERNAME
  if (-not $Owner) { $Owner = $env:USER }
  if (-not $Owner) { $Owner = "unknown" }
}

if (-not $AdminPassword) {
  Write-Host "  This lab deploys VMs and requires an admin password." -ForegroundColor Yellow
  Write-Host "  Requirements: 12+ chars, uppercase, lowercase, number, special char." -ForegroundColor DarkGray
  $secPwd = Read-Host "  VM Admin Password" -AsSecureString
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPwd)
  $AdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  if (-not $AdminPassword) { throw "Provide -AdminPassword (temporary lab VM password)." }
}

$Tags = Get-LabTags -LabId $script:LabId -Owner $Owner
$Tags["purpose"] = "vwan-p2s-s2s-firewall-split"
$tagStr = Get-LabTagString -Tags $Tags

$DataDir = Get-LabDataDir -RepoRoot $RepoRoot

# Cost estimate (list prices, USD/hr, approximate)
$fwHr = 0.395
if ($FirewallTier -eq "Standard") { $fwHr = 1.25 }
$costItems = [ordered]@{
  "Virtual hub (Standard)"                  = 0.25
  "S2S VPN gateway (1 scale unit) + 1 conn" = 0.41
  "P2S VPN gateway (1 scale unit) + 1 user" = 0.37
  "Azure Firewall in hub ($FirewallTier)"   = $fwHr
  "Azure Firewall in spoke ($FirewallTier)" = $fwHr
  "On-prem sim VPN gateway (VpnGw1AZ)"      = 0.36
  "3 x $VmSize VMs + disks"                 = 0.04
  "Public IPs + Log Analytics"              = 0.04
}
$costTotal = 0.0
foreach ($v in $costItems.Values) { $costTotal += $v }

Write-Step "Deployment configuration:"
Write-SubStep "Location:       $Location"
Write-SubStep "Resource group: $($script:ResourceGroup)"
Write-SubStep "Firewall tier:  $FirewallTier"
Write-SubStep "Owner:          $Owner"
Write-SubStep "Log file:       $($script:LogFile)"
Write-Host ""
Write-Host "  Estimated cost while running:" -ForegroundColor Yellow
foreach ($k in $costItems.Keys) {
  Write-Host ("    {0,-42} ~`${1:N2}/hr" -f $k, $costItems[$k]) -ForegroundColor Yellow
}
Write-Host ("    {0,-42} ~`${1:N2}/hr" -f "TOTAL", $costTotal) -ForegroundColor Yellow
Write-Host "  Deploy takes ~75-100 minutes (hub, three gateways, two firewalls)." -ForegroundColor Yellow
Write-Host "  Destroy when done: .\lab.ps1 -Destroy lab-011" -ForegroundColor Yellow
Write-Host ""

if (-not $Force) {
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}
Write-Log "Phase 0 complete"

# =============================================================================
# PHASE 1 : Core Fabric (RG, P2S client VM, certificates)
# =============================================================================
Write-Phase -Number 1 -Title "Core Fabric (RG + P2S client + certificates)"
$phase1Start = Get-Date

Write-Step "Resource group: $($script:ResourceGroup)"
$rg = Invoke-AzJson -AzArgs @("group", "show", "-n", $script:ResourceGroup)
if ($rg) {
  Write-SubStep "Exists, reusing"
} else {
  az group create -n $script:ResourceGroup -l $Location --tags $tagStr -o none
  Write-SubStep "Created"
}

Write-Step "Deploying P2S test client (infra/client.bicep, ~3-5 min)"
$null = Invoke-BicepDeployment -Name "lab-011-client" -TemplateFile (Join-Path $InfraDir "client.bicep") -DataDir $DataDir -Parameters @{
  location      = $Location
  tags          = $Tags
  adminUsername = $AdminUsername
  adminPassword = $AdminPassword
  vmSize        = $VmSize
}
Write-SubStep "Client VM ready: $($script:ClientVmName)"

Write-Step "Generating P2S root + client certificates on the client VM"
$certOut = Invoke-VmScript -VmName $script:ClientVmName -TemplatePath (Join-Path $ScriptsDir "p2s-certs.sh") -WorkDir $DataDir
$rootCertData = Get-Between -Text $certOut -Begin "ROOTCERT_BEGIN" -End "ROOTCERT_END"
$rootCertData = ($rootCertData -replace "\s", "")
if (-not $rootCertData -or $rootCertData.Length -lt 500) {
  Write-Host $certOut -ForegroundColor Red
  throw "Could not read the P2S root certificate from $($script:ClientVmName)."
}
Write-SubStep ("Root cert captured ({0} base64 chars); private keys stay on the VM" -f $rootCertData.Length)
Write-SubStep ("OpenVPN client: " + (Get-KeyValue -Text $certOut -Key "OPENVPN"))

$phase1Elapsed = Get-ElapsedTime -StartTime $phase1Start
Write-Log "Phase 1 complete in $phase1Elapsed"

# =============================================================================
# PHASE 2 : Primary Resources (main.bicep)
# =============================================================================
Write-Phase -Number 2 -Title "Primary Resources (main.bicep, 60-90 min)"
$phase2Start = Get-Date

# S2S pre-shared key: generated once, kept in gitignored .data so re-runs match
$keyFile = Join-Path $DataDir "s2s-shared-key.txt"
if (Test-Path $keyFile) {
  $s2sKey = (Get-Content -Path $keyFile -Raw).Trim()
} else {
  $chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789".ToCharArray()
  $s2sKey = -join (1..32 | ForEach-Object { $chars | Get-Random })
  Write-LfFile -Path $keyFile -Content $s2sKey
}

Write-SubStep "Order inside the template (hub writes are serialized):"
Write-SubStep "  vWAN -> hub -> FW VNet connection (static route) -> S2S GW -> P2S GW -> hub firewall -> S2S connection"
Write-SubStep "  In parallel: spoke firewall, app + on-prem VNets, on-prem VPN gateway, VMs, Log Analytics"
Write-SubStep "Started $(Get-Date -Format 'HH:mm'). Safe to leave running; re-run deploy to resume if interrupted."

$main = Invoke-BicepDeployment -Name "lab-011-main" -TemplateFile (Join-Path $InfraDir "main.bicep") -DataDir $DataDir -Parameters @{
  location        = $Location
  tags            = $Tags
  adminUsername   = $AdminUsername
  adminPassword   = $AdminPassword
  s2sSharedKey    = $s2sKey
  p2sRootCertData = $rootCertData
  firewallTier    = $FirewallTier
  vmSize          = $VmSize
}
$out = $main.properties.outputs
Write-SubStep ("Hub firewall private IP:   " + $out.hubFirewallPrivateIp.value)
Write-SubStep ("Spoke firewall private IP: " + $out.spokeFirewallPrivateIp.value)

$phase2Elapsed = Get-ElapsedTime -StartTime $phase2Start
Write-Log "Phase 2 complete in $phase2Elapsed"

# =============================================================================
# PHASE 3 : Secondary (all handled by Bicep)
# =============================================================================

# =============================================================================
# PHASE 4 : Connections (S2S tunnel + BGP)
# =============================================================================
Write-Phase -Number 4 -Title "Connections (S2S tunnel + BGP)"
$phase4Start = Get-Date

Write-Step "Waiting for the S2S tunnel (up to 20 min)..."
$tunnelUp = $false
for ($i = 1; $i -le 40; $i++) {
  $c = Invoke-AzJson -AzArgs @("network", "vpn-connection", "show", "-g", $script:ResourceGroup, "-n", $script:OnpremConnName)
  $status = "unknown"
  if ($c -and $c.PSObject.Properties.Name -contains "connectionStatus") { $status = $c.connectionStatus }
  Write-SubStep "[$(Get-ElapsedTime -StartTime $phase4Start)] on-prem connection: $status"
  if ($status -eq "Connected") { $tunnelUp = $true; break }
  Start-Sleep -Seconds 30
}
if (-not $tunnelUp) {
  Write-Host "  [WARN] Tunnel not Connected yet. Validation will show what is missing; re-run inspect later." -ForegroundColor Yellow
}

Write-Step "Giving BGP and hub route propagation 2 minutes..."
Start-Sleep -Seconds 120

$phase4Elapsed = Get-ElapsedTime -StartTime $phase4Start
Write-Log "Phase 4 complete in $phase4Elapsed"

# =============================================================================
# PHASE 5 : Validation
# =============================================================================
Write-Phase -Number 5 -Title "Validation (inspect.ps1, Baseline)"
$inspectArgs = @{ NoBanner = $true }
if ($SubscriptionKey) { $inspectArgs["SubscriptionKey"] = $SubscriptionKey }
& (Join-Path $LabRoot "inspect.ps1") @inspectArgs
$inspectCode = $LASTEXITCODE

# =============================================================================
# PHASE 6 : Summary
# =============================================================================
Write-Phase -Number 6 -Title "Summary"
$totalElapsed = Get-ElapsedTime -StartTime $deployStart

$outputs = [ordered]@{
  lab              = $script:LabId
  timestamp        = (Get-Date).ToString("o")
  subscriptionId   = $SubscriptionId
  location         = $Location
  resourceGroup    = $script:ResourceGroup
  firewallTier     = $FirewallTier
  hubFirewallIp    = $out.hubFirewallPrivateIp.value
  spokeFirewallIp  = $out.spokeFirewallPrivateIp.value
  appVmIp          = $out.appVmIp.value
  onpremVmIp       = $out.onpremVmIp.value
  p2sPool          = $out.p2sPool.value
  workspaceId      = $out.workspaceCustomerId.value
  deployTime       = $totalElapsed
  timestamps       = @{ phase1 = $phase1Elapsed; phase2 = $phase2Elapsed; phase4 = $phase4Elapsed }
}
$outputsFile = Join-Path $DataDir "outputs.json"
Write-LfFile -Path $outputsFile -Content ($outputs | ConvertTo-Json -Depth 10)

Write-Host "  Resource group: $($script:ResourceGroup)" -ForegroundColor White
Write-Host "  Total time:     $totalElapsed" -ForegroundColor White
Write-Host "  Outputs:        $outputsFile" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next steps (the actual experiment):" -ForegroundColor Yellow
Write-Host "  1. Steer the app prefix to the hub firewall on the shared Default RT:" -ForegroundColor Gray
Write-Host "       .\labs\lab-011-vwan-p2s-s2s-firewall-split\scenario.ps1 -Mode HubFwForP2S" -ForegroundColor Gray
Write-Host "  2. Wait ~10 min for firewall logs, then:  .\lab.ps1 -Inspect lab-011" -ForegroundColor Gray
Write-Host "  3. Try the symmetric variant:  scenario.ps1 -Mode HubFwSymmetric, then inspect again" -ForegroundColor Gray
Write-Host "  4. Back to start:  scenario.ps1 -Mode Baseline" -ForegroundColor Gray
Write-Host ""
Write-Host "  Destroy when done:  .\lab.ps1 -Destroy lab-011   (~`$$([math]::Round($costTotal, 2))/hr while up)" -ForegroundColor Yellow
Write-Host ""

Write-Log "Deploy finished in $totalElapsed (inspect exit $inspectCode)"
exit 0
