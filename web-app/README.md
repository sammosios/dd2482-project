# Roster: the example web app

A small users dashboard in Go and [htmx](https://htmx.org) on PostgreSQL. It's the example application for the Dokploy cluster: one stateless app service plus one database service. The UI copies Dokploy's look (shadcn/ui, zinc palette), in the light theme.

## What it does

- **Admins** get an overview (user counts, newest accounts) and a Users page: search and filter, create, edit (name, email, job title, role, password reset), enable/disable with a switch, and delete.
- **Members** see their own account and can edit their own details and password, nothing else.
- Anyone can sign up as a member (turn off with `ALLOW_SIGNUP=false`). The first admin comes from `ADMIN_EMAIL` / `ADMIN_PASSWORD`.
- Disabling an account signs it out everywhere at once. Admins can't disable, demote or delete themselves, so there's always an admin left.

## Configuration

All through environment variables:

| Variable | Default | |
|---|---|---|
| `DATABASE_URL` | required | `postgresql://user:password@host:5432/db`. In Dokploy: the database's *Internal Connection URL*. |
| `ADMIN_EMAIL`, `ADMIN_PASSWORD` | | Creates the first admin at startup, if there's no admin yet. Never changes an existing account. |
| `ADMIN_NAME` | `Administrator` | That admin's name. |
| `ALLOW_SIGNUP` | `true` | Whether the sign-in page offers "Create an account". |
| `PORT` | `8080` | |

## Built for a cluster

- **Stateless replicas.** Sessions are rows in Postgres, not in the app's memory, so any replica can serve any request. You can scale out without sticky sessions. The cookie holds a random token and the table stores only its SHA-256.
- **Schema migrations at startup.** The files in `migrations/` run in name order, each once, tracked in a `schema_migrations` table. A Postgres advisory lock makes replicas that start together take turns. To change the schema, add `002_something.sql`; never edit a migration that has already run.
- **Health checks.** `/healthz` only says the process is up and is what the image's `HEALTHCHECK` calls. `/readyz` also pings the database. The liveness check leaves the database out on purpose: during a database outage, restarting every replica doesn't help.
- **Which replica answered?** The page header shows the container's hostname.
- **Graceful shutdown.** On SIGTERM (what Swarm sends during updates), in-flight requests get to finish.
- **Image.** Multi-stage build: a static binary on `distroless/static` running as non-root. `.dockerignore` keeps `.env` out of the build context, because Dokploy writes one next to the Dockerfile before building.
- **Security.** bcrypt passwords; HttpOnly, SameSite=Lax cookies (Secure behind HTTPS); CSRF protection from Go's `http.CrossOriginProtection` (Fetch Metadata headers, no tokens); a CSP with no inline scripts or styles.

## Code map

| | |
|---|---|
| `main.go` | Config, server lifecycle, the `healthcheck` subcommand |
| `db.go` | Connecting (with retries), migrations, the first admin |
| `store.go` | All the SQL |
| `app.go` | Routes, middleware, error handling |
| `auth.go` | Sessions, passwords, sign-in/up/out |
| `users.go` | The admin pages: every action answers htmx with an HTML fragment |
| `profile.go` | Overview and your own profile |
| `views.go`, `icons.go` | Templates, static files (embedded in the binary), [Lucide](https://lucide.dev) icons |
| `templates/`, `static/` | HTML, CSS, a little JS. `static/htmx.min.js` is htmx 2.0.11, vendored so the app has no CDN dependency. |

## Running it locally

You need Go 1.26+ and a Postgres, for example:

```
docker run -d --name roster-db -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:18
DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres \
  ADMIN_EMAIL=admin@example.com ADMIN_PASSWORD=change-me-please go run .
```

Then open http://localhost:8080. To build the image: `docker build -t roster .`

## Tests

```
go test ./...
```

This runs the unit tests and renders every template. With `TEST_DATABASE_URL` set (URL form) it also runs `TestEndToEnd`, which drives every flow above over HTTP against a real Postgres, in a throwaway schema it drops afterwards:

```
TEST_DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres go test ./...
```
