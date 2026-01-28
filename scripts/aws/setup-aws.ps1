<#+
setup-aws.ps1
AWS setup checks for Azure Labs.
#>

[CmdletBinding()]
param(
  [string]$Profile = "aws-labs",
  [string]$Region
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Clear-Host

. (Join-Path $PSScriptRoot "aws-common.ps1")

Write-Host "AWS Setup" -ForegroundColor Cyan
Write-Host "---------" -ForegroundColor Cyan

Require-AwsCli

$awsVer = (aws --version 2>&1) | Out-String
Write-Host "AWS CLI: $($awsVer.Trim())" -ForegroundColor DarkGray

$resolvedRegion = Require-AwsRegion -Region $Region

# Show configured region from aws configure (informational)
try {
  $cfgRegion = (aws configure get region --profile $Profile 2>$null)
  if ($cfgRegion) {
    Write-Host "Config region (profile): $cfgRegion" -ForegroundColor DarkGray
  }
} catch { }

Require-AwsProfile -Profile $Profile
$identity = Get-AwsIdentity -Profile $Profile

Write-Host "Profile: $Profile" -ForegroundColor Green
Write-Host "Region:  $resolvedRegion" -ForegroundColor Green
Write-Host "Account: $($identity.Account)" -ForegroundColor Green
Write-Host "Arn:     $($identity.Arn)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "AWS setup OK." -ForegroundColor Green
exit 0
