<#
.SYNOPSIS
  Watches Azure Front Door TLS certificate propagation across edge nodes.

.DESCRIPTION
  Discovers AFD edge IPs via repeated DNS sampling, then connects to each
  edge directly on port 443 using SNI for the custom hostname. Inspects
  which certificate each edge is currently serving and classifies it:

    custom (expected)       Edge is serving the certificate for your hostname.
    platform (*.azureedge)  Edge is still serving the default AFD platform cert.
    other/unknown           Unexpected cert subject -- investigate further.

  Builds a rolling in-place report as edges are discovered and certs change.
  Designed for monitoring the propagation window after a custom domain cert
  is attached or changed on an AFD profile.

  Propagation notes:
    - Global config changes can take up to ~20 minutes for a single operation.
    - Consecutive changes can take longer.
    - Certificate deployment for a new custom domain can take up to ~1 hour.

  Completely self-contained: no imports, no module dependencies, no repo
  helpers. Copy this single file anywhere and run it standalone.

.PARAMETER Target
  URL or hostname to watch (e.g. https://myapp.azurefd.net or myapp.azurefd.net).
  Prompted interactively if not provided.

.PARAMETER DurationMinutes
  How long to watch. Default: 30 minutes.

.PARAMETER IntervalSeconds
  Seconds between probe cycles. Default: 30.

.PARAMETER DnsSamplesPerCycle
  Number of DNS queries per cycle used to discover edge IPs. AFD uses anycast
  so different resolves can return different IPs. Default: 8.

.PARAMETER DnsSampleDelayMs
  Milliseconds between DNS samples within a cycle. Default: 300.

.PARAMETER Port
  TCP port to use for TLS connections. Default: 443.

.PARAMETER ConnectTimeoutMs
  TCP connect timeout per edge IP, in milliseconds. Default: 5000.

.EXAMPLE
  # Watch with all defaults (30 min, 30s interval)
  .\Watch-AfdCertPropagation.ps1

  # Specify the URL up front
  .\Watch-AfdCertPropagation.ps1 -Target "https://myapp.azurefd.net"

  # Watch for 45 minutes with a 20-second interval
  .\Watch-AfdCertPropagation.ps1 -Target "myapp.azurefd.net" -DurationMinutes 45 -IntervalSeconds 20

  # Aggressive discovery: more DNS samples per cycle
  .\Watch-AfdCertPropagation.ps1 -Target "myapp.azurefd.net" -DnsSamplesPerCycle 15 -DnsSampleDelayMs 200
#>

param(
  [string]$Target,

  [int]$DurationMinutes = 30,

  [int]$IntervalSeconds = 30,

  [int]$DnsSamplesPerCycle = 8,

  [int]$DnsSampleDelayMs = 300,

  [int]$Port = 443,

  [int]$ConnectTimeoutMs = 5000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ESC = [char]27

# ==============================================================================
# Input Handling
# ==============================================================================

function Get-HostnameFromTarget {
  param([string]$Raw)
  if ($Raw -match "^https?://([^/:]+)") { return $Matches[1] }
  return $Raw.Trim()
}

# ==============================================================================
# DNS Sampling
# ==============================================================================

function Get-EdgeIPsViaDns {
  param([string]$Hostname, [int]$Samples, [int]$DelayMs)

  $ips = [System.Collections.Generic.HashSet[string]]::new()

  for ($i = 1; $i -le $Samples; $i++) {
    $records = $null
    $oldEP   = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $records = Resolve-DnsName -Name $Hostname -Type A -ErrorAction SilentlyContinue 2>$null
    $ErrorActionPreference = $oldEP

    if ($records) {
      foreach ($r in @($records)) {
        if ($r.Type -eq "A" -and -not [string]::IsNullOrWhiteSpace($r.IPAddress)) {
          [void]$ips.Add($r.IPAddress)
        }
      }
    }

    if ($i -lt $Samples -and $DelayMs -gt 0) {
      Start-Sleep -Milliseconds $DelayMs
    }
  }

  return $ips
}

# ==============================================================================
# TLS Cert Fetch
# ==============================================================================

function Get-TlsCert {
  param([string]$Hostname, [string]$Ip, [int]$Port, [int]$TimeoutMs)

  $tcp = $null
  $ssl = $null

  try {
    $tcp   = New-Object System.Net.Sockets.TcpClient
    $iar   = $tcp.BeginConnect($Ip, $Port, $null, $null)
    $ready = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

    if (-not $ready) {
      throw "TCP timeout after ${TimeoutMs}ms"
    }

    $null = $tcp.EndConnect($iar)

    $ignoreCert = [System.Net.Security.RemoteCertificateValidationCallback]{
      param($s, $c, $ch, $e)
      return $true
    }
    $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $ignoreCert)
    $ssl.AuthenticateAsClient($Hostname)

    return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $ssl.RemoteCertificate
  } finally {
    if ($ssl) { try { $ssl.Close() } catch { } }
    if ($tcp) { try { $tcp.Close() } catch { } }
  }
}

# ==============================================================================
# Cert Classification
# ==============================================================================

function Get-CertKind {
  param([string]$Hostname, [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)

  $dnsName = $Cert.GetNameInfo(
    [System.Security.Cryptography.X509Certificates.X509NameType]::DnsName, $false)

  if ($dnsName -match "azureedge\.net" -or $Cert.Subject -match "azureedge\.net") {
    return "platform (*.azureedge)"
  }

  # Exact match
  if ($dnsName -ieq $Hostname) { return "custom (expected)" }

  # Wildcard match: *.example.com covers sub.example.com
  if ($dnsName -match "^\*\.") {
    $suffix = $dnsName.Substring(1)   # .example.com
    if ($Hostname.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
      return "custom (expected)"
    }
  }

  return "other/unknown"
}

# ==============================================================================
# State
# ==============================================================================

$State = @{
  Cycles    = 0
  StartTime = [datetime]::Now
  Edges     = [ordered]@{}
  AllIPs    = [System.Collections.Generic.HashSet[string]]::new()
}

# ==============================================================================
# Report Rendering
# ==============================================================================

function Write-Ln {
  param([string]$Text = "", [string]$Color = "Gray")
  $w = 100
  try { $w = $Host.UI.RawUI.WindowSize.Width } catch { }
  if ($w -lt 40) { $w = 100 }
  Write-Host $Text.PadRight($w - 1) -ForegroundColor $Color
}

function Invoke-CursorUp {
  param([int]$Lines)
  if ($Lines -gt 0) { [Console]::Write("$($ESC)[$($Lines)A") }
}

function Get-KindColor {
  param([string]$Kind)
  switch -Wildcard ($Kind) {
    "custom*"    { return "Green"  }
    "platform*"  { return "Yellow" }
    "error"      { return "Red"    }
    default      { return "Cyan"   }
  }
}

function Write-Report {
  param([string]$Hostname, [int]$MaxCycles)

  $elapsed    = [datetime]::Now - $State.StartTime
  $elapsedFmt = "{0}m {1:D2}s" -f [int]$elapsed.TotalMinutes, ($elapsed.Seconds % 60)
  $lines      = 0

  $allEdges  = @($State.Edges.Values)
  $total     = $allEdges.Count
  $custom    = @($allEdges | Where-Object { $_.Kind -like "custom*"   }).Count
  $platform  = @($allEdges | Where-Object { $_.Kind -like "platform*" }).Count
  $errors    = @($allEdges | Where-Object { $_.Kind -eq  "error"      }).Count
  $pct       = if ($total -gt 0) { [int]($custom * 100 / $total) } else { 0 }

  # Header
  Write-Ln ("  Watch-AfdCertPropagation  |  {0}  |  Cycle {1}/{2}  |  {3}" -f `
    $Hostname, $State.Cycles, $MaxCycles, $elapsedFmt) "Cyan"
  Write-Ln ("  " + ("-" * 76)) "DarkGray"
  $lines += 2

  # Progress summary
  $progColor = if ($custom -eq $total -and $total -gt 0) { "Green" } `
               elseif ($custom -gt 0)                    { "Yellow" } `
               else                                      { "Gray"   }
  Write-Ln ("  Progress: {0}/{1} edges on custom cert ({2}%)   platform: {3}   errors: {4}" -f `
    $custom, $total, $pct, $platform, $errors) $progColor
  Write-Ln ("  " + ("-" * 76)) "DarkGray"
  $lines += 2

  # Column headers
  Write-Ln ("  {0,-16}  {1,-22}  {2,-10}  {3,3}  {4}" -f `
    "EDGE IP", "CERT KIND", "EXPIRES", "CHG", "SINCE") "DarkGray"
  Write-Ln ("  " + ("-" * 76)) "DarkGray"
  $lines += 2

  # Sort: errors first, then platform (not propagated), then other, then custom (done)
  $errEdges      = @($allEdges | Where-Object { $_.Kind -eq  "error"      } | Sort-Object { $_.IP })
  $platformEdges = @($allEdges | Where-Object { $_.Kind -like "platform*" } | Sort-Object { $_.IP })
  $otherEdges    = @($allEdges | Where-Object { $_.Kind -like "other*"    } | Sort-Object { $_.IP })
  $customEdges   = @($allEdges | Where-Object { $_.Kind -like "custom*"   } | Sort-Object { $_.IP })
  $sortedEdges   = $errEdges + $platformEdges + $otherEdges + $customEdges

  foreach ($edge in $sortedEdges) {
    $color    = Get-KindColor $edge.Kind
    $expiry   = if ($edge.Expiry) { $edge.Expiry.ToString("yyyy-MM-dd") } else { "--" }
    $since    = $edge.FirstSeen.ToString("HH:mm:ss")

    Write-Ln ("  {0,-16}  {1,-22}  {2,-10}  {3,3}  {4}" -f `
      $edge.IP, $edge.Kind, $expiry, $edge.Changes, $since) $color
    $lines++

    if ($edge.Kind -eq "error") {
      $msg = if ($null -ne $edge.LastError) { [string]$edge.LastError } else { "" }
      if ($msg.Length -gt 68) { $msg = $msg.Substring(0, 65) + "..." }
      Write-Ln "    err: $msg" "DarkGray"
      $lines++
    } elseif ($edge.CN) {
      $thumb8 = if ($edge.Thumbprint.Length -ge 8) { $edge.Thumbprint.Substring(0, 8) } else { $edge.Thumbprint }
      Write-Ln "    CN=$($edge.CN)  thumb=${thumb8}..." "DarkGray"
      $lines++
    }
  }

  if ($State.Edges.Count -eq 0) {
    Write-Ln "  (discovering edges via DNS sampling...)" "DarkGray"
    $lines++
  }

  Write-Ln ("  " + ("-" * 76)) "DarkGray"
  $lines++

  # Footer
  $elapsed2 = [datetime]::Now - $State.StartTime
  $nextIn   = $IntervalSeconds - ([int]$elapsed2.TotalSeconds % $IntervalSeconds)
  Write-Ln ("  Last: {0}  |  Next in: {1}s  |  Ctrl+C to stop" -f `
    ([datetime]::Now.ToString("HH:mm:ss")), $nextIn) "DarkGray"
  $lines++

  return $lines
}

# ==============================================================================
# Main
# ==============================================================================

if ([string]::IsNullOrWhiteSpace($Target)) {
  Write-Host ""
  $Target = Read-Host "  Enter URL or hostname (e.g. https://myapp.azurefd.net)"
}

$Hostname = Get-HostnameFromTarget -Raw $Target

if ([string]::IsNullOrWhiteSpace($Hostname)) {
  Write-Error "Could not parse hostname from: $Target"
  exit 1
}

$MaxCycles = [Math]::Ceiling($DurationMinutes * 60.0 / $IntervalSeconds)

# Static header -- printed once, outside the in-place loop
Write-Host ""
Write-Host "  Watch-AfdCertPropagation  |  v1.0  |  PS5.1+PS7  |  No dependencies" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Host     : $Hostname" -ForegroundColor White
Write-Host ("  Duration : {0}m  ({1} cycles at {2}s)" -f $DurationMinutes, $MaxCycles, $IntervalSeconds) -ForegroundColor White
Write-Host ("  DNS/cycle: {0} samples x {1}ms delay" -f $DnsSamplesPerCycle, $DnsSampleDelayMs) -ForegroundColor White
Write-Host ""
Write-Host "  Cert kinds:" -ForegroundColor White
Write-Host "    custom (expected)   = edge is serving the cert for your hostname  -- done" -ForegroundColor Green
Write-Host "    platform            = edge still on *.azureedge.net cert          -- propagating" -ForegroundColor Yellow
Write-Host "    other/unknown       = unexpected cert subject                     -- investigate" -ForegroundColor Cyan
Write-Host ""

$State.StartTime = [datetime]::Now
$endTime         = $State.StartTime.AddMinutes($DurationMinutes)
$prevLines       = 0

try {
  while ([datetime]::Now -lt $endTime) {
    $cycleStart = [datetime]::Now
    $State.Cycles++

    # 1. DNS sampling -- discover edge IPs
    $cycleIPs = Get-EdgeIPsViaDns -Hostname $Hostname -Samples $DnsSamplesPerCycle -DelayMs $DnsSampleDelayMs
    foreach ($ip in @($cycleIPs)) { [void]$State.AllIPs.Add($ip) }

    # 2. TLS probe every known IP
    foreach ($ip in @($State.AllIPs)) {
      $now = [datetime]::Now
      $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
      try {
        $cert  = Get-TlsCert -Hostname $Hostname -Ip $ip -Port $Port -TimeoutMs $ConnectTimeoutMs
        $kind  = Get-CertKind -Hostname $Hostname -Cert $cert
        $cn    = $cert.GetNameInfo(
          [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        $exp   = [datetime]::Parse($cert.GetExpirationDateString())
        $thumb = $cert.Thumbprint

        if (-not $State.Edges.Contains($ip)) {
          $State.Edges[$ip] = @{
            IP         = $ip
            Kind       = $kind
            CN         = $cn
            Expiry     = $exp
            Thumbprint = $thumb
            FirstSeen  = $now
            LastSeen   = $now
            Changes    = 0
            Errors     = 0
            LastError  = ""
          }
        } else {
          $e = $State.Edges[$ip]
          if ($e.Thumbprint -ne $thumb -or $e.Kind -ne $kind) { $e.Changes = $e.Changes + 1 }
          $e.Kind      = $kind
          $e.CN        = $cn
          $e.Expiry    = $exp
          $e.Thumbprint = $thumb
          $e.LastSeen  = $now
          $e.LastError = ""
        }
      } catch {
        $msg = $_.Exception.Message
        if (-not $State.Edges.Contains($ip)) {
          $State.Edges[$ip] = @{
            IP         = $ip
            Kind       = "error"
            CN         = ""
            Expiry     = $null
            Thumbprint = ""
            FirstSeen  = $now
            LastSeen   = $now
            Changes    = 0
            Errors     = 1
            LastError  = $msg
          }
        } else {
          $e = $State.Edges[$ip]
          $e.Kind      = "error"
          $e.Errors    = $e.Errors + 1
          $e.LastSeen  = $now
          $e.LastError = $msg
        }
      }
      $ErrorActionPreference = $oldEP
    }

    # 3. Render report in-place
    if ($prevLines -gt 0) { Invoke-CursorUp -Lines $prevLines }
    $prevLines = Write-Report -Hostname $Hostname -MaxCycles $MaxCycles

    # 4. Sleep remainder of interval
    $cycleDuration = ([datetime]::Now - $cycleStart).TotalSeconds
    $sleepMs       = [Math]::Max(0, ($IntervalSeconds - $cycleDuration) * 1000)
    if ($sleepMs -gt 0) { Start-Sleep -Milliseconds ([int]$sleepMs) }
  }
} finally {
  Write-Host ""
}

# Final render
if ($prevLines -gt 0) { Invoke-CursorUp -Lines $prevLines }
Write-Report -Hostname $Hostname -MaxCycles $MaxCycles | Out-Null

Write-Host ""
$allEdges = @($State.Edges.Values)
$custom   = @($allEdges | Where-Object { $_.Kind -like "custom*" }).Count
$total    = $allEdges.Count
Write-Host ("  Session complete.  {0}/{1} edges on custom cert after {2} cycle(s)." -f `
  $custom, $total, $State.Cycles) -ForegroundColor Cyan
Write-Host ""
