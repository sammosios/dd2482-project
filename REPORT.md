# A Self-Hosted PaaS with Dokploy, Built from Code

DD2482 DevOps, project report · Samouil Mosios, Pavlos Spanoudakis · 2026-10-08

## 1. What the project demonstrates

We built a small self-hosted Platform-as-a-Service: a Docker Swarm cluster on Google Cloud, managed by [Dokploy](https://dokploy.com), that can be created from nothing and torn down again with one command each (`./up.sh`, `./down.sh`). The proposal committed us to demonstrating five things, and each is running on the cluster:

| Feature | How it is shown |
|---|---|
| A PaaS on a multi-node cluster | Dokploy on a 3-node Swarm (1 manager, 2 workers); every service is deployed and visible through it, at <https://dokploy.sammosios.com> |
| Self-hosted CI | GitHub Actions runners that run inside the cluster, one per worker |
| An example app with a database | Roster (Go + htmx), 2 replicas with PostgreSQL and Redis, at <https://roster.sammosios.com> |
| A secrets vault | OpenBao, which Dokploy queries at deploy time, so apps never hold vault credentials |
| Security scanning | Trivy gates CI twice: a committed secret anywhere in the repository stops the image from being built, and HIGH/CRITICAL vulnerabilities with a fix fail the built image |

The sixth, implicit requirement is **reproducibility**: everything above, including VMs, DNS, certificates and every generated password, comes from the repository, with no manual steps. Section 5 is honest about how close we got.

To try the running cluster (logins, and what to look at in each service), see [`WALKTHROUGH.md`](./WALKTHROUGH.md).

## 2. Architecture

```
                 Internet ── 443/80 ──►  Traefik (control plane)
                                          │ dokploy.… │ bao.… │ roster.…
  ┌─────────────── GCP VPC 10.10.0.0/24, MTU 1500 ─────────────────────┐
  │ dokploy-cp (manager, e2-medium)   │ dokploy-worker-1/2 (e2-small) │
  │  Dokploy + its Postgres, Traefik  │  CI runner (one per worker)   │
  │  Registry :5000 (routing mesh)    │  Roster replicas              │
  │  OpenBao (Raft, auto-unseal)      │                                │
  │  Roster's PostgreSQL + Redis      │                                │
  └──────────── Swarm overlay network "dokploy-network" ───────────────┘
```

**Cloud layer.** Three Ubuntu 24.04 VMs in `europe-north1`, in their own VPC. The firewall admits ssh, 80/443 to the control plane only, and Swarm's ports between the nodes. A small iptables "port guard" on each node closes Dokploy, the registry and OpenBao again, in case a firewall rule is loosened. Cloudflare holds three DNS records pointing at the control plane's static IP.

**Platform layer.** Dokploy runs on the Swarm manager and manages everything else as Swarm services. Services that keep data in node-local volumes (registry, OpenBao, the databases) are pinned to the manager. Stateless ones (the app, the runners) run on the workers. Traefik, installed by Dokploy, is the single entry point and obtains Let's Encrypt certificates per domain.

**Code layer.** Five Terraform stages build this bottom-up: `bootstrap` (a GCS bucket for state), `gcp` (network, VMs, DNS, Secret Manager), `platform` (registry, OpenBao), `services` (OpenBao configuration, CI runners) and `apps/roster` (the example app). `ARCHITECTURE.md` lists every resource.

## 3. Processes

**Provisioning.** `up.sh` applies the stages in order and waits between them for what the next one needs. The VMs set themselves up from GCE startup scripts: they install Docker and Dokploy, form the swarm (workers fetch the join token through Google Secret Manager), and the control plane creates Dokploy's first admin and an API key through Dokploy's own sign-up endpoints, then puts Dokploy on its domain. The later stages read that key from Secret Manager, so the operator's machine never needs ssh. A fresh cluster takes about 20 minutes, mostly Dokploy's install and the first CI build.

**Delivery.** A push to `main` that touches the app runs CI on the in-cluster runners: tests and a Trivy secret scan of the whole repository in parallel, then, only if both pass, the image build, a Trivy report and gate, a push to the cluster registry tagged with the commit, then Dokploy's API is told to run the new image. The job waits until the app answers. On a fresh cluster, `up.sh` triggers the same workflow for the first image, so there is exactly one way an image reaches production.

To show the secret scan working, we committed a dummy GitHub token into the app's source (`web-app/auth.go`) and pushed it to `main`. In [that run](https://github.com/sammosios/dd2482-project/actions/runs/37439290067) the tests passed, the secret scan reported a CRITICAL "GitHub Personal Access Token" at `web-app/auth.go:21` and failed, and the image and deploy jobs were skipped: nothing was built or deployed. The image scan alone would not have caught it, because it only looks for vulnerable packages, and the token would have been an ordinary string compiled into the binary.

**Secrets.** OpenBao initializes itself on first start (OpenBao 2.7's declarative self-initialization), creating only a login for Terraform; no root token is ever handed out. Terraform then writes each project's secrets and creates, per Dokploy project, a policy, a token and a Dokploy "secrets provider". Apps' environment variables hold references such as `${{vault.bao-roster.roster/app:DATABASE_URL}}`, which Dokploy resolves when it deploys. The CI runners' GitHub token goes the same way.

## 4. How the components interact

- **User → app:** browser → Traefik (TLS) → a Roster replica on a worker over the overlay network → PostgreSQL and Redis on the manager, by service name.
- **Dokploy → OpenBao:** at every deploy, Dokploy's server fetches the referenced secrets from `http://openbao:8200` over the overlay, with that project's token only.
- **Nodes → registry:** every node pulls from `127.0.0.1:5000`. Swarm's routing mesh forwards it to the registry on the manager, so no node needs TLS or registry configuration.
- **CI → platform:** runners build with their node's Docker, push to the registry over the mesh, and call Dokploy's API over HTTPS with a dedicated key.
- **Terraform → everything:** GCP and Cloudflare APIs, then Dokploy's and OpenBao's APIs through their public HTTPS domains, and GitHub's API to hand CI its credentials.

## 5. Key design decisions

**Terraform, in stages.** We first built the setup as bash scripts calling Dokploy's API with idempotency checks around every call. The [`vanillauys/dokploy`](https://registry.terraform.io/providers/vanillauys/dokploy/latest) provider made most of that declarative, and Terraform added what the scripts never covered: the servers and DNS themselves. It had to be stages because a provider cannot be configured with a credential created in the same run (Dokploy's API key, OpenBao's login). The few things Terraform cannot do (installing software, the first admin) run on the VMs themselves rather than as Terraform provisioners, which would be the same scripts with worse error handling.

**Dokploy on Swarm.** Dokploy gives a Heroku-like UI and API over plain Docker Swarm, which is far lighter than Kubernetes for three small VMs. Its "Remote Servers" feature was rejected because each such server runs independently; we wanted one cluster.

**Terraform owns how the app runs, CI owns which version.** Terraform ignores the app's image. The alternative, committing each new tag and running Terraform from CI, would give CI the credentials to the entire platform instead of one Dokploy key.

**Secrets resolved by the platform.** Apps never authenticate to OpenBao, which sidesteps the question of how a workload gets its first credential. One provider per project gives two independent fences: Dokploy refuses cross-project references, and each token can only read its own path.

**Registry on the routing mesh.** Docker trusts plain HTTP on loopback, so `127.0.0.1:5000` works on every node with zero per-node setup. We use `127.0.0.1` rather than `localhost` because of a Docker bug (moby/moby#53091) in which IPv6 connections to Swarm-published ports hang.

**GCP + Cloudflare.** GCP gave us Secret Manager and a state bucket next to the VMs. We gave the cluster its own network because Swarm's overlay silently drops large packets on GCP's default 1460-byte MTU. Cloudflare is DNS only, so Traefik handles TLS itself.

## 6. Limitations and trade-offs

- **Single points of failure.** One Swarm manager, a single-node OpenBao, and databases and registry on node-local volumes: losing the control plane loses the cluster's data. Shared storage (a GCS-backed registry, managed databases) and three managers would fix this at a multiple of the cost.
- **Auto-unseal with a static key.** OpenBao unseals itself after restarts because its key is a Swarm secret on the same node as its data. Whoever owns the manager owns the secrets. Cloud KMS would be the production choice.
- **Secrets are not only in the vault.** Resolved values land in Swarm service specs on the manager, and every value Terraform generates is in its state. The state bucket is therefore access-controlled and versioned, and the runners' token is written write-only, so it never enters state.
- **Admin UIs on the internet.** Dokploy and OpenBao are public behind passwords and TLS. ssh is open to any address, with keys only. We chose convenience over an allowlist because our addresses change.
- **Provider gaps and upstream assumptions.** The admin bootstrap uses Dokploy's undocumented UI endpoints and may break on upgrades. Three provider gaps shaped the design: no Swarm placement, domains on stacks that need a redeploy, and a registry entry created before the registry answers. We worked around each in code, and each workaround is documented.
- **Reproducibility, measured.** Our first full `down.sh` → `up.sh` needed two runs of `up.sh`: the first gave up waiting for OpenBao's domain while OpenBao was healthy, most likely because of stale DNS for the control plane's new IP. The second run completed without intervention. Keeping the IP across rebuilds would remove the cause. Let's Encrypt's limit of 5 identical certificates per week also caps how often the cluster can be rebuilt with the same domains.
- **Small, shared-core workers.** e2-small workers throttle under sustained CI load, and CI jobs run with the node's Docker socket, making them root on the worker. That is acceptable for our own repository, not for untrusted pull requests.

Within those limits the cluster meets its goal: one command produces a working PaaS with CI, a vault and a scanned, deployed example app, and one command removes it.
