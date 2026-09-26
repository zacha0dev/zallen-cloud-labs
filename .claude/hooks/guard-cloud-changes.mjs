#!/usr/bin/env node
// PreToolUse hook (matcher: Bash).
// Reads the tool call from stdin. If the shell command would change cloud resources outside
// the repo's lanes, asks the person to approve it instead of letting it run silently.
// Read-only commands (show, list, query, what-if) pass straight through.
// No dependencies; needs Node 18+ on PATH (.claude/setup.ps1 checks for it).

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { raw += c; });
process.stdin.on('end', () => {
  let cmd = '';
  try { cmd = (JSON.parse(raw).tool_input || {}).command || ''; } catch { process.exit(0); }
  const reason = check(cmd);
  if (!reason) process.exit(0);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'ask',
      permissionDecisionReason: reason + ' See .claude/rules/safety.md and .claude/skills/infra-lane.',
    },
  }));
  process.exit(0);
});

function check(cmd) {
  const c = cmd.replace(/\s+/g, ' ');

  // The repo's own entry point: deploy/destroy with -Force skips the cost prompt.
  if (/lab\.ps1\b.*-(Deploy|Destroy)\b/i.test(c) && /-Force\b/i.test(c)) {
    return 'lab.ps1 with -Force skips the cost/confirmation prompt. Confirm the person already agreed to this deploy or destroy.';
  }
  if (/lab\.ps1\b.*-Destroy\b/i.test(c)) {
    return 'This destroys a lab. Confirm it was asked for in this session.';
  }

  // Direct Azure CLI changes outside the lanes.
  if (/\baz\s+deployment\s+(group|sub|mg|tenant)\s+create\b/i.test(c)) {
    return 'Applies a deployment. Run what-if first and confirm the diff with the person.';
  }
  const azMutating = /\baz\s+(?!.*\bwhat-if\b)[\w\s-]*?\b(create|delete|purge|update|set|start|stop|restart|deallocate|invoke|import|assign|reset|rotate|regenerate)\b/i;
  if (azMutating.test(c)) {
    return 'Direct az command that changes resources. Changes should go through the infra lane (code, what-if, apply, verify).';
  }

  // Azure PowerShell, Terraform, AWS CLI equivalents.
  if (/\b(Remove|New|Set|Update|Stop|Restart)-Az\w+/i.test(c)) {
    return 'Azure PowerShell command that changes resources.';
  }
  if (/\bterraform\s+(apply|destroy|import|state\s+rm)\b/i.test(c)) {
    return 'Terraform change. Run terraform plan and confirm the plan first.';
  }
  if (/\baws\s+\S+\s+(delete|terminate|create|put|update|modify|run-instances)[\w-]*/i.test(c)) {
    return 'AWS CLI command that changes resources.';
  }
  return '';
}
