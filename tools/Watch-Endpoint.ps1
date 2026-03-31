<#
.SYNOPSIS
  Watches an endpoint over time, polling DNS, TCP, TLS, and HTTP behavior.

.DESCRIPTION
  Self-contained endpoint monitoring tool. Polls a target repeatedly on a
  configurable interval, building a rolling per-row learned state that updates
  in place without clearing the screen.

  Supports FQDN, IP address, and full URL targets. When the target is an FQDN
  and TCP or TLS tests are requested, DNS resolution is always performed
  internally to discover IPs -- regardless of whether DNS appears in -Tests.
  New IPs that appear over time automatically get their own TCP/TLS rows.

  Completely self-contained: no imports, no module dependencies, no repo-
  specific helpers. Copy this single file anywhere and run it standalone.

.PARAMETER Target
  Endpoint to watch. Accepts:
    FQDN        example.com, corp.internal, myapp.azure.com
    IP address  10.0.1.4, 192.168.0.1
    URL         https://myapp.azure.com, http://10.0.1.4:8080/health
  Port and scheme are extracted from URLs automatically.

.PARAMETER Tests
  Which test types to run. One or more of: DNS, TCP, TLS, HTTP, ALL.
  Default: ALL
  When ALL is specified:
    - DNS  is included for FQDN/URL targets only (not meaningful for bare IPs)
    - HTTP is included (opt-in via ALL, or by listing HTTP explicitly)
  For FQDN targets, DNS resolution is always run internally even when DNS is
  not listed in -Tests, so TCP/TLS rows can discover IPs over time.

.PARAMETER Ports
  TCP port(s) to test. If not specified, defaults to 443 for HTTPS/TLS
  targets, 80 for plain HTTP, 443 otherwise.

.PARAMETER DurationMinutes
  How long to poll. Default: 5 minutes.

.PARAMETER IntervalSeconds
  Seconds between polls. Default: 10.

.PARAMETER DnsResolvers
  One or more DNS resolver IP addresses to query explicitly
  (e.g. "8.8.8.8", "168.63.129.16"). Each resolver gets its own row.
  If omitted, uses the system default resolver.

.PARAMETER DnsRecordTypes
  DNS record type(s) to query. Default: A
  Accepted: A, AAAA, CNAME, MX, TXT, NS.

.PARAMETER ConnectTimeoutMs
  Timeout for TCP/TLS connect attempts, in milliseconds. Default: 3000.

.EXAMPLE
  # Watch DNS using the system resolver
  .\Watch-Endpoint.ps1 -Target "example.com" -Tests DNS

  # Full test suite against an FQDN on port 443
  .\Watch-Endpoint.ps1 -Target "myapp.azure.com" -Tests ALL -Ports 443

  # TCP reachability to a bare IP -- no DNS needed
  .\Watch-Endpoint.ps1 -Target "10.0.1.4" -Tests TCP -Ports 22,443

  # Compare two DNS resolvers over time with multiple record types
  .\Watch-Endpoint.ps1 -Target "corp.internal" -Tests DNS `
    -DnsResolvers "10.0.0.4","168.63.129.16" -DnsRecordTypes A,CNAME

  # Quick 2-minute HTTPS health check, polling every 5 seconds
  .\Watch-Endpoint.ps1 -Target "https://api.example.com" `
    -Tests TCP,TLS,HTTP -DurationMinutes 2 -IntervalSeconds 5

  # Watch a URL with default settings (ALL tests, 5 minutes)
  .\Watch-Endpoint.ps1 -Target "https://myapp.azure.com"
#>

param(
  [Parameter(Mandatory)]
  [string]$Target,

  [ValidateSet("DNS","TCP","TLS","HTTP","ALL")]
  [string[]]$Tests = @("ALL"),

  [int[]]$Ports,

  [int]$DurationMinutes = 5,

  [int]$IntervalSeconds = 10,

  [string[]]$DnsResolvers = @(),

  [ValidateSet("A","AAAA","CNAME","MX","TXT","NS")]
  [string[]]$DnsRecordTypes = @("A"),

  [int]$ConnectTimeoutMs = 3000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ESC = [char]27

# ==============================================================================
# Target Parsing
# ==============================================================================

function ConvertTo-TargetInfo {
  param([string]$Raw)

  $info = @{
    Original = $Raw
    Hostname = $null
    Port     = $null
    Scheme   = $null
    IsIP     = $false
    UrlPath  = "/"
  }

  if ($Raw -match "^(https?)://([^/:]+)(?::(\d+))?(/.*)?$") {
    $info.Scheme   = $Matches[1].ToLower()
    $info.Hostname = $Matches[2]
    if ($Matches[3]) { $info.Port = [int]$Matches[3] }
    if ($Matches[4]) { $info.UrlPath = $Matches[4] }
    if (-not $info.Port) {
      $info.Port = if ($info.Scheme -eq "https") { 443 } else { 80 }
    }
  } elseif ($Raw -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
    $info.Hostname = $Raw
    $info.IsIP     = $true
  } else {
    $info.Hostname = $Raw
  }

  return $info
}

# ==============================================================================
# Test Set + Port Resolution
# ==============================================================================

function Resolve-TestSet {
  param([string[]]$RequestedTests, [hashtable]$TInfo)

  $all = $RequestedTests -contains "ALL"

  return @{
    DNS  = ($all -or ($RequestedTests -contains "DNS"))  -and (-not $TInfo.IsIP)
    TCP  = ($all -or ($RequestedTests -contains "TCP"))
    TLS  = ($all -or ($RequestedTests -contains "TLS"))
    HTTP = ($all -or ($RequestedTests -contains "HTTP"))
  }
}

function Resolve-ActivePorts {
  param([int[]]$Requested, [hashtable]$TInfo, [hashtable]$TSet)

  if ($Requested -and $Requested.Count -gt 0) { return $Requested }
  if ($TInfo.Port)                             { return @($TInfo.Port) }
  if ($TSet.TLS)                               { return @(443) }
  if ($TSet.HTTP -and (-not $TSet.TLS))        { return @(80) }
  return @(443)
}

# ==============================================================================
# State
# ==============================================================================

$State = @{
  Polls     = 0
  StartTime = [datetime]::Now
  Rows      = [ordered]@{}
  KnownIPs  = [System.Collections.Generic.List[string]]::new()
}

function Set-StateRow {
  param([string]$Key, [hashtable]$Props)

  if (-not $State.Rows.Contains($Key)) {
    $State.Rows[$Key] = @{
      Key       = $Key
      Group     = ""
      Label     = ""
      SubLabel  = ""
      LastValue = ""
      Port      = $null
      Status    = "---"
      LastMs    = $null
      FirstSeen = [datetime]::Now
      PassCount = 0
      FailCount = 0
    }
  }
  $row = $State.Rows[$Key]
  foreach ($k in $Props.Keys) { $row[$k] = $Props[$k] }
}

# ==============================================================================
# DNS Test
# ==============================================================================

function Invoke-DnsTest {
  param([string]$Hostname, [string]$RecordType, [string]$Resolver)

  $result = @{ Success = $false; Values = @(); ErrorMsg = ""; ElapsedMs = 0 }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  try {
    $hasDnsClient = [bool](Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)

    if ($hasDnsClient) {
      $records = $null
      $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
      if ($Resolver) {
        $records = Resolve-DnsName -Name $Hostname -Type $RecordType `
          -Server $Resolver -ErrorAction SilentlyContinue 2>$null
      } else {
        $records = Resolve-DnsName -Name $Hostname -Type $RecordType `
          -ErrorAction SilentlyContinue 2>$null
      }
      $ErrorActionPreference = $oldEP

      if ($records) {
        $result.Success = $true
        # Wrap in @() to guarantee array -- PS5.1 switch can unroll a single-element
        # array to a scalar, breaking .Count under Set-StrictMode -Version Latest
        $result.Values  = @(switch ($RecordType) {
          "A"     { $records | Where-Object { $_.Type -eq "A"     } | ForEach-Object { $_.IPAddress } }
          "AAAA"  { $records | Where-Object { $_.Type -eq "AAAA"  } | ForEach-Object { $_.IPAddress } }
          "CNAME" { $records | Where-Object { $_.Type -eq "CNAME" } | ForEach-Object { $_.NameHost } }
          "MX"    { $records | Where-Object { $_.Type -eq "MX"    } | ForEach-Object { $_.NameExchange } }
          "TXT"   { $records | Where-Object { $_.Type -eq "TXT"   } | ForEach-Object { $_.Strings -join " " } }
          "NS"    { $records | Where-Object { $_.Type -eq "NS"    } | ForEach-Object { $_.NameHost } }
          default { }
        })
      }
    } elseif ($RecordType -in @("A","AAAA")) {
      # Cross-platform .NET fallback: system resolver only, A/AAAA records only
      $addrs = [System.Net.Dns]::GetHostAddresses($Hostname)
      $family = if ($RecordType -eq "A") { "InterNetwork" } else { "InterNetworkV6" }
      $result.Values  = @($addrs | Where-Object { $_.AddressFamily -eq $family } |
        ForEach-Object { $_.IPAddressToString })
      $result.Success = ($result.Values.Count -gt 0)
    } else {
      $result.ErrorMsg = "Resolve-DnsName unavailable; $RecordType not supported via .NET fallback"
    }
  } catch {
    $result.ErrorMsg = $_.Exception.Message
  }

  $sw.Stop()
  $result.ElapsedMs = $sw.ElapsedMilliseconds
  return $result
}

# ==============================================================================
# TCP Test
# ==============================================================================

function Invoke-TcpTest {
  param([string]$Ip, [int]$Port, [int]$TimeoutMs)

  $result = @{ Success = $false; ErrorMsg = ""; ElapsedMs = 0 }
  $sw  = [System.Diagnostics.Stopwatch]::StartNew()
  $tcp = $null

  try {
    $tcp   = New-Object System.Net.Sockets.TcpClient
    $async = $tcp.BeginConnect($Ip, $Port, $null, $null)
    $ready = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
    if ($ready) {
      $tcp.EndConnect($async)
      $result.Success = $true
    } else {
      $result.ErrorMsg = "Timeout"
    }
  } catch {
    $result.ErrorMsg = ($_.Exception.Message -replace ".+: ","")
  } finally {
    if ($tcp) { try { $tcp.Close() } catch { } }
    $sw.Stop()
    $result.ElapsedMs = $sw.ElapsedMilliseconds
  }

  return $result
}

# ==============================================================================
# TLS Test
# ==============================================================================

function Invoke-TlsTest {
  param([string]$Hostname, [string]$Ip, [int]$Port, [int]$TimeoutMs)

  $result = @{
    Success      = $false
    ErrorMsg     = ""
    ElapsedMs    = 0
    CertSubject  = ""
    CertExpiry   = $null
    CertDaysLeft = 0
  }
  $sw  = [System.Diagnostics.Stopwatch]::StartNew()
  $tcp = $null
  $ssl = $null

  try {
    $tcp   = New-Object System.Net.Sockets.TcpClient
    $async = $tcp.BeginConnect($Ip, $Port, $null, $null)
    $ready = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

    if (-not $ready) {
      $result.ErrorMsg = "TCP Timeout"
    } else {
      $tcp.EndConnect($async)

      # Accept all certs -- we report validity ourselves
      $ignoreCert = [System.Net.Security.RemoteCertificateValidationCallback]{
        param($sender, $cert, $chain, $errors)
        return $true
      }
      $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $ignoreCert)
      $ssl.AuthenticateAsClient($Hostname)

      $raw = $ssl.RemoteCertificate
      if ($raw) {
        $cert2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $raw
        $result.CertSubject  = $cert2.GetNameInfo(
          [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        $result.CertExpiry   = [datetime]::Parse($cert2.GetExpirationDateString())
        $result.CertDaysLeft = [int]($result.CertExpiry - [datetime]::Now).TotalDays
        $result.Success      = $true
      }
    }
  } catch {
    $result.ErrorMsg = ($_.Exception.Message -replace ".+: ","")
  } finally {
    if ($ssl) { try { $ssl.Close() } catch { } }
    if ($tcp) { try { $tcp.Close() } catch { } }
    $sw.Stop()
    $result.ElapsedMs = $sw.ElapsedMilliseconds
  }

  return $result
}

# ==============================================================================
# HTTP Test
# ==============================================================================

function Invoke-HttpTest {
  param([string]$Url, [int]$TimeoutMs)

  $result = @{ Success = $false; StatusCode = 0; ErrorMsg = ""; ElapsedMs = 0 }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  try {
    $timeoutSec = [Math]::Max(1, [int]($TimeoutMs / 1000))

    if ($PSVersionTable.PSVersion.Major -ge 6) {
      # PS6+ -- use -SkipCertificateCheck for diagnostic use
      $resp  = $null
      $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
      try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -SkipCertificateCheck `
          -TimeoutSec $timeoutSec -ErrorAction SilentlyContinue
      } catch {
        if ($_.Exception.Response) {
          $result.StatusCode = [int]$_.Exception.Response.StatusCode
        } else {
          $result.ErrorMsg = ($_.Exception.Message -replace ".+: ","")
        }
      } finally {
        $ErrorActionPreference = $oldEP
      }
      if ($resp) { $result.StatusCode = [int]$resp.StatusCode }
    } else {
      # PS5.1 -- ServicePointManager cert bypass set at script start
      $req = [System.Net.HttpWebRequest]::Create($Url)
      $req.Timeout = $TimeoutMs
      $req.AllowAutoRedirect = $true
      $resp  = $null
      $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
      try {
        $resp = $req.GetResponse()
      } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
          $resp = $_.Exception.Response
        } else {
          $result.ErrorMsg = ($_.Exception.Message -replace ".+: ","")
        }
      } finally {
        $ErrorActionPreference = $oldEP
      }
      if ($resp) {
        $result.StatusCode = [int]$resp.StatusCode
        $resp.Close()
      }
    }

    $result.Success = ($result.StatusCode -gt 0 -and $result.StatusCode -lt 500)
  } catch {
    $result.ErrorMsg = ($_.Exception.Message -replace ".+: ","")
  }

  $sw.Stop()
  $result.ElapsedMs = $sw.ElapsedMilliseconds
  return $result
}

# ==============================================================================
# Implicit DNS: resolve FQDN -> IPs for TCP/TLS when DNS test is not displayed
# ==============================================================================

function Resolve-HostIPs {
  param([string]$Hostname)

  $ips = @()
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  try {
    $hasDnsClient = [bool](Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)
    if ($hasDnsClient) {
      $records = $null
      $records = Resolve-DnsName -Name $Hostname -Type A `
        -ErrorAction SilentlyContinue 2>$null
      if ($records) {
        $ips = @($records | Where-Object { $_.Type -eq "A" } |
          ForEach-Object { $_.IPAddress })
      }
    }
    if ($ips.Count -eq 0) {
      $addrs = [System.Net.Dns]::GetHostAddresses($Hostname)
      $ips   = @($addrs | Where-Object { $_.AddressFamily -eq "InterNetwork" } |
        ForEach-Object { $_.IPAddressToString })
    }
  } catch { }
  $ErrorActionPreference = $oldEP
  return $ips
}

# ==============================================================================
# Report Rendering
# ==============================================================================

function Format-Latency {
  param([object]$Ms)
  if ($null -eq $Ms) { return "     --" }
  $capped = [Math]::Min([long]$Ms, 99999)
  return ("{0,5}ms" -f $capped)
}

function Get-StatusColor {
  param([string]$Status)
  switch -Wildcard ($Status.ToUpper()) {
    "OK"        { return "Green"  }
    "CONNECTED" { return "Green"  }
    "VALID"     { return "Green"  }
    "2*"        { return "Green"  }
    "3*"        { return "Cyan"   }
    "TIMEOUT"   { return "Red"    }
    "FAIL"      { return "Red"    }
    "ERR*"      { return "Red"    }
    "NXDOMAIN"  { return "Yellow" }
    "EXPIRED"   { return "Yellow" }
    "4*"        { return "Yellow" }
    "5*"        { return "Red"    }
    default     { return "Gray"   }
  }
}

function Write-Ln {
  param([string]$Text = "", [string]$Color = "Gray")
  $w = 100
  try { $w = $Host.UI.RawUI.WindowSize.Width } catch { }
  if ($w -lt 40) { $w = 100 }
  # Pad to window width so reprinting overwrites any longer previous content
  $out = $Text.PadRight($w - 1)
  Write-Host $out -ForegroundColor $Color
}

function Invoke-CursorUp {
  param([int]$Lines)
  if ($Lines -gt 0) {
    [Console]::Write("$($ESC)[$($Lines)A")
  }
}

function Write-Report {
  param([hashtable]$TInfo, [hashtable]$TSet, [int[]]$APorts)

  $elapsed    = [datetime]::Now - $State.StartTime
  $maxPolls   = [Math]::Ceiling($DurationMinutes * 60.0 / $IntervalSeconds)
  $elapsedFmt = "{0}m {1:D2}s" -f [int]$elapsed.TotalMinutes, ($elapsed.Seconds % 60)
  $lines      = 0

  # Header bar
  $hdr = "  Watch-Endpoint  |  {0}  |  Poll {1}/{2}  |  {3}" -f `
    $TInfo.Hostname, $State.Polls, $maxPolls, $elapsedFmt
  Write-Ln $hdr "Cyan"
  Write-Ln ("  " + ("-" * 76)) "DarkGray"
  $lines += 2

  # Column headers
  Write-Ln ("  {0,-10}  {1,-24}  {2,5}  {3,-11}  {4,7}  {5}" -f `
    "TEST","ADDRESS/VALUE","PORT","STATUS","LATENCY","P/F") "DarkGray"
  Write-Ln ("  " + ("-" * 76)) "DarkGray"
  $lines += 2

  # Rows, grouped by test type in canonical order
  foreach ($group in @("DNS","TCP","TLS","HTTP")) {
    foreach ($key in @($State.Rows.Keys)) {
      $row = $State.Rows[$key]
      if ($row.Group -ne $group) { continue }

      $pf      = "{0}/{1}" -f $row.PassCount, $row.FailCount
      $portFmt = if ($null -ne $row.Port) { "$($row.Port)" } else { "--" }
      $color   = Get-StatusColor $row.Status

      # Guard against null LastValue -- can occur if a prior poll errored mid-assignment
      $val = if ($null -ne $row.LastValue) { [string]$row.LastValue } else { "" }
      if ($val.Length -gt 24) { $val = $val.Substring(0, 21) + "..." }

      $dataLine = "  {0,-10}  {1,-24}  {2,5}  {3,-11}  {4,7}  {5}" -f `
        $row.Label, $val, $portFmt, $row.Status, (Format-Latency $row.LastMs), $pf
      Write-Ln $dataLine $color
      $lines++

      if ($row.SubLabel) {
        Write-Ln ("            $($row.SubLabel)") "DarkGray"
        $lines++
      }
    }
  }

  if ($State.Rows.Count -eq 0) {
    Write-Ln "  (running first poll...)" "DarkGray"
    $lines++
  }

  Write-Ln ("  " + ("-" * 76)) "DarkGray"
  $lines++

  # Footer
  $elapsed2   = [datetime]::Now - $State.StartTime
  $nextIn     = $IntervalSeconds - ([int]$elapsed2.TotalSeconds % $IntervalSeconds)
  $footer     = "  Last: {0}  |  Next in: {1}s  |  Ctrl+C to stop" -f `
    ([datetime]::Now.ToString("HH:mm:ss")), $nextIn
  Write-Ln $footer "DarkGray"
  $lines++

  return $lines
}

# ==============================================================================
# Poll
# ==============================================================================

function Invoke-Poll {
  param([hashtable]$TInfo, [hashtable]$TSet, [int[]]$APorts)

  $State.Polls++

  # Resolve IPs for TCP/TLS (always, even when DNS test is not displayed)
  $connIPs = @()
  if ($TInfo.IsIP) {
    $connIPs = @($TInfo.Hostname)
  } else {
    $fresh = @(Resolve-HostIPs -Hostname $TInfo.Hostname)
    foreach ($ip in $fresh) {
      if (-not $State.KnownIPs.Contains($ip)) { $State.KnownIPs.Add($ip) }
    }
    $connIPs = @($State.KnownIPs)
  }

  # ---- DNS ----
  if ($TSet.DNS) {
    $resolvers = if ($DnsResolvers -and $DnsResolvers.Count -gt 0) {
      $DnsResolvers
    } else {
      @("")
    }
    foreach ($rtype in $DnsRecordTypes) {
      foreach ($resolver in $resolvers) {
        $rKey = if ($resolver) { $resolver } else { "sys" }
        $key  = "DNS:${rtype}:${rKey}:$($TInfo.Hostname)"
        $r    = Invoke-DnsTest -Hostname $TInfo.Hostname -RecordType $rtype -Resolver $resolver

        # Values is now always @() or a proper array -- safe to use .Count directly
        [string]$valStr = if ($r.Values.Count -eq 0)   { "" }
                          elseif ($r.Values.Count -eq 1) { $r.Values[0] }
                          else { "$($r.Values[0]) (+$($r.Values.Count - 1))" }
        $status = if     ($r.Success)                                      { "OK"      }
                  elseif ($r.ErrorMsg -match "[Tt]imeout")                 { "TIMEOUT" }
                  elseif ($r.ErrorMsg)                                     { "FAIL"    }
                  elseif (-not $r.Success -and $r.ElapsedMs -gt 5000)     { "TIMEOUT" }
                  else                                                     { "NXDOMAIN"}
        $subLbl = if ($resolver) { "@$resolver" } else { "(system resolver)" }
        # Show full IP list in SubLabel when there are multiple values so nothing is hidden
        if ($r.Values.Count -gt 1) {
          $ipList = $r.Values -join ", "
          if ($ipList.Length -gt 60) { $ipList = $ipList.Substring(0, 57) + "..." }
          $subLbl = "$subLbl  [$ipList]"
        }

        Set-StateRow -Key $key -Props @{
          Group     = "DNS"
          Label     = "DNS $rtype"
          SubLabel  = $subLbl
          LastValue = $valStr
          LastMs    = $r.ElapsedMs
          Status    = $status
        }
        if ($r.Success) { $State.Rows[$key].PassCount++ } else { $State.Rows[$key].FailCount++ }
      }
    }
  }

  # ---- TCP ----
  if ($TSet.TCP) {
    foreach ($ip in $connIPs) {
      foreach ($port in $APorts) {
        $key = "TCP:${ip}:${port}"
        $r   = Invoke-TcpTest -Ip $ip -Port $port -TimeoutMs $ConnectTimeoutMs

        $status = if     ($r.Success)                      { "CONNECTED" }
                  elseif ($r.ErrorMsg -eq "Timeout")       { "TIMEOUT"   }
                  else                                     { "FAIL"      }
        $sub    = if (-not $r.Success -and $r.ErrorMsg -and $r.ErrorMsg -ne "Timeout") {
          $r.ErrorMsg.Substring(0, [Math]::Min(50, $r.ErrorMsg.Length))
        } else { "" }

        Set-StateRow -Key $key -Props @{
          Group     = "TCP"
          Label     = "TCP"
          SubLabel  = $sub
          LastValue = $ip
          Port      = $port
          LastMs    = $r.ElapsedMs
          Status    = $status
        }
        if ($r.Success) { $State.Rows[$key].PassCount++ } else { $State.Rows[$key].FailCount++ }
      }
    }
  }

  # ---- TLS ----
  if ($TSet.TLS) {
    foreach ($ip in $connIPs) {
      foreach ($port in $APorts) {
        $key = "TLS:${ip}:${port}"
        $r   = Invoke-TlsTest -Hostname $TInfo.Hostname -Ip $ip -Port $port -TimeoutMs $ConnectTimeoutMs

        $status = if (-not $r.Success) {
          if ($r.ErrorMsg -match "[Tt]imeout") { "TIMEOUT" } else { "FAIL" }
        } elseif ($r.CertDaysLeft -gt 0) { "VALID" } else { "EXPIRED" }

        $sub = if ($r.Success -and $r.CertSubject) {
          "CN=$($r.CertSubject)  exp $($r.CertExpiry.ToString('yyyy-MM-dd'))  ($($r.CertDaysLeft)d left)"
        } elseif (-not $r.Success -and $r.ErrorMsg) {
          $r.ErrorMsg.Substring(0, [Math]::Min(60, $r.ErrorMsg.Length))
        } else { "" }

        Set-StateRow -Key $key -Props @{
          Group     = "TLS"
          Label     = "TLS"
          SubLabel  = $sub
          LastValue = $ip
          Port      = $port
          LastMs    = $r.ElapsedMs
          Status    = $status
        }
        if ($r.Success) { $State.Rows[$key].PassCount++ } else { $State.Rows[$key].FailCount++ }
      }
    }
  }

  # ---- HTTP ----
  if ($TSet.HTTP) {
    $url = $TInfo.Original
    if ($url -notmatch "^https?://") {
      $scheme = if ($APorts -contains 443) { "https" } else { "http" }
      $url    = "${scheme}://$($TInfo.Hostname):$($APorts[0])/"
    }

    $key = "HTTP:${url}"
    $r   = Invoke-HttpTest -Url $url -TimeoutMs $ConnectTimeoutMs

    $status = if (-not $r.Success) {
      if   ($r.ErrorMsg -match "[Tt]imeout") { "TIMEOUT"           }
      elseif ($r.StatusCode -gt 0)           { "$($r.StatusCode)"  }
      else                                   { "FAIL"              }
    } else { "$($r.StatusCode)" }

    $sub = if ($r.ErrorMsg -and -not $r.Success) {
      $r.ErrorMsg.Substring(0, [Math]::Min(60, $r.ErrorMsg.Length))
    } else { "" }

    $displayUrl = $url
    if ($displayUrl.Length -gt 24) { $displayUrl = $displayUrl.Substring(0, 21) + "..." }

    Set-StateRow -Key $key -Props @{
      Group     = "HTTP"
      Label     = "HTTP"
      SubLabel  = $sub
      LastValue = $displayUrl
      Port      = $APorts[0]
      LastMs    = $r.ElapsedMs
      Status    = $status
    }
    if ($r.Success) { $State.Rows[$key].PassCount++ } else { $State.Rows[$key].FailCount++ }
  }
}

# ==============================================================================
# Main
# ==============================================================================

$TInfo  = ConvertTo-TargetInfo -Raw $Target
$TSet   = Resolve-TestSet -RequestedTests $Tests -TInfo $TInfo
$APorts = Resolve-ActivePorts -Requested $Ports -TInfo $TInfo -TSet $TSet

# PS5.1 HTTPS cert bypass for diagnostic use (HTTP test only)
if ($TSet.HTTP -and $PSVersionTable.PSVersion.Major -lt 6) {
  [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

# Static header -- printed once, outside the in-place refresh loop
Write-Host ""
Write-Host "  Watch-Endpoint  |  v1.0  |  PS5.1+PS7  |  No dependencies" -ForegroundColor DarkCyan
Write-Host ""
Write-Host ("  Target   : {0}{1}" -f `
  $TInfo.Hostname, $(if ($TInfo.IsIP) { "  (IP - DNS skipped)" } else { "" })) -ForegroundColor White
$activeTests = @("DNS","TCP","TLS","HTTP") | Where-Object { $TSet[$_] }
Write-Host ("  Tests    : {0}" -f ($activeTests -join ", ")) -ForegroundColor White
Write-Host ("  Ports    : {0}" -f ($APorts -join ", ")) -ForegroundColor White
Write-Host ("  Polling  : every {0}s for {1}m  ({2} polls total)" -f `
  $IntervalSeconds, $DurationMinutes,
  [Math]::Ceiling($DurationMinutes * 60.0 / $IntervalSeconds)) -ForegroundColor White
if ($DnsResolvers -and $DnsResolvers.Count -gt 0) {
  Write-Host ("  Resolvers: {0}" -f ($DnsResolvers -join ", ")) -ForegroundColor White
}
Write-Host ""

$State.StartTime = [datetime]::Now
$endTime         = $State.StartTime.AddMinutes($DurationMinutes)
$prevLines       = 0

try {
  while ([datetime]::Now -lt $endTime) {
    $pollStart = [datetime]::Now

    Invoke-Poll -TInfo $TInfo -TSet $TSet -APorts $APorts

    if ($prevLines -gt 0) { Invoke-CursorUp -Lines $prevLines }
    $prevLines = Write-Report -TInfo $TInfo -TSet $TSet -APorts $APorts

    $pollDuration = ([datetime]::Now - $pollStart).TotalSeconds
    $sleepMs      = [Math]::Max(0, ($IntervalSeconds - $pollDuration) * 1000)
    if ($sleepMs -gt 0) { Start-Sleep -Milliseconds ([int]$sleepMs) }
  }
} finally {
  # Ensure clean line on Ctrl+C or normal exit
  Write-Host ""
}

# Final poll + final render
Invoke-Poll -TInfo $TInfo -TSet $TSet -APorts $APorts
if ($prevLines -gt 0) { Invoke-CursorUp -Lines $prevLines }
Write-Report -TInfo $TInfo -TSet $TSet -APorts $APorts | Out-Null

Write-Host ""
Write-Host ("  Session complete.  Polls: {0}  Duration: {1} minute(s)." -f `
  $State.Polls, $DurationMinutes) -ForegroundColor Cyan
Write-Host ""
