<#
.SYNOPSIS
    Checks for and applies lab package updates from GitHub.

.DESCRIPTION
    Helper script called by setup.ps1 during the setup flow.
    Fetches from remote, compares versions, and pulls latest if available.
    Handles local changes gracefully: asks user whether to keep or override.

    Not intended to be called directly — use .\setup.ps1 instead.

.NOTES
    Compatible with Windows PowerShell 5.1 and PowerShell 7+
#>

[CmdletBinding()]
param(
  [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
  $RepoRoot = $PSScriptRoot
  # Script is in scripts/, so repo root is parent
  $RepoRoot = Split-Path $RepoRoot -Parent
}

function Get-LabVersion {
  param([string]$Path)
  $versionFile = Join-Path $Path "VERSION"
  if (Test-Path $versionFile) {
    return (Get-Content $versionFile -Raw).Trim()
  }
  return $null
}

function Test-HasGit {
  try {
    $null = Get-Command git -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Test-IsGitRepo {
  param([string]$Path)
  return (Test-Path (Join-Path $Path ".git"))
}

# --- Main ---

Write-Host ""
Write-Host "Checking for updates..." -ForegroundColor Cyan
Write-Host ""

# Preflight: git must exist and this must be a repo
if (-not (Test-HasGit)) {
  Write-Host "  [--] Git not installed — skipping update check" -ForegroundColor Yellow
  return
}

if (-not (Test-IsGitRepo $RepoRoot)) {
  Write-Host "  [--] Not a git repository — skipping update check" -ForegroundColor Yellow
  Write-Host "       If you downloaded the ZIP, re-download from GitHub to update." -ForegroundColor Gray
  return
}

$currentVersion = Get-LabVersion $RepoRoot
if ($currentVersion) {
  Write-Host "  Current version: v$currentVersion" -ForegroundColor DarkGray
}

# Fetch from remote (silent)
Push-Location $RepoRoot
try {
  $fetchOutput = git fetch origin 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  [--] Could not reach GitHub — skipping update check" -ForegroundColor Yellow
    Write-Host "       Check your network connection. Setup will continue." -ForegroundColor Gray
    Write-Host ""
    return
  }
} finally {
  Pop-Location
}

# Compare local vs remote
Push-Location $RepoRoot
try {
  $branch = (git rev-parse --abbrev-ref HEAD 2>&1).Trim()
  $localHash = (git rev-parse HEAD 2>&1).Trim()
  $remoteRef = "origin/$branch"

  # Check if remote branch exists
  $remoteHash = git rev-parse $remoteRef 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ok] No remote branch to compare — skipping" -ForegroundColor DarkGray
    Write-Host ""
    return
  }
  $remoteHash = $remoteHash.Trim()

  if ($localHash -eq $remoteHash) {
    Write-Host "  [ok] Labs are up to date" -ForegroundColor Green
    Write-Host ""
    return
  }

  # Count how many commits behind
  $behind = git rev-list --count "HEAD..$remoteRef" 2>$null
  if (-not $behind) { $behind = "some" }
  Write-Host "  Updates available ($behind new commit$(if ($behind -ne '1') { 's' }))" -ForegroundColor Yellow
} finally {
  Pop-Location
}

# Check for local changes
Push-Location $RepoRoot
try {
  $dirtyFiles = git status --porcelain 2>&1
  $hasLocalChanges = [bool]$dirtyFiles
} finally {
  Pop-Location
}

# Ask user what to do
if ($hasLocalChanges) {
  Write-Host ""
  Write-Host "  You have local changes:" -ForegroundColor Yellow

  # Show changed files (just lab files, keep it clean)
  Push-Location $RepoRoot
  try {
    $changedFiles = git status --porcelain 2>&1
    $changedFiles | ForEach-Object {
      $line = $_.ToString().Trim()
      if ($line) {
        Write-Host "    $line" -ForegroundColor DarkGray
      }
    }
  } finally {
    Pop-Location
  }

  Write-Host ""
  Write-Host "  Options:" -ForegroundColor White
  Write-Host "    [K] Keep local changes (stash, update, restore)" -ForegroundColor Gray
  Write-Host "    [O] Override with latest (discard local changes to tracked files)" -ForegroundColor Gray
  Write-Host "    [S] Skip update (continue setup without updating)" -ForegroundColor Gray
  Write-Host ""
  $choice = Read-Host "  Choose [K/O/S]"
  $choice = $choice.Trim().ToUpper()

  if ($choice -eq "S") {
    Write-Host "  Skipped update." -ForegroundColor DarkGray
    Write-Host ""
    return
  }

  if ($choice -eq "O") {
    # Override: reset tracked files, pull
    Write-Host "  Overriding local changes with latest..." -ForegroundColor Yellow
    Push-Location $RepoRoot
    try {
      git checkout -- . 2>&1 | Out-Null
      git clean -fd 2>&1 | Out-Null
    } finally {
      Pop-Location
    }
    Write-Host "  [ok] Local changes discarded" -ForegroundColor Green
  } else {
    # Default to Keep: stash, pull, pop
    Write-Host "  Stashing local changes..." -ForegroundColor Gray
    Push-Location $RepoRoot
    try {
      git stash push -m "azure-labs-setup-autostash" 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Host "  [--] Could not stash changes — skipping update" -ForegroundColor Yellow
        Write-Host ""
        return
      }
    } finally {
      Pop-Location
    }
    Write-Host "  [ok] Changes stashed" -ForegroundColor Green
  }
} else {
  # No local changes — just confirm update
  $confirm = Read-Host "  Pull latest updates? (y/n)"
  if ($confirm.Trim().ToLower() -ne "y") {
    Write-Host "  Skipped." -ForegroundColor DarkGray
    Write-Host ""
    return
  }
}

# Pull latest
Write-Host "  Pulling latest from GitHub..." -ForegroundColor Gray
Push-Location $RepoRoot
try {
  $pullOutput = git pull --ff-only 2>&1
  $pullOk = ($LASTEXITCODE -eq 0)

  if (-not $pullOk) {
    # Try rebase as fallback
    $pullOutput = git pull --rebase 2>&1
    $pullOk = ($LASTEXITCODE -eq 0)
  }

  if ($pullOk) {
    $newVersion = Get-LabVersion $RepoRoot
    if ($currentVersion -and $newVersion -and $currentVersion -ne $newVersion) {
      Write-Host "  [ok] Updated: v$currentVersion -> v$newVersion" -ForegroundColor Green
    } else {
      Write-Host "  [ok] Updated successfully" -ForegroundColor Green
    }
  } else {
    Write-Host "  [--] Pull failed: $pullOutput" -ForegroundColor Yellow
    Write-Host "       Setup will continue with current version." -ForegroundColor Gray
  }
} finally {
  Pop-Location
}

# Restore stash if we stashed
if ($hasLocalChanges -and $choice -ne "O") {
  Write-Host "  Restoring your local changes..." -ForegroundColor Gray
  Push-Location $RepoRoot
  try {
    $popOutput = git stash pop 2>&1
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  [ok] Local changes restored" -ForegroundColor Green
    } else {
      Write-Host "  [--] Could not auto-restore changes (conflicts)" -ForegroundColor Yellow
      Write-Host "       Your changes are saved in: git stash list" -ForegroundColor Gray
      Write-Host "       Restore manually with: git stash pop" -ForegroundColor Gray
    }
  } finally {
    Pop-Location
  }
}

Write-Host ""
