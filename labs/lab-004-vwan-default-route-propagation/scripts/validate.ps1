# labs/lab-004-vwan-default-route-propagation/scripts/validate.ps1
# Validates vWAN default route propagation by checking effective routes

[CmdletBinding()]
param(
  [ValidateSet("lab","prod")]
  [string]$SubscriptionKey = "lab"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..")

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

$ResourceGroup = "rg-lab-004-vwan-route-prop"

function Test-HasDefaultRoute([array]$Routes) {
  foreach ($route in $Routes) {
    if ($route.addressPrefix -eq "0.0.0.0/0") { return $true }
  }
  return $false
}

function Get-EffectiveRoutes([string]$NicName) {
  $json = az network nic show-effective-route-table `
    --resource-group $ResourceGroup --name $NicName --output json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $json) { return @() }
  return ($json | ConvertFrom-Json).value
}

# Setup
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
az account get-access-token 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI not authenticated. Run: az login" }
az account set --subscription $SubscriptionId | Out-Null

Write-Host ""
Write-Host "vWAN Default Route Propagation Validation" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Expected: A1/A2 have 0/0, A3/A4/B1/B2 do NOT" -ForegroundColor Gray
Write-Host ""

$tests = @(
  @{ Nic = "nic-vm-a1"; Expect = $true;  Label = "Spoke A1 (rt-fw-default)" }
  @{ Nic = "nic-vm-a2"; Expect = $true;  Label = "Spoke A2 (rt-fw-default)" }
  @{ Nic = "nic-vm-a3"; Expect = $false; Label = "Spoke A3 (Default RT)" }
  @{ Nic = "nic-vm-a4"; Expect = $false; Label = "Spoke A4 (Default RT)" }
  @{ Nic = "nic-vm-b1"; Expect = $false; Label = "Spoke B1 (Hub B)" }
  @{ Nic = "nic-vm-b2"; Expect = $false; Label = "Spoke B2 (Hub B)" }
)

$pass = 0; $fail = 0

foreach ($t in $tests) {
  $routes = Get-EffectiveRoutes $t.Nic
  $has00 = Test-HasDefaultRoute $routes
  $ok = ($t.Expect -eq $has00)

  if ($ok) {
    Write-Host "[PASS] " -ForegroundColor Green -NoNewline
    $pass++
  } else {
    Write-Host "[FAIL] " -ForegroundColor Red -NoNewline
    $fail++
  }

  $status = if ($has00) { "has 0/0" } else { "no 0/0" }
  Write-Host "$($t.Label) - $status"
}

Write-Host ""
Write-Host "Result: $pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })

if ($fail -gt 0) { exit 1 }
