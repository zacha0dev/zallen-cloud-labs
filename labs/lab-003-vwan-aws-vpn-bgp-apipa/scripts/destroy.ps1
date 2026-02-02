# labs/lab-003-vwan-aws-vpn-bgp-apipa/scripts/destroy.ps1
# Destroys AWS and Azure resources for lab-003 with proper cleanup verification

[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$SubscriptionKey,
  [string]$AwsProfile = "aws-labs",
  [string]$AwsRegion,
  [switch]$Force,
  [switch]$SkipVerification
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..")
$OutputsPath = Join-Path $RepoRoot ".data\lab-003\outputs.json"
$AwsDir = Join-Path $LabRoot "aws"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")
. (Join-Path $RepoRoot "scripts\aws\aws-common.ps1")

# Lab identifiers for tag-based cleanup
$LabTag = "lab-003"
$ResourceGroup = "rg-lab-003-vwan-aws"

# ============================================
# Helper Functions
# ============================================

function Get-AwsResourcesByTag {
  param(
    [string]$Profile,
    [string]$Region,
    [string]$TagKey = "lab",
    [string]$TagValue = "lab-003"
  )

  $resources = @{
    vpnConnections = @()
    customerGateways = @()
    vpnGateways = @()
    routeTables = @()
    internetGateways = @()
    subnets = @()
    vpcs = @()
  }

  Write-Host "  Scanning for resources with tag $TagKey=$TagValue in $Region..." -ForegroundColor DarkGray

  # VPN Connections
  $vpnConns = aws ec2 describe-vpn-connections --profile $Profile --region $Region `
    --filters "Name=tag:$TagKey,Values=$TagValue" --query "VpnConnections[].VpnConnectionId" --output json 2>$null | ConvertFrom-Json
  if ($vpnConns) { $resources.vpnConnections = @($vpnConns) }

  # Customer Gateways
  $cgws = aws ec2 describe-customer-gateways --profile $Profile --region $Region `
    --filters "Name=tag:$TagKey,Values=$TagValue" --query "CustomerGateways[].CustomerGatewayId" --output json 2>$null | ConvertFrom-Json
  if ($cgws) { $resources.customerGateways = @($cgws) }

  # VPN Gateways
  $vgws = aws ec2 describe-vpn-gateways --profile $Profile --region $Region `
    --filters "Name=tag:$TagKey,Values=$TagValue" --query "VpnGateways[].VpnGatewayId" --output json 2>$null | ConvertFrom-Json
  if ($vgws) { $resources.vpnGateways = @($vgws) }

  # Route Tables (exclude main)
  $rts = aws ec2 describe-route-tables --profile $Profile --region $Region `
    --filters "Name=tag:$TagKey,Values=$TagValue" --query "RouteTables[?Associations[0].Main!=``true``].RouteTableId" --output json 2>$null | ConvertFrom-Json
  if ($rts) { $resources.routeTables = @($rts) }

  # Internet Gateways
  $igws = aws ec2 describe-internet-gateways --profile $Profile --region $Region `
    --filters "Name=tag:$TagKey,Values=$TagValue" --query "InternetGateways[].InternetGatewayId" --output json 2>$null | ConvertFrom-Json
  if ($igws) { $resources.internetGateways = @($igws) }

  # Subnets
  $subnets = aws ec2 describe-subnets --profile $Profile --region $Region `
    --filters "Name=tag:$TagKey,Values=$TagValue" --query "Subnets[].SubnetId" --output json 2>$null | ConvertFrom-Json
  if ($subnets) { $resources.subnets = @($subnets) }

  # VPCs
  $vpcs = aws ec2 describe-vpcs --profile $Profile --region $Region `
    --filters "Name=tag:$TagKey,Values=$TagValue" --query "Vpcs[].VpcId" --output json 2>$null | ConvertFrom-Json
  if ($vpcs) { $resources.vpcs = @($vpcs) }

  return $resources
}

function Show-ResourcesToDelete {
  param(
    [hashtable]$AwsResources,
    [string]$AwsRegion,
    [string]$AzureResourceGroup,
    [bool]$AzureRgExists
  )

  Write-Host ""
  Write-Host "============================================" -ForegroundColor Yellow
  Write-Host "RESOURCES TO BE DELETED (Dry Run)" -ForegroundColor Yellow
  Write-Host "============================================" -ForegroundColor Yellow
  Write-Host ""

  Write-Host "AWS Resources (region: $AwsRegion):" -ForegroundColor White
  if ($AwsResources.vpnConnections.Count -gt 0) {
    Write-Host "  VPN Connections:    $($AwsResources.vpnConnections -join ', ')" -ForegroundColor Gray
  }
  if ($AwsResources.customerGateways.Count -gt 0) {
    Write-Host "  Customer Gateways:  $($AwsResources.customerGateways -join ', ')" -ForegroundColor Gray
  }
  if ($AwsResources.vpnGateways.Count -gt 0) {
    Write-Host "  VPN Gateways:       $($AwsResources.vpnGateways -join ', ')" -ForegroundColor Gray
  }
  if ($AwsResources.routeTables.Count -gt 0) {
    Write-Host "  Route Tables:       $($AwsResources.routeTables -join ', ')" -ForegroundColor Gray
  }
  if ($AwsResources.internetGateways.Count -gt 0) {
    Write-Host "  Internet Gateways:  $($AwsResources.internetGateways -join ', ')" -ForegroundColor Gray
  }
  if ($AwsResources.subnets.Count -gt 0) {
    Write-Host "  Subnets:            $($AwsResources.subnets -join ', ')" -ForegroundColor Gray
  }
  if ($AwsResources.vpcs.Count -gt 0) {
    Write-Host "  VPCs:               $($AwsResources.vpcs -join ', ')" -ForegroundColor Gray
  }

  $awsTotal = $AwsResources.vpnConnections.Count + $AwsResources.customerGateways.Count +
              $AwsResources.vpnGateways.Count + $AwsResources.routeTables.Count +
              $AwsResources.internetGateways.Count + $AwsResources.subnets.Count +
              $AwsResources.vpcs.Count

  if ($awsTotal -eq 0) {
    Write-Host "  (no resources found)" -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "Azure Resources:" -ForegroundColor White
  if ($AzureRgExists) {
    Write-Host "  Resource Group: $AzureResourceGroup (and all contents)" -ForegroundColor Gray
  } else {
    Write-Host "  (resource group '$AzureResourceGroup' not found)" -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "============================================" -ForegroundColor Yellow
}

function Remove-AwsResourcesInOrder {
  param(
    [hashtable]$Resources,
    [string]$Profile,
    [string]$Region
  )

  # Deletion order (dependencies):
  # 1. VPN Connections (depends on VGW, CGW)
  # 2. Detach VGW from VPC
  # 3. Delete VGW
  # 4. Delete CGW
  # 5. Route Table associations (then delete RT)
  # 6. Detach and delete IGW
  # 7. Delete Subnets
  # 8. Delete VPC

  Write-Host "  Deleting AWS resources in dependency order..." -ForegroundColor Gray

  # 1. Delete VPN Connections
  foreach ($vpnId in $Resources.vpnConnections) {
    Write-Host "    Deleting VPN Connection: $vpnId" -ForegroundColor DarkGray
    aws ec2 delete-vpn-connection --profile $Profile --region $Region --vpn-connection-id $vpnId 2>$null
    # Wait for deletion
    $maxWait = 60
    $waited = 0
    while ($waited -lt $maxWait) {
      $state = aws ec2 describe-vpn-connections --profile $Profile --region $Region `
        --vpn-connection-ids $vpnId --query "VpnConnections[0].State" --output text 2>$null
      if ($state -eq "deleted" -or -not $state) { break }
      Start-Sleep -Seconds 5
      $waited += 5
    }
  }

  # 2-3. Detach and Delete VPN Gateways
  foreach ($vgwId in $Resources.vpnGateways) {
    # Get attached VPC
    $attachedVpc = aws ec2 describe-vpn-gateways --profile $Profile --region $Region `
      --vpn-gateway-ids $vgwId --query "VpnGateways[0].VpcAttachments[?State=='attached'].VpcId" --output text 2>$null

    if ($attachedVpc -and $attachedVpc -ne "None") {
      Write-Host "    Detaching VGW $vgwId from VPC $attachedVpc" -ForegroundColor DarkGray
      aws ec2 detach-vpn-gateway --profile $Profile --region $Region --vpn-gateway-id $vgwId --vpc-id $attachedVpc 2>$null
      Start-Sleep -Seconds 5
    }

    Write-Host "    Deleting VPN Gateway: $vgwId" -ForegroundColor DarkGray
    aws ec2 delete-vpn-gateway --profile $Profile --region $Region --vpn-gateway-id $vgwId 2>$null
  }

  # 4. Delete Customer Gateways
  foreach ($cgwId in $Resources.customerGateways) {
    Write-Host "    Deleting Customer Gateway: $cgwId" -ForegroundColor DarkGray
    aws ec2 delete-customer-gateway --profile $Profile --region $Region --customer-gateway-id $cgwId 2>$null
  }

  # 5. Delete Route Tables (disassociate first)
  foreach ($rtId in $Resources.routeTables) {
    # Get associations
    $assocs = aws ec2 describe-route-tables --profile $Profile --region $Region `
      --route-table-ids $rtId --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" --output json 2>$null | ConvertFrom-Json

    foreach ($assocId in $assocs) {
      Write-Host "    Disassociating route table: $assocId" -ForegroundColor DarkGray
      aws ec2 disassociate-route-table --profile $Profile --region $Region --association-id $assocId 2>$null
    }

    Write-Host "    Deleting Route Table: $rtId" -ForegroundColor DarkGray
    aws ec2 delete-route-table --profile $Profile --region $Region --route-table-id $rtId 2>$null
  }

  # 6. Detach and Delete Internet Gateways
  foreach ($igwId in $Resources.internetGateways) {
    # Get attached VPC
    $attachedVpc = aws ec2 describe-internet-gateways --profile $Profile --region $Region `
      --internet-gateway-ids $igwId --query "InternetGateways[0].Attachments[0].VpcId" --output text 2>$null

    if ($attachedVpc -and $attachedVpc -ne "None") {
      Write-Host "    Detaching IGW $igwId from VPC $attachedVpc" -ForegroundColor DarkGray
      aws ec2 detach-internet-gateway --profile $Profile --region $Region --internet-gateway-id $igwId --vpc-id $attachedVpc 2>$null
      Start-Sleep -Seconds 2
    }

    Write-Host "    Deleting Internet Gateway: $igwId" -ForegroundColor DarkGray
    aws ec2 delete-internet-gateway --profile $Profile --region $Region --internet-gateway-id $igwId 2>$null
  }

  # 7. Delete Subnets
  foreach ($subnetId in $Resources.subnets) {
    Write-Host "    Deleting Subnet: $subnetId" -ForegroundColor DarkGray
    aws ec2 delete-subnet --profile $Profile --region $Region --subnet-id $subnetId 2>$null
  }

  # 8. Delete VPCs
  foreach ($vpcId in $Resources.vpcs) {
    Write-Host "    Deleting VPC: $vpcId" -ForegroundColor DarkGray
    aws ec2 delete-vpc --profile $Profile --region $Region --vpc-id $vpcId 2>$null
  }
}

function Test-AwsResourcesRemain {
  param(
    [string]$Profile,
    [string]$Region,
    [string]$TagKey = "lab",
    [string]$TagValue = "lab-003"
  )

  $remaining = Get-AwsResourcesByTag -Profile $Profile -Region $Region -TagKey $TagKey -TagValue $TagValue

  $total = $remaining.vpnConnections.Count + $remaining.customerGateways.Count +
           $remaining.vpnGateways.Count + $remaining.routeTables.Count +
           $remaining.internetGateways.Count + $remaining.subnets.Count +
           $remaining.vpcs.Count

  return @{
    HasResources = ($total -gt 0)
    Resources = $remaining
    Count = $total
  }
}

function Test-AzureResourcesRemain {
  param(
    [string]$ResourceGroup,
    [string]$SubscriptionId
  )

  # Check if RG exists
  $rgExists = az group exists --name $ResourceGroup 2>$null
  if ($rgExists -eq "true") {
    # Check for resources with lab=lab-003 tag
    $resources = az resource list -g $ResourceGroup --query "[?tags.lab=='lab-003'].name" -o json 2>$null | ConvertFrom-Json
    return @{
      HasResources = ($resources.Count -gt 0 -or $rgExists -eq "true")
      ResourceGroup = $ResourceGroup
      Count = $resources.Count
    }
  }

  return @{
    HasResources = $false
    ResourceGroup = $ResourceGroup
    Count = 0
  }
}

# ============================================
# Main Script
# ============================================

Write-Host ""
Write-Host "Lab 003: Destroy Resources" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""

# Load outputs if available (for region detection)
if (Test-Path $OutputsPath) {
  $outputs = Get-Content $OutputsPath -Raw | ConvertFrom-Json
  if (-not $AwsRegion) { $AwsRegion = $outputs.aws.region }
  if (-not $AwsProfile) { $AwsProfile = $outputs.aws.profile }
  $ResourceGroup = $outputs.azure.resourceGroup
}

# Default region if not found
if (-not $AwsRegion) { $AwsRegion = "us-east-2" }

Write-Host "==> Authentication" -ForegroundColor Yellow

# Auth checks (prompts to login if needed)
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
Write-Host "  Azure: $SubscriptionId" -ForegroundColor Gray

Ensure-AwsAuth -Profile $AwsProfile
Write-Host "  AWS: $AwsProfile ($AwsRegion)" -ForegroundColor Gray

# ============================================
# Discovery Phase
# ============================================
Write-Host ""
Write-Host "==> Resource Discovery" -ForegroundColor Yellow

# Find AWS resources by tag (fallback if no Terraform state)
$awsResources = Get-AwsResourcesByTag -Profile $AwsProfile -Region $AwsRegion

# Check Azure RG
$azureRgExists = (az group exists --name $ResourceGroup) -eq "true"

# ============================================
# Dry Run Mode (-WhatIf)
# ============================================
if ($WhatIfPreference -or $PSCmdlet.ShouldProcess("lab-003 resources", "Delete")) {
  if ($WhatIfPreference) {
    Show-ResourcesToDelete -AwsResources $awsResources -AwsRegion $AwsRegion `
      -AzureResourceGroup $ResourceGroup -AzureRgExists $azureRgExists
    Write-Host "To actually delete, run without -WhatIf" -ForegroundColor Yellow
    return
  }
}

# Confirmation
if (-not $Force) {
  Show-ResourcesToDelete -AwsResources $awsResources -AwsRegion $AwsRegion `
    -AzureResourceGroup $ResourceGroup -AzureRgExists $azureRgExists

  Write-Host "This will PERMANENTLY DELETE all resources above." -ForegroundColor Red
  $confirm = Read-Host "Type DELETE to confirm"
  if ($confirm -ne "DELETE") { throw "Cancelled." }
}

# ============================================
# Phase 1: Destroy AWS (Terraform first, then tag-based fallback)
# ============================================
Write-Host ""
Write-Host "==> Phase 1: AWS teardown" -ForegroundColor Cyan

$tfstatePath = Join-Path $AwsDir "terraform.tfstate"
$tfvarsPath = Join-Path $AwsDir "terraform.tfvars"

if (Test-Path $tfstatePath) {
  Write-Host "  Using Terraform state for cleanup..." -ForegroundColor Gray
  $env:AWS_PROFILE = $AwsProfile

  Push-Location $AwsDir
  try {
    terraform destroy -auto-approve -input=false 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  Terraform destroy had issues, falling back to tag-based cleanup..." -ForegroundColor Yellow
      Remove-AwsResourcesInOrder -Resources $awsResources -Profile $AwsProfile -Region $AwsRegion
    }
  }
  finally {
    Pop-Location
  }

  # Clean up terraform files
  @($tfvarsPath, $tfstatePath,
    (Join-Path $AwsDir "terraform.tfstate.backup"),
    (Join-Path $AwsDir ".terraform.lock.hcl")) | ForEach-Object {
    if (Test-Path $_) { Remove-Item $_ -Force }
  }
  $tfDir = Join-Path $AwsDir ".terraform"
  if (Test-Path $tfDir) { Remove-Item $tfDir -Recurse -Force }
} else {
  Write-Host "  No Terraform state found, using tag-based cleanup..." -ForegroundColor Yellow
  Remove-AwsResourcesInOrder -Resources $awsResources -Profile $AwsProfile -Region $AwsRegion
}

# ============================================
# Phase 2: Destroy Azure
# ============================================
Write-Host ""
Write-Host "==> Phase 2: Azure teardown" -ForegroundColor Cyan

if ($azureRgExists) {
  Write-Host "  Deleting resource group '$ResourceGroup'..." -ForegroundColor Gray
  az group delete --name $ResourceGroup --yes --no-wait
  Write-Host "  Deletion initiated (runs in background)" -ForegroundColor Green
} else {
  Write-Host "  Resource group '$ResourceGroup' not found" -ForegroundColor DarkGray
}

# Clean up outputs file
if (Test-Path $OutputsPath) {
  Remove-Item $OutputsPath -Force
  Write-Host "  Removed outputs file" -ForegroundColor Gray
}

# ============================================
# Phase 3: Verification
# ============================================
if (-not $SkipVerification) {
  Write-Host ""
  Write-Host "==> Phase 3: Cleanup Verification" -ForegroundColor Yellow

  # Wait a moment for deletions to propagate
  Start-Sleep -Seconds 5

  # Check AWS
  Write-Host "  Checking AWS for remaining resources..." -ForegroundColor Gray
  $awsCheck = Test-AwsResourcesRemain -Profile $AwsProfile -Region $AwsRegion

  if ($awsCheck.HasResources) {
    Write-Host ""
    Write-Host "  WARNING: $($awsCheck.Count) AWS resources still found with tag lab=$LabTag" -ForegroundColor Yellow
    Write-Host "  These may still be deleting or require manual cleanup:" -ForegroundColor Yellow
    if ($awsCheck.Resources.vpcs.Count -gt 0) {
      Write-Host "    VPCs: $($awsCheck.Resources.vpcs -join ', ')" -ForegroundColor Gray
    }
    if ($awsCheck.Resources.vpnGateways.Count -gt 0) {
      Write-Host "    VGWs: $($awsCheck.Resources.vpnGateways -join ', ')" -ForegroundColor Gray
    }
  } else {
    Write-Host "  AWS: No resources with tag lab=$LabTag found" -ForegroundColor Green
  }

  # Check Azure
  Write-Host "  Checking Azure for remaining resources..." -ForegroundColor Gray
  $azureRgStillExists = (az group exists --name $ResourceGroup 2>$null) -eq "true"

  if ($azureRgStillExists) {
    $provState = az group show -n $ResourceGroup --query provisioningState -o tsv 2>$null
    Write-Host "  Azure: Resource group still exists (state: $provState)" -ForegroundColor Yellow
    Write-Host "  Monitor with: az group show -n $ResourceGroup --query provisioningState -o tsv" -ForegroundColor Gray
  } else {
    Write-Host "  Azure: Resource group deleted" -ForegroundColor Green
  }
}

Write-Host ""
Write-Host "===========================" -ForegroundColor Cyan
Write-Host "Destroy Complete" -ForegroundColor Green
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor White
Write-Host "  AWS Region: $AwsRegion" -ForegroundColor Gray
Write-Host "  Azure RG:   $ResourceGroup" -ForegroundColor Gray
Write-Host ""
Write-Host "If Azure RG deletion is still in progress, monitor with:" -ForegroundColor Yellow
Write-Host "  az group show -n $ResourceGroup --query provisioningState -o tsv" -ForegroundColor Cyan
Write-Host ""
Write-Host "To verify no lab-003 resources remain:" -ForegroundColor Yellow
Write-Host "  .\scripts\destroy.ps1 -WhatIf" -ForegroundColor Cyan
