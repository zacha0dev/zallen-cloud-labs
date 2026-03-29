<#
lab.ps1 - Azure Cloud Labs CLI

Single entry point for all lab operations. Wraps setup, deployment, cost
checking, and inspection tooling into one place for fast onboarding and
day-to-day lab management.

Usage:
  .\lab.ps1                              # Show help (default)
  .\lab.ps1 -Help                        # Show help
  .\lab.ps1 -Status                      # Environment status (CLI tools, auth, config)
  .\lab.ps1 -Login                       # Azure login (az login)
  .\lab.ps1 -Setup                       # Azure environment setup
  .\lab.ps1 -Setup -Aws                  # AWS environment setup (lab-003 only)
  .\lab.ps1 -List                        # List all labs with cost and cloud
  .\lab.ps1 -Deploy lab-001              # Deploy a lab
  .\lab.ps1 -Deploy lab-001 -Force       # Deploy without confirmation prompts
  .\lab.ps1 -Destroy lab-001             # Destroy a lab
  .\lab.ps1 -Inspect lab-001             # Run post-deploy inspection
  .\lab.ps1 -Cost                        # Scan for billable resources (all labs)
  .\lab.ps1 -Cost -Lab lab-003           # Cost check for a specific lab
  .\lab.ps1 -Cost -AwsProfile aws-labs   # Include AWS in cost check
#>

[CmdletBinding()]
param(
  # Action switches (pick one)
  [switch]$Help,
  [switch]$Status,
  [switch]$Login,
  [switch]$Setup,
  [switch]$List,
  [switch]$Deploy,
  [switch]$Destroy,
  [switch]$Inspect,
  [switch]$Cost,

  # Lab selector (used with -Deploy, -Destroy, -Inspect, -Cost)
  [string]$Lab,

  # Modifiers
  [switch]$Aws,                         # Modifier for -Setup; enables AWS toolchain
  [string]$SubscriptionKey,             # Passed through to deploy/destroy scripts
  [string]$Location,                    # Azure region, passed through to deploy
  [switch]$Force,                       # Skip confirmation prompts
  [string]$AwsProfile = "aws-labs"      # AWS CLI profile (used with -Cost)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:PYTHONWARNINGS = "ignore::UserWarning"

$RepoRoot = $PSScriptRoot

# =============================================================================
# Lab Catalog (embedded; update when new labs are added)
# =============================================================================

$LabCatalog = @{
  "lab-000" = @{ Desc = "Resource Group + VNet baseline";                Cost = "Free";       Cloud = "Azure";       CostPerHr = 0.00 }
  "lab-001" = @{ Desc = "vWAN hub routing";                              Cost = "~`$0.26/hr"; Cloud = "Azure";       CostPerHr = 0.26 }
  "lab-002" = @{ Desc = "App Gateway + Front Door (L7 LB)";             Cost = "~`$0.30/hr"; Cloud = "Azure";       CostPerHr = 0.30 }
  "lab-003" = @{ Desc = "vWAN to AWS VPN - BGP/APIPA";                  Cost = "~`$0.70/hr"; Cloud = "Azure + AWS"; CostPerHr = 0.70 }
  "lab-004" = @{ Desc = "vWAN default route propagation";               Cost = "~`$0.60/hr"; Cloud = "Azure";       CostPerHr = 0.60 }
  "lab-005" = @{ Desc = "vWAN S2S BGP/APIPA reference";                 Cost = "~`$0.61/hr"; Cloud = "Azure";       CostPerHr = 0.61 }
  "lab-006" = @{ Desc = "vWAN spoke BGP router + loopback";             Cost = "~`$0.37/hr"; Cloud = "Azure";       CostPerHr = 0.37 }
  "lab-007" = @{ Desc = "Azure Private DNS Zones + auto-registration";  Cost = "~`$0.02/hr"; Cloud = "Azure";       CostPerHr = 0.02 }
  "lab-008" = @{ Desc = "DNS Private Resolver + forwarding ruleset";    Cost = "~`$0.03/hr"; Cloud = "Azure";       CostPerHr = 0.03 }
  "lab-009" = @{ Desc = "AVNM dual-region hub-spoke + Global Mesh";    Cost = "~`$0.01/hr"; Cloud = "Azure";       CostPerHr = 0.01 }
}

# =============================================================================
# Helpers
# =============================================================================

function Write-Header([string]$Title) {
  Write-Host ""
  Write-Host $Title -ForegroundColor Cyan
  Write-Host ("-" * $Title.Length) -ForegroundColor Cyan
}

function Write-Step([string]$Msg) {
  Write-Host "  $Msg" -ForegroundColor Gray
}

function Write-Ok([string]$Msg) {
  Write-Host "  $Msg" -ForegroundColor Green
}

function Write-Warn([string]$Msg) {
  Write-Host "  $Msg" -ForegroundColor Yellow
}

function Write-Err([string]$Msg) {
  Write-Host "  $Msg" -ForegroundColor Red
}

function Resolve-LabDir {
  <#
  .SYNOPSIS
    Finds a lab directory by partial ID match (e.g. "lab-001").
    Returns full path, or $null if not found.
  #>
  param([string]$LabId)

  $labsDir = Join-Path $RepoRoot "labs"
  if (-not (Test-Path $labsDir)) {
    Write-Err "Labs directory not found: $labsDir"
    return $null
  }

  $candidates = @(Get-ChildItem -Path $labsDir -Directory |
    Where-Object { $_.Name -like "$LabId*" -or $_.Name -eq $LabId })

  if ($candidates.Count -eq 0) {
    Write-Err "Lab not found: $LabId"
    Write-Warn "Run: .\lab.ps1 -List   to see available labs"
    return $null
  }

  if ($candidates.Count -gt 1) {
    Write-Err "Ambiguous lab ID '$LabId' - matches $($candidates.Count) directories:"
    foreach ($c in $candidates) { Write-Warn "  $($c.Name)" }
    Write-Warn "Provide a more specific ID."
    return $null
  }

  return $candidates[0].FullName
}

function Resolve-Script {
  <#
  .SYNOPSIS
    Validates a script exists in the given lab directory.
  #>
  param([string]$LabDir, [string]$ScriptName)

  $path = Join-Path $LabDir $ScriptName
  if (-not (Test-Path $path)) {
    Write-Err "$ScriptName not found in $LabDir"
    return $null
  }
  return $path
}

function Get-NormalizedLabId {
  <#
  .SYNOPSIS
    Normalizes user input to "lab-NNN" format for catalog lookups.
    Accepts: "lab-001", "001", "1", "lab-001-some-name".
  #>
  param([string]$Input)

  if ($Input -match "^(lab-\d{3})") { return $Matches[1] }
  if ($Input -match "^(\d{1,3})$") {
    $n = [int]$Input
    return "lab-{0:D3}" -f $n
  }
  return $Input
}

function Discover-Labs {
  <#
  .SYNOPSIS
    Returns an ordered list of discovered lab directories.
  #>
  $labsDir = Join-Path $RepoRoot "labs"
  if (-not (Test-Path $labsDir)) { return @() }
  return @(Get-ChildItem -Path $labsDir -Directory |
    Where-Object { $_.Name -match "^lab-\d{3}" } |
    Sort-Object Name)
}

# =============================================================================
# Action: Help
# =============================================================================

function Show-Help {
  Write-Host ""
  Write-Host "Azure Cloud Labs CLI" -ForegroundColor Cyan
  Write-Host "====================" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "USAGE" -ForegroundColor White
  Write-Host "  .\lab.ps1 <action> [options]"
  Write-Host ""
  Write-Host "SETUP" -ForegroundColor White
  Write-Host "  -Status                     Check environment (CLI tools, auth, config)"
  Write-Host "  -Login                      Authenticate with Azure (az login)"
  Write-Host "  -Setup                      Full Azure environment setup"
  Write-Host "  -Setup -Aws                 AWS environment setup (lab-003 only)"
  Write-Host ""
  Write-Host "LABS" -ForegroundColor White
  Write-Host "  -List                       Show all labs with cost, cloud, and live status"
  Write-Host "  -Deploy <lab-id>            Deploy a lab (e.g. -Deploy lab-001)"
  Write-Host "  -Destroy <lab-id>           Tear down a lab cleanly"
  Write-Host "  -Inspect <lab-id>           Run post-deploy validation on a lab"
  Write-Host ""
  Write-Host "COST" -ForegroundColor White
  Write-Host "  -Cost                       Scan subscription for billable lab resources"
  Write-Host "  -Cost -Lab <lab-id>         Cost check for a specific lab only"
  Write-Host "  -Cost -AwsProfile <name>    Include AWS account in scan"
  Write-Host ""
  Write-Host "OPTIONS (for -Deploy / -Destroy)" -ForegroundColor White
  Write-Host "  -Lab <lab-id>               Lab identifier (e.g. lab-001, 001, or 1)"
  Write-Host "  -SubscriptionKey <key>      Subscription key from .data/subs.json"
  Write-Host "  -Location <region>          Azure region (e.g. eastus)"
  Write-Host "  -Force                      Skip DEPLOY confirmation prompt"
  Write-Host ""
  Write-Host "EXAMPLES" -ForegroundColor White
  Write-Host "  .\lab.ps1 -Setup                      # First-time Azure setup"
  Write-Host "  .\lab.ps1 -Status                     # Check everything is ready"
  Write-Host "  .\lab.ps1 -List                       # Browse available labs"
  Write-Host "  .\lab.ps1 -Deploy lab-000             # Start with the free baseline lab"
  Write-Host "  .\lab.ps1 -Deploy lab-001 -Force      # Deploy vWAN lab (skip prompt)"
  Write-Host "  .\lab.ps1 -Destroy lab-001            # Clean up after a lab session"
  Write-Host "  .\lab.ps1 -Cost                       # Check for leftover billable resources"
  Write-Host "  .\lab.ps1 -Cost -AwsProfile aws-labs  # Cost check including AWS"
  Write-Host ""
  Write-Host "RECOMMENDED RUN ORDER" -ForegroundColor DarkGray
  Write-Host "  lab-000 (free) -> lab-001 -> lab-006 -> lab-004/005 -> lab-002 -> lab-003 -> lab-007 -> lab-008 -> lab-009" -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  Always run -Destroy after each lab session to avoid charges." -ForegroundColor Yellow
  Write-Host ""
}

# =============================================================================
# Action: Status
# =============================================================================

function Invoke-Status {
  & (Join-Path $RepoRoot "setup.ps1") -Status
}

# =============================================================================
# Action: Login
# =============================================================================

function Invoke-Login {
  Write-Header "Azure Login"

  $hasAz = [bool](Get-Command "az" -ErrorAction SilentlyContinue)
  if (-not $hasAz) {
    Write-Err "Azure CLI (az) not found."
    Write-Warn "Run: .\lab.ps1 -Setup   to install and configure Azure CLI"
    exit 1
  }

  Write-Step "Running: az login"
  Write-Host ""
  az login
  $exitCode = $LASTEXITCODE
  Write-Host ""
  if ($exitCode -eq 0) {
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldEap
    if ($acct -and $acct.name) {
      Write-Ok "Authenticated: $($acct.user.name)"
      Write-Ok "Active subscription: $($acct.name)"
    } else {
      Write-Ok "Login completed."
    }
    Write-Host ""
    Write-Step "Next: .\lab.ps1 -Setup   (if first time) or .\lab.ps1 -Status"
  } else {
    Write-Err "Login failed. Run: az login"
    exit 1
  }
  Write-Host ""
}

# =============================================================================
# Action: Setup
# =============================================================================

function Invoke-Setup {
  $setupScript = Join-Path $RepoRoot "setup.ps1"
  if (-not (Test-Path $setupScript)) {
    Write-Err "setup.ps1 not found at repo root."
    exit 1
  }

  if ($Aws) {
    & $setupScript -Aws
  } else {
    & $setupScript -Azure
  }
}

# =============================================================================
# Action: List
# =============================================================================

function Get-DeployedLabKeys {
  <#
  .SYNOPSIS
    Returns a hashtable of lab keys (e.g. "lab-001") that have a live resource
    group in the current Azure subscription. Single az group list call for speed.
    Returns empty hashtable if az is not available or not authenticated.
  #>
  $result = @{}
  $hasAz = [bool](Get-Command "az" -ErrorAction SilentlyContinue)
  if (-not $hasAz) { return $result }

  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $rgJson = az group list --query "[?starts_with(name, 'rg-lab-')].[name]" -o tsv 2>$null
  $ErrorActionPreference = $oldEap

  if (-not $rgJson) { return $result }

  foreach ($rgName in ($rgJson -split "`n" | Where-Object { $_ -match "\S" })) {
    $rgName = $rgName.Trim()
    if ($rgName -match "rg-(lab-\d{3})") {
      $key = $Matches[1]
      $result[$key] = $true
    }
  }
  return $result
}

function Invoke-List {
  Write-Header "Available Labs"

  $discovered = Discover-Labs
  if ($discovered.Count -eq 0) {
    Write-Warn "No labs found in: $(Join-Path $RepoRoot 'labs')"
    return
  }

  # Probe Azure for live resource groups (one call, best-effort)
  Write-Host ""
  Write-Host "  Checking deployed status..." -ForegroundColor DarkGray
  $deployed = Get-DeployedLabKeys
  $liveCount = $deployed.Keys.Count

  Write-Host ""
  Write-Host ("  {0,-10}  {1,-46}  {2,-12}  {3,-14}  {4}" -f "Lab", "Description", "Est. Cost", "Cloud", "Status") -ForegroundColor White
  Write-Host ("  {0,-10}  {1,-46}  {2,-12}  {3,-14}  {4}" -f "---", "-----------", "---------", "-----", "------") -ForegroundColor DarkGray

  foreach ($labDir in $discovered) {
    $id = $labDir.Name

    $key = ""
    if ($id -match "^(lab-\d{3})") { $key = $Matches[1] }

    $desc  = ""
    $cost  = "?"
    $cloud = "Azure"
    $costPerHr = 0.0

    if ($key -and $LabCatalog.ContainsKey($key)) {
      $entry     = $LabCatalog[$key]
      $desc      = $entry.Desc
      $cost      = $entry.Cost
      $cloud     = $entry.Cloud
      $costPerHr = $entry.CostPerHr
    } else {
      $desc = ($id -replace "^lab-\d{3}[-_]?", "") -replace "[-_]", " "
    }

    if ($desc.Length -gt 46) { $desc = $desc.Substring(0, 43) + "..." }

    $isLive = $key -and $deployed.ContainsKey($key)

    $costColor = "White"
    if ($cost -eq "Free")                                        { $costColor = "Green" }
    elseif ($costPerHr -gt 0 -and $costPerHr -le 0.10)          { $costColor = "Green" }
    elseif ($costPerHr -gt 0.10 -and $costPerHr -le 0.45)       { $costColor = "Yellow" }
    elseif ($costPerHr -gt 0.45)                                 { $costColor = "Red" }

    # Status label + color
    $statusLabel = "-"
    $statusColor = "DarkGray"
    if ($isLive) {
      if ($cost -eq "Free") {
        $statusLabel = "LIVE"
        $statusColor = "Green"
      } elseif ($costPerHr -le 0.10) {
        $statusLabel = "LIVE (~$cost)"
        $statusColor = "Yellow"
      } else {
        $statusLabel = "LIVE (~$cost)"
        $statusColor = "Red"
      }
    }

    Write-Host -NoNewline ("  {0,-10}  {1,-46}  " -f $key, $desc)
    Write-Host -NoNewline ("{0,-12}" -f $cost) -ForegroundColor $costColor
    Write-Host -NoNewline ("  {0,-14}  " -f $cloud)
    Write-Host $statusLabel -ForegroundColor $statusColor
  }

  Write-Host ""
  if ($liveCount -gt 0) {
    Write-Host "  $liveCount lab(s) currently deployed - charges accruing." -ForegroundColor Yellow
    Write-Host "  Destroy when done:  .\lab.ps1 -Destroy <lab-id>" -ForegroundColor Yellow
    Write-Host "  Full cost scan:     .\lab.ps1 -Cost" -ForegroundColor DarkGray
  } else {
    Write-Host "  No labs currently deployed." -ForegroundColor DarkGray
    Write-Host "  Deploy a lab:  .\lab.ps1 -Deploy lab-000" -ForegroundColor DarkGray
  }
  Write-Host ""
}

# =============================================================================
# Action: Deploy
# =============================================================================

function Invoke-Deploy {
  param([string]$LabId)

  if (-not $LabId) {
    Write-Err "-Deploy requires a lab ID.  Example: .\lab.ps1 -Deploy lab-001"
    Write-Warn "Run: .\lab.ps1 -List   to see available labs"
    exit 1
  }

  $labDir = Resolve-LabDir -LabId $LabId
  if (-not $labDir) { exit 1 }

  $script = Resolve-Script -LabDir $labDir -ScriptName "deploy.ps1"
  if (-not $script) { exit 1 }

  $normalizedId = Get-NormalizedLabId -Input $LabId
  Write-Host ""
  Write-Host "Deploying $normalizedId" -ForegroundColor Cyan
  if ($LabCatalog.ContainsKey($normalizedId)) {
    $entry = $LabCatalog[$normalizedId]
    Write-Host "  $($entry.Desc)" -ForegroundColor Gray
    Write-Host "  Estimated cost: $($entry.Cost)  Cloud: $($entry.Cloud)" -ForegroundColor DarkGray
  }
  Write-Host ""

  # Build argument list dynamically (PS5.1-compatible splatting)
  $scriptArgs = @()
  if ($SubscriptionKey) { $scriptArgs += "-SubscriptionKey"; $scriptArgs += $SubscriptionKey }
  if ($Location)        { $scriptArgs += "-Location";        $scriptArgs += $Location }
  if ($Force)           { $scriptArgs += "-Force" }

  & $script @scriptArgs
  $exitCode = $LASTEXITCODE

  Write-Host ""
  if ($exitCode -eq 0) {
    Write-Host "  Deploy complete. When finished:" -ForegroundColor Green
    Write-Host "    Inspect:  .\lab.ps1 -Inspect $normalizedId" -ForegroundColor DarkGray
    Write-Host "    Destroy:  .\lab.ps1 -Destroy $normalizedId" -ForegroundColor DarkGray
    Write-Host "    Costs:    .\lab.ps1 -Cost" -ForegroundColor DarkGray
  } else {
    Write-Host "  Deploy exited with code $exitCode." -ForegroundColor Yellow
    Write-Host "  Check output above for errors. Cleanup: .\lab.ps1 -Destroy $normalizedId" -ForegroundColor DarkGray
  }
  Write-Host ""
  exit $exitCode
}

# =============================================================================
# Action: Destroy
# =============================================================================

function Invoke-Destroy {
  param([string]$LabId)

  if (-not $LabId) {
    Write-Err "-Destroy requires a lab ID.  Example: .\lab.ps1 -Destroy lab-001"
    Write-Warn "Run: .\lab.ps1 -List   to see available labs"
    exit 1
  }

  $labDir = Resolve-LabDir -LabId $LabId
  if (-not $labDir) { exit 1 }

  $script = Resolve-Script -LabDir $labDir -ScriptName "destroy.ps1"
  if (-not $script) { exit 1 }

  $normalizedId = Get-NormalizedLabId -Input $LabId
  Write-Host ""
  Write-Host "Destroying $normalizedId" -ForegroundColor Cyan
  Write-Host ""

  $scriptArgs = @()
  if ($SubscriptionKey) { $scriptArgs += "-SubscriptionKey"; $scriptArgs += $SubscriptionKey }
  if ($Force)           { $scriptArgs += "-Force" }

  & $script @scriptArgs
  $exitCode = $LASTEXITCODE

  Write-Host ""
  if ($exitCode -eq 0) {
    Write-Host "  Teardown complete. Verify no resources remain:" -ForegroundColor Green
    Write-Host "    .\lab.ps1 -Cost" -ForegroundColor DarkGray
  } else {
    Write-Host "  Destroy exited with code $exitCode. Check output above." -ForegroundColor Yellow
  }
  Write-Host ""
  exit $exitCode
}

# =============================================================================
# Action: Inspect
# =============================================================================

function Invoke-Inspect {
  param([string]$LabId)

  if (-not $LabId) {
    Write-Err "-Inspect requires a lab ID.  Example: .\lab.ps1 -Inspect lab-001"
    exit 1
  }

  $labDir = Resolve-LabDir -LabId $LabId
  if (-not $labDir) { exit 1 }

  $script = Resolve-Script -LabDir $labDir -ScriptName "inspect.ps1"
  if (-not $script) {
    Write-Warn "No inspect.ps1 for $LabId. Check the lab README for manual validation steps."
    exit 0
  }

  $normalizedId = Get-NormalizedLabId -Input $LabId
  Write-Host ""
  Write-Host "Inspecting $normalizedId" -ForegroundColor Cyan
  Write-Host ""

  $scriptArgs = @()
  if ($SubscriptionKey) { $scriptArgs += "-SubscriptionKey"; $scriptArgs += $SubscriptionKey }

  & $script @scriptArgs
  exit $LASTEXITCODE
}

# =============================================================================
# Action: Cost
# =============================================================================

function Invoke-Cost {
  $costScript = Join-Path $RepoRoot "tools" "cost-check.ps1"
  if (-not (Test-Path $costScript)) {
    Write-Err "cost-check.ps1 not found at tools/cost-check.ps1"
    exit 1
  }

  $scriptArgs = @()
  if ($Lab) {
    $normalizedId = Get-NormalizedLabId -Input $Lab
    $scriptArgs += "-Lab"; $scriptArgs += $normalizedId
  }
  if ($SubscriptionKey) { $scriptArgs += "-SubscriptionKey"; $scriptArgs += $SubscriptionKey }
  if ($AwsProfile -and $AwsProfile -ne "aws-labs") {
    $scriptArgs += "-AwsProfile"; $scriptArgs += $AwsProfile
  } elseif ($Aws) {
    $scriptArgs += "-AwsProfile"; $scriptArgs += $AwsProfile
  }

  & $costScript @scriptArgs
  exit $LASTEXITCODE
}

# =============================================================================
# MAIN - Dispatch
# =============================================================================

# Resolve -Lab as the positional lab identifier for actions that need it
# Allow: .\lab.ps1 -Deploy lab-001  OR  .\lab.ps1 -Deploy -Lab lab-001
$LabTarget = $Lab

# If no action switch is set, show help
$anyAction = $Help -or $Status -or $Login -or $Setup -or $List -or $Deploy -or $Destroy -or $Inspect -or $Cost
if (-not $anyAction) {
  Show-Help
  exit 0
}

if ($Help)    { Show-Help; exit 0 }
if ($Status)  { Invoke-Status; exit $LASTEXITCODE }
if ($Login)   { Invoke-Login }
if ($Setup)   { Invoke-Setup }
if ($List)    { Invoke-List }
if ($Deploy)  { Invoke-Deploy -LabId $LabTarget }
if ($Destroy) { Invoke-Destroy -LabId $LabTarget }
if ($Inspect) { Invoke-Inspect -LabId $LabTarget }
if ($Cost)    { Invoke-Cost }
