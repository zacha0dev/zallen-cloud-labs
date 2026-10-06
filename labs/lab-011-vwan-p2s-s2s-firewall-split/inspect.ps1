# labs/lab-011-vwan-p2s-s2s-firewall-split/inspect.ps1
# Measures lab-011 in whatever scenario is active (Baseline / HubFwForP2S /
# HubFwSymmetric). Control plane, P2S client routes, data plane, and firewall
# logs that show WHICH firewall each branch's traffic crossed.
#
# Changes nothing in Azure. It does (re)connect the OpenVPN client on the test
# VM and send pings / TCP probes between lab VMs.

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [int]$LogWaitMinutes = 12,
  [switch]$SkipDataPlane,
  [switch]$NoBanner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
. (Join-Path (Join-Path $RepoRoot "scripts") "labs-common.ps1")
. (Join-Path (Join-Path $LabRoot "scripts") "lab-011-helpers.ps1")
$ScriptsDir = Join-Path $LabRoot "scripts"

$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
$DataDir = Get-LabDataDir -RepoRoot $RepoRoot

if (-not $NoBanner) {
  Write-Host ""
  Write-Host ("=" * 60) -ForegroundColor Magenta
  Write-Host "  Lab 011 inspect: who carries S2S and P2S to the app?" -ForegroundColor Magenta
  Write-Host ("=" * 60) -ForegroundColor Magenta
}

$rg = Invoke-AzJson -AzArgs @("group", "show", "-n", $script:ResourceGroup)
if (-not $rg) {
  Write-Host "Resource group $($script:ResourceGroup) not found. Deploy first: .\lab.ps1 -Deploy lab-011" -ForegroundColor Yellow
  exit 1
}

$results = [ordered]@{}
function Add-Result {
  param([string]$Key, [string]$Status, [string]$Details)
  $results[$Key] = [ordered]@{ status = $Status; details = $Details }
  Write-Validation -Check $Key -Status $Status -Details $Details
}

function Get-Prop {
  # StrictMode-safe property read: returns $null when the property is absent
  param($Obj, [string]$Name)
  if ($null -eq $Obj) { return $null }
  if ($Obj.PSObject.Properties.Name -contains $Name) { return $Obj.$Name }
  return $null
}

function ConvertTo-UInt32Ip {
  param([string]$Ip)
  $b = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
  return ([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor [uint32]$b[3]
}

function Test-PrefixCovers {
  # True when $Outer (a.b.c.d/n) contains all of $Inner (a.b.c.d/m)
  param([string]$Outer, [string]$Inner)
  $o = $Outer -split "/"; $i = $Inner -split "/"
  if ($o.Count -ne 2 -or $i.Count -ne 2) { return $false }
  $oLen = [int]$o[1]; $iLen = [int]$i[1]
  if ($oLen -gt $iLen) { return $false }
  if ($oLen -eq 0) { return $true }
  # 0xFFFFFFFF is a signed -1 in PowerShell; build the mask arithmetically
  $mask = [uint32]([int64]4294967296 - [int64][math]::Pow(2, 32 - $oLen))
  return (((ConvertTo-UInt32Ip $o[0]) -band $mask) -eq ((ConvertTo-UInt32Ip $i[0]) -band $mask))
}

function Get-LastSegment {
  param([string]$Id)
  if (-not $Id) { return "" }
  return ($Id.TrimEnd("/") -split "/")[-1]
}

# =============================================================================
# 1. Scenario + branch association
# =============================================================================
Write-Phase -Number 1 -Title "Scenario and branch association"

$rt = Get-DefaultRouteTable -SubscriptionId $SubscriptionId
$scenario = Get-ActiveScenario -RouteTable $rt
$results["scenario"] = $scenario
Write-Host "  Active scenario: $scenario" -ForegroundColor Cyan
$staticRoutes = @(Get-HubStaticRoutes -RouteTable $rt)
if ($staticRoutes.Count -eq 0) {
  Write-SubStep "defaultRouteTable static routes: (none)"
} else {
  foreach ($r in $staticRoutes) {
    Write-SubStep ("defaultRouteTable static: {0} {1} -> {2}" -f $r.name, ($r.destinations -join ","), (Get-LastSegment $r.nextHop))
  }
}
$defaultRtId = ""
if ($rt) { $defaultRtId = $rt.id }

$s2sConn = Invoke-AzJson -AzArgs @("network", "vpn-gateway", "connection", "show", "-g", $script:ResourceGroup,
  "--gateway-name", $script:S2sGwName, "-n", $script:S2sConnName)
$p2sGw = Invoke-AzJson -AzArgs @("network", "p2s-vpn-gateway", "show", "-g", $script:ResourceGroup, "-n", $script:P2sGwName)

$s2sAssoc = ""
if ($s2sConn) { $s2sAssoc = Get-LastSegment $s2sConn.routingConfiguration.associatedRouteTable.id }
$p2sAssoc = ""
if ($p2sGw -and $p2sGw.p2SConnectionConfigurations) {
  $p2sAssoc = Get-LastSegment $p2sGw.p2SConnectionConfigurations[0].routingConfiguration.associatedRouteTable.id
}
$bothDefault = ($s2sAssoc -eq "defaultRouteTable" -and $p2sAssoc -eq "defaultRouteTable")
$st = "FAIL"; if ($bothDefault) { $st = "PASS" }
Add-Result -Key "S2S and P2S both associated with defaultRouteTable" -Status $st `
  -Details "S2S: $s2sAssoc | P2S: $p2sAssoc  (same table = same destination lookup for both branches)"

$fwConn = Invoke-AzJson -AzArgs @("network", "vhub", "connection", "show", "-g", $script:ResourceGroup,
  "--vhub-name", $script:HubName, "-n", $script:FwConnName)
$staticOnConn = ""
$propagateFlag = "n/a"
if ($fwConn) {
  $vr = Get-Prop $fwConn.routingConfiguration "vnetRoutes"
  if ($vr) {
    foreach ($s in @(Get-Prop $vr "staticRoutes")) {
      if ($s) { $staticOnConn += ("{0} {1} -> {2}; " -f $s.name, ($s.addressPrefixes -join ","), $s.nextHopIpAddress) }
    }
    $cfg = Get-Prop $vr "staticRoutesConfig"
    if ($cfg) { $propagateFlag = [string](Get-Prop $cfg "propagateStaticRoutes") }
  }
}
$st = "FAIL"; if ($staticOnConn) { $st = "PASS" }
Add-Result -Key "conn-vnet-fw carries the static route to the spoke firewall" -Status $st `
  -Details "$staticOnConn propagateStaticRoutes=$propagateFlag"

# =============================================================================
# 2. Hub effective routes (defaultRouteTable)
# =============================================================================
Write-Phase -Number 2 -Title "Hub defaultRouteTable effective routes"

$eff = $null
if ($defaultRtId) {
  $eff = Invoke-AzJson -AzArgs @("network", "vhub", "get-effective-routes", "-g", $script:ResourceGroup,
    "-n", $script:HubName, "--resource-type", "RouteTable", "--resource-id", $defaultRtId)
}
$effRoutes = @()
if ($eff) {
  $v = Get-Prop $eff "value"
  if ($v) { $effRoutes = @($v) } elseif ($eff -is [array]) { $effRoutes = @($eff) }
}
foreach ($e in $effRoutes) {
  $hops = @(Get-Prop $e "nextHops") | ForEach-Object { Get-LastSegment $_ }
  Write-SubStep ("{0,-20} {1,-28} {2,-26} origin={3}" -f (($e.addressPrefixes) -join ","), $e.nextHopType, ($hops -join ","), (Get-LastSegment (Get-Prop $e "routeOrigin")))
}
Write-Host ""

function Find-EffRoute {
  param([string]$Prefix)
  foreach ($e in $effRoutes) { if (@($e.addressPrefixes) -contains $Prefix) { return $e } }
  return $null
}

$appRoute = Find-EffRoute -Prefix $script:AppCidr
$appHopType = ""; $appHop = ""
if ($appRoute) { $appHopType = $appRoute.nextHopType; $appHop = (@($appRoute.nextHops) | ForEach-Object { Get-LastSegment $_ }) -join "," }
# Same-prefix Default static route beats the propagated VNet-connection route;
# a broader aggregate should not (longest prefix match comes first).
$expectedHop = $script:FwConnName
if ($scenario -eq "HubFwForP2S" -or $scenario -eq "HubFwSymmetric") { $expectedHop = $script:HubFwName }
$st = "FAIL"; if ($appHop -match [regex]::Escape($expectedHop)) { $st = "PASS" }
Add-Result -Key "Default RT: $($script:AppCidr) next hop is $expectedHop" -Status $st -Details "observed: $appHopType $appHop"

if ($scenario -eq "HubFwAggregate") {
  $agg = Find-EffRoute -Prefix "10.0.0.0/8"
  $st = "FAIL"; $d = "10.0.0.0/8 not in effective routes"
  if ($agg) { $d = "$($agg.nextHopType) " + ((@($agg.nextHops) | ForEach-Object { Get-LastSegment $_ }) -join ","); if ($d -match [regex]::Escape($script:HubFwName)) { $st = "PASS" } }
  Add-Result -Key "Default RT: aggregate 10.0.0.0/8 next hop is $($script:HubFwName)" -Status $st -Details $d
}
foreach ($p in @($script:OnpremCidr, $script:P2sPool)) {
  $r = Find-EffRoute -Prefix $p
  $st = "FAIL"; $d = "missing"
  if ($r) { $st = "PASS"; $d = "$($r.nextHopType) " + ((@($r.nextHops) | ForEach-Object { Get-LastSegment $_ }) -join ",") }
  Add-Result -Key "Default RT has $p" -Status $st -Details $d
}

# =============================================================================
# 3. What the on-prem side learned over S2S BGP
# =============================================================================
Write-Phase -Number 3 -Title "On-prem VM effective routes (learned over S2S)"
$nicRoutes = Invoke-AzJson -AzArgs @("network", "nic", "show-effective-route-table", "-g", $script:ResourceGroup,
  "-n", "nic-$($script:OnpremVmName)")
$onpremList = @()
if ($nicRoutes) { $onpremList = @(Get-Prop $nicRoutes "value") }
foreach ($p in @($script:AppCidr, $script:P2sPool, $script:HubCidr)) {
  $hit = $null
  foreach ($r in $onpremList) {
    if ($r -and $r.nextHopType -eq "VirtualNetworkGateway") {
      foreach ($ap in @($r.addressPrefix)) { if ($ap -and (Test-PrefixCovers -Outer $ap -Inner $p)) { $hit = $ap } }
    }
  }
  $st = "FAIL"; $d = "no VirtualNetworkGateway route covers it"
  if ($hit) { $st = "PASS"; $d = "via VirtualNetworkGateway ($hit)" }
  Add-Result -Key "On-prem learned $p" -Status $st -Details $d
}

# =============================================================================
# 4. P2S client: connect and read pushed routes
# =============================================================================
Write-Phase -Number 4 -Title "P2S client routes (OpenVPN on $($script:ClientVmName))"
$clientRoutes = @()
$tunnelUp = $false
$vpnProfile = Invoke-AzJson -AzArgs @("network", "p2s-vpn-gateway", "vpn-client", "generate", "-g", $script:ResourceGroup,
  "-n", $script:P2sGwName, "--authentication-method", "EAPTLS")
$profileUrl = ""
if ($vpnProfile) { $profileUrl = [string](Get-Prop $vpnProfile "profileUrl") }
if (-not $profileUrl) {
  Add-Result -Key "P2S profile generated" -Status "FAIL" -Details "az network p2s-vpn-gateway vpn-client generate returned no profileUrl"
} else {
  $urlB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($profileUrl))
  $p2sOut = Invoke-VmScript -VmName $script:ClientVmName -TemplatePath (Join-Path $ScriptsDir "p2s-connect.sh") `
    -Tokens @{ "__PROFILE_URL_B64__" = $urlB64 } -WorkDir $DataDir
  $tunnelUp = ((Get-KeyValue -Text $p2sOut -Key "TUNNEL") -eq "UP")
  $st = "FAIL"; if ($tunnelUp) { $st = "PASS" }
  Add-Result -Key "P2S tunnel up" -Status $st -Details ("tun0 " + (Get-KeyValue -Text $p2sOut -Key "TUN_ADDR"))
  if (-not $tunnelUp -and $p2sOut) { Write-SubStep ($p2sOut -split "`n" | Select-Object -Last 15 | Out-String) }

  $push = Get-Between -Text $p2sOut -Begin "PUSH_BEGIN" -End "PUSH_END"
  Write-SubStep "Gateway PUSH_REPLY: $push"
  $profileLines = Get-Between -Text $p2sOut -Begin "PROFILE_LINES_BEGIN" -End "PROFILE_LINES_END"
  if ($profileLines) { Write-SubStep "Route lines inside the downloaded profile:`n$profileLines" }
  $results["p2sPushReply"] = $push

  $routeText = Get-Between -Text $p2sOut -Begin "TUN_ROUTES_BEGIN" -End "TUN_ROUTES_END"
  foreach ($line in ($routeText -split "`n")) {
    $m = [regex]::Match($line, "^(\d+\.\d+\.\d+\.\d+/\d+)")
    if ($m.Success) { $clientRoutes += $m.Groups[1].Value }
  }
  Write-SubStep ("Kernel routes on tun0: " + ($clientRoutes -join ", "))
}
foreach ($p in @($script:AppCidr, $script:FwVnetCidr, $script:HubCidr, $script:OnpremCidr)) {
  $cover = ""
  foreach ($cr in $clientRoutes) { if (Test-PrefixCovers -Outer $cr -Inner $p) { $cover = $cr } }
  $st = "FAIL"; $d = "no tun0 route covers it"
  if ($cover) { $st = "PASS"; $d = "tun0 route $cover" }
  Add-Result -Key "P2S client has a route for $p" -Status $st -Details $d
}

# =============================================================================
# 5. Data plane + firewall logs
# =============================================================================
$probeStartUtc = (Get-Date).ToUniversalTime().AddMinutes(-1)
$s2sTcp = $false; $p2sTcp = $false
if (-not $SkipDataPlane) {
  Write-Phase -Number 5 -Title "Data plane probes to app VM $($script:AppVmIp)"
  $probe = Join-Path $ScriptsDir "probe.sh"
  $tok = @{ "__TARGET__" = $script:AppVmIp }

  $o = Invoke-VmScript -VmName $script:OnpremVmName -TemplatePath $probe -Tokens $tok -WorkDir $DataDir
  $s2sTcp = ((Get-KeyValue -Text $o -Key "TCP22") -eq "OK")
  $st = "FAIL"; if ($s2sTcp) { $st = "PASS" }
  Add-Result -Key "S2S: on-prem VM -> app TCP/22" -Status $st -Details ("ping=" + (Get-KeyValue -Text $o -Key "PING") + " | " + (Get-KeyValue -Text $o -Key "ROUTE_GET"))

  if ($tunnelUp) {
    $c = Invoke-VmScript -VmName $script:ClientVmName -TemplatePath $probe -Tokens $tok -WorkDir $DataDir
    $p2sTcp = ((Get-KeyValue -Text $c -Key "TCP22") -eq "OK")
    $st = "FAIL"; if ($p2sTcp) { $st = "PASS" }
    Add-Result -Key "P2S: client -> app TCP/22" -Status $st -Details ("ping=" + (Get-KeyValue -Text $c -Key "PING") + " | " + (Get-KeyValue -Text $c -Key "ROUTE_GET"))
  } else {
    Add-Result -Key "P2S: client -> app TCP/22" -Status "FAIL" -Details "skipped: tunnel down"
  }

  # Which firewall saw which branch? Resource-specific AZFWNetworkRule table.
  Write-Phase -Number 6 -Title "Firewall logs: which firewall carried each branch"
  $ws = Invoke-AzJson -AzArgs @("monitor", "log-analytics", "workspace", "show", "-g", $script:ResourceGroup, "-n", $script:WorkspaceName)
  $hits = @{}
  if (-not $ws) {
    Write-SubStep "Workspace not found; skipping log checks"
  } elseif ($LogWaitMinutes -le 0) {
    Write-SubStep "LogWaitMinutes=0; skipping log checks"
  } else {
    $since = $probeStartUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $kql = @"
AZFWNetworkRule
| where TimeGenerated > datetime($since)
| where DestinationIp == '$($script:AppVmIp)'
| extend Firewall = tostring(split(_ResourceId, '/')[-1])
| extend Branch = case(SourceIp startswith '10.120.', 'S2S', SourceIp startswith '172.16.110.', 'P2S', 'other')
| summarize Hits = count() by Firewall, Branch
"@
    $kqlFile = Join-Path $DataDir "inspect-query.kql"
    Write-LfFile -Path $kqlFile -Content $kql
    $deadline = (Get-Date).AddMinutes($LogWaitMinutes)
    $rows = @()
    Write-SubStep "Waiting up to $LogWaitMinutes min for flow logs (ingestion lag is normal)..."
    while ((Get-Date) -lt $deadline) {
      $q = Invoke-AzJson -AzArgs @("monitor", "log-analytics", "query", "-w", $ws.customerId, "--analytics-query", "@$kqlFile")
      $rows = @()
      if ($q) { $rows = @($q) }
      $keys = @($rows | ForEach-Object { "$($_.Firewall)|$($_.Branch)" })
      $haveS2s = @($keys | Where-Object { $_ -like "*|S2S" }).Count -gt 0
      $haveP2s = (-not $tunnelUp) -or (@($keys | Where-Object { $_ -like "*|P2S" }).Count -gt 0)
      if ($haveS2s -and $haveP2s) { Start-Sleep -Seconds 60; $q = Invoke-AzJson -AzArgs @("monitor", "log-analytics", "query", "-w", $ws.customerId, "--analytics-query", "@$kqlFile"); if ($q) { $rows = @($q) }; break }
      Write-SubStep ("[{0}] rows so far: {1}" -f (Get-Date -Format "HH:mm:ss"), ($keys -join ", "))
      Start-Sleep -Seconds 60
    }
    Remove-Item -Path $kqlFile -Force -ErrorAction SilentlyContinue
    foreach ($r in $rows) {
      $hits["$($r.Firewall)|$($r.Branch)"] = [int]$r.Hits
      Write-SubStep ("{0,-20} {1,-6} hits={2}" -f $r.Firewall, $r.Branch, $r.Hits)
    }
    if ($rows.Count -eq 0) { Write-SubStep "No rows yet. Re-run inspect in ~10 min for the log-based verdicts." }
  }
  $results["firewallHits"] = $hits

  function Get-Hits { param([string]$Fw, [string]$Branch) $k = "$Fw|$Branch"; if ($hits.ContainsKey($k)) { return $hits[$k] } return 0 }
  $logsKnown = ($hits.Count -gt 0)

  # =============================================================================
  # 7. Verdict against the design goal
  # =============================================================================
  Write-Phase -Number 7 -Title "Verdict: S2S via spoke FW, P2S via hub FW"
  if (-not $logsKnown) {
    Add-Result -Key "S2S -> app crosses the spoke firewall" -Status "PENDING" -Details "no firewall log rows yet"
    Add-Result -Key "S2S -> app does NOT cross the hub firewall" -Status "PENDING" -Details "no firewall log rows yet"
    Add-Result -Key "P2S -> app crosses the hub firewall" -Status "PENDING" -Details "no firewall log rows yet"
  } else {
    $a = Get-Hits $script:SpokeFwName "S2S"; $st = "FAIL"; if ($a -gt 0) { $st = "PASS" }
    Add-Result -Key "S2S -> app crosses the spoke firewall" -Status $st -Details "spoke FW S2S hits: $a"
    $b = Get-Hits $script:HubFwName "S2S"; $st = "FAIL"; if ($b -eq 0 -and $s2sTcp) { $st = "PASS" }
    Add-Result -Key "S2S -> app does NOT cross the hub firewall" -Status $st -Details "hub FW S2S hits: $b"
    $c2 = Get-Hits $script:HubFwName "P2S"; $st = "FAIL"; if ($c2 -gt 0) { $st = "PASS" }
    Add-Result -Key "P2S -> app crosses the hub firewall" -Status $st -Details ("hub FW P2S hits: $c2 | spoke FW P2S hits: " + (Get-Hits $script:SpokeFwName "P2S"))
  }
  $appRouteOnClient = ($results.Contains("P2S client has a route for $($script:AppCidr)") -and $results["P2S client has a route for $($script:AppCidr)"].status -eq "PASS")
  $st = "FAIL"; if ($appRouteOnClient -and $p2sTcp) { $st = "PASS" }
  Add-Result -Key "P2S client routes to the app and connects" -Status $st -Details "route on tun0=$appRouteOnClient, TCP/22=$p2sTcp"
}

# =============================================================================
# Save + summary
# =============================================================================
$pass = 0; $fail = 0; $pend = 0
foreach ($k in $results.Keys) {
  $v = $results[$k]
  if ($v -is [System.Collections.IDictionary] -and $v.Contains("status")) {
    if ($v.status -eq "PASS") { $pass++ }
    if ($v.status -eq "FAIL") { $fail++ }
    if ($v.status -eq "PENDING") { $pend++ }
  }
}
$file = Join-Path $DataDir ("inspect-{0}-{1}.json" -f $scenario, (Get-Date -Format "yyyyMMdd-HHmmss"))
Write-LfFile -Path $file -Content ($results | ConvertTo-Json -Depth 10)

Write-Host ""
Write-Host ("  Scenario {0}: {1} PASS, {2} FAIL, {3} PENDING" -f $scenario, $pass, $fail, $pend) -ForegroundColor Cyan
Write-Host "  A FAIL here can be the finding (for example S2S also hitting the hub firewall)." -ForegroundColor DarkGray
Write-Host "  Saved: $file" -ForegroundColor DarkGray
Write-Host ""
exit 0
