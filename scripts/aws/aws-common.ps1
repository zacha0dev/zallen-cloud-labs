<#+
Common AWS helper functions for Azure Labs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- constants ----------
$script:AwsDefaultRegion = "us-east-2"

# ---------- helpers ----------
function HasCmd([string]$name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Ensure-AwsCli {
  <# Installs the AWS CLI via winget if missing. #>
  if (HasCmd "aws") { return }

  Write-Host "AWS CLI not found. Attempting install via winget..." -ForegroundColor Yellow
  if (-not (HasCmd "winget")) {
    throw "AWS CLI not found and winget unavailable. Install manually: https://aws.amazon.com/cli/"
  }

  winget install --exact --id Amazon.AWSCLI --accept-package-agreements --accept-source-agreements
  # Refresh PATH so the current session can find aws
  $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
              [System.Environment]::GetEnvironmentVariable("PATH", "User")

  if (-not (HasCmd "aws")) {
    throw "AWS CLI installed but 'aws' not on PATH. Restart your terminal and re-run."
  }
  Write-Host "AWS CLI installed." -ForegroundColor Green
}

function Require-AwsCli {
  if (-not (HasCmd "aws")) {
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
    Write-Host "No AWS region specified. Defaulting to $script:AwsDefaultRegion." -ForegroundColor Yellow
    $resolved = $script:AwsDefaultRegion
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

function Test-AwsIdentity {
  <# Returns $true if the profile can call STS, $false otherwise. #>
  param([Parameter(Mandatory = $true)][string]$Profile)

  aws sts get-caller-identity --profile $Profile --output json 1>$null 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Clear-AwsCredentialCache {
  <# Removes local AWS CLI credential/SSO caches so a fresh login is required. #>
  $awsDir = Join-Path $env:USERPROFILE ".aws"
  $ssoCache = Join-Path $awsDir "sso" "cache"
  $cliCache = Join-Path $awsDir "cli" "cache"

  foreach ($dir in @($ssoCache, $cliCache)) {
    if (Test-Path $dir) {
      Remove-Item -Path (Join-Path $dir "*") -Force -ErrorAction SilentlyContinue
      Write-Host "Cleared: $dir" -ForegroundColor DarkGray
    }
  }
}

function Ensure-AwsAuth {
  <# Validates credentials for a profile; offers login/re-configure on failure. #>
  param(
    [Parameter(Mandatory = $true)][string]$Profile,
    [switch]$DoLogin
  )

  if (Test-AwsIdentity -Profile $Profile) { return }

  Write-Host "AWS credentials for profile '$Profile' are expired or invalid." -ForegroundColor Yellow

  if ($DoLogin) {
    Write-Host "Clearing stale credential caches..." -ForegroundColor Yellow
    Clear-AwsCredentialCache

    Write-Host "Attempting: aws sso login --profile $Profile" -ForegroundColor Yellow
    aws sso login --profile $Profile 2>$null
    if (Test-AwsIdentity -Profile $Profile) {
      Write-Host "AWS login succeeded." -ForegroundColor Green
      return
    }

    Write-Host "SSO login did not resolve credentials. Trying: aws configure --profile $Profile" -ForegroundColor Yellow
    Write-Host "(Enter your Access Key ID, Secret Access Key, region, and output format.)" -ForegroundColor Gray
    aws configure --profile $Profile
    if (Test-AwsIdentity -Profile $Profile) {
      Write-Host "AWS credentials configured." -ForegroundColor Green
      return
    }

    throw "AWS profile '$Profile' still not usable after login attempts."
  }

  throw "AWS profile '$Profile' not authenticated. Re-run with -DoLogin or run: aws sso login --profile $Profile"
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
