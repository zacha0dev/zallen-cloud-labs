<#
.SYNOPSIS
  Audits Azure and AWS resources created by azure-labs to help stay cost-aware.

.DESCRIPTION
  Read-only audit tool that scans for lab resources in Azure and AWS.
  Identifies high-cost resources and provides cleanup recommendations.

.PARAMETER Scope
  Labs = Only scan lab resource groups (rg-lab-*, rg-azure-labs-*)
  All  = Scan entire subscription for high-cost resource types

.PARAMETER Lab
  Optional filter to a specific lab (e.g., "lab-003")

.PARAMETER SubscriptionKey
  Azure subscription key from .data/subs.json (default: uses config default)

.PARAMETER AwsProfile
  AWS CLI profile name. If not provided, AWS checks are skipped.

.PARAMETER AwsRegion
  AWS region to scan. Default: us-east-2

.PARAMETER JsonOutputPath
  Optional path to save JSON report

.EXAMPLE
  ./tools/cost-check.ps1
  ./tools/cost-check.ps1 -Lab lab-003 -AwsProfile aws-labs
  ./tools/cost-check.ps1 -Scope All -AwsProfile aws-labs -AwsRegion us-east-2
#>

param(
  [ValidateSet("Labs", "All")]
  [string]$Scope = "Labs",

  [string]$Lab,

  [string]$SubscriptionKey,

  [string]$AwsProfile,

  [string]$AwsRegion = "us-east-2",

  [string]$JsonOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==============================================================================
# Setup and Helpers
# ==============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

# Import shared functions
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

function Write-Header {
  param([string]$Text)
  Write-Host ""
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host $Text -ForegroundColor Cyan
  Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Write-SubHeader {
  param([string]$Text)
  Write-Host ""
  Write-Host "--- $Text ---" -ForegroundColor Yellow
}

function Write-Check {
  param(
    [string]$Label,
    [bool]$IsWarning = $false,
    [string]$Details = ""
  )
  $marker = if ($IsWarning) { "[WARN]" } else { "[PASS]" }
  $color = if ($IsWarning) { "Yellow" } else { "Green" }
  Write-Host "  $marker " -ForegroundColor $color -NoNewline
  Write-Host $Label -NoNewline
  if ($Details) {
    Write-Host " - $Details" -ForegroundColor DarkGray
  } else {
    Write-Host ""
  }
}

# High-cost resource types to flag
$HighCostTypes = @(
  "Microsoft.Network/virtualWans",
  "Microsoft.Network/virtualHubs",
  "Microsoft.Network/vpnGateways",
  "Microsoft.Network/applicationGateways",
  "Microsoft.Compute/virtualMachines",
  "Microsoft.Network/publicIPAddresses",
  "Microsoft.Cdn/profiles",
  "Microsoft.Network/azureFirewalls"
)

$HighCostTypeShortNames = @{
  "Microsoft.Network/virtualWans" = "vWAN"
  "Microsoft.Network/virtualHubs" = "vHub"
  "Microsoft.Network/vpnGateways" = "VPN Gateway"
  "Microsoft.Network/applicationGateways" = "App Gateway"
  "Microsoft.Compute/virtualMachines" = "VM"
  "Microsoft.Network/publicIPAddresses" = "Public IP"
  "Microsoft.Cdn/profiles" = "Front Door/CDN"
  "Microsoft.Network/azureFirewalls" = "Azure Firewall"
}

# ==============================================================================
# Main Script
# ==============================================================================

Write-Host ""
Write-Host "Cost Audit Tool for Azure Labs" -ForegroundColor Cyan
Write-Host "===============================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Scope: $Scope" -ForegroundColor Gray
if ($Lab) { Write-Host "Lab filter: $Lab" -ForegroundColor Gray }
Write-Host "AWS Profile: $(if ($AwsProfile) { $AwsProfile } else { '(not provided - skipping AWS)' })" -ForegroundColor Gray
Write-Host ""

# Results tracking
$report = @{
  timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
  scope = $Scope
  labFilter = $Lab
  azure = @{
    subscriptionId = $null
    resourceGroups = @()
    highCostResources = @()
    totalHighCostCount = 0
  }
  aws = @{
    profile = $AwsProfile
    region = $AwsRegion
    resources = @()
    totalBillableCount = 0
  }
  warnings = @()
}

# ==============================================================================
# Azure Checks
# ==============================================================================

Write-Header "Azure Resource Audit"

# Resolve subscription
Write-Host "==> Config preflight" -ForegroundColor Yellow
try {
  $cfg = Get-LabConfig -RepoRoot $RepoRoot
  Write-Host "  Status: OK" -ForegroundColor Green
  $SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -Config $cfg -RepoRoot $RepoRoot
  Write-Check "Azure subscription resolved" -Details $SubscriptionId
  $report.azure.subscriptionId = $SubscriptionId
} catch {
  Write-Host "  [WARN] Could not resolve subscription: $_" -ForegroundColor Yellow
  Write-Host "  Skipping Azure checks." -ForegroundColor Yellow
  $SubscriptionId = $null
}

if ($SubscriptionId) {
  # Set subscription context
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az account set --subscription $SubscriptionId 2>$null
  $ErrorActionPreference = $oldErrPref

  Write-SubHeader "Resource Groups"

  # Get lab resource groups
  $rgFilter = if ($Scope -eq "Labs") {
    "[?starts_with(name, 'rg-lab-') || starts_with(name, 'rg-azure-labs-')]"
  } else {
    "[]"
  }

  $rgsJson = az group list --query $rgFilter -o json 2>$null
  $rgs = @()
  if ($rgsJson) {
    $rgs = $rgsJson | ConvertFrom-Json
  }

  # Filter by lab if specified
  if ($Lab -and $rgs.Count -gt 0) {
    $rgs = @($rgs | Where-Object { $_.name -match $Lab })
  }

  if ($rgs.Count -eq 0) {
    Write-Host "  No lab resource groups found." -ForegroundColor Gray
  } else {
    Write-Host ""
    Write-Host "  Found $($rgs.Count) resource group(s):" -ForegroundColor White
    Write-Host ""

    # Table header
    $fmt = "  {0,-35} {1,-15} {2,-10} {3,-20}"
    Write-Host ($fmt -f "Resource Group", "Location", "Resources", "Tags") -ForegroundColor DarkCyan
    Write-Host ($fmt -f ("-" * 35), ("-" * 15), ("-" * 10), ("-" * 20)) -ForegroundColor DarkGray

    foreach ($rg in $rgs) {
      $rgName = $rg.name
      $rgLocation = $rg.location

      # Get resource count
      $resourcesJson = az resource list --resource-group $rgName --query "length(@)" -o tsv 2>$null
      $resourceCount = if ($resourcesJson) { [int]$resourcesJson } else { 0 }

      # Extract relevant tags
      $tagStr = ""
      if ($rg.tags) {
        $tagParts = @()
        if ($rg.tags.project) { $tagParts += "project=$($rg.tags.project)" }
        if ($rg.tags.lab) { $tagParts += "lab=$($rg.tags.lab)" }
        if ($rg.tags.owner) { $tagParts += "owner=$($rg.tags.owner)" }
        $tagStr = $tagParts -join ", "
      }
      if (-not $tagStr) { $tagStr = "(none)" }

      Write-Host ($fmt -f $rgName, $rgLocation, $resourceCount, $tagStr)

      $report.azure.resourceGroups += @{
        name = $rgName
        location = $rgLocation
        resourceCount = $resourceCount
        tags = $rg.tags
      }
    }
  }

  Write-SubHeader "High-Cost Resources in Lab RGs"

  $allHighCost = @()

  foreach ($rg in $rgs) {
    $rgName = $rg.name

    foreach ($resourceType in $HighCostTypes) {
      $resourcesJson = az resource list --resource-group $rgName --resource-type $resourceType -o json 2>$null
      if ($resourcesJson) {
        $resources = $resourcesJson | ConvertFrom-Json
        foreach ($res in $resources) {
          $shortType = $HighCostTypeShortNames[$resourceType]
          $allHighCost += @{
            resourceGroup = $rgName
            name = $res.name
            type = $resourceType
            shortType = $shortType
            location = $res.location
          }
        }
      }
    }
  }

  if ($allHighCost.Count -eq 0) {
    Write-Check "No high-cost resources found in lab RGs"
  } else {
    Write-Host ""
    Write-Host "  [WARN] Found $($allHighCost.Count) high-cost resource(s):" -ForegroundColor Yellow
    Write-Host ""

    $fmt = "  {0,-35} {1,-25} {2,-15}"
    Write-Host ($fmt -f "Resource Group", "Resource Name", "Type") -ForegroundColor DarkCyan
    Write-Host ($fmt -f ("-" * 35), ("-" * 25), ("-" * 15)) -ForegroundColor DarkGray

    foreach ($res in $allHighCost) {
      Write-Host ($fmt -f $res.resourceGroup, $res.name, $res.shortType) -ForegroundColor Yellow
    }

    $report.azure.highCostResources = $allHighCost
    $report.azure.totalHighCostCount = $allHighCost.Count
    $report.warnings += "Azure: $($allHighCost.Count) high-cost resources found"
  }

  # If Scope=All, also scan subscription-wide
  if ($Scope -eq "All") {
    Write-SubHeader "Subscription-Wide High-Cost Resources"

    $subHighCost = @()
    foreach ($resourceType in $HighCostTypes) {
      $resourcesJson = az resource list --resource-type $resourceType -o json 2>$null
      if ($resourcesJson) {
        $resources = $resourcesJson | ConvertFrom-Json
        foreach ($res in $resources) {
          # Skip if already counted in lab RGs
          $alreadyCounted = $allHighCost | Where-Object { $_.name -eq $res.name -and $_.resourceGroup -eq $res.resourceGroup }
          if (-not $alreadyCounted) {
            $shortType = $HighCostTypeShortNames[$resourceType]
            $subHighCost += @{
              resourceGroup = $res.resourceGroup
              name = $res.name
              type = $resourceType
              shortType = $shortType
              location = $res.location
            }
          }
        }
      }
    }

    if ($subHighCost.Count -eq 0) {
      Write-Check "No additional high-cost resources outside lab RGs"
    } else {
      Write-Host ""
      Write-Host "  [INFO] Found $($subHighCost.Count) high-cost resource(s) outside lab RGs:" -ForegroundColor Cyan
      Write-Host ""

      $fmt = "  {0,-35} {1,-25} {2,-15}"
      Write-Host ($fmt -f "Resource Group", "Resource Name", "Type") -ForegroundColor DarkCyan
      Write-Host ($fmt -f ("-" * 35), ("-" * 25), ("-" * 15)) -ForegroundColor DarkGray

      foreach ($res in $subHighCost) {
        Write-Host ($fmt -f $res.resourceGroup, $res.name, $res.shortType)
      }
    }
  }
}

# ==============================================================================
# AWS Checks
# ==============================================================================

Write-Header "AWS Resource Audit"

if (-not $AwsProfile) {
  Write-Host "  [SKIP] AWS profile not provided. Use -AwsProfile to enable AWS checks." -ForegroundColor DarkGray
} else {
  # Check AWS auth
  $env:AWS_PROFILE = $AwsProfile
  $env:AWS_DEFAULT_REGION = $AwsRegion

  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $awsAccount = aws sts get-caller-identity --query "Account" --output text 2>$null
  $ErrorActionPreference = $oldErrPref

  if (-not $awsAccount -or $LASTEXITCODE -ne 0) {
    Write-Host "  [WARN] AWS not authenticated with profile '$AwsProfile'" -ForegroundColor Yellow
    Write-Host "  Run: aws sso login --profile $AwsProfile" -ForegroundColor Cyan
  } else {
    Write-Check "AWS authenticated" -Details "Account: $awsAccount, Region: $AwsRegion"

    # Build tag filter
    $tagFilter = "Name=tag:project,Values=azure-labs"
    if ($Lab) {
      $tagFilter = "Name=tag:project,Values=azure-labs Name=tag:lab,Values=$Lab"
    }

    $awsBillable = @()

    Write-SubHeader "VPN Connections"
    $vpnsJson = aws ec2 describe-vpn-connections --filters $tagFilter --query "VpnConnections[?State!='deleted']" --output json 2>$null
    if ($vpnsJson) {
      $vpns = $vpnsJson | ConvertFrom-Json
      if ($vpns.Count -gt 0) {
        foreach ($vpn in $vpns) {
          Write-Host "  [WARN] VPN Connection: $($vpn.VpnConnectionId) (State: $($vpn.State))" -ForegroundColor Yellow
          $awsBillable += @{ type = "VPN Connection"; id = $vpn.VpnConnectionId; state = $vpn.State }
        }
      } else {
        Write-Check "No VPN connections found"
      }
    } else {
      Write-Check "No VPN connections found"
    }

    Write-SubHeader "Virtual Private Gateways"
    $vgwsJson = aws ec2 describe-vpn-gateways --filters $tagFilter --query "VpnGateways[?State!='deleted']" --output json 2>$null
    if ($vgwsJson) {
      $vgws = $vgwsJson | ConvertFrom-Json
      if ($vgws.Count -gt 0) {
        foreach ($vgw in $vgws) {
          Write-Host "  [INFO] VPN Gateway: $($vgw.VpnGatewayId) (State: $($vgw.State))" -ForegroundColor Cyan
          $awsBillable += @{ type = "VPN Gateway"; id = $vgw.VpnGatewayId; state = $vgw.State }
        }
      } else {
        Write-Check "No VPN gateways found"
      }
    } else {
      Write-Check "No VPN gateways found"
    }

    Write-SubHeader "Customer Gateways"
    $cgwsJson = aws ec2 describe-customer-gateways --filters $tagFilter --query "CustomerGateways[?State!='deleted']" --output json 2>$null
    if ($cgwsJson) {
      $cgws = $cgwsJson | ConvertFrom-Json
      if ($cgws.Count -gt 0) {
        foreach ($cgw in $cgws) {
          Write-Host "  [INFO] Customer Gateway: $($cgw.CustomerGatewayId) (State: $($cgw.State))" -ForegroundColor Cyan
        }
      } else {
        Write-Check "No customer gateways found"
      }
    } else {
      Write-Check "No customer gateways found"
    }

    Write-SubHeader "EC2 Instances"
    $ec2sJson = aws ec2 describe-instances --filters $tagFilter "Name=instance-state-name,Values=running,stopped" --query "Reservations[].Instances[]" --output json 2>$null
    if ($ec2sJson) {
      $ec2s = $ec2sJson | ConvertFrom-Json
      if ($ec2s.Count -gt 0) {
        foreach ($ec2 in $ec2s) {
          Write-Host "  [WARN] EC2 Instance: $($ec2.InstanceId) (State: $($ec2.State.Name), Type: $($ec2.InstanceType))" -ForegroundColor Yellow
          $awsBillable += @{ type = "EC2 Instance"; id = $ec2.InstanceId; state = $ec2.State.Name }
        }
      } else {
        Write-Check "No EC2 instances found"
      }
    } else {
      Write-Check "No EC2 instances found"
    }

    Write-SubHeader "Elastic IPs"
    $eipsJson = aws ec2 describe-addresses --filters $tagFilter --output json 2>$null
    if ($eipsJson) {
      $eips = ($eipsJson | ConvertFrom-Json).Addresses
      if ($eips -and $eips.Count -gt 0) {
        foreach ($eip in $eips) {
          $associated = if ($eip.AssociationId) { "associated" } else { "unassociated (BILLING!)" }
          $color = if ($eip.AssociationId) { "Cyan" } else { "Yellow" }
          Write-Host "  [$( if ($eip.AssociationId) { 'INFO' } else { 'WARN' })] EIP: $($eip.PublicIp) ($associated)" -ForegroundColor $color
          if (-not $eip.AssociationId) {
            $awsBillable += @{ type = "Elastic IP (unassociated)"; id = $eip.PublicIp; state = "unassociated" }
          }
        }
      } else {
        Write-Check "No Elastic IPs found"
      }
    } else {
      Write-Check "No Elastic IPs found"
    }

    Write-SubHeader "NAT Gateways"
    $natsJson = aws ec2 describe-nat-gateways --filter $tagFilter "Name=state,Values=available,pending" --output json 2>$null
    if ($natsJson) {
      $nats = ($natsJson | ConvertFrom-Json).NatGateways
      if ($nats -and $nats.Count -gt 0) {
        foreach ($nat in $nats) {
          Write-Host "  [WARN] NAT Gateway: $($nat.NatGatewayId) (State: $($nat.State))" -ForegroundColor Yellow
          $awsBillable += @{ type = "NAT Gateway"; id = $nat.NatGatewayId; state = $nat.State }
        }
      } else {
        Write-Check "No NAT gateways found"
      }
    } else {
      Write-Check "No NAT gateways found"
    }

    Write-SubHeader "Load Balancers"
    $lbsJson = aws elbv2 describe-load-balancers --output json 2>$null
    if ($lbsJson) {
      $lbs = ($lbsJson | ConvertFrom-Json).LoadBalancers
      # Filter by tag (need separate call for tags)
      $labLbs = @()
      foreach ($lb in $lbs) {
        $tagsJson = aws elbv2 describe-tags --resource-arns $lb.LoadBalancerArn --output json 2>$null
        if ($tagsJson) {
          $tags = ($tagsJson | ConvertFrom-Json).TagDescriptions[0].Tags
          $projectTag = $tags | Where-Object { $_.Key -eq "project" -and $_.Value -eq "azure-labs" }
          if ($projectTag) {
            $labLbs += $lb
          }
        }
      }
      if ($labLbs.Count -gt 0) {
        foreach ($lb in $labLbs) {
          Write-Host "  [WARN] Load Balancer: $($lb.LoadBalancerName) (Type: $($lb.Type))" -ForegroundColor Yellow
          $awsBillable += @{ type = "Load Balancer"; id = $lb.LoadBalancerName; state = $lb.State.Code }
        }
      } else {
        Write-Check "No tagged load balancers found"
      }
    } else {
      Write-Check "No load balancers found"
    }

    Write-SubHeader "VPCs"
    $vpcsJson = aws ec2 describe-vpcs --filters $tagFilter --output json 2>$null
    if ($vpcsJson) {
      $vpcs = ($vpcsJson | ConvertFrom-Json).Vpcs
      if ($vpcs -and $vpcs.Count -gt 0) {
        foreach ($vpc in $vpcs) {
          $nameTag = ($vpc.Tags | Where-Object { $_.Key -eq "Name" }).Value
          Write-Host "  [INFO] VPC: $($vpc.VpcId) ($nameTag) - CIDR: $($vpc.CidrBlock)" -ForegroundColor Cyan
        }
      } else {
        Write-Check "No tagged VPCs found"
      }
    } else {
      Write-Check "No tagged VPCs found"
    }

    $report.aws.resources = $awsBillable
    $report.aws.totalBillableCount = $awsBillable.Count

    if ($awsBillable.Count -gt 0) {
      $report.warnings += "AWS: $($awsBillable.Count) billable resources found"
    }
  }
}

# ==============================================================================
# Summary
# ==============================================================================

Write-Header "Summary"

$azureRgCount = $report.azure.resourceGroups.Count
$azureHighCost = $report.azure.totalHighCostCount
$awsBillable = $report.aws.totalBillableCount

Write-Host ""
Write-Host "  Azure:" -ForegroundColor White
Write-Host "    Lab resource groups: $azureRgCount" -ForegroundColor $(if ($azureRgCount -gt 0) { "Yellow" } else { "Green" })
Write-Host "    High-cost resources: $azureHighCost" -ForegroundColor $(if ($azureHighCost -gt 0) { "Yellow" } else { "Green" })

Write-Host ""
Write-Host "  AWS:" -ForegroundColor White
if ($AwsProfile) {
  Write-Host "    Billable resources:  $awsBillable" -ForegroundColor $(if ($awsBillable -gt 0) { "Yellow" } else { "Green" })
} else {
  Write-Host "    (skipped - no profile provided)" -ForegroundColor DarkGray
}

# Action required?
$needsAction = ($azureHighCost -gt 0) -or ($awsBillable -gt 0)

if ($needsAction) {
  Write-Host ""
  Write-Host ("!" * 60) -ForegroundColor Red
  Write-Host "  ACTION REQUIRED: Billable resources detected!" -ForegroundColor Red
  Write-Host ("!" * 60) -ForegroundColor Red
  Write-Host ""
  Write-Host "  To clean up, run the destroy script for the relevant lab:" -ForegroundColor Yellow
  Write-Host ""

  # Suggest destroy commands based on detected resources
  $detectedLabs = @()
  foreach ($rg in $report.azure.resourceGroups) {
    if ($rg.name -match "rg-lab-(\d{3})") {
      $labNum = $Matches[1]
      $detectedLabs += "lab-$labNum"
    }
  }
  $detectedLabs = $detectedLabs | Sort-Object -Unique

  if ($detectedLabs.Count -gt 0) {
    foreach ($lab in $detectedLabs) {
      $labPath = Get-ChildItem -Path (Join-Path $RepoRoot "labs") -Directory | Where-Object { $_.Name -match "^$lab" } | Select-Object -First 1
      if ($labPath) {
        Write-Host "    cd $($labPath.FullName)" -ForegroundColor Cyan
        Write-Host "    .\destroy.ps1" -ForegroundColor Cyan
        Write-Host ""
      }
    }
  } else {
    Write-Host "    cd labs/<lab-folder>" -ForegroundColor Cyan
    Write-Host "    .\destroy.ps1" -ForegroundColor Cyan
    Write-Host ""
  }
} else {
  Write-Host ""
  Write-Host "  All clear! No billable lab resources detected." -ForegroundColor Green
  Write-Host ""
}

# Save JSON report if requested
if ($JsonOutputPath) {
  $reportJson = $report | ConvertTo-Json -Depth 10
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($JsonOutputPath, $reportJson, $utf8NoBom)
  Write-Host "  Report saved to: $JsonOutputPath" -ForegroundColor Gray
}

Write-Host ""
