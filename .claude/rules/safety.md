# Rule: safety

These hold in every session, for every agent.

## Nothing changes a cloud environment without an explicit ask

- Default mode is **plan and describe**. Deploying, destroying, or changing a resource needs the
  person to ask for it in this session.
- Every change goes through a lane (`skills/infra-lane` or `skills/deploy-lane`). No one-off
  `az ... create` or `az ... delete` typed straight into a shell. The pre-tool hook pauses those and asks the person first.
- Destroy is a change too. It needs the same explicit ask, even though it saves money.

## No identifiers or secrets in committed files

Never write any of these into a tracked file:

| Never commit | Resolve it at runtime from |
|---|---|
| Subscription or tenant IDs | `az account show` / `.data/subs.json` (gitignored) |
| Object, client or principal IDs | `az ad ... show` at run time |
| Emails, UPNs, real names in config | `az account show --query user.name`, `$env:USERNAME` |
| Keys, tokens, passwords, connection strings | the person's local profile or a key vault, never the repo |
| Real hostnames, IPs or domains from a live environment | outputs under `.data/` or `outputs/` (gitignored) |

Examples and docs use the fictional company **acme** (`rg-acme-web`, `acme.example`,
`app.acme.internal`). If you are about to type a GUID, an `@`, or a real domain into a tracked
file, stop and load it from the environment instead.

## Scope

- Work inside resource groups this repo creates (see `rules/scope.md`). Never touch resources
  that are not tagged as this repo's.
- Never change subscription-wide policy, directory (Entra ID) settings, or grant Owner or
  Contributor at subscription scope.
- If a subscription-level prerequisite is missing (a resource provider, a quota), report it
  with the exact command for the person to run. Don't run it yourself.

## Outward-facing actions need a yes

Pushing to `main`, publishing a release, making a repo public, or posting anywhere outside the
session: describe it first, then wait for the person to say yes.

## When a claim is made, it is measured

"Deployed", "healthy", "resolves", "cleaned up", "no cost" are claims. Make them only after a
read-only check (see `skills/measure-before-claiming`), and show the check.
