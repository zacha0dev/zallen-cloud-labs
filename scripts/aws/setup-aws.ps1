<#+
setup-aws.ps1
AWS environment setup for Azure Labs.

Ensures:
- AWS CLI installed (via winget if needed)
- Named profile exists and is authenticated
- Region resolved
- Caller identity validated

Optional:
- -DoLogin  => attempts aws sso login / aws configure on auth failure
#>

[CmdletBinding()]
param(
  [string]$Profile = "aws-labs",
  [string]$Region,
  [switch]$DoLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Clear-Host

. (Join-Path $PSScriptRoot "aws-common.ps1")

Write-Host "AWS Setup" -ForegroundColor Cyan
Write-Host "---------" -ForegroundColor Cyan

# 1. Ensure AWS CLI is installed
Ensure-AwsCli

$awsVer = (aws --version 2>&1) | Out-String
Write-Host "AWS CLI: $($awsVer.Trim())" -ForegroundColor DarkGray

# 2. Resolve region (falls back to env vars, then default us-east-2)
$resolvedRegion = Require-AwsRegion -Region $Region

# Show configured region from aws configure (informational)
try {
  $cfgRegion = (aws configure get region --profile $Profile 2>$null)
  if ($cfgRegion) {
    Write-Host "Config region (profile): $cfgRegion" -ForegroundColor DarkGray
  }
} catch { }

# 3. Validate profile + auth (Ensure-AwsAuth handles missing profile,
#    expired SSO, and invalid IAM creds with granular guidance)
Ensure-AwsAuth -Profile $Profile -DoLogin:$DoLogin

$identity = Get-AwsIdentity -Profile $Profile

Write-Host "Profile: $Profile" -ForegroundColor Green
Write-Host "Region:  $resolvedRegion" -ForegroundColor Green
Write-Host "Account: $($identity.Account)" -ForegroundColor Green
Write-Host "Arn:     $($identity.Arn)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "AWS setup OK." -ForegroundColor Green
exit 0
