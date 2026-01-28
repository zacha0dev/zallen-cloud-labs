<#+
setup.ps1
Wrapper setup for Azure Labs with optional AWS checks.
#>

[CmdletBinding()]
param(
  [switch]$DoLogin,
  [switch]$UpgradeAz,
  [ValidateSet("lab","prod")]
  [string]$SubscriptionKey,
  [switch]$IncludeAWS,
  [string]$AwsProfile = "aws-labs",
  [string]$AwsRegion = "us-east-2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Clear-Host

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$PkgSetup = Join-Path $RepoRoot ".packages\setup.ps1"
$AwsPreflight = Join-Path $RepoRoot "scripts\aws\setup-aws.ps1"

if (-not (Test-Path $PkgSetup)) {
  throw "Missing setup script: $PkgSetup"
}

& $PkgSetup @{
  DoLogin = $DoLogin
  UpgradeAz = $UpgradeAz
  SubscriptionKey = $SubscriptionKey
}

if ($IncludeAWS) {
  if (-not (Test-Path $AwsPreflight)) {
    throw "Missing AWS setup script: $AwsPreflight"
  }

  & $AwsPreflight @{
    Profile = $AwsProfile
    Region = $AwsRegion
  }
} else {
  Write-Host ""
  Write-Host "AWS setup skipped (Azure-only mode)." -ForegroundColor DarkGray
}
