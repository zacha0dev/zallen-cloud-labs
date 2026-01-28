<#
run.ps1 — zero-parameter “engineer helper” entrypoint

Behavior:
- Fast path: if already configured + tools present, just show status and exit.
- Slow path: if missing config or tools, run subscription wizard + setup + self-test.

It also:
- Logs only when doing actual work (slow path) to logs/run-*.log
- Stores repo-local config in .data/subs.json (gitignored)
- Removes template entries (lab/prod) automatically
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Title([string]$t) {
  Write-Host ""
  Write-Host $t -ForegroundColor Cyan
  Write-Host ("=" * $t.Length) -ForegroundColor Cyan
}

function RepoRoot { (Resolve-Path $PSScriptRoot).Path }
$root     = RepoRoot

$pkgSetup = Join-Path $root "scripts\setup.ps1"

$dataDir   = Join-Path $root ".data"
$subsPath  = Join-Path $dataDir "subs.json"
$statePath = Join-Path $dataDir "setup.state.json"

$logsDir  = Join-Path $root "logs"
$logFile  = Join-Path $logsDir ("run-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")

function Ensure-Dirs {
  if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
  if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }
  $keep = Join-Path $logsDir ".keep"
  if (-not (Test-Path $keep)) { New-Item -ItemType File -Path $keep | Out-Null }
}

function HasCmd([string]$name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Az-Authenticated {
  if (-not (HasCmd "az")) { return $false }
  az account show 1>$null 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Read-Json([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  return (Get-Content $path -Raw | ConvertFrom-Json)
}

function Write-Json([string]$path, $obj) {
  $obj | ConvertTo-Json -Depth 20 | Set-Content $path -Encoding UTF8
}

function Get-PropNames($obj) {
  if (-not $obj) { return @() }

  # If there's only one property, PowerShell can collapse it to a scalar string (no .Count).
  # Force an array return.
  return ,(@($obj.PSObject.Properties | ForEach-Object { $_.Name }))
}


function Normalize-SubsConfig($cfg) {
  if (-not $cfg) {
    $cfg = [pscustomobject]@{ default = $null; subscriptions = [pscustomobject]@{} }
  }

  # Ensure subscriptions exists and is a mutable object
  if (-not $cfg.PSObject.Properties["subscriptions"]) {
    $cfg | Add-Member -NotePropertyName "subscriptions" -NotePropertyValue ([pscustomobject]@{})
  }
  if ($cfg.subscriptions -is [hashtable]) {
    $cfg.subscriptions = [pscustomobject]$cfg.subscriptions
  }

  $names = Get-PropNames $cfg.subscriptions

  # Remove template keys if present (lab/prod)
  foreach ($k in @("lab","prod")) {
    if ($names -contains $k) {
      $cfg.subscriptions.PSObject.Properties.Remove($k)
    }
  }

  # Refresh
  $names = Get-PropNames $cfg.subscriptions

  # Ensure default is valid
  if ($cfg.default -and -not ($names -contains $cfg.default)) {
    $cfg.default = $null
  }
  if (-not $cfg.default -and $names.Count -gt 0) {
    $cfg.default = $names[0]
  }

  return $cfg
}

function Next-Key($cfg) {
  $i = 1
  while ($true) {
    $k = ("sub{0:00}" -f $i)
    $names = Get-PropNames $cfg.subscriptions
    if (-not ($names -contains $k)) { return $k }
    $i++
  }
}

function Get-ToolFingerprint {
  $azVer = $null
  if (HasCmd "az") {
    try { $azVer = ((az version --output json | ConvertFrom-Json)."azure-cli") } catch {}
  }

  $bicepVer = $null
  if (HasCmd "az") {
    try { $bicepVer = (az bicep version 2>$null) } catch {}
  }

  $azModuleVer = $null
  try {
    $m = Get-Module -ListAvailable -Name Az -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($m) { $azModuleVer = "$($m.Version)" }
  } catch {}

  return [pscustomobject]@{
    az_cli = $azVer
    bicep  = $bicepVer
    az_ps  = $azModuleVer
  }
}

function Setup-Is-Current {
  $state = Read-Json $statePath
  if (-not $state) { return $false }

  $fpNow = Get-ToolFingerprint
  return (
    $state.tooling.az_cli -eq $fpNow.az_cli -and
    $state.tooling.bicep  -eq $fpNow.bicep  -and
    $state.tooling.az_ps  -eq $fpNow.az_ps
  )
}

function Mark-Setup-Current {
  $fpNow = Get-ToolFingerprint
  $state = [pscustomobject]@{
    updated_at = (Get-Date).ToString("o")
    tooling = $fpNow
  }
  Write-Json $statePath $state
}

function Prompt-Login-Now {
  $ans = Read-Host "Login now in browser? (y/n)"
  return ($ans.Trim().ToLower() -eq "y")
}

function Run-Az-Login {
  Write-Host "Running: az login" -ForegroundColor Yellow
  az login | Out-Null
  az account show 1>$null 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Wizard-Subscriptions {
  Title "Subscription Setup"

  if (-not (HasCmd "az")) {
    Write-Host "Azure CLI (az) missing. Run setup first (.packages/setup.ps1)." -ForegroundColor Yellow
    return $false
  }

  $cfg = Normalize-SubsConfig (Read-Json $subsPath)

  # Ensure we are authenticated enough to list accounts
  if (-not (Az-Authenticated)) {
    Write-Host "Azure CLI not authenticated." -ForegroundColor Yellow
    if (-not (Prompt-Login-Now)) { return $false }
    if (-not (Run-Az-Login)) { throw "az login failed or was cancelled." }
  }

  Write-Host "Paste subscription IDs (GUID). Type 'done' when finished." -ForegroundColor Gray
  Write-Host "If a subscription is not visible, you may need to login to another account/tenant." -ForegroundColor DarkGray

  while ($true) {
    $raw = Read-Host "Subscription ID (or 'done')"
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $raw = $raw.Trim()
    if ($raw.ToLower() -eq "done") { break }

    if ($raw -notmatch '^[0-9a-fA-F-]{36}$') {
      Write-Host "That does not look like a subscription GUID. Try again." -ForegroundColor Yellow
      continue
    }

    while ($true) {
      $subs = az account list -o json | ConvertFrom-Json
      $match = $subs | Where-Object { $_.id -eq $raw } | Select-Object -First 1

      if (-not $match) {
        Write-Host "Subscription not visible in current az context." -ForegroundColor Yellow
        if (-not (Prompt-Login-Now)) { break }
        if (-not (Run-Az-Login)) {
          Write-Host "Login did not complete. Try again later." -ForegroundColor Yellow
          break
        }
        continue
      }

      # De-dupe by ID
      $existingKey = $null
      foreach ($p in @($cfg.subscriptions.PSObject.Properties)) {
        if ($p.Value.id -eq $match.id) { $existingKey = $p.Name; break }
      }
      if ($existingKey) {
        Write-Host "Already saved: $($match.name) ($existingKey)" -ForegroundColor Yellow
        break
      }

      $key = Next-Key $cfg
      $cfg.subscriptions | Add-Member -NotePropertyName $key -NotePropertyValue ([pscustomobject]@{
        id       = $match.id
        name     = $match.name
        tenantId = $match.tenantId
      })

      if (-not $cfg.default) { $cfg.default = $key }

      Write-Host "Saved: [$key] $($match.name)" -ForegroundColor Green
      break
    }
  }

  $cfg = Normalize-SubsConfig $cfg

  # If still no subscriptions, nothing to do
  if (@($cfg.subscriptions.PSObject.Properties).Count -eq 0) {
    Write-Host "No subscriptions saved." -ForegroundColor Yellow
    return $false
  }

  # Default selection prompt only if more than one subscription
  if (@($cfg.subscriptions.PSObject.Properties).Count -gt 1) {
    Write-Host ""
    Write-Host "Choose default subscription:" -ForegroundColor Cyan
    $items = @()
    $i = 1
    foreach ($p in @($cfg.subscriptions.PSObject.Properties)) {
      $isDefault = ($p.Name -eq $cfg.default)
      Write-Host ("{0}) {1} [{2}]{3}" -f $i, $p.Value.name, $p.Name, $(if ($isDefault){"  (current default)"}else{""})) -ForegroundColor Gray
      $items += $p.Name
      $i++
    }

    $ans = Read-Host "Default number (Enter keeps current)"
    if (-not [string]::IsNullOrWhiteSpace($ans)) {
      $n = 0
      if ([int]::TryParse($ans.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $items.Count) {
        $cfg.default = $items[$n - 1]
      }
    }
  }

  Write-Json $subsPath $cfg

  # Set active subscription once
  $def = $cfg.subscriptions.($cfg.default)
  Write-Host ""
  Write-Host "Setting active subscription -> $($def.name)" -ForegroundColor Cyan
  az account set --subscription $def.id | Out-Null

  $active = az account show --query "{name:name, id:id, user:user.name}" -o json | ConvertFrom-Json
  Write-Host "Active: $($active.name) [$($active.id)]" -ForegroundColor Green
  Write-Host "Saved: .data/subs.json (gitignored)" -ForegroundColor DarkGray

  return $true
}

function Show-Status {
  Title "Status"

  if (HasCmd "az") {
    az account show 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) {
      az account show --query "{name:name, id:id, user:user.name}" -o table
    } else {
      Write-Host "Azure: not authenticated" -ForegroundColor Yellow
    }
  } else {
    Write-Host "Azure CLI (az): missing" -ForegroundColor Yellow
  }

  $cfg = Normalize-SubsConfig (Read-Json $subsPath)
  Write-Host ""
  if (@($cfg.subscriptions.PSObject.Properties).Count -gt 0) {
    Write-Host "Subscriptions (.data/subs.json):" -ForegroundColor Cyan
    foreach ($p in @($cfg.subscriptions.PSObject.Properties)) {
      $mark = if ($cfg.default -eq $p.Name) { "*" } else { " " }
      "{0} {1,-5}  {2}" -f $mark, $p.Name, $p.Value.name
    }
    Write-Host "Default: $($cfg.default)" -ForegroundColor Gray
  } else {
    Write-Host "Subscriptions: not configured (run .\run.ps1 and add your IDs)" -ForegroundColor Yellow
  }

  Write-Host ""
  if (Test-Path $statePath) {
    $s = Read-Json $statePath
    Write-Host "Tooling state: OK (cached)" -ForegroundColor Green
    Write-Host "Last verified: $($s.updated_at)" -ForegroundColor DarkGray
  } else {
    Write-Host "Tooling state: not verified yet" -ForegroundColor Yellow
  }
}

function Show-Help {
  Title "run.ps1"
  Write-Host "Just run:" -ForegroundColor Cyan
  Write-Host "  .\run.ps1" -ForegroundColor Gray
  Write-Host ""
  Write-Host "Optional:" -ForegroundColor Cyan
  Write-Host "  .\run.ps1 status" -ForegroundColor Gray
  Write-Host "  .\run.ps1 help" -ForegroundColor Gray
}

function Needs-Work {
  # needs subscription config
  $cfg = Normalize-SubsConfig (Read-Json $subsPath)
  $needsSubs = (@($cfg.subscriptions.PSObject.Properties).Count -eq 0)

  # needs tooling verification
  $needsSetup = (-not (Test-Path $statePath)) -or (-not (Setup-Is-Current))

  # needs az auth (only if we already have subs to operate)
  $needsAuth = $false
  if (-not $needsSubs) {
    $needsAuth = (-not (Az-Authenticated))
  }

  return [pscustomobject]@{
    needsSubs  = $needsSubs
    needsSetup = $needsSetup
    needsAuth  = $needsAuth
  }
}

function Run-Main {
  Title "Azure Labs – Run"
  Ensure-Dirs

  $w = Needs-Work

  # FAST PATH: ready -> status and exit
  if (-not $w.needsSubs -and -not $w.needsSetup -and -not $w.needsAuth) {
    Show-Status
    Write-Host ""
    Write-Host "Ready." -ForegroundColor Green
    return
  }

  # SLOW PATH: do actual work (log it)
  Start-Transcript -Path $logFile -Append | Out-Null
  try {
    Write-Host "Working... (log: $logFile)" -ForegroundColor DarkGray

    # 1) Subscriptions/auth first (only if missing)
    if ($w.needsSubs -or $w.needsAuth) {
      $ok = Wizard-Subscriptions
      if (-not $ok) {
        Write-Host "Subscription setup not completed." -ForegroundColor Yellow
      }
    }

    # 2) Tooling/self-test only if needed
    if (-not (Test-Path $pkgSetup)) { throw "Missing: scripts/setup.ps1" }
    if (-not (Setup-Is-Current)) {
      Write-Host ""
      Write-Host "Tooling + self-test" -ForegroundColor Cyan
      & $pkgSetup
      Mark-Setup-Current
    }

    Show-Status
    Write-Host ""
    Write-Host "Ready." -ForegroundColor Green
  }
  finally {
    Stop-Transcript | Out-Null
  }
}

# Entry
if ($args.Count -gt 0) {
  $a0 = $args[0].ToString().ToLower()
  if ($a0 -eq "help") { Show-Help; exit 0 }
  if ($a0 -eq "status") { Show-Status; exit 0 }
}

Run-Main
