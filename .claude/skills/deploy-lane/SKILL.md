---
name: deploy-lane
description: Use when application code (not infrastructure) is being shipped onto lab infrastructure: a container, a web app, a VM service, e.g. the FastAPI app behind App Gateway and Front Door in lab-002. Build, gate, roll, verify, in that order.
---

# Deploy lane: build → gate → roll → verify

The infra lane builds the house; this lane moves the furniture in. Keep them separate: an app
release should never quietly change a network, and an infra change should never ship code.

## 1. Build

Produce one artifact per release (a container image, a zip, a package) and give it a version
that points back to a commit.

```powershell
$version = git rev-parse --short HEAD
docker build -t acme-web:$version ./app        # example; use your lab's build step
```

## 2. Gate

Nothing rolls unless the artifact passes, **locally, before it touches the cloud**:

- tests pass (`pytest`, `npm test`, whatever the app uses)
- it starts and answers a health endpoint (`/healthz` returns 200)
- no secrets baked into the artifact (config comes from the environment)

If the gate fails, stop. Don't "roll and see".

## 3. Roll

Replace what is running with the new artifact, one step at a time, keeping the previous version
available to roll back to:

- App Service / Container Apps: deploy to a slot or a new revision, then shift traffic.
- VMs: update one instance, verify it, then the rest.
- Anything else: whatever lets you go back in one command.

Write the rollback command down **before** you roll.

## 4. Verify

Measure the running thing through the same path a user takes, read-only:

```powershell
curl -sI https://app.acme.example/healthz          # through the front door, not the VM
az webapp show -n acme-web -g rg-acme-lab --query state -o tsv
```

"Released" is said only when the health check through the public path passes
(see `skills/measure-before-claiming`). If it fails, run the rollback you wrote down.
