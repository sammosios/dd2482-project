# Walkthrough

A 10-minute tour of the running cluster, for readers of [`REPORT.md`](./REPORT.md). Everything below is live until **27 October 2026**. To build your own copy instead, see [`README.md`](./README.md); it needs your own GCP project and a domain on Cloudflare.

## Logins

| Service | URL | Login |
|---|---|---|
| Roster (example app) | <https://roster.sammosios.com> | Sign up with any email; admin login on request |
| Dokploy (the PaaS) | <https://dokploy.sammosios.com> | Admin login on request |
| OpenBao (the vault) | <https://bao.sammosios.com/ui> | Method **Userpass**, admin login on request |

Ask us (Samouil Mosios, Pavlos Spanoudakis) for the admin logins; they are not in this repository, because the repository is public.

## 1. The app: Roster

1. Open <https://roster.sammosios.com> and **sign up**. You are now a *member*: you see and edit only your own account.
2. Sign out and sign in as the admin. Admins get an overview and a Users page where they can create, edit, disable and delete accounts.
3. Reload a few times. Two replicas on the two worker nodes serve the requests and keep sessions in PostgreSQL, so you stay signed in whichever replica answers. Redis rate-limits sign-ins: after 5 attempts on one account within 15 minutes, that account is locked until the 15 minutes run out, whichever replica gets the attempts.

## 2. The platform: Dokploy

1. Open the **roster** project. It holds three services: `roster-app`, `roster-db` (PostgreSQL) and `roster-redis`.
2. In `roster-app`, open **Environment**. There are no passwords in it, only references such as
   `DATABASE_URL=${{vault.bao-roster.roster/app:DATABASE_URL}}`. Dokploy fetches the real values from OpenBao when it deploys.
3. Open **Deployments**. Each entry was started by CI with an image tagged with a commit hash, `127.0.0.1:5000/roster:<commit>`.
4. The **infrastructure** project holds the platform's own services: the registry, OpenBao and the CI runners.

## 3. The vault: OpenBao

1. Sign in, open the `secret/` engine, then `roster/app`. These are the values Dokploy resolved in step 2.2.
2. Under **Policies**, `dokploy-project-roster` lets the `roster` project's token read only `secret/roster/*`, and `dokploy-project-infrastructure` does the same for `secret/infrastructure/*`. That is why a reference to one project's secrets fails from any other project.

## 4. Delivery: CI with Trivy

You can't push to `main`, so here are two finished runs of the same workflow:

- [A normal deploy](https://github.com/sammosios/dd2482-project/actions/runs/37437508974): `test` → `image` (build, Trivy scan, push to the cluster registry) → `deploy` (Dokploy runs the new image and the job waits until the app answers).
- [A blocked commit](https://github.com/sammosios/dd2482-project/actions/runs/37439290067): a dummy GitHub token committed in `web-app/auth.go`. The secret scan fails with a CRITICAL finding, and `image` and `deploy` never run.

Both ran on the self-hosted runners inside the cluster. A job's "Set up job" step shows which runner it used.
