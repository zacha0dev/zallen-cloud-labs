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
  <# Validates credentials for a profile with granular diagnostics.
     Detects: missing profile, no SSO config, expired token, generic failure.
     Prints the exact next-step command for each case. #>
  param(
    [Parameter(Mandatory = $true)][string]$Profile,
    [switch]$DoLogin
  )

  # --- fast path: already authenticated ---
  if (Test-AwsIdentity -Profile $Profile) { return }

  # --- diagnose the specific failure ---
  $profiles = @()
  try { $profiles = @(aws configure list-profiles 2>$null) } catch { $profiles = @() }

  $profileExists = ($profiles.Count -gt 0 -and ($profiles -contains $Profile))

  if (-not $profileExists) {
    # Case 1: profile does not exist at all
    Write-Host "" -ForegroundColor Yellow
    Write-Host "AWS profile '$Profile' does not exist." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Next step:" -ForegroundColor White
    Write-Host "  aws configure sso --profile $Profile" -ForegroundColor Cyan
    Write-Host "" -ForegroundColor Gray
    Write-Host "(Or for IAM access keys: aws configure --profile $Profile)" -ForegroundColor Gray

    if ($DoLogin) {
      Write-Host ""
      Write-Host "Running: aws configure sso --profile $Profile" -ForegroundColor Yellow
      aws configure sso --profile $Profile
      if (Test-AwsIdentity -Profile $Profile) {
        Write-Host "AWS profile configured and authenticated." -ForegroundColor Green
        return
      }
      # fall back to basic configure
      Write-Host "SSO configure did not complete. Trying basic configure..." -ForegroundColor Yellow
      aws configure --profile $Profile
      if (Test-AwsIdentity -Profile $Profile) {
        Write-Host "AWS profile configured." -ForegroundColor Green
        return
      }
    }
    throw "AWS profile '$Profile' not configured. See the commands above."
  }

  # Profile exists — check if SSO is configured
  $ssoStartUrl = $null
  try { $ssoStartUrl = (aws configure get sso_start_url --profile $Profile 2>$null) } catch { }
  $hasSso = (-not [string]::IsNullOrWhiteSpace($ssoStartUrl))

  if ($hasSso) {
    # Case 2: SSO configured but token expired / not logged in
    Write-Host "" -ForegroundColor Yellow
    Write-Host "AWS profile '$Profile' is configured (SSO) but not authenticated." -ForegroundColor Yellow
    Write-Host "The SSO session has likely expired." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor White
    Write-Host "Next step:" -ForegroundColor White
    Write-Host "  aws sso login --profile $Profile" -ForegroundColor Cyan

    if ($DoLogin) {
      Write-Host ""
      Write-Host "Clearing stale SSO caches..." -ForegroundColor DarkGray
      Clear-AwsCredentialCache
      Write-Host "Running: aws sso login --profile $Profile" -ForegroundColor Yellow
      aws sso login --profile $Profile
      if (Test-AwsIdentity -Profile $Profile) {
        Write-Host "AWS SSO login succeeded." -ForegroundColor Green
        return
      }
    }
    throw "AWS profile '$Profile' SSO login required. Run: aws sso login --profile $Profile"
  }

  # Case 3: IAM / static credentials configured but invalid
  Write-Host "" -ForegroundColor Yellow
  Write-Host "AWS profile '$Profile' exists but credentials are invalid or expired." -ForegroundColor Yellow
  Write-Host "" -ForegroundColor White
  Write-Host "Next step (pick one):" -ForegroundColor White
  Write-Host "  aws configure sso --profile $Profile    # recommended (browser login)" -ForegroundColor Cyan
  Write-Host "  aws configure --profile $Profile         # IAM access key" -ForegroundColor Cyan

  if ($DoLogin) {
    Write-Host ""
    Write-Host "Clearing stale credential caches..." -ForegroundColor DarkGray
    Clear-AwsCredentialCache
    Write-Host "Running: aws configure --profile $Profile" -ForegroundColor Yellow
    aws configure --profile $Profile
    if (Test-AwsIdentity -Profile $Profile) {
      Write-Host "AWS credentials configured." -ForegroundColor Green
      return
    }
  }
  throw "AWS profile '$Profile' not authenticated. See the commands above."
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
