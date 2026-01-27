# labs/lab-000_resource-group/destroy.ps1
param(
  [string[]]$Subs,
  [string]$RgPrefix = "rg-azure-labs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $name"
  }
}

function RepoRoot-FromHere {
  return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Load-SubsConfig($repoRoot) {
  $path = Join-Path $repoRoot ".data\subs.json"
  if (Test-Path $path) {
    return (Get-Content $path -Raw | ConvertFrom-Json)
  }
  return $null
}

function Get-TargetSubs($cfg, [string[]]$subsArg) {
  if ($subsArg -and $subsArg.Count -gt 0) { return $subsArg }
  if ($cfg -and $cfg.default) { return @($cfg.default) }
  $id = (az account show --query id -o tsv 2>$null)
  if (-not $id) { throw "Not logged in. Run: az login" }
  return @($id)
}

function Normalize-SubId($cfg, [string]$token) {
  if ($token -match '^[0-9a-fA-F-]{36}$') { return $token }
  if ($cfg -and $cfg.subscriptions -and $cfg.subscriptions.$token -and $cfg.subscriptions.$token.id) {
    return $cfg.subscriptions.$token.id
  }
  return $token
}

Require-Command az

$repoRoot = RepoRoot-FromHere
$cfg = Load-SubsConfig $repoRoot
$targets = Get-TargetSubs $cfg $Subs

Write-Host ""
Write-Host "Lab-000 Destroy (delete RG)" -ForegroundColor Cyan
Write-Host ""

foreach ($t in $targets) {
  $subId = Normalize-SubId $cfg $t
  Write-Host "==> Target subscription: $t -> $subId" -ForegroundColor Yellow
  az account set --subscription $subId | Out-Null

  $subShort =
    if ($t -match '^sub\d+$') { $t }
    elseif ($subId -match '^[0-9a-fA-F-]{8}') { $subId.Substring(0,8) }
    else { "sub" }

  $rgName = "$RgPrefix-$subShort"

  Write-Host "    Deleting RG: $rgName"
  az group delete --name $rgName --yes --no-wait | Out-Null

  Write-Host "    [OK] Delete started (no-wait)" -ForegroundColor Green
  Write-Host ""
}

Write-Host "Done." -ForegroundColor Cyan
