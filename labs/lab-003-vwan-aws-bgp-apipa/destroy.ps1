# labs/lab-003-vwan-aws-bgp-apipa/destroy.ps1
# Destroys all resources created by lab-003 (Azure and AWS)

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$AwsProfile = "aws-labs",
  [string]$AwsRegion = "us-east-2",
  [switch]$Force,
  [switch]$KeepLogs,
  [switch]$AzureOnly,
  [switch]$AwsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")
. (Join-Path $RepoRoot "scripts\aws\aws-common.ps1")

# Lab configuration
$ResourceGroup = "rg-lab-003-vwan-aws"

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

Write-Host ""
Write-Host "Lab 003: Destroy Resources" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""

$destroyStartTime = Get-Date

# ============================================
# Azure Cleanup
# ============================================
if (-not $AwsOnly) {
  Write-Host "==> Azure Cleanup" -ForegroundColor Yellow
  Write-Host ""

  # Check for Azure CLI
  if (-not (Get-Command "az" -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install from: https://aka.ms/installazurecli"
  }

  # Get subscription
  $SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
  Ensure-AzureAuth -DoLogin
  az account set --subscription $SubscriptionId | Out-Null

  # Check if resource group exists (use 'exists' to avoid error on missing RG)
  $rgExists = $false
  try {
    $rgExists = (az group exists -n $ResourceGroup 2>$null) -eq "true"
  } catch {
    $rgExists = $false
  }

  if (-not $rgExists) {
    Write-Host "Azure resource group '$ResourceGroup' does not exist. Skipping Azure cleanup." -ForegroundColor Yellow
  } else {
    # Show what will be deleted
    Write-Host "Azure resources to delete:" -ForegroundColor Yellow
    Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
    Write-Host "  Subscription: $SubscriptionId" -ForegroundColor Gray
    Write-Host ""

    # List resources in the group
    $resources = az resource list -g $ResourceGroup --query "[].{Name:name, Type:type}" -o json 2>$null | ConvertFrom-Json
    if ($resources) {
      Write-Host "Resources in group:" -ForegroundColor White
      foreach ($r in $resources) {
        Write-Host "  - $($r.Name) ($($r.Type))" -ForegroundColor DarkGray
      }
      Write-Host ""
    }

    # Confirmation
    if (-not $Force) {
      Write-Host "WARNING: This will permanently delete all Azure resources!" -ForegroundColor Red
      $confirm = Read-Host "Type DELETE to confirm Azure deletion"
      if ($confirm -ne "DELETE") {
        Write-Host "Azure deletion cancelled." -ForegroundColor Yellow
        if (-not $AzureOnly) {
          Write-Host "Continuing to AWS cleanup..." -ForegroundColor Gray
        } else {
          exit 0
        }
      } else {
        # Delete resource group
        Write-Host ""
        Write-Host "Deleting Azure resource group: $ResourceGroup" -ForegroundColor Yellow
        Write-Host "This may take 5-10 minutes..." -ForegroundColor Gray

        $azureStartTime = Get-Date

        az group delete --name $ResourceGroup --yes --no-wait

        # Wait for deletion
        Write-Host "Waiting for Azure deletion to complete..." -ForegroundColor Gray
        $maxAttempts = 60
        $attempt = 0

        while ($attempt -lt $maxAttempts) {
          $attempt++
          $rgExists = az group exists -n $ResourceGroup 2>$null
          if ($rgExists -eq "false") {
            break
          }

          $elapsed = Get-ElapsedTime -StartTime $azureStartTime
          Write-Host "  [$elapsed] Still deleting... (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
          Start-Sleep -Seconds 15
        }

        $azureElapsed = Get-ElapsedTime -StartTime $azureStartTime
        Write-Host ""
        Write-Host "Azure resource group deleted in $azureElapsed" -ForegroundColor Green
      }
    } else {
      # Force mode - delete immediately
      Write-Host "Deleting Azure resource group: $ResourceGroup (Force mode)" -ForegroundColor Yellow
      az group delete --name $ResourceGroup --yes --no-wait

      $maxAttempts = 60
      $attempt = 0
      $azureStartTime = Get-Date

      while ($attempt -lt $maxAttempts) {
        $attempt++
        $rgExists = az group exists -n $ResourceGroup 2>$null
        if ($rgExists -eq "false") {
          break
        }
        $elapsed = Get-ElapsedTime -StartTime $azureStartTime
        Write-Host "  [$elapsed] Still deleting... (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
      }

      $azureElapsed = Get-ElapsedTime -StartTime $azureStartTime
      Write-Host "Azure resource group deleted in $azureElapsed" -ForegroundColor Green
    }
  }
}

# ============================================
# AWS Cleanup
# ============================================
if (-not $AzureOnly) {
  Write-Host ""
  Write-Host "==> AWS Cleanup" -ForegroundColor Yellow
  Write-Host ""

  # Check AWS CLI
  if (-not (Get-Command "aws" -ErrorAction SilentlyContinue)) {
    Write-Host "AWS CLI not found. Skipping AWS cleanup." -ForegroundColor Yellow
  } else {
    # Set AWS profile
    $env:AWS_PROFILE = $AwsProfile
    $env:AWS_DEFAULT_REGION = $AwsRegion

    # Verify AWS auth
    $awsIdentity = $null
    try {
      $awsIdentity = aws sts get-caller-identity --output json 2>$null | ConvertFrom-Json
    } catch { }

    if (-not $awsIdentity) {
      Write-Host "AWS profile '$AwsProfile' not authenticated. Skipping AWS cleanup." -ForegroundColor Yellow
    } else {
      Write-Host "AWS Account: $($awsIdentity.Account)" -ForegroundColor Gray
      Write-Host "AWS Region: $AwsRegion" -ForegroundColor Gray
      Write-Host ""

      # Find lab-003 resources
      Write-Host "Finding AWS resources with lab=lab-003 tag..." -ForegroundColor Gray

      # Find VPN Connections
      $vpnConns = aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --query "VpnConnections[?State!='deleted'].VpnConnectionId" --output json 2>$null | ConvertFrom-Json
      if ($vpnConns -and $vpnConns.Count -gt 0) {
        Write-Host "  VPN Connections: $($vpnConns -join ', ')" -ForegroundColor DarkGray
      }

      # Find Customer Gateways
      $cgws = aws ec2 describe-customer-gateways --filters "Name=tag:lab,Values=lab-003" --query "CustomerGateways[?State!='deleted'].CustomerGatewayId" --output json 2>$null | ConvertFrom-Json
      if ($cgws -and $cgws.Count -gt 0) {
        Write-Host "  Customer Gateways: $($cgws -join ', ')" -ForegroundColor DarkGray
      }

      # Find VGW
      $vgws = aws ec2 describe-vpn-gateways --filters "Name=tag:lab,Values=lab-003" --query "VpnGateways[?State!='deleted'].VpnGatewayId" --output json 2>$null | ConvertFrom-Json
      if ($vgws -and $vgws.Count -gt 0) {
        Write-Host "  VPN Gateways: $($vgws -join ', ')" -ForegroundColor DarkGray
      }

      # Find VPC
      $vpcs = aws ec2 describe-vpcs --filters "Name=tag:lab,Values=lab-003" --query "Vpcs[].VpcId" --output json 2>$null | ConvertFrom-Json
      if ($vpcs -and $vpcs.Count -gt 0) {
        Write-Host "  VPCs: $($vpcs -join ', ')" -ForegroundColor DarkGray
      }

      $hasAwsResources = ($vpnConns -and $vpnConns.Count -gt 0) -or ($cgws -and $cgws.Count -gt 0) -or ($vgws -and $vgws.Count -gt 0) -or ($vpcs -and $vpcs.Count -gt 0)

      if (-not $hasAwsResources) {
        Write-Host "No AWS resources found with lab=lab-003 tag. Nothing to delete." -ForegroundColor Yellow
      } else {
        Write-Host ""

        # Confirmation
        if (-not $Force) {
          Write-Host "WARNING: This will permanently delete all AWS resources!" -ForegroundColor Red
          $confirm = Read-Host "Type DELETE to confirm AWS deletion"
          if ($confirm -ne "DELETE") {
            Write-Host "AWS deletion cancelled." -ForegroundColor Yellow
          } else {
            $deleteAws = $true
          }
        } else {
          $deleteAws = $true
        }

        if ($deleteAws) {
          $awsStartTime = Get-Date

          # Delete VPN Connections first (must complete before VGW can be deleted)
          if ($vpnConns -and $vpnConns.Count -gt 0) {
            Write-Host "Deleting VPN Connections..." -ForegroundColor Gray
            foreach ($vpnId in $vpnConns) {
              Write-Host "  Deleting: $vpnId" -ForegroundColor DarkGray
              aws ec2 delete-vpn-connection --vpn-connection-id $vpnId 2>$null
            }
            # Wait for VPN connections to actually be deleted
            Write-Host "  Waiting for VPN connections to be deleted..." -ForegroundColor DarkGray
            $maxWait = 18  # 3 minutes max
            $waited = 0
            while ($waited -lt $maxWait) {
              Start-Sleep -Seconds 10
              $waited++
              $remaining = aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --query "VpnConnections[?State!='deleted'].VpnConnectionId" --output json 2>$null | ConvertFrom-Json
              if (-not $remaining -or $remaining.Count -eq 0) {
                Write-Host "  VPN connections deleted." -ForegroundColor DarkGray
                break
              }
              Write-Host "  Still waiting... ($($remaining.Count) remaining)" -ForegroundColor DarkGray
            }
          }

          # Delete Customer Gateways
          if ($cgws -and $cgws.Count -gt 0) {
            Write-Host "Deleting Customer Gateways..." -ForegroundColor Gray
            foreach ($cgwId in $cgws) {
              Write-Host "  Deleting: $cgwId" -ForegroundColor DarkGray
              aws ec2 delete-customer-gateway --customer-gateway-id $cgwId 2>$null
            }
          }

          # Detach and Delete VGW (with proper wait and retry)
          if ($vgws -and $vgws.Count -gt 0) {
            Write-Host "Deleting VPN Gateways..." -ForegroundColor Gray
            foreach ($vgwId in $vgws) {
              # Get VPC attachment and detach
              $vgwDetails = aws ec2 describe-vpn-gateways --vpn-gateway-ids $vgwId --output json 2>$null | ConvertFrom-Json
              if ($vgwDetails.VpnGateways[0].VpcAttachments) {
                foreach ($attachment in $vgwDetails.VpnGateways[0].VpcAttachments) {
                  if ($attachment.State -eq "attached") {
                    Write-Host "  Detaching VGW from VPC: $($attachment.VpcId)" -ForegroundColor DarkGray
                    aws ec2 detach-vpn-gateway --vpn-gateway-id $vgwId --vpc-id $attachment.VpcId 2>$null
                  }
                }
                # Wait for detachment to complete
                Write-Host "  Waiting for VGW detachment..." -ForegroundColor DarkGray
                $maxWait = 18  # 3 minutes max
                $waited = 0
                while ($waited -lt $maxWait) {
                  Start-Sleep -Seconds 10
                  $waited++
                  $vgwState = aws ec2 describe-vpn-gateways --vpn-gateway-ids $vgwId --query "VpnGateways[0].VpcAttachments[0].State" --output text 2>$null
                  if ($vgwState -eq "detached" -or [string]::IsNullOrEmpty($vgwState) -or $vgwState -eq "None") {
                    Write-Host "  VGW detached." -ForegroundColor DarkGray
                    break
                  }
                  Write-Host "  Still detaching... (state: $vgwState)" -ForegroundColor DarkGray
                }
              }

              # Delete VGW with retry
              Write-Host "  Deleting VGW: $vgwId" -ForegroundColor DarkGray
              $deleteAttempts = 0
              $maxAttempts = 6
              while ($deleteAttempts -lt $maxAttempts) {
                $deleteAttempts++
                aws ec2 delete-vpn-gateway --vpn-gateway-id $vgwId 2>$null
                Start-Sleep -Seconds 5
                $vgwExists = aws ec2 describe-vpn-gateways --vpn-gateway-ids $vgwId --query "VpnGateways[?State!='deleted'].VpnGatewayId" --output text 2>$null
                if ([string]::IsNullOrEmpty($vgwExists)) {
                  Write-Host "  VGW deleted." -ForegroundColor DarkGray
                  break
                }
                if ($deleteAttempts -lt $maxAttempts) {
                  Write-Host "  Retry $deleteAttempts/$maxAttempts..." -ForegroundColor DarkGray
                  Start-Sleep -Seconds 10
                }
              }
            }
          }

          # Delete VPC and associated resources
          if ($vpcs -and $vpcs.Count -gt 0) {
            Write-Host "Deleting VPCs and associated resources..." -ForegroundColor Gray
            foreach ($vpcId in $vpcs) {
              # Delete IGW
              $igws = aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpcId" --query "InternetGateways[].InternetGatewayId" --output json 2>$null | ConvertFrom-Json
              foreach ($igwId in $igws) {
                Write-Host "  Detaching and deleting IGW: $igwId" -ForegroundColor DarkGray
                aws ec2 detach-internet-gateway --internet-gateway-id $igwId --vpc-id $vpcId 2>$null
                aws ec2 delete-internet-gateway --internet-gateway-id $igwId 2>$null
              }

              # Delete subnets
              $subnets = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --query "Subnets[].SubnetId" --output json 2>$null | ConvertFrom-Json
              foreach ($subnetId in $subnets) {
                Write-Host "  Deleting subnet: $subnetId" -ForegroundColor DarkGray
                aws ec2 delete-subnet --subnet-id $subnetId 2>$null
              }

              # Delete route tables (except main)
              $rts = aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpcId" --query "RouteTables[?Associations[0].Main!=``true``].RouteTableId" --output json 2>$null | ConvertFrom-Json
              foreach ($rtId in $rts) {
                # Disassociate first
                $assocs = aws ec2 describe-route-tables --route-table-ids $rtId --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" --output json 2>$null | ConvertFrom-Json
                foreach ($assocId in $assocs) {
                  aws ec2 disassociate-route-table --association-id $assocId 2>$null
                }
                Write-Host "  Deleting route table: $rtId" -ForegroundColor DarkGray
                aws ec2 delete-route-table --route-table-id $rtId 2>$null
              }

              # Delete VPC
              Write-Host "  Deleting VPC: $vpcId" -ForegroundColor DarkGray
              aws ec2 delete-vpc --vpc-id $vpcId 2>$null
            }
          }

          $awsElapsed = Get-ElapsedTime -StartTime $awsStartTime
          Write-Host ""
          Write-Host "AWS resources deleted in $awsElapsed" -ForegroundColor Green
        }
      }
    }
  }
}

# ============================================
# Local Data Cleanup
# ============================================
Write-Host ""
Write-Host "==> Local Data Cleanup" -ForegroundColor Yellow

$dataDir = Join-Path $RepoRoot ".data\lab-003"
if (Test-Path $dataDir) {
  Write-Host "Cleaning up local data: $dataDir" -ForegroundColor Gray
  Remove-Item -Path $dataDir -Recurse -Force
}

# Optionally clean up logs
if (-not $KeepLogs) {
  $logsDir = Join-Path $LabRoot "logs"
  if (Test-Path $logsDir) {
    $logFiles = @(Get-ChildItem -Path $logsDir -Filter "lab-003-*.log" -ErrorAction SilentlyContinue)
    if ($logFiles -and $logFiles.Count -gt 0) {
      Write-Host "Cleaning up $($logFiles.Count) log file(s)..." -ForegroundColor Gray
      $logFiles | Remove-Item -Force
    }
  }
}

$totalElapsed = Get-ElapsedTime -StartTime $destroyStartTime

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "Cleanup complete!" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "Total cleanup time: $totalElapsed" -ForegroundColor Gray
Write-Host ""
