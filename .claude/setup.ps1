<#
.SYNOPSIS
  Checks the tools the Claude Code package in .claude/ needs, then prints prompts to try first.

.DESCRIPTION
  Read-only. Installs nothing and changes nothing in Azure. Works on Windows PowerShell 5.1
  and PowerShell 7.

.EXAMPLE
  .\.claude\setup.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$missing = 0

function Test-Tool {
  param([string]$Name, [string]$Command, [string]$VersionArgs, [string]$Why, [string]$Install, [switch]$Optional)
  $found = Get-Command $Command -ErrorAction SilentlyContinue
  if ($found) {
    $ver = ''
    try { $ver = (& $Command $VersionArgs.Split(' ') 2>$null | Select-Object -First 1) } catch { $ver = '' }
    Write-Host ("  [ok]   {0,-12} {1}" -f $Name, $ver) -ForegroundColor Green
    return $true
  }
  if ($Optional) {
    Write-Host ("  [skip] {0,-12} not found ({1})" -f $Name, $Why) -ForegroundColor Yellow
    return $true
  }
  Write-Host ("  [miss] {0,-12} {1}. Install: {2}" -f $Name, $Why, $Install) -ForegroundColor Red
  return $false
}

Write-Host ''
Write-Host 'Claude Code package for zallen-cloud-labs: prerequisite check' -ForegroundColor Cyan
Write-Host ''

$psv = $PSVersionTable.PSVersion
Write-Host ("  [ok]   {0,-12} {1}" -f 'PowerShell', $psv.ToString()) -ForegroundColor Green

if (-not (Test-Tool -Name 'git' -Command 'git' -VersionArgs '--version' -Why 'needed to clone and branch' -Install 'https://git-scm.com/downloads')) { $missing++ }
if (-not (Test-Tool -Name 'Azure CLI' -Command 'az' -VersionArgs '--version' -Why 'every lab deploys with it' -Install '.\lab.ps1 -Setup')) { $missing++ }
if (-not (Test-Tool -Name 'Claude Code' -Command 'claude' -VersionArgs '--version' -Why 'runs the agents and skills' -Install 'https://docs.claude.com/en/docs/claude-code/setup')) { $missing++ }
if (-not (Test-Tool -Name 'Node.js' -Command 'node' -VersionArgs '--version' -Why 'runs the two hooks in .claude/hooks' -Install 'https://nodejs.org (18 or newer)')) { $missing++ }
[void](Test-Tool -Name 'Bicep' -Command 'bicep' -VersionArgs '--version' -Why 'optional; az uses its own copy' -Install '' -Optional)

# Azure sign-in (read-only; prints no IDs)
$signedIn = $false
if (Get-Command az -ErrorAction SilentlyContinue) {
  $userType = az account show --query "user.type" -o tsv 2>$null
  if ($LASTEXITCODE -eq 0 -and $userType) { $signedIn = $true }
}
if ($signedIn) {
  Write-Host ("  [ok]   {0,-12} signed in" -f 'Azure login') -ForegroundColor Green
} else {
  Write-Host ("  [todo] {0,-12} not signed in. Run: .\lab.ps1 -Login" -f 'Azure login') -ForegroundColor Yellow
}

# Package files present
$expected = @('settings.json', 'hooks\session-start.mjs', 'hooks\guard-cloud-changes.mjs', 'rules\safety.md', 'rules\scope.md')
foreach ($rel in $expected) {
  $p = Join-Path $PSScriptRoot $rel
  if (-not (Test-Path $p)) {
    Write-Host ("  [miss] .claude\{0}" -f $rel) -ForegroundColor Red
    $missing++
  }
}

Write-Host ''
if ($missing -gt 0) {
  Write-Host ("{0} required item(s) missing. Fix those, then run this again." -f $missing) -ForegroundColor Red
  exit 1
}

Write-Host 'Ready. From the repo root, start Claude Code:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  claude'
Write-Host ''
Write-Host 'First prompts to try (each one is safe; nothing deploys without you typing yes):' -ForegroundColor Cyan
Write-Host ''
Write-Host '  1. "What labs are live right now, and what are they costing me?"'
Write-Host '  2. "Plan a deploy of lab-000 and walk me through what it will create."'
Write-Host '  3. "Deploy lab-000, prove it worked, then destroy it and prove nothing is left."'
Write-Host '  4. "Explain lab-004 in plain words: what question does it answer?"'
Write-Host '  5. "Audit the lab-007 README for claims we have not measured."'
Write-Host ''
Write-Host ("Guide: {0}" -f (Join-Path $RepoRoot 'docs\AGENTIC-OPS.md'))
Write-Host ''
