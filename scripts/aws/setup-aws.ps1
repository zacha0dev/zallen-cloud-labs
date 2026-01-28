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
$resolvedRegion = Require-AwsRegion -Region $Region
Require-AwsProfile -Profile $Profile
$identity = Get-AwsIdentity -Profile $Profile

Write-Host "Profile: $Profile" -ForegroundColor Green
Write-Host "Region:  $resolvedRegion" -ForegroundColor Green
Write-Host "Account: $($identity.Account)" -ForegroundColor Green
Write-Host "Arn:     $($identity.Arn)" -ForegroundColor DarkGray
