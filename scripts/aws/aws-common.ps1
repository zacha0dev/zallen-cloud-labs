<#+
Common AWS helper functions for Azure Labs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-AwsCli {
  if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "AWS CLI not found. Install with: winget install Amazon.AWSCLI"
  }
}

function Require-AwsProfile {
  param([Parameter(Mandatory = $true)][string]$Profile)

  $profiles = @()
  try {
    $profiles = @(aws configure list-profiles 2>$null)
  } catch {
    $profiles = @()
  }

  if ($profiles.Count -gt 0 -and -not ($profiles -contains $Profile)) {
    throw "AWS profile '$Profile' not found. Run: aws configure --profile $Profile"
  }
}

function Require-AwsRegion {
  param([string]$Region)

  $resolved = $Region
  if (-not $resolved) { $resolved = $env:AWS_REGION }
  if (-not $resolved) { $resolved = $env:AWS_DEFAULT_REGION }

  if (-not $resolved) {
    throw "AWS region not set. Set AWS_REGION/AWS_DEFAULT_REGION or pass -Region <region>."
  }

  return $resolved
}

function Get-AwsIdentity {
  param([Parameter(Mandatory = $true)][string]$Profile)

  $json = aws sts get-caller-identity --profile $Profile --output json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $json) {
    throw "AWS profile '$Profile' is not usable. Run: aws configure --profile $Profile"
  }

  return ($json | ConvertFrom-Json)
}

function Confirm-AwsBudgetWarning {
  param(
    [string]$Message = "This lab creates billable AWS resources. Review costs before continuing.",
    [switch]$Force
  )

  if ($Force) { return }

  Write-Host "";
  Write-Host $Message -ForegroundColor Yellow
  $confirm = Read-Host "Type CONTINUE to proceed"
  if ($confirm -ne "CONTINUE") {
    throw "User cancelled."
  }
}
