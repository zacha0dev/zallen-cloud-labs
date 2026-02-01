# labs/lab-003-vwan-aws-vpn-bgp-apipa/scripts/validate.ps1
# Validates Azure-AWS VPN connectivity, BGP status, APIPA configuration

[CmdletBinding()]
param(
  [string]$SubscriptionKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..")
$OutputsPath = Join-Path $RepoRoot ".data\lab-003\outputs.json"
$ValidateOutputPath = Join-Path $RepoRoot ".data\lab-003\azure-validate.json"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")
. (Join-Path $RepoRoot "scripts\aws\aws-common.ps1")

function Write-TestResult([string]$Test, [bool]$Passed, [string]$Details = "") {
  if ($Passed) {
    Write-Host "[PASS] " -ForegroundColor Green -NoNewline
  } else {
    Write-Host "[FAIL] " -ForegroundColor Red -NoNewline
  }
  Write-Host $Test -NoNewline
  if ($Details) { Write-Host " - $Details" -ForegroundColor Gray } else { Write-Host "" }
  return $Passed
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

# Load outputs
if (-not (Test-Path $OutputsPath)) {
  throw "Outputs not found: $OutputsPath. Run deploy.ps1 first."
}

$outputs = Get-Content $OutputsPath -Raw | ConvertFrom-Json
$resourceGroup = $outputs.azure.resourceGroup
$vpnGwName = $outputs.azure.vpnGatewayName
$vpnSiteName = $outputs.azure.vpnSiteName
$awsProfile = $outputs.aws.profile
$awsRegion = $outputs.aws.region
$vpnConnId = $outputs.aws.vpnConnectionId

# Auth
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
az account get-access-token 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI not authenticated." }
az account set --subscription $SubscriptionId | Out-Null

Ensure-AwsAuth -Profile $awsProfile

Write-Host ""
Write-Host "Lab 003: VPN Validation" -ForegroundColor Cyan
Write-Host "========================" -ForegroundColor Cyan
Write-Host ""

$passCount = 0
$failCount = 0
$validationReport = @{
  metadata = @{
    generatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    resourceGroup = $resourceGroup
    subscriptionId = $SubscriptionId
  }
  checks = @{}
  extracts = @{}
}

# ============================================
# Azure VPN Site Checks
# ============================================
Write-Host "Azure VPN Site Checks:" -ForegroundColor Yellow

# Get VPN Site
$vpnSite = az network vpn-site show -g $resourceGroup -n $vpnSiteName -o json 2>$null | ConvertFrom-Json
$vpnSiteExists = $null -ne $vpnSite
if (Write-TestResult "VPN Site exists" $vpnSiteExists $vpnSiteName) { $passCount++ } else { $failCount++ }
$validationReport.checks["vpnSiteExists"] = $vpnSiteExists

# Check VPN Site Links (should be 4 for full redundancy)
$vpnSiteLinksCount = 0
$vpnSiteLinks = @()
if ($vpnSite -and $vpnSite.vpnSiteLinks) {
  $vpnSiteLinksCount = $vpnSite.vpnSiteLinks.Count
  $vpnSiteLinks = $vpnSite.vpnSiteLinks
}
$hasLinks = $vpnSiteLinksCount -ge 4
if (Write-TestResult "VPN Site Links count >= 4" $hasLinks "$vpnSiteLinksCount link(s)") { $passCount++ } else { $failCount++ }
$validationReport.checks["vpnSiteLinksCount"] = $vpnSiteLinksCount
$validationReport.checks["vpnSiteLinksPresent"] = $hasLinks

# Check APIPA (169.254.x.x) in BGP properties
$apipaFound = $false
$apipaAddresses = @()
foreach ($link in $vpnSiteLinks) {
  if ($link.bgpProperties -and $link.bgpProperties.bgpPeeringAddress) {
    $bgpAddr = $link.bgpProperties.bgpPeeringAddress
    if ($bgpAddr -match "^169\.254\.") {
      $apipaFound = $true
      $apipaAddresses += @{
        linkName = $link.name
        bgpPeeringAddress = $bgpAddr
        asn = $link.bgpProperties.asn
        ipAddress = $link.ipAddress
      }
    }
  }
}
if (Write-TestResult "APIPA (169.254.x.x) in BGP properties" $apipaFound ($apipaAddresses | ForEach-Object { $_.bgpPeeringAddress }) -join ", ") { $passCount++ } else { $failCount++ }
$validationReport.checks["apipaPresent169_254"] = $apipaFound
$validationReport.extracts["vpnSiteLinks"] = $apipaAddresses

# ============================================
# Azure VPN Gateway Checks
# ============================================
Write-Host ""
Write-Host "Azure VPN Gateway Checks:" -ForegroundColor Yellow

# Check VPN Gateway exists
$gw = az network vpn-gateway show -g $resourceGroup -n $vpnGwName -o json 2>$null | ConvertFrom-Json
$gwExists = $null -ne $gw
if (Write-TestResult "VPN Gateway exists" $gwExists $vpnGwName) { $passCount++ } else { $failCount++ }
$validationReport.checks["vpnGatewayExists"] = $gwExists

# Check VPN connections
$conns = az network vpn-gateway connection list -g $resourceGroup --gateway-name $vpnGwName -o json 2>$null | ConvertFrom-Json
$connCount = if ($conns) { $conns.Count } else { 0 }
$hasConnections = $connCount -ge 1
if (Write-TestResult "VPN Gateway connections" $hasConnections "$connCount connection(s)") { $passCount++ } else { $failCount++ }
$validationReport.checks["vpnConnectionsPresent"] = $hasConnections
$validationReport.checks["vpnConnectionsCount"] = $connCount

# Check enableBgp on connections
$bgpEnabledOnConn = $false
$connectionDetails = @()
if ($conns) {
  foreach ($conn in $conns) {
    $connInfo = @{
      name = $conn.name
      enableBgp = $conn.enableBgp
      provisioningState = $conn.provisioningState
      vpnLinkConnectionsCount = if ($conn.vpnLinkConnections) { $conn.vpnLinkConnections.Count } else { 0 }
    }
    $connectionDetails += $connInfo
    if ($conn.enableBgp -eq $true) {
      $bgpEnabledOnConn = $true
    }
  }
}
if (Write-TestResult "BGP enabled on VPN connection" $bgpEnabledOnConn) { $passCount++ } else { $failCount++ }
$validationReport.checks["bgpEnabledOnConnection"] = $bgpEnabledOnConn
$validationReport.extracts["vpnConnections"] = $connectionDetails

# ============================================
# Azure BGP Peer Status
# ============================================
Write-Host ""
Write-Host "Azure BGP Peer Status:" -ForegroundColor Yellow
$bgpPeers = az network vpn-gateway list-bgp-peer-status -g $resourceGroup -n $vpnGwName -o json 2>$null | ConvertFrom-Json

$bgpEstablished = 0
$bgpPeerDetails = @()
if ($bgpPeers -and $bgpPeers.value) {
  foreach ($peer in $bgpPeers.value) {
    $state = $peer.state
    $peerIp = $peer.neighbor
    $isUp = $state -eq "Connected"
    if ($isUp) { $bgpEstablished++ }
    Write-Host "  Peer $peerIp : $state" -ForegroundColor $(if ($isUp) { "Green" } else { "Yellow" })
    $bgpPeerDetails += @{
      neighbor = $peerIp
      state = $state
      asn = $peer.asn
      connectedDuration = $peer.connectedDuration
    }
  }
}
$hasBgpPeers = $bgpEstablished -ge 1
if (Write-TestResult "BGP sessions established" $hasBgpPeers "$bgpEstablished peer(s) connected") { $passCount++ } else { $failCount++ }
$validationReport.checks["bgpSessionsEstablished"] = $hasBgpPeers
$validationReport.checks["bgpPeersConnectedCount"] = $bgpEstablished
$validationReport.extracts["bgpPeers"] = $bgpPeerDetails

# ============================================
# AWS Checks (both VPN Connections)
# ============================================
Write-Host ""
Write-Host "AWS Checks:" -ForegroundColor Yellow

# Get both VPN connections for the lab
$allVpnConns = aws ec2 describe-vpn-connections --profile $awsProfile --region $awsRegion `
  --filters "Name=tag:lab,Values=lab-003" --output json 2>$null | ConvertFrom-Json

$vpnConnsAvailable = 0
$vpnConnDetails = @()
if ($allVpnConns -and $allVpnConns.VpnConnections) {
  foreach ($conn in $allVpnConns.VpnConnections) {
    $state = $conn.State
    $connId = $conn.VpnConnectionId
    $isAvailable = $state -eq "available"
    if ($isAvailable) { $vpnConnsAvailable++ }
    Write-Host "  VPN $connId : $state" -ForegroundColor $(if ($isAvailable) { "Green" } else { "Yellow" })
    $vpnConnDetails += @{
      vpnConnectionId = $connId
      state = $state
    }
  }
}
$hasVpnConns = $vpnConnsAvailable -ge 2
if (Write-TestResult "AWS VPN Connections (need 2)" $hasVpnConns "$vpnConnsAvailable connection(s) available") { $passCount++ } else { $failCount++ }
$validationReport.checks["awsVpnConnectionsAvailable"] = $vpnConnsAvailable
$validationReport.extracts["awsVpnConnections"] = $vpnConnDetails

# Check tunnel status across all VPN connections (should be 4 tunnels total)
Write-Host ""
Write-Host "AWS Tunnel Status (4 tunnels expected):" -ForegroundColor Yellow
$tunnelsUp = 0
$tunnelDetails = @()
if ($allVpnConns -and $allVpnConns.VpnConnections) {
  foreach ($conn in $allVpnConns.VpnConnections) {
    foreach ($tunnel in $conn.VgwTelemetry) {
      $status = $tunnel.Status
      $outsideIp = $tunnel.OutsideIpAddress
      $isUp = $status -eq "UP"
      if ($isUp) { $tunnelsUp++ }
      Write-Host "  $outsideIp : $status" -ForegroundColor $(if ($isUp) { "Green" } else { "Yellow" })
      $tunnelDetails += @{
        vpnConnectionId = $conn.VpnConnectionId
        outsideIpAddress = $outsideIp
        status = $status
        statusMessage = $tunnel.StatusMessage
      }
    }
  }
}
$hasTunnelsUp = $tunnelsUp -ge 2
if (Write-TestResult "AWS tunnels UP (need >= 2 of 4)" $hasTunnelsUp "$tunnelsUp tunnel(s) up") { $passCount++ } else { $failCount++ }
$validationReport.checks["awsTunnelsUp"] = $hasTunnelsUp
$validationReport.checks["awsTunnelsUpCount"] = $tunnelsUp
$validationReport.extracts["awsTunnels"] = $tunnelDetails

# ============================================
# Summary
# ============================================
Write-Host ""
Write-Host "========================" -ForegroundColor Cyan
$allPassed = $failCount -eq 0
Write-Host "Summary: $passCount passed, $failCount failed" -ForegroundColor $(if ($allPassed) { "Green" } else { "Red" })
Write-Host "========================" -ForegroundColor Cyan
Write-Host ""

$validationReport.summary = @{
  passed = $passCount
  failed = $failCount
  allPassed = $allPassed
}

# Save validation report
Ensure-Directory (Split-Path -Parent $ValidateOutputPath)
$validationReport | ConvertTo-Json -Depth 10 | Set-Content -Path $ValidateOutputPath -Encoding UTF8
Write-Host "Validation report saved to: $ValidateOutputPath" -ForegroundColor Gray
Write-Host ""

# Diagnostic bundle
Write-Host "Diagnostic Info:" -ForegroundColor Yellow
Write-Host "  Azure RG: $resourceGroup" -ForegroundColor Gray
Write-Host "  Azure VPN GW: $vpnGwName" -ForegroundColor Gray
Write-Host "  Azure VPN Site: $vpnSiteName" -ForegroundColor Gray
Write-Host "  Azure VPN IPs: $($outputs.azure.vpnGatewayIps -join ', ')" -ForegroundColor Gray
Write-Host "  AWS VPN Conn 1: $($outputs.aws.vpnConnectionId)" -ForegroundColor Gray
Write-Host "  AWS VPN Conn 2: $($outputs.aws.vpnConnection2Id)" -ForegroundColor Gray
Write-Host "  AWS Tunnel 1: $($outputs.aws.tunnel1OutsideIp) (APIPA: $($outputs.aws.tunnel1BgpIp))" -ForegroundColor Gray
Write-Host "  AWS Tunnel 2: $($outputs.aws.tunnel2OutsideIp) (APIPA: $($outputs.aws.tunnel2BgpIp))" -ForegroundColor Gray
Write-Host "  AWS Tunnel 3: $($outputs.aws.tunnel3OutsideIp) (APIPA: $($outputs.aws.tunnel3BgpIp))" -ForegroundColor Gray
Write-Host "  AWS Tunnel 4: $($outputs.aws.tunnel4OutsideIp) (APIPA: $($outputs.aws.tunnel4BgpIp))" -ForegroundColor Gray
Write-Host ""

if ($failCount -gt 0) {
  Write-Host "Troubleshooting tips:" -ForegroundColor Yellow
  if (-not $hasLinks) {
    Write-Host "  - VPN Site Links missing: Re-run deploy.ps1 to create links" -ForegroundColor Gray
  }
  if (-not $apipaFound) {
    Write-Host "  - APIPA missing: Check that AWS Terraform outputs include 169.254.x.x addresses" -ForegroundColor Gray
  }
  if (-not $hasConnections) {
    Write-Host "  - VPN Connection missing: Check deploy.ps1 Phase 4 output" -ForegroundColor Gray
  }
  if (-not $hasBgpPeers) {
    Write-Host "  - Wait 5-10 min after deploy for BGP to converge" -ForegroundColor Gray
    Write-Host "  - Check Azure portal: VPN Gateway > BGP peers" -ForegroundColor Gray
  }
  Write-Host "  - Check AWS console: VPN Connections > Tunnel details" -ForegroundColor Gray
  Write-Host "  - See docs/troubleshooting.md for common issues" -ForegroundColor Gray
  exit 1
}
