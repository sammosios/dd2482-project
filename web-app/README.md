# Roster: the example web app

A small users dashboard in Go and [htmx](https://htmx.org) on PostgreSQL, with Redis for rate limiting sign-ins. It's the example application for the Dokploy cluster: one stateless app service plus a database and a Redis service. The UI copies Dokploy's look (shadcn/ui, zinc palette), in the light theme.

## What it does

- **Admins** get an overview (user counts, newest accounts) and a Users page: search and filter, create, edit (name, email, job title, role, password reset), enable/disable with a switch, and delete.
- **Members** see their own account and can edit their own details and password, nothing else.
- Anyone can sign up as a member (turn off with `ALLOW_SIGNUP=false`). The first admin comes from `ADMIN_EMAIL` / `ADMIN_PASSWORD`.
- Disabling an account signs it out everywhere at once. Admins can't disable, demote or delete themselves, so there's always an admin left.
- Sign-ins are rate limited: 5 attempts per account per 15 minutes, after which the account is locked until the 15 minutes are up (HTTP 429 with `Retry-After`). A successful sign-in resets the count.

## Configuration

All through environment variables:

| Variable | Default | |
|---|---|---|
| `DATABASE_URL` | required | `postgresql://user:password@host:5432/db`. In Dokploy: the database's *Internal Connection URL*. |
| `REDIS_URL` | | `redis://default:password@host:6379`. In Dokploy: the Redis service's *Internal Connection URL*. Without it, sign-ins aren't rate limited. |
| `ADMIN_EMAIL`, `ADMIN_PASSWORD` | | Creates the first admin at startup, if there's no admin yet. Never changes an existing account. |
| `ADMIN_NAME` | `Administrator` | That admin's name. |
| `ALLOW_SIGNUP` | `true` | Whether the sign-in page offers "Create an account". |
| `PORT` | `8080` | |

## Built for a cluster

- **Stateless replicas.** Sessions are rows in Postgres, not in the app's memory, so any replica can serve any request. You can scale out without sticky sessions. The cookie holds a random token and the table stores only its SHA-256.
- **Schema migrations at startup.** The files in `migrations/` run in name order, each once, tracked in a `schema_migrations` table. A Postgres advisory lock makes replicas that start together take turns. To change the schema, add `002_something.sql`; never edit a migration that has already run.
- **Health checks.** `/healthz` only says the process is up and is what the image's `HEALTHCHECK` calls. `/readyz` also pings the database. The liveness check leaves the database out on purpose: during a database outage, restarting every replica doesn't help.
- **Rate limiting in Redis, shared by every replica.** Counters in each replica's memory would be defeated by the load balancer, which spreads the guesses across replicas and so multiplies the allowance. Each attempt is one atomic Redis transaction (count it, start the 15-minute window if it's the first, read what's left), so concurrent attempts on different replicas can't slip past the limit. Unknown emails are counted the same way, so a lockout reveals nothing about which accounts exist, and the keys are hashes, not email addresses. The tradeoff of limiting per account: anyone can lock an account for 15 minutes by guessing wrong on purpose. Limiting per client IP as well would narrow that.
- **Fails open.** If Redis is down, sign-ins go through without rate limiting and each one logs a warning. A Redis outage shouldn't lock everyone out; Redis being optional also keeps local runs and tests simple.
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
| `ratelimit.go` | Sign-in rate limiting in Redis |
| `users.go` | The admin pages: every action answers htmx with an HTML fragment |
| `profile.go` | Overview and your own profile |
| `views.go`, `icons.go` | Templates, static files (embedded in the binary), [Lucide](https://lucide.dev) icons |
| `templates/`, `static/` | HTML, CSS, a little JS. `static/htmx.min.js` is htmx 2.0.11, vendored so the app has no CDN dependency. |

## On the cluster

`local/07-deploy-web-app.sh` (or `remote/07-deploy-web-app.sh`, from the repo root; also run by `bootstrap.sh`) builds the image of the last commit that touched this directory, pushes it to the cluster registry as `roster:<commit>`, and deploys it through Dokploy with its database and Redis. Re-run it after committing a change to redeploy. Why it's done this way, rather than with Dokploy's own Git builds, is in DESIGN.md.

## Running it locally

You need Go 1.26+ and a Postgres, for example:

```
docker run -d --name roster-db -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:18
DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres \
  ADMIN_EMAIL=admin@example.com ADMIN_PASSWORD=change-me-please go run .
```

Then open http://localhost:8080. To try the rate limiting too, start a Redis (`docker run -d --name roster-redis -p 6379:6379 redis:8`) and add `REDIS_URL=redis://localhost:6379`. To build the image: `docker build -t roster .`

## Tests

```
go test ./...
```

This runs the unit tests and renders every template. The rate limiter's tests run against an in-memory Redis ([miniredis](https://github.com/alicebob/miniredis)), which they can fast-forward through the 15 minutes, so no Redis server is needed. With `TEST_DATABASE_URL` set (URL form) it also runs `TestEndToEnd`, which drives every flow above over HTTP against a real Postgres, in a throwaway schema it drops afterwards:

```
TEST_DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres go test ./...
```
