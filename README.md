# Self-Hosted PaaS Cluster with Dokploy

Reproducible Multipass VMs → Docker Swarm → [Dokploy](https://dokploy.com/) cluster, driven by a chain of bash scripts. DD2482 project (Samouil Mosios, Pavlos Spanoudakis) — see [`PLAN.md`](./PLAN.md) for the full design, decisions, and bugs found along the way. This README covers just what's needed to run it; it'll grow as the project does.

## Requirements

- [Multipass](https://multipass.run/) — provisions the VMs
- `curl`, `jq`
- **bash 4+** — macOS ships bash 3.2 by default, which is too old (`teardown.sh` uses `mapfile`, a bash 4+ builtin). Install a newer one (e.g. `brew install bash`) and make sure it's first in `PATH`; check with `bash --version`.
- ~2 CPU cores per VM, 4GB RAM for the control plane (`--cp-mem`) and 2GB per worker (`--mem`). Disks are 10G per worker and 30G for the control plane (`--cp-disk`), which holds the image builds and the registry. Multipass disks are sparse, so they only use host space as they fill. — `bootstrap.sh` estimates how many workers your machine can handle if you don't pass a count.
- If running from Windows: see PLAN.md's "Host OS notes" before using WSL2 — there's a real networking gap to know about first.

## One-time setup: admin credentials

```
cp .dokploy-admin.env.example .dokploy-admin.env
```

Fill in `DOKPLOY_ADMIN_NAME` / `DOKPLOY_ADMIN_EMAIL` / `DOKPLOY_ADMIN_PASSWORD` with real values (any strong password works, including ones with special characters). This file is gitignored and never committed. With it present, the whole cluster — including Dokploy's first admin account and API key — comes up with zero manual steps. Without it, you'll be prompted to create the admin account through the browser once and paste back a token; either way works.

## Optional: CI runners

```
cp .github-runner.env.example .github-runner.env
```

Put a GitHub PAT that can manage this repo's self-hosted runners in `GITHUB_RUNNER_PAT` (fine-grained: "Administration: Read and write" on the repo; classic: `repo` scope), or export `GITHUB_RUNNER_PAT` instead. The file is gitignored. Without either, `bootstrap.sh` skips the runners.

## Key commands

```
./bootstrap.sh 3        # bring up control plane + 3 workers (mandatory worker count,
                         # prompted with a device-capacity estimate if omitted)
./teardown.sh            # tear everything down (prompts for confirmation; -y to skip)
```

Both are safe to re-run. `bootstrap.sh` is idempotent — re-running it with the same or a higher worker count skips anything already up and only adds what's missing. **Known limitation**: re-running with a *lower* worker count does not scale down — extra workers are left running (see PLAN.md).

### If multipass itself breaks (macOS)

If every `multipass` command fails with `cannot connect to the multipass socket`, the daemon is probably crash-looping on a VM whose suspend state can't be restored. Both scripts need sudo.

```
./multipass-unsuspend.sh   # drop suspend state, keep all VMs and disks - try this first
./multipass-reset.sh       # wipe ALL multipass VMs and state, restart the daemon (-y to skip prompt)
```

Each phase is also its own standalone script if you need finer control: `00-launch-cp-vm.sh` → `01-dokploy-api-key.sh` → `02-launch-worker-vms.sh` → `03-setup-registry.sh` → `04-setup-ci-runner.sh` → `05-setup-openbao.sh` → `06-deploy-core-services.sh`. `bootstrap.sh` just chains these.

Deploying an app isn't part of bootstrap: when you have one, follow [APP-PROJECT-SETUP.md](APP-PROJECT-SETUP.md) to give its Dokploy project its own OpenBao secrets provider.

## What to expect right now

After `./bootstrap.sh N` finishes:

- `N + 1` Multipass VMs running (`dokploy-control-plane`, `dokploy-worker-1..N`)
- A Docker Swarm with the control plane as manager and all `N` workers `Ready`/`Active` (`docker node ls` on the control plane)
- Dokploy reachable at `http://<control-plane-ip>:3000`, logged in with the admin account from `.dokploy-admin.env`
- A container registry at `127.0.0.1:5000` on every node, pinned to the control plane and registered in Dokploy as `cluster-registry`. Its credentials are in `.registry-credentials` (gitignored).
- One self-hosted GitHub Actions runner per worker, if a PAT is configured (below). Target them with `runs-on: [self-hosted, dokploy]`.
- **No application services deployed yet** — `06-deploy-core-services.sh` is still a stub. The rest of the core service set (example app, database, Trivy scanning) is designed but not yet implemented; see PLAN.md's "Core services" checklist.

Every service runs from a compose file in [`stacks/`](./stacks), deployed as a Dokploy Compose resource of type Stack (see DESIGN.md "Services as code").

`./teardown.sh` returns you to a clean slate — no VMs, no stale local credentials.
