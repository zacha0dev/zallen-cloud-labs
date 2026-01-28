# labs/lab-003-vwan-aws-vpn-bgp-apipa/scripts/validate.ps1
# Validates Azure-AWS VPN connectivity and BGP status

[CmdletBinding()]
param(
  [ValidateSet("lab","prod")]
  [string]$SubscriptionKey = "lab"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..")
$OutputsPath = Join-Path $RepoRoot ".data\lab-003\outputs.json"

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

# Load outputs
if (-not (Test-Path $OutputsPath)) {
  throw "Outputs not found: $OutputsPath. Run deploy.ps1 first."
}

$outputs = Get-Content $OutputsPath -Raw | ConvertFrom-Json
$resourceGroup = $outputs.azure.resourceGroup
$vpnGwName = $outputs.azure.vpnGatewayName
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

# ============================================
# Azure Checks
# ============================================
Write-Host "Azure Checks:" -ForegroundColor Yellow

# Check VPN Gateway exists
$gw = az network vpn-gateway show -g $resourceGroup -n $vpnGwName -o json 2>$null | ConvertFrom-Json
if (Write-TestResult "VPN Gateway exists" ($null -ne $gw) $vpnGwName) { $passCount++ } else { $failCount++ }

# Check VPN connections
$conns = az network vpn-gateway connection list -g $resourceGroup --gateway-name $vpnGwName -o json 2>$null | ConvertFrom-Json
$connCount = if ($conns) { $conns.Count } else { 0 }
if (Write-TestResult "VPN Site connections" ($connCount -ge 1) "$connCount connection(s)") { $passCount++ } else { $failCount++ }

# Check BGP peer status
Write-Host ""
Write-Host "Azure BGP Peer Status:" -ForegroundColor Yellow
$bgpPeers = az network vpn-gateway list-bgp-peer-status -g $resourceGroup -n $vpnGwName -o json 2>$null | ConvertFrom-Json

$bgpEstablished = 0
if ($bgpPeers -and $bgpPeers.value) {
  foreach ($peer in $bgpPeers.value) {
    $state = $peer.state
    $peerIp = $peer.neighbor
    $isUp = $state -eq "Connected"
    if ($isUp) { $bgpEstablished++ }
    Write-Host "  Peer $peerIp : $state" -ForegroundColor $(if ($isUp) { "Green" } else { "Yellow" })
  }
}

if (Write-TestResult "BGP sessions established" ($bgpEstablished -ge 1) "$bgpEstablished peer(s) connected") { $passCount++ } else { $failCount++ }

# ============================================
# AWS Checks
# ============================================
Write-Host ""
Write-Host "AWS Checks:" -ForegroundColor Yellow

# Check VPN connection state
$vpnConn = aws ec2 describe-vpn-connections --profile $awsProfile --region $awsRegion --vpn-connection-ids $vpnConnId --output json 2>$null | ConvertFrom-Json
$vpnState = if ($vpnConn -and $vpnConn.VpnConnections) { $vpnConn.VpnConnections[0].State } else { "unknown" }
if (Write-TestResult "VPN Connection state" ($vpnState -eq "available") $vpnState) { $passCount++ } else { $failCount++ }

# Check tunnel status
Write-Host ""
Write-Host "AWS Tunnel Status:" -ForegroundColor Yellow
$tunnelsUp = 0
if ($vpnConn -and $vpnConn.VpnConnections) {
  foreach ($tunnel in $vpnConn.VpnConnections[0].VgwTelemetry) {
    $status = $tunnel.Status
    $outsideIp = $tunnel.OutsideIpAddress
    $isUp = $status -eq "UP"
    if ($isUp) { $tunnelsUp++ }
    Write-Host "  $outsideIp : $status" -ForegroundColor $(if ($isUp) { "Green" } else { "Yellow" })
  }
}

if (Write-TestResult "At least one tunnel UP" ($tunnelsUp -ge 1) "$tunnelsUp tunnel(s) up") { $passCount++ } else { $failCount++ }

# ============================================
# Summary
# ============================================
Write-Host ""
Write-Host "========================" -ForegroundColor Cyan
Write-Host "Summary: $passCount passed, $failCount failed" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
Write-Host "========================" -ForegroundColor Cyan
Write-Host ""

# Diagnostic bundle
Write-Host "Diagnostic Info:" -ForegroundColor Yellow
Write-Host "  Azure RG: $resourceGroup" -ForegroundColor Gray
Write-Host "  Azure VPN GW: $vpnGwName" -ForegroundColor Gray
Write-Host "  Azure VPN IPs: $($outputs.azure.vpnGatewayIps -join ', ')" -ForegroundColor Gray
Write-Host "  AWS VPN Conn: $vpnConnId" -ForegroundColor Gray
Write-Host "  AWS Tunnel 1: $($outputs.aws.tunnel1OutsideIp)" -ForegroundColor Gray
Write-Host "  AWS Tunnel 2: $($outputs.aws.tunnel2OutsideIp)" -ForegroundColor Gray
Write-Host ""

if ($failCount -gt 0) {
  Write-Host "Troubleshooting tips:" -ForegroundColor Yellow
  Write-Host "  - Wait 5-10 min after deploy for BGP to converge" -ForegroundColor Gray
  Write-Host "  - Check Azure portal: VPN Gateway > BGP peers" -ForegroundColor Gray
  Write-Host "  - Check AWS console: VPN Connections > Tunnel details" -ForegroundColor Gray
  Write-Host "  - See docs/troubleshooting.md for common issues" -ForegroundColor Gray
  exit 1
}
