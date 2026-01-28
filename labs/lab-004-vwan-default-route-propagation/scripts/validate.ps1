# labs/lab-004-vwan-default-route-propagation/scripts/validate.ps1
# Validates vWAN default route propagation by checking effective routes on each VM NIC

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Clear-Host

$LabRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..")
$ConfigPath = Join-Path $RepoRoot ".data\lab-004\config.json"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $name"
  }
}

function Require-ConfigField($obj, [string]$Name, [string]$Path) {
  if (-not $obj.PSObject.Properties[$Name] -or [string]::IsNullOrWhiteSpace("$($obj.$Name)")) {
    throw "Missing config value: $Path.$Name"
  }
  return $obj.$Name
}

function Test-HasDefaultRoute([array]$Routes) {
  # Check if 0.0.0.0/0 exists in effective routes
  foreach ($route in $Routes) {
    if ($route.addressPrefix -eq "0.0.0.0/0") {
      return $true
    }
  }
  return $false
}

function Get-EffectiveRoutes([string]$ResourceGroup, [string]$NicName) {
  $json = az network nic show-effective-route-table `
    --resource-group $ResourceGroup `
    --name $NicName `
    --output json 2>$null

  if ($LASTEXITCODE -ne 0 -or -not $json) {
    return @()
  }

  $result = $json | ConvertFrom-Json
  return $result.value
}

function Write-TestResult([string]$TestName, [bool]$Passed, [string]$Details) {
  if ($Passed) {
    Write-Host "[PASS] " -ForegroundColor Green -NoNewline
  } else {
    Write-Host "[FAIL] " -ForegroundColor Red -NoNewline
  }
  Write-Host "$TestName" -NoNewline
  if ($Details) {
    Write-Host " - $Details" -ForegroundColor Gray
  } else {
    Write-Host ""
  }
}

# Load config
if (-not (Test-Path $ConfigPath)) {
  throw "Config not found: $ConfigPath. Run deploy.ps1 first."
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$azure = $cfg.azure

$subscriptionId = Require-ConfigField $azure "subscriptionId" "azure"
$resourceGroup = Require-ConfigField $azure "resourceGroup" "azure"

Require-Command az

# Validate Azure auth
az account get-access-token 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI token expired or missing. Run: az login" }
& az account set --subscription $subscriptionId | Out-Null

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  vWAN Default Route Propagation Validation" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Expected behavior:" -ForegroundColor White
Write-Host "  - Spoke A1, A2: SHOULD have 0.0.0.0/0 (associated with rt-fw-default)" -ForegroundColor Gray
Write-Host "  - Spoke A3, A4: should NOT have 0.0.0.0/0 (associated with Default RT)" -ForegroundColor Gray
Write-Host "  - Spoke B1, B2: should NOT have 0.0.0.0/0 (Hub B, Default RT only)" -ForegroundColor Gray
Write-Host ""

# Define test cases
$tests = @(
  @{ Nic = "nic-vm-a1"; ExpectDefault = $true;  Label = "Spoke A1 (rt-fw-default)" }
  @{ Nic = "nic-vm-a2"; ExpectDefault = $true;  Label = "Spoke A2 (rt-fw-default)" }
  @{ Nic = "nic-vm-a3"; ExpectDefault = $false; Label = "Spoke A3 (Default RT)" }
  @{ Nic = "nic-vm-a4"; ExpectDefault = $false; Label = "Spoke A4 (Default RT)" }
  @{ Nic = "nic-vm-b1"; ExpectDefault = $false; Label = "Spoke B1 (Hub B, Default RT)" }
  @{ Nic = "nic-vm-b2"; ExpectDefault = $false; Label = "Spoke B2 (Hub B, Default RT)" }
)

$passCount = 0
$failCount = 0

Write-Host "Checking effective routes on each VM NIC..." -ForegroundColor Yellow
Write-Host "(This may take a minute)" -ForegroundColor DarkGray
Write-Host ""

foreach ($test in $tests) {
  $routes = Get-EffectiveRoutes -ResourceGroup $resourceGroup -NicName $test.Nic
  $hasDefault = Test-HasDefaultRoute -Routes $routes

  if ($test.ExpectDefault) {
    # Should have 0/0
    $passed = $hasDefault
    $details = if ($hasDefault) { "Has 0.0.0.0/0 route" } else { "Missing 0.0.0.0/0 route!" }
  } else {
    # Should NOT have 0/0
    $passed = -not $hasDefault
    $details = if ($hasDefault) { "Unexpected 0.0.0.0/0 route found!" } else { "No 0.0.0.0/0 route (correct)" }
  }

  Write-TestResult -TestName $test.Label -Passed $passed -Details $details

  if ($passed) { $passCount++ } else { $failCount++ }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Summary: $passCount passed, $failCount failed" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Additional diagnostic info
Write-Host "Hub Route Table Details:" -ForegroundColor Yellow
Write-Host ""

Write-Host "rt-fw-default routes:" -ForegroundColor White
az network vhub route-table show `
  --resource-group $resourceGroup `
  --vhub-name "vhub-a-lab-004" `
  --name "rt-fw-default" `
  --query "routes" `
  --output table 2>$null

Write-Host ""
Write-Host "Hub A connections:" -ForegroundColor White
az network vhub connection list `
  --resource-group $resourceGroup `
  --vhub-name "vhub-a-lab-004" `
  --query "[].{Name:name, AssociatedRT:routingConfiguration.associatedRouteTable.id}" `
  --output table 2>$null

Write-Host ""
Write-Host "What this lab demonstrates:" -ForegroundColor Cyan
Write-Host "  1. Static 0/0 in a custom RT propagates to VNets associated with that RT" -ForegroundColor Gray
Write-Host "  2. VNets on the Default route table do NOT learn 0/0 from custom RTs" -ForegroundColor Gray
Write-Host "  3. Hub-to-hub: Hub B spokes also do NOT learn 0/0 (stays in custom RT scope)" -ForegroundColor Gray
Write-Host ""

if ($failCount -gt 0) {
  Write-Host "Some tests failed. Check:" -ForegroundColor Yellow
  Write-Host "  - Allow 5-10 minutes after deployment for routes to propagate" -ForegroundColor Gray
  Write-Host "  - Verify VNet connection associations in Azure portal" -ForegroundColor Gray
  exit 1
}
