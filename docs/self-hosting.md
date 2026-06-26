# Self-hosting Magus

This guide covers running Magus in production. For a local dev setup see the
[README](../README.md#getting-started).

## Components

A Magus deployment has three parts:

| Component | Purpose | Notes |
|---|---|---|
| **App** (this repo) | Phoenix/LiveView + the SvelteKit workbench | Stateless; scale horizontally behind a load balancer. |
| **PostgreSQL 16+** with `pgvector` | Source of truth: all resources, embeddings | Back this up. |
| **FalkorDB** | Super Brain knowledge graph (Layers 1–2) | A **derived, disposable index** over Postgres; rebuildable, no backup required. |

The fastest way to bring all three up together is the self-contained Compose
file:

```bash
docker compose -f docker-compose.selfhost.yml up
```

It runs migrations and then starts the app on port 4000. For a real deployment,
provide your own secrets and data services as below.

## Configuration

All configuration is via environment variables. Copy `.env.example` and fill it
in, then verify with the built-in doctor (it reports what each key unlocks and
exits non-zero if anything required is missing — use it as a deploy gate):

```bash
mix magus.doctor
```

**Required:**

- `DATABASE_URL` (or `PG*` parts) — Postgres connection.
- `SECRET_KEY_BASE` — generate with `mix phx.gen.secret`.
- `TOKEN_SIGNING_SECRET` — generate with `mix phx.gen.secret`.
- `INTEGRATION_ENCRYPTION_KEY` — 32 bytes, base64:
  `elixir -e ":crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()"`.
- At least one LLM provider key (e.g. `OPENROUTER_API_KEY`).
- `PHX_HOST` — the public hostname; `PORT` — the listen port.

**Optional** (unlock features when set): `FALKORDB_*` (Super Brain),
object-storage `AWS_*` (file storage), a Swoosh mail adapter (email),
`SANDBOX_PROVIDER` + credentials (code execution), and per-integration keys.
See `.env.example` for the full list.

Never commit secrets, and never reuse the development defaults in production. See
[SECURITY.md](../SECURITY.md).

## Building and running a release

The included [`Dockerfile`](../Dockerfile) builds a production OTP release.

```bash
docker build -t magus .
docker run --env-file .env -p 4000:4000 magus
```

Or build a release directly with `MIX_ENV=prod mix release` and run
`bin/magus start` (set `PHX_SERVER=true`).

## Migrations

Run migrations on every deploy, before the new app version starts serving:

```bash
bin/magus eval "Magus.Release.migrate"
```

The Compose file and most release setups run this automatically as a release
command. To seed default data on first boot:

```bash
bin/magus eval "Magus.Release.seed()"
```

## Upgrading

1. Pull/build the new version.
2. Run migrations (`Magus.Release.migrate`).
3. Restart the app (rolling restart is fine — the app is stateless).

Migrations are additive and ordered; never edit a migration that has already
been applied in production.

## TLS and reverse proxy

Terminate TLS at a reverse proxy (Caddy, nginx, Traefik, or your platform's load
balancer) and forward to the app's `PORT`. Set `PHX_HOST` to the public hostname
so generated URLs and cookies are correct. Magus sets secure-cookie and CSRF
protections; serve it only over HTTPS in production.

## Backups and recovery

- **PostgreSQL** is the source of truth — back it up (e.g. `pg_dump` or your
  provider's snapshots) and test restores.
- **FalkorDB** holds the Super Brain graph, which is derived from Postgres. If it
  is lost or wiped, the graph rebuilds from Postgres in the background; no backup
  is needed.
- **Object storage** (if configured for files) — back up per your provider.

## Health checks

The app exposes an unauthenticated `GET /health` endpoint (returns app + FalkorDB
status) for load-balancer and uptime checks.
