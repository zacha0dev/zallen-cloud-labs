#!/usr/bin/env node
// SessionStart hook. Prints a short briefing that Claude Code adds to the session context:
// repo version and branch, whether the Azure CLI is signed in, and which labs have live
// resource groups (found by tag, so it costs nothing to check).
// Read-only. Never prints subscription or tenant IDs.

import { execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = process.env.CLAUDE_PROJECT_DIR || process.cwd();
const run = (cmd, ms = 15000) => {
  try { return execSync(cmd, { cwd: root, timeout: ms, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim(); }
  catch { return null; }
};

const lines = [];
let version = '?';
try { version = readFileSync(join(root, 'VERSION'), 'utf8').trim(); } catch {}
const branch = run('git rev-parse --abbrev-ref HEAD', 5000) || '?';
lines.push(`Repo: v${version} on branch ${branch}.`);

const signedIn = run('az account show --query "user.type" -o tsv', 10000);
if (!signedIn) {
  lines.push('Azure CLI: not signed in (run: .\\lab.ps1 -Login). Measurement commands will fail until then.');
} else {
  lines.push('Azure CLI: signed in.');
  const live = run('az group list --tag project=azure-labs --query "[].{rg:name, lab:tags.lab}" -o tsv');
  if (live === null) {
    lines.push('Live labs: could not check (az group list failed).');
  } else if (live === '') {
    lines.push('Live labs: none. Nothing from this repo is billing.');
  } else {
    const rows = live.split(/\r?\n/).filter(Boolean);
    lines.push(`Live labs (${rows.length} resource group(s) tagged project=azure-labs; these may be billing):`);
    for (const r of rows) lines.push('  - ' + r.replace('\t', '  lab='));
    lines.push('Mention these to the person early, and offer .\\lab.ps1 -Cost before deploying more.');
  }
}

lines.push('Rules: .claude/rules/. Nothing deploys or destroys without an explicit ask; claims need a measurement.');
process.stdout.write(lines.join('\n') + '\n');
