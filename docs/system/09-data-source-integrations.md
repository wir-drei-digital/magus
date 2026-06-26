# Data Source Integrations

How external data streams (logs, RSS feeds, email) are ingested, stored, preprocessed, and made available to custom agents via tools and inbox event escalation.

## Overview

Data source integrations extend the Integrations domain with a shared `IngestionEntry` resource and a `DataSourceBehaviour` for providers that ingest external data. Two initial providers — LogSource (push/webhook) and RssSource (pull/polling) — validate the pattern. The design supports future providers (email/IMAP, webhooks, APIs) with the same pipeline.

## Architecture

```
                    Push (Vector HTTP)          Pull (Oban schedule)
                         |                            |
                         v                            v
                  WebhookController            PollDataSource worker
                         |                            |
                         v                            v
                  LogSource.parse_ingestion    RssSource.poll
                         |                            |
                         +------------+---------------+
                                      |
                                      v
                         ProcessIngestion module
                           - provider.classify/1 per entry
                           - SHA-256 content hash
                           - Bulk insert IngestionEntry (skip dupes)
                                      |
                                      v
                         ThresholdChecker.check/2
                                      |
                          +-----------+-----------+
                          |                       |
                     threshold met           below threshold
                          |                       |
                          v                       v
                  Create summarized          No action
                  AgentInboxEvent            (entries queryable
                  (type: :integration,        via tools)
                   urgency: :deferred)
                          |
                          v
                  Agent picks up on
                  next heartbeat wake-up
                  (list_inbox_events,
                   dismiss_event, etc.)
```

## Components

### IngestionEntry Resource

`lib/magus/integrations/ingestion_entry.ex`

Normalized storage for all data source providers. One row per ingested item.

| Field | Type | Description |
|-------|------|-------------|
| `id` | uuid_v7 | Primary key |
| `user_integration_id` | uuid (FK) | Links to UserIntegration |
| `user_id` | uuid (FK) | Owner (denormalized from UserIntegration for query perf) |
| `source_type` | atom | `:log`, `:rss`, `:email` |
| `external_id` | string | Dedup key from source (nullable) |
| `severity` | atom | `:critical`, `:error`, `:warning`, `:info`, `:debug` |
| `title` | string | RSS title, email subject, log summary (nullable) |
| `content` | text | Full content |
| `metadata` | map | Source-specific structured data |
| `occurred_at` | utc_datetime_usec | When it happened at source |
| `content_hash` | string | SHA-256 of content for dedup |
| `inserted_at` | utc_datetime_usec | When we stored it |

**Indexes:**
- `(user_integration_id, content_hash)` — unique, dedup
- `(user_integration_id, occurred_at)` — time-range queries
- `(user_id, source_type, occurred_at)` — cross-source user queries

**Policies:** Reads scoped to `user_id == actor(:id)`. Create/destroy allowed unconditionally (system operations use `authorize?: false`).

**Actions:**
- `:create` — accepts all fields
- `:for_integration` — read with optional filters (since, until, severity, query, limit)
- `:count_by_severity` — read filtered by integration + severity + time window (used with `Ash.count`)
- `:for_user_sources` — read scoped to user_id with optional filters

### DataSourceBehaviour

`lib/magus/integrations/providers/data_source_behaviour.ex`

Separate from the base `Behaviour` to avoid conflicts with `parse_webhook/2` (which returns InputMessage-shaped data). Data source providers implement both behaviours.

```elixir
@callback parse_ingestion_payload(payload :: map(), headers :: list()) ::
            {:ok, [map()]} | {:error, term()}

@callback classify(parsed_entry :: map()) :: %{severity: atom(), title: String.t() | nil}

@callback poll(integration, credential | nil) :: {:ok, [map()]} | {:error, term()}
# Optional callbacks: poll/2, should_create_inbox_event?/2, build_inbox_event_attrs/2

@callback should_create_inbox_event?(integration, new_entries) :: boolean()
@callback build_inbox_event_attrs(integration, new_entries) :: map()
```

### ProcessIngestion

`lib/magus/integrations/process_ingestion.ex`

Plain module (not an Ash Reactor) that handles the ingestion pipeline:

1. Parse payload via `provider.parse_ingestion_payload/2` (or accept pre-parsed entries via `run_with_entries/3`)
2. Classify each entry via `provider.classify/1` — refines severity, adds title
3. Generate SHA-256 content hash per entry
4. Bulk insert `IngestionEntry` records, skipping dedup violations (logs non-dedup errors)
5. Run `ThresholdChecker.check/3` on successfully inserted entries (provider_module, integration, entries)

```elixir
# Webhook path — parses raw payload
ProcessIngestion.run(provider_module, integration, payload, headers)

# Poll path — entries already parsed by provider.poll/2
ProcessIngestion.run_with_entries(provider_module, integration, raw_entries)
```

### ThresholdChecker

`lib/magus/integrations/threshold_checker.ex`

Thin delegation module that calls provider callbacks to determine if an inbox event should be created:

1. Calls `provider_module.should_create_inbox_event?(integration, new_entries)` — returns boolean
2. If true, calls `provider_module.build_inbox_event_attrs(integration, new_entries)` — returns event attributes
3. Creates `AgentInboxEvent` with the provider-supplied attributes

The threshold logic lives in each provider module (e.g., `LogSource` counts errors in a rolling window, `RssSource` checks for any new items). Idempotency keys prevent duplicate alerts — the `AgentInboxEvent` identity constraint silently rejects duplicates.

### WebhookController Branching

`lib/magus_web/controllers/webhook_controller.ex`

The webhook controller routes based on `provider_module.source_type()`:

```
POST /webhooks/:provider/:integration_id
    |
    v
WebhookController.webhook/2
    |
    v
load integration + verify + rate limit
    |
    v
provider_module.source_type()
    |
    +---> :data_source → ProcessIngestion.run/4 → JSON {status: "ok", ingested: N}
    +---> :channel     → ProcessWebhook reactor → InputMessage → conversation routing
    +---> :knowledge   → Knowledge sync trigger
```

## Providers

### LogSource

`lib/magus/integrations/providers/log_source.ex`

| Key | Value |
|-----|-------|
| `key` | `:log_source` |
| `auth_type` | `:webhook_only` |
| `supports_input?` | `true` |
| `supports_output?` | `false` |

**Payload formats:** Single entry (`{"message": "...", "level": "...", "timestamp": "..."}`) or batch (`{"entries": [...]}`). Falls back to extracting level from content via regex.

**Classification:** Maps log levels to severity atoms. Detects crash signatures (GenServer terminating, EXIT, SIGTERM, etc.) and escalates to `:critical`.

### RssSource

`lib/magus/integrations/providers/rss_source.ex`

| Key | Value |
|-----|-------|
| `key` | `:rss_source` |
| `auth_type` | `:none` |
| `supports_input?` | `false` |
| `supports_output?` | `false` |

**Polling:** Uses `Req` for HTTP fetching (1 MiB body size limit, 15s timeout) and `FastRSS` for XML parsing. Supports both RSS 2.0 and Atom feeds. Config key is `"feed_urls"` (plural) — supports multiple feed URLs per integration.

**Classification:** All items get `:info` severity by default.

## Agent Tools

### SearchEntries

`lib/magus/agents/tools/integrations/search_entries.ex`

Jido Action tool (`search_ingested_data`) that queries `IngestionEntry` records across all user data sources. Supports filtering by source_type, severity, query text, time range, and limit.

### GetSourceStatus

`lib/magus/agents/tools/integrations/get_source_status.ex`

Jido Action tool (`get_source_status`) that returns per-integration health summaries: entry counts (using `Ash.count`, not full record loading), error counts, last sync time, and config.

Both tools are registered in `ToolBuilder` under the `:integrations` category and are available to any agent with at least one active data source integration. They're also listed in each provider's `tools/0` callback, so users can enable/disable them per integration via `UserIntegration.enabled_tools`.

## Oban Workers

### PollDataSource

`lib/magus/integrations/workers/poll_data_source.ex`

Standalone Oban worker (queue: `:integrations`, max_attempts: 3) for polling pull-type sources.

**Flow:**
1. Load integration, verify active
2. Resolve provider module, verify `poll/2` is implemented
3. Load credential (nil-safe for unauthenticated sources)
4. Call `provider.poll/2`
5. Feed results through `ProcessIngestion.run_with_entries/3`
6. Record sync timestamp
7. Re-enqueue self at configured `poll_interval_minutes` (default 30)

**Self-scheduling:** After each successful poll, the job re-enqueues itself with a delay. If the integration is deactivated, the job exits without re-enqueuing. Uses `unique: [period: 300, keys: [:integration_id]]` for idempotent enqueue.

### PurgeIngestionEntries

`lib/magus/integrations/workers/purge_ingestion_entries.ex`

Daily Oban worker (queue: `:maintenance`, max_attempts: 1, cron: `0 3 * * *`) for retention cleanup.

**Flow:**
1. Query active data source integrations (providers `:log_source`, `:rss_source`)
2. For each, read `retention_days` from config (default: 7)
3. Delete entries older than cutoff in batches of 1000

## Data Flow Diagrams

### Push (Logs)

```
Vector/Log Shipper
    |
    | POST /webhooks/log_source/:integration_id
    | {"message": "...", "level": "error", ...}
    v
WebhookController → data_source_provider? → true
    |
    v
ProcessIngestion.run(LogSource, integration, payload, headers)
    |
    +---> LogSource.parse_ingestion_payload/2 → [%{content, severity, metadata, occurred_at}]
    +---> LogSource.classify/1 per entry → refine severity (crash → :critical)
    +---> SHA-256 content hash
    +---> Bulk insert IngestionEntry (skip dupes)
    +---> ThresholdChecker.check/2 → maybe create AgentInboxEvent
    |
    v
JSON response: {status: "ok", ingested: N}
```

### Pull (RSS)

```
PollDataSource Oban job fires (every poll_interval_minutes)
    |
    v
Load integration → verify active → resolve provider
    |
    v
RssSource.poll/2
    |
    +---> For each feed_url: Req.get(url) → XML body (max 1 MiB)
    +---> FastRSS.parse_rss/1 or FastRSS.parse_atom/1
    +---> Normalize to [%{title, content, metadata, occurred_at, external_id}]
    |
    v
ProcessIngestion.run_with_entries(RssSource, integration, entries)
    |
    +---> classify, hash, insert, threshold check (same as push)
    |
    v
Record sync timestamp → re-enqueue at poll_interval_minutes
```

## Adding New Data Source Providers

1. Create module in `lib/magus/integrations/providers/` implementing both `Behaviour` and `DataSourceBehaviour`
2. Implement required callbacks: `key/0`, `name/0`, `description/0`, `auth_type/0`, `source_type/0` (return `:data_source`) from base `Behaviour`
3. Implement `parse_ingestion_payload/2` and `classify/1` from `DataSourceBehaviour`
4. Optionally implement `poll/2` for pull-type sources
5. Return `SearchEntries` and `GetSourceStatus` from `tools/0`
6. Register in `@provider_modules` map in `lib/magus/integrations.ex`
7. For pull-type: enqueue `PollDataSource` job when integration is activated

No database seeding required — providers are discovered via the compile-time `@provider_modules` registry.

## Security

- **XML parsing:** RSS feeds parsed via `FastRSS` (Rust-based, no external entity resolution)
- **Body size limit:** RSS HTTP fetches limited to 1 MiB to prevent memory exhaustion
- **Credential isolation:** Credentials are decrypted only by the PollDataSource worker — never exposed to agent tools
- **Authorization policies:** IngestionEntry reads scoped to `user_id == actor(:id)`
- **Content dedup:** SHA-256 content hashing prevents duplicate entry creation from retries
- **Idempotent escalation:** Time-bucketed idempotency keys prevent duplicate inbox events
