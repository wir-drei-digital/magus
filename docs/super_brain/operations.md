# Super Brain Operations

## Running FalkorDB

### Local development

```
docker compose up -d falkordb
docker exec -it magus_falkordb redis-cli -p 6379
```

Persistence: the `docker-compose.yml` mounts a named `falkordb_data` volume at `/var/lib/falkordb/data` and passes `REDIS_ARGS="--appendonly yes --appendfsync everysec --save 900 1 --save 300 10 --save 60 10000 --dir /var/lib/falkordb/data"`, enabling AOF (durable WAL flushed every second) alongside the standard RDB snapshot intervals. Local state survives `docker compose down`; to wipe, use `docker compose down -v` to drop the volume.

### Self-hosting (production)

For self-hosted deployments, FalkorDB runs as its own service alongside the Phoenix app via `docker-compose.selfhost.yml`. The compose file defines a dedicated `falkordb` service with a persistent volume and the production `REDIS_ARGS`.

First-time setup:

```
docker compose -f docker-compose.selfhost.yml up -d falkordb
```

The Phoenix app reaches FalkorDB over the compose network. Set the corresponding env vars on the Phoenix service:

```
FALKORDB_HOST=falkordb
FALKORDB_PORT=6379
```

Key config notes (see `docker-compose.selfhost.yml`):
- FalkorDB must always be reachable, so it runs with `restart: unless-stopped`.
- `REDIS_ARGS` enables AOF (`--appendonly yes --appendfsync everysec`) plus RDB snapshots.
- A named volume mounts at `/var/lib/falkordb/data`.
- 1 GB RAM is enough for tens of thousands of entities; bump as graphs grow.

### Backups

`bin/falkordb-snapshot.sh` triggers `BGSAVE`, polls `LASTSAVE` until completion, then uploads `dump.rdb` to S3-compatible storage. The script is generic and runs anywhere `redis-cli` and `aws` are available.

Run inside the FalkorDB container so `dump.rdb` is read from the local volume:

```
docker compose -f docker-compose.selfhost.yml exec falkordb /path/to/falkordb-snapshot.sh
```

Environment variables consumed:
- `REDIS_HOST` (default `localhost`)
- `REDIS_PORT` (default `6379`)
- `S3_BUCKET` (required for upload; if unset, BGSAVE only)
- `S3_ENDPOINT` (optional; for R2, B2, or other S3-compatible providers)
- `DUMP_PATH` (default `/var/lib/falkordb/data/dump.rdb`)
- AWS credentials via the standard env vars (`AWS_ACCESS_KEY_ID`, etc.) or the machine's instance profile

Schedule the snapshot daily via a host cron job, GitHub Actions, or an external scheduler. The script's `LASTSAVE` poll detects BGSAVE completion robustly (no fixed sleep).

### Restore

To restore from a snapshot:

```
docker compose -f docker-compose.selfhost.yml exec falkordb sh
# inside the container:
aws s3 cp s3://<bucket>/falkordb/dump-YYYYMMDDTHHMMSSZ.rdb /var/lib/falkordb/data/dump.rdb
redis-cli SHUTDOWN NOSAVE   # FalkorDB will restart with the new dump
```

The container restarts automatically (`restart: unless-stopped`). On startup, FalkorDB loads `dump.rdb` and replays any AOF.

If the snapshot is older than acceptable, after restore run `mix super_brain.rebuild --graph <graph_name> --yes` for affected graphs to re-derive from the Postgres episode log (the canonical source of truth: extractions are append-only since the spec-compliance patch).

### Disaster recovery

The Postgres-side episode log is authoritative: every successful extraction writes an `:extracted` row to `super_brain_episodes`. If FalkorDB is completely lost and there is no usable snapshot, `mix super_brain.rebuild --graph <name> --yes` per graph drops and re-derives the graph from those episodes. Cost: one LLM call per episode (mockable in dev; real in production).

The `mix super_brain.backfill --user <user_id>` task can prioritize specific users during recovery to drain their queue ahead of the per-tick `BackfillScheduler` cap.

## Inspecting graphs

```
docker exec -it magus_falkordb redis-cli GRAPH.LIST
docker exec -it magus_falkordb redis-cli GRAPH.QUERY brain:<uuid> "MATCH (n) RETURN count(n)"
```

## Health check

- `GET /health` returns `{"status": "ok", "falkordb": "ok" | "unavailable", "checked_at": "..."}`.
- The endpoint stays 200 even when FalkorDB is unavailable so other traffic continues.

## Common operations

### Replaying a graph

```
mix super_brain.rebuild --graph brain:<brain_id>          # prompts for confirmation
mix super_brain.rebuild --graph brain:<brain_id> --yes    # no prompt (for scripts)
```

Drops the FalkorDB graph and re-enqueues every `:extracted` Episode for that graph through the appropriate worker. The workers (`ExtractBrainPage`, `ExtractMemory`, `ExtractFileChunk`, `ExtractDraft`) all share the `ExtractBase` pipeline, which is idempotent and fingerprint-gated.

### Backfilling existing data

Iter2 introduced automatic backfill via the `BackfillScheduler` cron job (runs every 15 minutes, throttles to 10 candidates per user per resource type per tick). Per-user daily LLM budget gates actual extractions; backfill enqueues optimistically and the per-resource worker short-circuits with `{:cancel, :budget_exceeded}` once the killswitch fires.

To prioritize a specific user (bypass the per-tick cap, still respects the daily budget):

```
mix super_brain.backfill --user <user_id>                       # all resource types
mix super_brain.backfill --user <user_id> --resource-type memory
```

Resource types: `brain_page | memory | file_chunk | draft`.

### Inspecting extraction failures

```elixir
iex> Magus.SuperBrain.Episode
...> |> Ash.Query.filter(status == :failed)
...> |> Ash.read!(authorize?: false)
```

### Bumping a user's daily budget temporarily

```elixir
iex> {:ok, budget} = Magus.SuperBrain.ExtractionBudget.get_for(user_id, Date.utc_today())
iex> Ash.update!(budget, %{ceiling_call_count: 500})
```

## Workers and triggers

Four extraction workers all share the `Magus.SuperBrain.Workers.ExtractBase` pipeline:

| Resource | Worker | Trigger actions (Task 17) | Routing |
|----------|--------|---------------------------|---------|
| `Magus.Brain.Page` | `Workers.ExtractBrainPage` | `:create`, `:create_as_external_agent`, `:update_title` | `brain:<brain_id>` |
| `Magus.Memory.Memory` | `Workers.ExtractMemory` | `:create_user`, `:create_agent`, `:set` (scope `[:user, :agent]` only; `:local` skipped) | `memories:user:<id>` or `memories:workspace:<ws>` |
| `Magus.Files.Chunk` | `Workers.ExtractFileChunk` | `:create`, `:bulk_create` (parent file's `type` must be `:document`, `:text`, or `:email`) | `files:user:<id>` or `files:workspace:<ws>` |
| `Magus.Drafts.Draft` | `Workers.ExtractDraft` | `:create`, `:update_content`, `:update_content_json`, `:replace_text`, `:restore_version` | `drafts:user:<id>` |

All workers carry a content `fingerprint` (SHA-256 of the raw text). Re-extraction is a no-op when the fingerprint matches a prior `:extracted` Episode. The `unique: [period: 60, fields: [:args]]` Oban constraint dedupes the same `resource_id` within 60 seconds, so burst edits absorb cheaply.

Jobs use the arg key `"resource_id"` (previously `"page_id"` for brain pages; the worker still accepts the legacy key for backward compatibility).

### Enqueue mechanism

Extraction jobs are enqueued via `Ash.Changeset.after_action` hooks on the relevant resource actions, NOT via AshOban `trigger` DSL. The hooks call `Oban.insert/1` directly. This is a deliberate post-iter2 decision documented in `docs/superpowers/specs/2026-05-21-super-brain-iteration-2-design.md` (see "Post-iter2 update"). The two-layer dedup (Oban's 60s unique window + the worker's content fingerprint gate) makes the enqueue best-effort: failures log but never block the resource mutation.

## Failure modes

- **FalkorDB down**: Per-graph circuit breaker opens. If every accessible graph errors with `:graph_unavailable`, `Magus.SuperBrain.Retrieval.search/2` returns `{:error, :all_graphs_unavailable}` and `Tools.Search` surfaces a friendly message to the agent. If some graphs are reachable, results return from those only (degraded silently).
- **Extraction LLM down**: episodes stay `:pending`; on recovery, the next Oban run drains them.
- **Stuck job**: the worker's 120s wall-clock guard short-circuits and Oban retries (max 5 attempts).
- **Mid-pipeline partial write**: per-episode source-scoped DELETE plus per-entity upsert can leave a sliver of the graph empty between the two steps on a transient error. The next retry re-runs both. The `:source_id` filter scopes the DELETE to the episode being replayed, so other episodes' entities in the same graph are not affected.

## Cost monitoring

Every super brain LLM call writes a `Magus.Chat.MessageUsage` row with `usage_type: :super_brain_extraction` (extractions) or `:embedding` (search-time query embedding). Combine with the existing chat cost data for unified cost accounting.

```sql
-- Today's super brain spend per user
SELECT user_id, SUM(total_cost) AS total_cost, SUM(total_tokens) AS total_tokens
  FROM message_usages
 WHERE usage_type = 'super_brain_extraction'
   AND inserted_at >= CURRENT_DATE
 GROUP BY user_id
 ORDER BY total_cost DESC;

-- Daily call count per user (matches the fast-path budget killswitch)
SELECT user_id, llm_call_count, llm_cost_cents, ceiling_call_count
  FROM super_brain_extraction_budget
 WHERE date = CURRENT_DATE
 ORDER BY llm_cost_cents DESC;
```

The `super_brain_extraction_budget` table is the fast-path daily killswitch (consulted before each LLM call). `MessageUsage` is the analytics source of truth.

## Authorization invariants

- Every brain has a dedicated FalkorDB graph: `brain:<brain_id>`.
- `Magus.SuperBrain.AccessibleGraphs.for_actor/2` is the runtime authority for which graphs an actor may read. Retrieval queries only those graphs.
- Workspace **admins** do NOT get implicit read access on workspace brains (only update/destroy). Cross-user reads require a `ResourceAccess` grant. This is enforced by property-based tests in `test/magus/super_brain/authorization_test.exs`.

## Layer 2 super graphs (iter3+)

Iter3 introduced per-accessor super graphs that aggregate Layer 1 graphs into a canonical-entity layer with cross-resource edges. Each user has a personal `super:user:<uid>` super graph; each `(user, workspace)` membership has a `super:workspace:<ws>:<uid>` super graph.

### Architecture

- **Continuous builds** via `Magus.SuperBrain.Workers.BuildSuperIncremental`, enqueued after every successful extraction via `ExtractBase`. One job per accessor whose read-set includes the source Layer 1 graph. Oban coalesces bursts within a 30-second window per accessor.
- **Nightly full rebuilds** via `Magus.SuperBrain.Workers.NightlyBuildSuperScheduler` at 03:30 UTC. Drops each accessor's super graph and rebuilds from scratch as the source of truth, catching incremental drift.
- **Maintenance** via `Magus.SuperBrain.Workers.SuperGraphMaintenance` at 04:00 UTC. Re-enqueues failed builds and any super graph stale > 36 hours.

The build pipeline reads Layer 1 graphs via `AccessibleGraphs.for_actor/2`, so the super graph never contains data the accessor cannot read. Read-set drift (workspace grant added/removed) triggers a full rebuild rather than incremental modification.

### Inspecting super graphs

```
docker exec -it magus_falkordb redis-cli GRAPH.QUERY super:user:<uid> "MATCH (c:CanonicalEntity) RETURN count(c)"
docker exec -it magus_falkordb redis-cli GRAPH.QUERY super:user:<uid> "MATCH (c:CanonicalEntity)-[:APPEARS_IN]->(s:SourcePointer) RETURN c.name, collect(s.graph_name)"
docker exec -it magus_falkordb redis-cli GRAPH.QUERY super:user:<uid> "MATCH (a:CanonicalEntity)-[r:RELATES_TO]->(b:CanonicalEntity) RETURN a.name, r.predicate, b.name LIMIT 25"
```

### Force a rebuild

```
mix super_brain.rebuild --graph super:user:<uid> --yes
mix super_brain.rebuild --graph super:workspace:<ws>:<uid> --yes
```

The task drops the FalkorDB super graph and enqueues `BuildSuperFull` for the corresponding accessor. Behind the per-accessor advisory lock, only one build runs at a time for a given accessor; concurrent rebuild requests serialize.

### Migration mechanism (graph identity changes)

Graph identity changes (the `CanonicalId` hash, the `stable_id` formula, required-property shapes that downstream code reads back) are NOT Postgres migrations. They touch FalkorDB nodes that have no schema enforcement. The Super Brain manages these via a marker-and-sweep loop.

| Module | Role |
|--------|------|
| `Magus.SuperBrain.Migration` | Holds `entity_version/0` and `canonical_version/0` integer constants. Bump in the same PR that introduces the identity change. |
| Every write site | Stamps `migration_marker` on the node with the current version constant (Entity in `ExtractBase`; CanonicalEntity in `BuildSuperFull` and `BuildSuperIncremental`). |
| `Magus.SuperBrain.Workers.MigrationSweeper` | Oban cron `*/10 * * * *`. Probes each `SuperGraph` row for any `CanonicalEntity` whose marker is missing or below `canonical_version/0`. Stale graphs are rebuilt by enqueueing `BuildSuperFull` (rate-capped via `:super_brain_migration_sweeper, :max_enqueues_per_tick`, default 20). |

**What bumping looks like.** Bump the constant from `1` to `2` in the same PR that lands the identity change, push, deploy. The next sweeper tick (within 10 minutes) sees every accessor's Layer 2 graph as stale and starts rebuilds. There is no separate "register a new migration" step: the constant IS the registration.

**Layer 1 staleness** is observable but NOT auto-rebuilt by the sweeper. A Layer 1 rebuild re-runs LLM extraction for every resource in the graph, which is expensive enough that operator intervention is the right default. Force a Layer 1 rebuild with `mix super_brain.rebuild --graph <layer1_graph_name>`. Natural re-extraction (content edits trigger `after_action` extraction hooks) also heals individual nodes incrementally.

**Telemetry.** Each sweeper tick emits `[:super_brain, :migration, :progress]` with measurements `%{total_rows, stale_rows, enqueued, current_marker_rows, probe_errors}` and metadata `%{current_version}`. The `Magus.SuperBrain.TelemetryHandler` Logger sink (attached at app startup) surfaces this as a structured log line; a richer reporter (Telemetry.Metrics, Prometheus, AppSignal, etc.) can be attached alongside without changes to producers.

**Lifecycle.** Once every graph carries the current marker, the sweeper is a no-op (one cheap COUNT query per accessor per tick). The cron stays scheduled so the next `canonical_version/0` bump triggers the same loop.

### Inspecting Postgres state

```elixir
iex> Magus.SuperBrain.SuperGraph |> Ash.read!(authorize?: false)
```

Each row carries `last_built_at`, `last_build_status` (`:pending | :building | :ok | :failed`), `last_build_duration_ms`, `canonical_entity_count`, `read_set_snapshot`. Failed builds carry `last_error`.

```sql
-- Recent failed builds
SELECT graph_name, last_built_at, last_error
  FROM super_brain_super_graphs
 WHERE last_build_status = 'failed'
 ORDER BY updated_at DESC
 LIMIT 20;
```

### Failure modes

- **BuildSuperFull errors mid-rebuild**: the super graph is in an indeterminate state because the drop already ran. `last_build_status = :failed` in Postgres; retrieval falls back to per-Layer-1 fan-out (`legacy_fan_out_search`). `SuperGraphMaintenance` at 04:00 UTC retries.
- **BuildSuperIncremental errors**: super graph keeps prior state (the incremental writes are append-only canonicals + edges); the nightly full rebuild eventually corrects.
- **Read-set drift mid-day** (workspace grant revoked, member demoted): `BuildSuperIncremental` detects the snapshot mismatch, enqueues `BuildSuperFull`, exits with `:ok` (drift was handled). Until the full rebuild completes, retrieval falls back to legacy fan-out.
- **Stale super graph after app downtime**: `SuperGraphMaintenance` picks up anything > 36h since last build.

### Canonicalization audit

Inline canonicalize (continuous, during extraction) writes audit rows to `super_brain_canonicalization_events`:

```sql
SELECT graph_name, winner_id, loser_id, similarity, reason, inserted_at
  FROM super_brain_canonicalization_events
 WHERE graph_name = 'brain:<id>'
 ORDER BY inserted_at DESC
 LIMIT 20;
```

Each merge records the winner/loser entity ids, the cosine similarity at merge time, and the reason (currently always `inline_extract`; iter4 may add `nightly_llm_judge`).

### Subtype disambiguation

Entities of the same `type` but different `normalized_subtype` (e.g. `:person`/`user` vs `:person`/`character`) stay as separate canonicals. The LLM emits raw `subtype` strings during extraction; `Magus.SuperBrain.Ontology.SubtypeNormalizer` collapses them via a small synonym map.

### Cost profile

Super graph builds are pure CPU + IO. No LLM calls during build. Entity embeddings are read from Layer 1 entities (paid for at extraction time); cross-graph canonicalization is in-process cosine math.

Typical cost per accessor rebuild: 15-30 seconds (for ~1000 entities across ~5 source graphs). Nightly cron for 30 users completes in ~10-15 minutes total.

The per-extraction fan-out triggers N `BuildSuperIncremental` jobs per source-graph-with-N-accessors. Workspace size dominates the cost multiplier. The Oban queue and the per-accessor advisory lock together bound concurrency.

### Known iter3 limits

- LLM-judge canonicalize (deferred to iter4): two real Daniels (your coworker Daniel and your friend Daniel, both `:person`/`coworker` say) collide into one canonical. The disambiguation needs an LLM call per borderline pair, which iter4 adds as a nightly pass.
- `BuildSuperIncremental` defers cross-graph `:RELATES_TO` edge aggregation to the nightly full rebuild. Daily-cycle reads see canonicals immediately but cross-resource edges may take up to 24 hours to appear if only incrementals have run.
- PageRank-based importance scoring (deferred to iter4): the current `importance_score` uses a simple weighted formula. Iter4's `Score` night-cycle pass replaces this with PageRank + access-frequency telemetry.
- `Reontologize` (deferred): the subtype synonym map is hand-maintained. Iter4 promotes stable subtypes from data.
- `Reconcile`, `Cluster`, `Forget` night-cycle passes are all deferred.

## Known limits (iter2)

- **Image and video files** are not extracted (no vision LLM in iter2). Files with `type` in `{:document, :text, :email}` are extracted via per-chunk workers; `:image` and `:video` chunks are filtered upstream.
- **Conversation/message extraction** is not implemented. The Episode model supports `:message` as a resource type for future iterations.
- **Embedder usage tracking is approximate**: the OpenAI embedding API does not return token counts to `Magus.Files.EmbeddingModel.embed_query/1`, so super brain estimates via `max(div(String.length(text), 4), 1)`. Real token counts await an upstream API change.
- **Layer 2 super graphs** (`super:user:<id>`, `super:workspace:<ws>:<user>`) and the **night cycle** (`Canonicalize`, `Reontologize`, etc.) are deferred to iter3. Iter2 ships Layer 1 only.
- **PART_OF edge** between Chunk and File entities is not materialised. Chunk-level provenance is preserved via `file_id` and `chunk_id` properties on entity nodes. See the iter2 design spec.
- **`mix ash.reset` is forbidden** by repo convention. Use `mix ash.migrate` and `mix super_brain.rebuild` for state recovery.
