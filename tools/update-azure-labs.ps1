<#
.SYNOPSIS
    Updates the azure-labs repository safely.

.DESCRIPTION
    Fetches and pulls the latest changes from the remote repository.
    This script is safe: it never pushes, never resets, never stashes automatically.

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

# --- Configuration ---
$ScriptName = "Azure Labs Updater"
$ScriptVersion = "1.0.0"

# --- Helper Functions ---
function Write-Header {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $ScriptName" -ForegroundColor Cyan
    Write-Host "  v$ScriptVersion" -ForegroundColor DarkCyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

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
        # Check for uncommitted changes (staged or unstaged)
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

# --- Main Script ---
Write-Header

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
    Write-Host "    git clone https://github.com/zacha0dev/azure-labs.git" -ForegroundColor Gray
    Write-Host ""
    exit 1
}
Write-Pass "Repository found"
Write-Detail "Path:" $RepoRoot

# Step 3: Check working tree is clean
Write-Step "Checking for local changes..."
$cleanCheck = Test-WorkingTreeClean -RepoPath $RepoRoot
if (-not $cleanCheck.Clean) {
    Write-Fail "Local changes detected"
    Write-Host ""
    Write-Host "  Your working tree has uncommitted changes." -ForegroundColor Yellow
    Write-Host "  Please commit or stash your changes first:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    git stash           # Temporarily save changes" -ForegroundColor Gray
    Write-Host "    git stash pop       # Restore changes after update" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Or commit your changes:" -ForegroundColor Gray
    Write-Host "    git add ." -ForegroundColor Gray
    Write-Host "    git commit -m `"Your message`"" -ForegroundColor Gray
    Write-Host ""
    exit 1
}
Write-Pass "Working tree is clean"

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
        # Check if it's a non-fast-forward error
        if ($pullOutput -match "fatal.*not possible to fast-forward" -or
            $pullOutput -match "fatal.*Cannot fast-forward") {
            Write-Fail "Cannot fast-forward"
            Write-Host ""
            Write-Host "  Your local branch has diverged from the remote." -ForegroundColor Yellow
            Write-Host "  This usually means you have local commits that aren't on the remote." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  To resolve, choose one of these options:" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  Option 1: Merge (keeps your commits)" -ForegroundColor White
            Write-Host "    git pull --no-ff" -ForegroundColor Gray
            Write-Host ""
            Write-Host "  Option 2: Rebase (replays your commits on top)" -ForegroundColor White
            Write-Host "    git pull --rebase" -ForegroundColor Gray
            Write-Host ""
            Write-Host "  Option 3: Reset to remote (WARNING: loses local commits)" -ForegroundColor White
            Write-Host "    git reset --hard origin/<branch>" -ForegroundColor Gray
            Write-Host ""
            exit 1
        } else {
            Write-Fail "Failed to pull"
            Write-Host ""
            Write-Host "  Error: $pullOutput" -ForegroundColor Red
            Write-Host ""
            exit 1
        }
    }

    # Check if we got updates
    if ($pullOutput -match "Already up to date" -or $pullOutput -match "Already up-to-date") {
        Write-Pass "Already up to date"
    } else {
        Write-Pass "Updated successfully"
    }
} finally {
    Pop-Location
}

# Step 6: Show summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Update Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

$branch = Get-CurrentBranch -RepoPath $RepoRoot
$commit = Get-LatestCommit -RepoPath $RepoRoot

Write-Info "Current state:"
Write-Detail "Branch:" $branch
if ($commit) {
    Write-Detail "Commit:" "$($commit.Hash) - $($commit.Message)"
}
Write-Detail "Path:" $RepoRoot

Write-Host ""
Write-Host "  Run .\setup.ps1 -Status to check your environment." -ForegroundColor Gray
Write-Host ""

exit 0
