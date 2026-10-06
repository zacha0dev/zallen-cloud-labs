# labs/lab-011-vwan-p2s-s2s-firewall-split/scripts/lab-011-helpers.ps1
# Shared constants and helpers for lab-011 deploy / inspect / scenario / destroy.
# Dot-source AFTER scripts\labs-common.ps1.

$script:LabId          = "lab-011"
$script:ResourceGroup  = "rg-lab-011-vwan-fw-split"
$script:HubName        = "vhub-lab-011"
$script:S2sGwName      = "vpngw-lab-011"
$script:P2sGwName      = "p2sgw-lab-011"
$script:S2sConnName    = "conn-site-onprem"
$script:OnpremConnName = "cn-lab-011-onprem-to-vwan"
$script:FwConnName     = "conn-vnet-fw"
$script:HubFwName      = "afw-lab-011-hub"
$script:SpokeFwName    = "afw-lab-011-spoke"
$script:ClientVmName   = "vm-lab-011-client"
$script:OnpremVmName   = "vm-lab-011-onprem"
$script:AppVmName      = "vm-lab-011-app"
$script:WorkspaceName  = "law-lab-011"

$script:HubCidr     = "10.110.0.0/24"
$script:FwVnetCidr  = "10.111.0.0/24"
$script:AppCidr     = "10.112.0.0/24"
$script:OnpremCidr  = "10.120.0.0/24"
$script:P2sPool     = "172.16.110.0/24"
$script:AppVmIp     = "10.112.0.4"
$script:OnpremVmIp  = "10.120.0.68"

# Static routes this lab owns in the hub defaultRouteTable (scenario.ps1)
$script:LabRoutePrefix = "lab011-"
$script:NetApiVersion  = "2023-09-01"

function Write-Phase {
  param([int]$Number, [string]$Title)
  Write-Host ""
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host "PHASE $Number : $Title" -ForegroundColor Cyan
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host ""
}

function Write-Step {
  param([string]$Message)
  Write-Host "  --> $Message" -ForegroundColor White
}

function Write-SubStep {
  param([string]$Message)
  Write-Host "      $Message" -ForegroundColor DarkGray
}

function Write-Validation {
  param([string]$Check, [string]$Status, [string]$Details = "")
  # Status: PASS, FAIL, INFO, PENDING
  $color = "Gray"
  if ($Status -eq "PASS") { $color = "Green" }
  if ($Status -eq "FAIL") { $color = "Red" }
  if ($Status -eq "PENDING") { $color = "Yellow" }
  Write-Host ("  [{0}] {1}" -f $Status, $Check) -ForegroundColor $color
  if ($Details) {
    foreach ($line in ($Details -split "`n")) {
      Write-Host "         $line" -ForegroundColor DarkGray
    }
  }
}

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

function Get-LabDataDir {
  param([string]$RepoRoot)
  $dir = Join-Path (Join-Path $RepoRoot ".data") "lab-011"
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function Invoke-AzJson {
  <#
  .SYNOPSIS
    Runs an az command that may legitimately fail (show/list on something not
    there yet) and returns parsed JSON or $null. Never throws.
  #>
  param([Parameter(Mandatory)][string[]]$AzArgs)
  $result = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $raw = $null
  $raw = & az @AzArgs -o json 2>$null
  $code = $LASTEXITCODE
  $ErrorActionPreference = $oldEap
  if ($code -ne 0 -or -not $raw) { return $null }
  try { $result = ($raw -join "`n") | ConvertFrom-Json } catch { $result = $null }
  return $result
}

function Write-LfFile {
  # Bash on the VM rejects CRLF, and a Windows checkout may hand us CRLF templates.
  param([string]$Path, [string]$Content)
  $lf = $Content -replace "`r`n", "`n"
  [System.IO.File]::WriteAllText($Path, $lf, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-VmScript {
  <#
  .SYNOPSIS
    Sends a bash template from scripts\ to a VM with az vm run-command, after
    token replacement. Returns the cleaned stdout, or $null on failure.
    The script travels as an @file argument so no shell quoting is involved.
  #>
  param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][string]$TemplatePath,
    [hashtable]$Tokens = @{},
    [Parameter(Mandatory)][string]$WorkDir,
    [int]$MaxTries = 3
  )
  $content = Get-Content -Path $TemplatePath -Raw
  foreach ($k in $Tokens.Keys) { $content = $content.Replace($k, [string]$Tokens[$k]) }
  $tmp = Join-Path $WorkDir ("run-" + [System.IO.Path]::GetFileName($TemplatePath))
  Write-LfFile -Path $tmp -Content $content

  $cleanOut = $null
  for ($attempt = 1; $attempt -le $MaxTries; $attempt++) {
    if ($attempt -gt 1) { Start-Sleep -Seconds 30 }
    $res = Invoke-AzJson -AzArgs @("vm", "run-command", "invoke", "-g", $script:ResourceGroup, "-n", $VmName,
      "--command-id", "RunShellScript", "--scripts", "@$tmp")
    if (-not $res -or -not $res.value -or $res.value.Count -eq 0) { continue }
    $raw = [string]$res.value[0].message
    # First call on a new VM can return the extension's test.sh output instead
    if ($raw -match "This is a sample script") { continue }
    $cleanOut = ($raw -replace '\[stdout\]', '' -replace '\[stderr\]', '').Trim()
    break
  }
  Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
  return $cleanOut
}

function Get-Between {
  param([string]$Text, [string]$Begin, [string]$End)
  if (-not $Text) { return "" }
  $pattern = [regex]::Escape($Begin) + "(?s)(.*?)" + [regex]::Escape($End)
  $m = [regex]::Match($Text, $pattern)
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ""
}

function Get-KeyValue {
  param([string]$Text, [string]$Key)
  if (-not $Text) { return "" }
  $m = [regex]::Match($Text, "(?m)^" + [regex]::Escape($Key) + "=(.*)$")
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ""
}

function Get-HubRouteTableUrl {
  param([string]$SubscriptionId)
  return "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$($script:ResourceGroup)/providers/Microsoft.Network/virtualHubs/$($script:HubName)/hubRouteTables/defaultRouteTable?api-version=$($script:NetApiVersion)"
}

function Get-DefaultRouteTable {
  param([string]$SubscriptionId)
  return Invoke-AzJson -AzArgs @("rest", "--method", "get", "--url", (Get-HubRouteTableUrl -SubscriptionId $SubscriptionId))
}

function Get-HubStaticRoutes {
  # StrictMode-safe: the routes array is absent (not empty) on a fresh table
  param($RouteTable)
  if (-not $RouteTable) { return @() }
  if (-not ($RouteTable.PSObject.Properties.Name -contains "properties")) { return @() }
  $p = $RouteTable.properties
  if (-not ($p.PSObject.Properties.Name -contains "routes") -or -not $p.routes) { return @() }
  return @($p.routes)
}

function Get-ActiveScenario {
  <#
  .SYNOPSIS
    Reads the lab-owned static routes from defaultRouteTable and names the mode.
  #>
  param($RouteTable)
  $names = @()
  foreach ($r in (Get-HubStaticRoutes -RouteTable $RouteTable)) {
    if ($r.name -like "$($script:LabRoutePrefix)*") { $names += $r.name }
  }
  if ($names -contains "lab011-agg-to-hub-fw") { return "HubFwAggregate" }
  if ($names -contains "lab011-pool-to-hub-fw") { return "HubFwSymmetric" }
  if ($names -contains "lab011-app-to-hub-fw") { return "HubFwForP2S" }
  return "Baseline"
}
