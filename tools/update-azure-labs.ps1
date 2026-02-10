<#
.SYNOPSIS
    Updates the azure-labs repository safely.

.DESCRIPTION
    Client-facing updater for the Azure Labs package. Pulls the latest labs,
    scripts, and docs from GitHub. Automatically handles local changes by
    stashing them before update and restoring them after.

    After pulling, runs setup.ps1 -Status so you know if your tools are current.

    Can be run from any working directory - it will detect the repository root.

.EXAMPLE
    .\tools\update-azure-labs.ps1

    # Or from anywhere via the wrapper:
    .\update.ps1

.NOTES
    Compatible with Windows PowerShell 5.1 and PowerShell 7+
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Helper Functions ---
function Write-Step {
    param([string]$Message)
    Write-Host "  -> $Message" -ForegroundColor White
}

function Write-Pass {
    param([string]$Message)
    Write-Host "  [PASS] " -ForegroundColor Green -NoNewline
    Write-Host $Message -ForegroundColor White
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] " -ForegroundColor Red -NoNewline
    Write-Host $Message -ForegroundColor White
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message -ForegroundColor White
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] " -ForegroundColor Cyan -NoNewline
    Write-Host $Message -ForegroundColor White
}

function Write-Detail {
    param([string]$Label, [string]$Value)
    Write-Host "         $Label" -ForegroundColor Gray -NoNewline
    Write-Host " $Value" -ForegroundColor White
}

function Test-GitInstalled {
    try {
        $null = Get-Command git -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-RepoRoot {
    # Try to find repo root from script location first
    $scriptDir = $PSScriptRoot
    if ($scriptDir) {
        # Script is in tools/, so repo root is parent
        $candidate = Split-Path $scriptDir -Parent
        if (Test-Path (Join-Path $candidate ".git")) {
            return $candidate
        }
    }

    # Fall back to searching from current directory upward
    $current = Get-Location
    while ($current) {
        $gitDir = Join-Path $current.Path ".git"
        if (Test-Path $gitDir) {
            return $current.Path
        }
        $parent = Split-Path $current.Path -Parent
        if (-not $parent -or $parent -eq $current.Path) {
            break
        }
        $current = Get-Item $parent
    }

    return $null
}

function Test-WorkingTreeClean {
    param([string]$RepoPath)

    Push-Location $RepoPath
    try {
        $status = git status --porcelain 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{ Clean = $false; Error = "Failed to check git status" }
        }

        if ($status) {
            return @{ Clean = $false; Error = "Local changes detected" }
        }

        return @{ Clean = $true; Error = $null }
    } finally {
        Pop-Location
    }
}

function Get-CurrentBranch {
    param([string]$RepoPath)

    Push-Location $RepoPath
    try {
        $branch = git rev-parse --abbrev-ref HEAD 2>&1
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        return $branch.Trim()
    } finally {
        Pop-Location
    }
}

function Get-LatestCommit {
    param([string]$RepoPath)

    Push-Location $RepoPath
    try {
        $hash = git rev-parse --short HEAD 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }

        $message = git log -1 --format="%s" 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }

        return @{
            Hash = $hash.Trim()
            Message = $message.Trim()
        }
    } finally {
        Pop-Location
    }
}

function Get-LabVersion {
    param([string]$RepoPath)
    $versionFile = Join-Path $RepoPath "VERSION"
    if (Test-Path $versionFile) {
        return (Get-Content $versionFile -Raw).Trim()
    }
    return "unknown"
}

# --- Main Script ---

# Read current version before update
$preRepoRoot = Get-RepoRoot
$versionBefore = if ($preRepoRoot) { Get-LabVersion $preRepoRoot } else { "unknown" }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Azure Labs Updater" -ForegroundColor Cyan
if ($versionBefore -ne "unknown") {
    Write-Host "  Current: v$versionBefore" -ForegroundColor DarkCyan
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Check git is installed
Write-Step "Checking for Git..."
if (-not (Test-GitInstalled)) {
    Write-Fail "Git is not installed or not in PATH"
    Write-Host ""
    Write-Host "  Please install Git from: https://git-scm.com/" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Pass "Git is installed"

# Step 2: Find repository root
Write-Step "Locating repository..."
$RepoRoot = Get-RepoRoot
if (-not $RepoRoot) {
    Write-Fail "Not a git repository"
    Write-Host ""
    Write-Host "  This script must be run from within the azure-labs repository." -ForegroundColor Yellow
    Write-Host "  If you downloaded the ZIP, updates require re-downloading from GitHub." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  To clone the repository:" -ForegroundColor Cyan
    Write-Host "    git clone https://github.com/zacha0dev/zallen-cloud-labs.git" -ForegroundColor Gray
    Write-Host ""
    exit 1
}
Write-Pass "Repository found"
Write-Detail "Path:" $RepoRoot

# Step 3: Handle local changes (auto-stash)
Write-Step "Checking for local changes..."
$cleanCheck = Test-WorkingTreeClean -RepoPath $RepoRoot
$didStash = $false

if (-not $cleanCheck.Clean) {
    Write-Warn "Local changes detected — stashing automatically"
    Push-Location $RepoRoot
    try {
        $stashOutput = git stash push -m "azure-labs-update-autostash" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Could not stash local changes"
            Write-Host ""
            Write-Host "  Error: $stashOutput" -ForegroundColor Red
            Write-Host "  Please commit or manually stash your changes, then re-run .\update.ps1" -ForegroundColor Yellow
            Write-Host ""
            exit 1
        }
        $didStash = $true
        Write-Info "Changes stashed (will restore after update)"
    } finally {
        Pop-Location
    }
} else {
    Write-Pass "Working tree is clean"
}

# Step 4: Fetch from remote
Write-Step "Fetching from remote..."
Push-Location $RepoRoot
try {
    $fetchOutput = git fetch --all --prune 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to fetch from remote"
        Write-Host ""
        Write-Host "  Error: $fetchOutput" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Check your network connection and try again." -ForegroundColor Yellow
        Write-Host ""
        # Restore stash if we stashed
        if ($didStash) {
            git stash pop 2>&1 | Out-Null
            Write-Info "Local changes restored"
        }
        exit 1
    }
    Write-Pass "Fetched successfully"
} finally {
    Pop-Location
}

# Step 5: Pull with fast-forward only
Write-Step "Pulling latest changes..."
Push-Location $RepoRoot
try {
    $pullOutput = git pull --ff-only 2>&1
    $pullExitCode = $LASTEXITCODE

    if ($pullExitCode -ne 0) {
        if ($pullOutput -match "fatal.*not possible to fast-forward" -or
            $pullOutput -match "fatal.*Cannot fast-forward") {
            Write-Fail "Cannot fast-forward"
            Write-Host ""
            Write-Host "  Your local branch has diverged from the remote." -ForegroundColor Yellow
            Write-Host "  This usually means you have local commits." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Options:" -ForegroundColor Cyan
            Write-Host "    git pull --rebase     # Replay your commits on top of remote" -ForegroundColor Gray
            Write-Host "    git pull --no-ff      # Merge (keeps your commits)" -ForegroundColor Gray
            Write-Host ""
        } else {
            Write-Fail "Failed to pull"
            Write-Host ""
            Write-Host "  Error: $pullOutput" -ForegroundColor Red
            Write-Host ""
        }
        # Restore stash if we stashed
        if ($didStash) {
            git stash pop 2>&1 | Out-Null
            Write-Info "Local changes restored"
        }
        exit 1
    }

    if ($pullOutput -match "Already up to date" -or $pullOutput -match "Already up-to-date") {
        Write-Pass "Already up to date"
    } else {
        Write-Pass "Updated successfully"
    }
} finally {
    Pop-Location
}

# Step 6: Restore stashed changes
if ($didStash) {
    Write-Step "Restoring your local changes..."
    Push-Location $RepoRoot
    try {
        $popOutput = git stash pop 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Stash restore had conflicts"
            Write-Host ""
            Write-Host "  Your local changes conflicted with the update." -ForegroundColor Yellow
            Write-Host "  Your changes are still in the stash. To resolve:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "    git stash show         # See what was stashed" -ForegroundColor Gray
            Write-Host "    git stash pop          # Try again" -ForegroundColor Gray
            Write-Host "    git stash drop         # Discard stashed changes" -ForegroundColor Gray
            Write-Host ""
        } else {
            Write-Pass "Local changes restored"
        }
    } finally {
        Pop-Location
    }
}

# Step 7: Read version after update
$versionAfter = Get-LabVersion $RepoRoot

# Step 8: Run setup status check
Write-Host ""
Write-Step "Checking environment..."
$setupScript = Join-Path $RepoRoot "setup.ps1"
if (Test-Path $setupScript) {
    Push-Location $RepoRoot
    try {
        & $setupScript -Status
    } catch {
        Write-Warn "Setup status check failed: $($_.Exception.Message)"
        Write-Host "  Run .\setup.ps1 manually to fix." -ForegroundColor Yellow
    } finally {
        Pop-Location
    }
} else {
    Write-Warn "setup.ps1 not found — skipping environment check"
}

# Step 9: Summary
$branch = Get-CurrentBranch -RepoPath $RepoRoot
$commit = Get-LatestCommit -RepoPath $RepoRoot

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Update Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

if ($versionBefore -ne $versionAfter -and $versionAfter -ne "unknown") {
    Write-Info "Updated: v$versionBefore -> v$versionAfter"
} elseif ($versionAfter -ne "unknown") {
    Write-Info "Version: v$versionAfter"
}

Write-Detail "Branch:" $branch
if ($commit) {
    Write-Detail "Commit:" "$($commit.Hash) - $($commit.Message)"
}
Write-Detail "Path:" $RepoRoot
if ($didStash) {
    Write-Detail "Stash:" "Local changes were preserved"
}

Write-Host ""

exit 0
