# Self-Hosted PaaS Cluster with Dokploy

A [Dokploy](https://dokploy.com/) cluster on Docker Swarm, on GCP, entirely from Terraform: one command brings up the VMs, the swarm, Dokploy, a container registry, OpenBao for secrets, self-hosted CI runners and an example app, each on its own HTTPS domain. DD2482 project (Samouil Mosios, Pavlos Spanoudakis). What runs where: [`ARCHITECTURE.md`](./ARCHITECTURE.md); why it's built this way: [`DESIGN.md`](./DESIGN.md); the build log: [`PLAN.md`](./PLAN.md).

## Requirements

- `terraform` ≥ 1.11, `gcloud`, `gh`, `curl`, `jq`, `git`
- A GCP project (`devops-project-510215`) with billing on, and you as its owner:
  `gcloud auth application-default login`
- `gh auth login`, with the `repo` and `workflow` scopes (the default)
- A Cloudflare API token with DNS Edit on the `sammosios.com` zone
- A fine-grained GitHub token for the CI runners: this repo only, Administration read/write, Metadata read-only

## One-time setup

```
cp terraform/gcp/terraform.tfvars.example terraform/gcp/terraform.tfvars
cp terraform/services/terraform.tfvars.example terraform/services/terraform.tfvars
```

Fill them in: your ssh public key, the Cloudflare zone id and token, Dokploy's admin name and email, and the runners' GitHub token. Both files are gitignored. Everything else (every password, key and token the cluster uses) is generated.

## Commands

```
./up.sh      # bring the cluster up, or bring it in line with the code
./down.sh    # tear it down (the state bucket stays)
```

`up.sh` applies five Terraform stages in order and waits between them for what the next one needs; see the top of the script, or DESIGN.md "Provisioning". It's safe to re-run: a stage with nothing to change does nothing. A fresh cluster takes about 20 minutes, most of it the control plane installing Dokploy and CI building the first image.

To change one stage, apply it on its own: `terraform -chdir=terraform/<stage> apply`. The stages are `bootstrap`, `gcp`, `platform`, `services` and `apps/roster`.

## What you get

| | |
|---|---|
| Dokploy | `https://dokploy.sammosios.com`. Admin: the email in `terraform/gcp/terraform.tfvars`, password from `terraform -chdir=terraform/gcp output -raw dokploy_admin_password` |
| OpenBao | `https://bao.sammosios.com/ui`. User `terraform`, password in the `dokploy-openbao-password` secret in Secret Manager |
| Roster | `https://roster.sammosios.com`, the example app ([`web-app/`](./web-app)), 2 replicas, with its own PostgreSQL and Redis. First admin: `terraform -chdir=terraform/apps/roster output -raw admin_password` |
| Registry | `127.0.0.1:5000` on every node, registered in Dokploy as `cluster-registry` |
| CI | one self-hosted runner per worker: `runs-on: [self-hosted, dokploy]` |
| Nodes | `dokploy-cp` (e2-medium) and `dokploy-worker-1..2` (e2-small) in `europe-north1-a`; ssh as `ubuntu` with your key |

**Deploying the app** is CI's job: push a change under `web-app/` to `main`, and the workflow tests it, builds and scans the image, pushes it and tells Dokploy to run it. Terraform decides how the app runs, CI which version.

**Adding an app** with secrets from OpenBao: [APP-PROJECT-SETUP.md](APP-PROJECT-SETUP.md).

**Scaling** workers: set `worker_count` in `terraform/gcp/terraform.tfvars` and run `./up.sh`. New workers join the swarm by themselves and get a CI runner.

**Debugging a node:** its setup log is `sudo journalctl -u google-startup-scripts` on it.
