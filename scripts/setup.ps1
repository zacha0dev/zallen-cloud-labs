<#+
setup.ps1
Wrapper setup for Azure Labs with optional AWS checks.

Runs .packages/setup.ps1 (Azure tooling) then optionally runs
scripts/aws/setup-aws.ps1 (AWS CLI + auth).

If run interactively without -IncludeAWS or -AzureOnly, the script
will ask whether to include AWS setup.
#>

[CmdletBinding()]
param(
  [switch]$DoLogin,
  [switch]$UpgradeAz,
  [ValidateSet("lab","prod")]
  [string]$SubscriptionKey,
  [switch]$IncludeAWS,
  [switch]$AzureOnly,
  [string]$AwsProfile = "aws-labs",
  [string]$AwsRegion = "us-east-2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Clear-Host

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$PkgSetup = Join-Path $RepoRoot ".packages\setup.ps1"
$AwsPreflight = Join-Path $RepoRoot "scripts\aws\setup-aws.ps1"

# --- Azure tooling ---
if (-not (Test-Path $PkgSetup)) {
  throw "Missing setup script: $PkgSetup"
}

$pkgParams = @{
  DoLogin   = $DoLogin
  UpgradeAz = $UpgradeAz
}
if ($SubscriptionKey) { $pkgParams["SubscriptionKey"] = $SubscriptionKey }

& $PkgSetup @pkgParams

# --- AWS decision ---
$runAws = $IncludeAWS.IsPresent

if (-not $runAws -and -not $AzureOnly.IsPresent) {
  # Interactive prompt — only when neither flag was given
  $ans = Read-Host "Also set up AWS environment? (y/n)"
  $runAws = ($ans.Trim().ToLower() -eq "y")
}

if ($runAws) {
  if (-not (Test-Path $AwsPreflight)) {
    throw "Missing AWS setup script: $AwsPreflight"
  }

  $awsParams = @{
    Profile = $AwsProfile
    Region  = $AwsRegion
    DoLogin = $DoLogin
  }
  & $AwsPreflight @awsParams
} else {
  Write-Host ""
  Write-Host "AWS setup skipped." -ForegroundColor DarkGray
}
