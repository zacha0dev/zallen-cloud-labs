# labs/lab-000_resource-group/deploy.ps1
param(
  [string[]]$Subs,

  [string]$Location = "centralus",
  [string]$RgPrefix = "rg-azure-labs",
  [string]$VnetPrefix = "vnet-azure-labs",

  [string]$VnetCidr    = "10.50.0.0/16",
  [string]$Subnet1Cidr = "10.50.1.0/24",
  [string]$Subnet2Cidr = "10.50.2.0/24"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Missing required command: $name" }
}

function RepoRoot-FromHere {
  (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Load-Json($path) {
  if (Test-Path $path) { return (Get-Content $path -Raw | ConvertFrom-Json) }
  return $null
}

function Apply-Config {
  param([pscustomobject]$cfg)

  if (-not $cfg) { return }

  if (-not $PSBoundParameters.ContainsKey("Location") -and $cfg.location) { $script:Location = $cfg.location }
  if (-not $PSBoundParameters.ContainsKey("RgPrefix") -and $cfg.rgPrefix) { $script:RgPrefix = $cfg.rgPrefix }
  if (-not $PSBoundParameters.ContainsKey("VnetPrefix") -and $cfg.vnetPrefix) { $script:VnetPrefix = $cfg.vnetPrefix }

  if (-not $PSBoundParameters.ContainsKey("VnetCidr") -and $cfg.vnetCidr) { $script:VnetCidr = $cfg.vnetCidr }
  if (-not $PSBoundParameters.ContainsKey("Subnet1Cidr") -and $cfg.subnet1Cidr) { $script:Subnet1Cidr = $cfg.subnet1Cidr }
  if (-not $PSBoundParameters.ContainsKey("Subnet2Cidr") -and $cfg.subnet2Cidr) { $script:Subnet2Cidr = $cfg.subnet2Cidr }

  if (-not $PSBoundParameters.ContainsKey("Subs") -and $cfg.subs) { $script:Subs = @($cfg.subs) }
}

function Normalize-SubId($subsCfg, [string]$token) {
  if ($token -match '^[0-9a-fA-F-]{36}$') { return $token }
  if ($subsCfg -and $subsCfg.subscriptions -and $subsCfg.subscriptions.$token -and $subsCfg.subscriptions.$token.id) {
    return $subsCfg.subscriptions.$token.id
  }
  return $token
}

Require-Command az

$repoRoot = RepoRoot-FromHere

# Optional per-lab local config (ignored) + example config (tracked)
$labCfg = Load-Json (Join-Path $PSScriptRoot "lab.config.json")
if (-not $labCfg) { $labCfg = Load-Json (Join-Path $PSScriptRoot "lab.config.example.json") }
Apply-Config $labCfg

# Global subs config (ignored)
$subsCfg = Load-Json (Join-Path $repoRoot ".data\subs.json")

# Determine targets
if (-not $Subs -or $Subs.Count -eq 0) {
  if ($subsCfg -and $subsCfg.default) {
    $Subs = @($subsCfg.default)
  } else {
    $id = (az account show --query id -o tsv 2>$null)
    if (-not $id) { throw "Not logged in. Run: az login" }
    $Subs = @($id)
  }
}

Write-Host ""
Write-Host "Lab-000 Deploy (RG + VNet)" -ForegroundColor Cyan
Write-Host "Location: $Location"
Write-Host ""

foreach ($t in $Subs) {
  $subId = Normalize-SubId $subsCfg $t
  Write-Host "==> Target subscription: $t -> $subId" -ForegroundColor Yellow
  az account set --subscription $subId | Out-Null

  $subName = (az account show --query name -o tsv)

  $subShort =
    if ($t -match '^sub\d+$') { $t }
    elseif ($subId -match '^[0-9a-fA-F-]{8}') { $subId.Substring(0,8) }
    else { "sub" }

  $rgName   = "$RgPrefix-$subShort"
  $vnetName = "$VnetPrefix-$subShort"

  Write-Host "    RG:   $rgName"
  Write-Host "    VNet: $vnetName"

  az group create `
    --name $rgName `
    --location $Location `
    --tags owner="$env:USERNAME" project="azure-labs" lab="lab-000" ttlHours="8" `
    | Out-Null

  az network vnet create `
    --resource-group $rgName `
    --name $vnetName `
    --location $Location `
    --address-prefixes $VnetCidr `
    --subnet-name "snet-01" `
    --subnet-prefixes $Subnet1Cidr `
    | Out-Null

  $snet2Exists = (az network vnet subnet show `
    --resource-group $rgName `
    --vnet-name $vnetName `
    --name "snet-02" `
    --query "name" -o tsv 2>$null)

  if (-not $snet2Exists) {
    az network vnet subnet create `
      --resource-group $rgName `
      --vnet-name $vnetName `
      --name "snet-02" `
      --address-prefixes $Subnet2Cidr `
      | Out-Null
  }

  Write-Host "    [OK] Deployed for: $subName" -ForegroundColor Green
  Write-Host ""
}

Write-Host "Done." -ForegroundColor Cyan
