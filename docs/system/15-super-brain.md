# Super Brain (Knowledge Graph)

Cross-resource knowledge graph that fuses entities and relations extracted from brain pages, memories, file chunks, and drafts into a per-actor "super graph" used for hybrid VectorRAG + GraphRAG retrieval.

The Super Brain is distinct from the [Knowledge Brain](./14-knowledge-brain.md). The Knowledge Brain is the page/block editor users interact with directly. The Super Brain is a background-built knowledge graph derived from every source the user can read (including brain pages, but also memories, files, and drafts), used to answer "what do I know about X" at retrieval time.

## Overview

Two-tier topology:

- **Layer 1 (source graphs):** one FalkorDB graph per source unit. Brain pages → `brain:<brain_id>`. Personal memories → `memories:user:<uid>`. Workspace memories → `memories:workspace:<ws>`. Files and drafts mirror the same shape. Entities and `:RELATES_TO` edges land here as extraction happens.
- **Layer 2 (super graphs):** one graph per `(accessor_type, user_id, workspace_id)` tuple — `super:user:<uid>` for personal, `super:workspace:<ws>:<uid>` for workspace surfaces. Built by fusing all Layer 1 graphs the accessor can read into a single canonical-entity graph. Queries hit Layer 2 by default.

```
┌────────────────────────────────────────────────────────────────────────────┐
│                        SUPER BRAIN ARCHITECTURE                            │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│   Sources (Ash resources)             after_action hooks                   │
│   ┌──────────────────┐                                                     │
│   │  Brain.Page      │──┐                                                  │
│   │  Brain.Block     │  │                                                  │
│   │  Brain.Connection│  │                                                  │
│   │  Memory          │  ├──▶ Oban.insert(ExtractXxx{resource_id: ...})    │
│   │  Files.Chunk     │  │                                                  │
│   │  Drafts.Draft    │──┘                                                  │
│   └──────────────────┘                                                     │
│                                  │                                         │
│                                  ▼                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │              ExtractBase (shared pipeline, lib/.../extract_base.ex) │  │
│   │   1. acquire advisory lock per (graph_name, resource_id)            │  │
│   │   2. fetch resource, render text                                    │  │
│   │   3. LLM extract entities + edges (Extraction.Prompt)               │  │
│   │   4. atom-safe sanitize (Extraction.Sanitizer)                      │  │
│   │   5. embed entity names (BatchEmbedder)                             │  │
│   │   6. write Entity/RELATES_TO nodes/edges to Layer 1                 │  │
│   │   7. inline canonicalize (cosine >= 0.95, same type+subtype)        │  │
│   │   8. append-only :extracted Episode row                             │  │
│   │   9. write MessageUsage row (unified usage accounting)             │  │
│   │  10. enqueue BuildSuperIncremental for each accessor                │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                  │                                         │
│                ┌─────────────────┴─────────────────┐                       │
│                ▼                                   ▼                       │
│   FalkorDB Layer 1                   FalkorDB Layer 2                      │
│   ┌──────────────────────┐           ┌──────────────────────────────────┐  │
│   │ brain:<id>           │           │ super:user:<uid>                 │  │
│   │ memories:user:<uid>  │ ───────▶  │ super:workspace:<ws>:<uid>       │  │
│   │ memories:workspace:..│  fuse     │                                  │  │
│   │ files:user:<uid>     │           │ CanonicalEntity + SourcePointer  │  │
│   │ files:workspace:..   │           │ APPEARS_IN + RELATES_TO          │  │
│   │ drafts:user:<uid>    │           │ Episode + HAS_ENTITY             │  │
│   └──────────────────────┘           └──────────────────────────────────┘  │
│                                                  │                         │
│                                                  ▼                         │
│                                  Magus.SuperBrain.Retrieval.search/2       │
│                                  (super-graph KNN + 1-hop neighborhoods)   │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

## Key Concepts

### Auth-by-graph-boundary

The crucial safety property. `Magus.SuperBrain.AccessibleGraphs.for_actor/2` produces the list of Layer 1 graphs an actor is allowed to read by calling Ash with the actor as the authorization principal. Personal sources resolve from `actor.id`; workspace sources are included only when the actor is an active workspace member; brain graphs come from `BrainResource.workspace_scoped_policies(:brain)`. Layer 2 build snapshots this read-set into `super_brain_super_graphs.read_set_snapshot`. Retrieval at runtime detects drift between the snapshot and the live read-set and falls back to the per-Layer-1 fan-out path while a rebuild runs. The graph backend itself enforces nothing: authorization lives entirely in `AccessibleGraphs`.

### Trust tiers

Every entity is tagged with one of three tiers:

| Tier | Multiplier | Source |
|------|------------|--------|
| `:instruction` | 1.5 | User-declared intent (explicit brain `Brain.Connection`, system-set "remember this") |
| `:evidence` | 1.0 | Default for extracted facts from any source |
| `:noise` | 0.2 | Auto-detected boilerplate, low-confidence extractions, filler |

`Magus.SuperBrain.Ontology.trust_tier_multiplier/1` is the single authority. The multiplier is applied exactly once at query time by `Retrieval.score_canonicals/2`.

### Ontology

12 seed entity types (`Magus.SuperBrain.Ontology.entity_types/0`, in code order): `:person`, `:organization`, `:project`, `:concept`, `:event`, `:location`, `:date`, `:document`, `:technology`, `:decision`, `:task`, `:fact`. 8 canonical predicates (`Magus.SuperBrain.Ontology.canonical_predicates/0`, in code order): `:relates_to` (fallback), `:mentions`, `:supports`, `:contradicts`, `:derived_from`, `:updates`, `:extends`, `:derives`. Free-form subtypes (e.g. `"coworker"`, `"side-project"`) are normalized via `Magus.SuperBrain.Ontology.SubtypeNormalizer` so `"colleague"` and `"coworker"` fuse but `"person (actual)"` and `"person (character)"` do not. The normalizer covers all 12 entity types with roughly 160 synonym entries (`lib/magus/super_brain/ontology/subtype_normalizer.ex`); unknown subtypes pass through lowercased and whitespace-collapsed so the LLM keeps its expressive room.

### Canonical fusion

Two passes:

1. **Inline (cheap, at extraction time)** — `ExtractBase.canonicalize_within_episode/3` and `BuildSuperIncremental` use FalkorDB's vector KNN to find existing canonicals with `cosine >= 0.95` AND matching `(primary_type, normalized_subtype)`. Hit → merge under the existing canonical id. Miss → create new. Bounded by per-episode size; runs synchronously inside the extraction worker.
2. **Nightly (full rebuild)** — `BuildSuperFull` at 03:30 UTC drops and re-derives the super graph from Layer 1, recomputing canonical ids deterministically via `sha256(super_graph | name_downcased | type | normalized_subtype)`. The formula is mirrored by `BuildSuperIncremental.canonical_id_for/4` so an incremental insert and a subsequent nightly produce the same id for the same `(name, type, normalized_subtype)`.

Two correctness details on the canonical id formula:

- **`__none__` sentinel for nil subtype.** A `nil` `normalized_subtype` is hashed as the explicit string `"__none__"` rather than the empty string. The sentinel is a known-unknown: subtype-less entities of the same `(name, type)` still fuse with each other (same bucket), but they no longer collide with any real-subtype bucket and would not silently fuse with a subtyped entity if `""` ever became a valid `normalized_subtype` value in the future.
- **Edge properties preserved through canonicalize merges.** When the inline canonicalize step in `ExtractBase` re-points edges from a loser entity onto a winner, it now copies the loser-side `predicate`, `confidence`, `trust_tier`, `extractor`, and `source_id` properties using a conflict-aware SET (`coalesce` for predicate/tier/provenance, `max` for confidence). This closed a silent property-loss bug where every canonicalize merge stripped those properties off the surviving edge.

A future LLM-judge pass would refine fusion beyond pure embedding similarity.

### Importance scoring

Importance is split between a **write-time** raw popularity score and a **query-time** log-compressed factor, with the trust-tier multiplier applied exactly once at query time.

**At write time** (`BuildSuperFull.compute_importance_scores/1` after the nightly fuse) each `CanonicalEntity` carries:

```
importance_score = source_count * sum(source_weight * log(1 + mention_count))
```

Raw popularity only. The trust tier multiplier is NOT baked in here.

**At query time** (`Magus.SuperBrain.Retrieval.score_canonicals/2`) the composite per-hit score is:

```
score = vector_sim * tier_mult * importance_factor * neighborhood_support

  where importance_factor = 1 + log10(1 + importance_score)
```

The log10 compression bounds growth so each 10x in raw importance adds only +1.0 to the factor (importance 100 → 3.0, importance 1000 → 4.0), keeping hot entities from drowning out vector-strong but rarely-mentioned candidates.

**Design decision:** `tier_mult` is applied exactly once, at query time. Baking it into the stored `importance_score` would double-apply when the ranker re-multiplies by `tier_mult`. Earlier iterations conflated the two and have been unwound; the write-time score is now pure popularity.

## Layer 1: Source Graphs

Each source resource owns one graph name produced by `Magus.SuperBrain.GraphRouter`:

| Resource | Graph Name | Worker | Tier |
|----------|------------|--------|------|
| `Brain.Page` | `brain:<brain_id>` | `ExtractBrainPage` | `:evidence` |
| `Brain.Block` | `brain:<brain_id>` | `ExtractBrainPage` (block-level) | `:evidence` |
| `Brain.Connection` | `brain:<brain_id>` | `IngestBrainConnection` | `:instruction` |
| `Memory` (personal) | `memories:user:<uid>` | `ExtractMemory` | `:evidence` |
| `Memory` (workspace) | `memories:workspace:<ws>` | `ExtractMemory` | `:evidence` |
| `Files.Chunk` (personal) | `files:user:<uid>` | `ExtractFileChunk` | `:evidence` |
| `Files.Chunk` (workspace) | `files:workspace:<ws>` | `ExtractFileChunk` | `:evidence` |
| `Drafts.Draft` | `drafts:user:<uid>` | `ExtractDraft` | `:evidence` |

Layer 1 graphs hold `:Entity` and `:Episode` nodes plus `:RELATES_TO` and `:HAS_ENTITY` edges. An `Entity` carries `name`, `type` (canonical), `subtype` + `normalized_subtype`, `embedding` (vecf32, 1536-dim), `confidence`, `trust_tier`, `source_id` (the Postgres Episode id). `RELATES_TO` carries `predicate`, `confidence`. `HAS_ENTITY` links the source `Episode` node to each extracted entity for provenance.

Episodes are append-only since the iter2.5 spec-compliance patch: the Postgres `super_brain_episodes` table is the source of truth, and `mix super_brain.rebuild --graph <name>` can re-derive any Layer 1 graph by replaying its episodes.

## Layer 2: Super Graphs

One graph per accessor. Schema:

| Node | Properties |
|------|------------|
| `:CanonicalEntity` | `id`, `name`, `primary_type`, `subtype`, `normalized_subtype`, `embedding` (1536-d), `trust_tier`, `importance_score`, `source_count`, `last_evidence_at`, `built_at` |
| `:SourcePointer` | `id`, `graph_name`, `source_node_id` |

| Edge | From → To | Properties |
|------|-----------|------------|
| `:APPEARS_IN` | CanonicalEntity → SourcePointer | `graph_name`, `source_node_id`, `mention_count`, `latest_evidence_at`, `source_weight` |
| `:RELATES_TO` | CanonicalEntity → CanonicalEntity | aggregated `predicate`, `confidence`, `trust_tier`, `appearance_count`, `source_graphs`, `contested:bool`, `predicate_breakdown` (JSON-encoded `%{predicate => count}`) |

`contested` is `true` whenever the set of observed predicates for the same `(from_canonical, to_canonical)` pair contains both halves of any entry in `Ontology.contradicting_predicates/0` (today: `"supports"` vs `"contradicts"`). `predicate_breakdown` is serialized as JSON because FalkorDB has no native map type for edge properties; consumers decode it back to a map. The pair surfaces conflicting evidence to the LLM via the retrieval enrichment step so the prompt can present "supports: 2 / contradicts: 1" instead of silently parroting the modal predicate as ground truth.

`super_weight` per `APPEARS_IN` comes from `Magus.SuperBrain.GraphWeight.weight_for/2` — looks up per-accessor overrides keyed by `actor.id`, falls back to a prefix default (`memories:` → 1.0, `brain:` → 1.0, `files:` → 0.85, `drafts:` → 0.6). `BuildSuperFull` and `BuildSuperIncremental` both call this so the value is consistent across incremental inserts and nightly rebuilds.

## Extraction Pipeline

Every source resource enqueues extraction via an `Ash.Changeset.after_action` hook that calls `Oban.insert/1` directly. This is a documented exception to "always use ash_oban": AshOban's trigger DSL wraps a single Ash action and cannot point at an external Oban worker, and the migration would add boilerplate without behavioral change.

`Magus.SuperBrain.Workers.ExtractBase.perform/3` is the shared pipeline; the per-resource workers (`ExtractBrainPage`, `ExtractMemory`, `ExtractFileChunk`, `ExtractDraft`) are thin shims that supply a `resource_module`, a `text_renderer`, and the graph-name resolution. Steps inside `ExtractBase`:

1. `Magus.Repo.transaction(fn -> ... end)` for the Postgres-side work.
2. `pg_advisory_xact_lock` keyed on `sha256("super_brain|" <> graph_name <> "|" <> resource_id)` so duplicate enqueues for the same (graph, resource) serialize.
3. Idempotency check against `super_brain_episodes`: if a `:extracted` row already exists for this `(resource_type, resource_id)` at the current resource version, exit early.
4. `Extraction.run/3` → LLM call with `Extraction.Prompt.build/3`. Output schema: `{"entities": [...], "edges": [...]}`. Strict JSON via response_format; `LLMClient.ReqLLM` is the production adapter, `LLMMock` is the test adapter (`Mox`-backed; configured via `config :magus, :super_brain_llm`).
5. `Extraction.Sanitizer.sanitize/2` — name/type/subtype/predicate normalization. Atom-exhaustion DoS protection via `String.to_existing_atom/1` inside a `rescue ArgumentError` that falls back to the canonical `:relates_to` predicate.
6. `BatchEmbedder` (default `Magus.Embeddings.OpenAIBatchEmbedder`; mockable via `:super_brain_extraction_embedder`) embeds entity names. 1536-dim, OpenAI `text-embedding-3-small`.
7. `Magus.Graph.upsert_node/3` and `upsert_edge/4` write entities, edges, the `Episode` node, and `HAS_ENTITY` per entity. `vecf32([...])` is the FalkorDB embedding format (auto-wrapped from the numeric list).
8. Inline canonicalize within the same episode (dedup repeated names within one extraction batch).
9. Append `:extracted` Episode row to Postgres with the LLM model id, prompt/completion tokens, and a snapshot of the extracted JSON for replay.
10. `MessageUsage` write in the `:super_brain_extraction` usage_type. Costs flow through the same unified usage accounting model as chat LLM calls.
11. For each accessor that can read this graph (computed via `AccessibleGraphs.accessors_of/1`), enqueue a `BuildSuperIncremental` job with a 30s coalescing window.

`ExtractionBudget` gates extraction per user via usage-plan credits. Pre-flight inside `ExtractBase` short-circuits with `{:cancel, :budget_exhausted}` and writes a `:skipped` Episode.

`BackfillScheduler` (cron `*/15 * * * *`) drains the queue for users whose extraction lag exceeds the per-plan threshold. Manual override via `mix super_brain.backfill --user <user_id>`.

### Instruction-tier source routing

`Ontology.compute_trust_tier/2` only promotes facts to `:instruction` when the caller supplies an `instruction_sources` source (`:user_curated`, `:brain_connection`, or `:memory_explicit`) AND the extraction confidence is at or above `0.9`. Per-resource workers in `ExtractBase` pass `ontology_source` into the extraction so the right pathway lights up:

| Pathway | Routed by | Source value |
|---------|-----------|--------------|
| Brain pages containing at least one `:callout` block with `variant: "important"` | `ExtractBrainPage.ontology_source_for_page/1` | `:user_curated` |
| Memories with `kind in [:fact, :preference]` | `ExtractMemory.ontology_source_for_memory/1` | `:memory_explicit` |
| Explicit `Brain.Connection` rows | `IngestBrainConnection` | `:brain_connection` |
| The `pin_fact` agent tool (creates a `Brain.Connection` with `is_explicit: true`, `contributor_type: :user`) | Tool, then `IngestBrainConnection` after_action | `:brain_connection` |

Everything else defaults to `:llm_extract`, which can only reach `:evidence` or (for very low confidence / repeatedly contradicted facts) `:noise`. Without one of the pathways above, the 1.5x `:instruction` multiplier is unreachable.

## Retrieval Pipeline

`Magus.SuperBrain.Retrieval.search/2` dispatches between the iter3 super-graph path and the iter2 legacy fan-out:

```
search(actor, query, embedding, workspace_context, trust_tiers, limit)
        |
        ▼
super_graph_for(actor, workspace_context)
        |
        ├── no row yet?           → enqueue_initial_build + legacy fan-out
        ├── read_set drifted?     → enqueue_rebuild + legacy fan-out
        └── healthy → super_graph_search/2
                          |
                          ▼
                   FalkorDB KNN over :CanonicalEntity.embedding (k = limit * 3)
                          |
                          ▼
                   filter_by_tier (trust_tiers option)
                          |
                          ▼
                   fetch 1-hop neighborhoods → compute neighborhood_support
                   per canonical (mean cosine of neighbor embeddings vs query)
                          |
                          ▼
                   composite score per hit:
                     vector_sim × tier_mult × importance_factor × nb_support
                          |
                          ▼
                   sort desc, take limit, enrich with sources via APPEARS_IN
                          |
                          ▼
                   {:ok, %{entities: [...]}}
```

`neighborhood_support` lives in `[1.0, 2.0]` — the unweighted mean cosine of the canonical's `:RELATES_TO` neighbors against the query embedding, clipped at `1.0 + max(0.0, avg)`. The neutral floor keeps a canonical from being penalized for having no neighbors.

Legacy fan-out (`legacy_fan_out_search/2`) is the iter2 retrieval path. It searches every Layer 1 graph in parallel via `Task.async_stream/3` (max 8, 5s timeout each), ranks via `Retrieval.Ranker.score/1`, and aggregates. The ranker formula is `similarity × tier_mult × graph_weight × source_weight × recency_decay × neighborhood_support` with a 90-day exponential half-life. This path is the safety net for cold-start and read-set drift.

The enrichment step on the super-graph path also pulls 1-hop `:RELATES_TO` neighbors per result (`Retrieval.fetch_canonical_neighbors/2`) and surfaces each neighbor's `predicate`, `confidence`, `contested`, and decoded `predicate_breakdown`. The ranker does not use those fields itself; they are passed through to the LLM context so the prompt sees conflicting evidence (e.g. "supports: 2 / contradicts: 1") instead of only the modal predicate.

## Per-episode `:RELATES_TO` aggregation in `BuildSuperIncremental`

For each new Episode it processes, `BuildSuperIncremental` pulls Layer 1 `:RELATES_TO` edges tagged with that episode's `source_id`, resolves both endpoint canonicals via their `:SourcePointer` in the super graph, and upserts a `:CanonicalEntity-[:RELATES_TO]->:CanonicalEntity` edge when BOTH endpoints already exist. The MERGE uses an `ON CREATE` / `ON MATCH` split:

- `ON CREATE`: sets `predicate`, `confidence`, `appearance_count = 1`, `trust_tier`, `source_graphs = [g]`, `contested`, `predicate_breakdown`.
- `ON MATCH`: increments `appearance_count`, takes `max(confidence)`, leaves `trust_tier` if already set, and merges the incoming `predicate_breakdown` map into the prior one (decoded, summed, re-encoded as JSON). `contested` becomes the boolean OR of the prior flag and the freshly-merged map's contested check.

Edges whose endpoints are not yet materialized (e.g. a stale source graph not yet fused) defer to the nightly `BuildSuperFull`, which remains the authoritative reconciler for cross-graph predicate counts. Earlier iterations deferred ALL `:RELATES_TO` aggregation to nightly; this per-episode path is iter4's incremental fast path.

## Agent integration

Three entry points connect the super brain to running agents:

### Automatic injection (every turn)

`Magus.Agents.Context.SuperBrainRagContext.build/1` runs in parallel inside `Magus.Agents.Context.Builder.build_llm_context/7` alongside `MemoryContext`, `RagContext`, and `BrainRagContext`. For each user message of at least 10 characters, it embeds the query via `Magus.Files.EmbeddingModel.embed/1`, calls `Retrieval.search/2` with the active user and the conversation's workspace as `workspace_context`, and appends a compact block to the system prompt:

```
<super_brain>
Relevant entities from your accumulated knowledge graph:

- Daniel [person/coworker] (seen in: brain:abc, memories:user:uid)
- Project Phoenix [project/work_project] (seen in: brain:abc)
...
</super_brain>
```

Returns `nil` (and the appender silently skips) when the query is too short, the embedder fails, retrieval returns no entities, or the FalkorDB backend is unavailable. The legacy fan-out shape is also supported in `format_legacy/1` so cold-start results still surface.

### Tools the LLM can invoke

| Tool | Module | Purpose |
|------|--------|---------|
| `super_brain.search` | `Magus.SuperBrain.Tools.Search` | Semantic search over the actor's super graph. Context requires `user_id`; `workspace_context`, `tiers`, and `limit` are tool args. |
| `pin_fact` | `Magus.Agents.Tools.SuperBrain.PinFact` | Creates an explicit `Brain.Connection` (`is_explicit: true`, `contributor_type: :user`) between two brain pages. The connection's `after_action` enqueues `IngestBrainConnection`, which writes the edge at `:instruction` trust tier (1.5x ranking multiplier). The agent passes page-level ids; the tool resolves the source block by picking the first block on the source page. |

Both tools are registered in `Magus.Agents.Tools.ToolBuilder.main_tools` and `sub_agent_tools`, so they are available to ordinary conversation agents and to spawned sub-agents.

## Authorization

Single source of truth: `Magus.SuperBrain.AccessibleGraphs`.

| Function | Purpose |
|----------|---------|
| `for_actor(actor, workspace_context: nil)` | Layer 1 graphs the actor can read; calls Ash with the actor for brain reads |
| `accessors_of(graph_name)` | Inverse: who is allowed to read this graph (used by extraction to enqueue per-accessor builds) |
| `super_graph_for(actor, workspace_context: nil)` | Layer 2 graph name for this (actor, workspace) tuple |

`authorization_test.exs` uses StreamData property tests to assert: for any actor + workspace combination, no graph is ever returned that the actor doesn't have Ash-level read access to. The same property is exercised by `BuildSuperFull`'s read-set snapshot.

## Workers and Cron

| Worker | Trigger | Queue | Purpose |
|--------|---------|-------|---------|
| `ExtractBrainPage` | after_action on `Brain.Page`/`Brain.Block` | `super_brain_extraction` | Extract entities/edges from a brain page (per-block) |
| `ExtractMemory` | after_action on `Memory` | `super_brain_extraction` | Extract from memory summary + content |
| `ExtractFileChunk` | after_action on `Files.Chunk` | `super_brain_extraction` | Extract per file chunk |
| `ExtractDraft` | after_action on `Drafts.Draft` | `super_brain_extraction` | Extract from draft body |
| `IngestBrainConnection` | after_action on `Brain.Connection` | `super_brain_extraction` | Materialize explicit page-to-page link as an `:instruction` tier edge |
| `BackfillScheduler` | Oban cron `*/15 * * * *` | `super_brain_extraction` | Drain extraction lag for the worst-affected users |
| `BuildSuperIncremental` | enqueued per accessor at end of each extraction | `super_brain_extraction` | Delta-fuse new entities + per-episode `:RELATES_TO` aggregation + drift detection |
| `NightlyBuildSuperScheduler` | Oban cron `30 3 * * *` | `super_brain_extraction` | Enqueue `BuildSuperFull` for every active accessor |
| `BuildSuperFull` | scheduled or manual | `super_brain_extraction` | Full per-accessor rebuild with importance recompute |
| `SuperGraphMaintenance` | Oban cron `0 4 * * *` | `super_brain_extraction` | Compact, prune zero-source canonicals, refresh vector indexes |
| `MigrationSweeper` | Oban cron `*/10 * * * *` | `super_brain_extraction` | Detect Layer 2 graphs whose `migration_marker` is behind `Migration.canonical_version/0` and enqueue `BuildSuperFull` (rate-capped) |

The `super_brain_extraction` Oban queue has concurrency 4 in production. Workers use `unique: [period: 30, fields: [:args]]` so 30-second coalescing windows collapse bursty incremental enqueues into a single build per accessor.

## Ash Resources

| Resource | Table | Purpose |
|----------|-------|---------|
| `Magus.SuperBrain.Episode` | `super_brain_episodes` | Append-only log of every extraction attempt: status, model id, token counts, JSON snapshot, supersede chain |
| `Magus.SuperBrain.SuperGraph` | `super_brain_super_graphs` | One row per `(accessor_type, user_id, workspace_id)`: graph name, `read_set_snapshot`, `last_built_at`, `last_build_status`, `last_build_duration_ms`, canonical/edge counts |

The `SuperGraph` identity uses `nils_distinct?: false` so a single null `workspace_id` collides correctly: there is exactly one personal super graph per user, not N nulls.

Episode statuses: `:pending → :extracting → :extracted | :skipped | :failed | :superseded`. The supersede chain (`superseded_by_id`) is how content updates flow: re-extracting a brain page after edit produces a new `:extracted` episode and marks the previous one `:superseded`. Layer 1 writes are upserts keyed on `Entity.source_id`, so the new episode replaces the old graph state atomically per node/edge.

## Operations

| Mix Task | Purpose |
|----------|---------|
| `mix super_brain.rebuild --graph <name> --yes` | Drop and re-derive a graph from Postgres episodes (Layer 1) or enqueue `BuildSuperFull` (Layer 2) |
| `mix super_brain.backfill --user <id>` | Prioritize a user during recovery, bypassing the per-tick `BackfillScheduler` cap |
| `mix super_brain.search --user <email> --query "..."` | Run `Retrieval.search/2` from the CLI; labels which path served the result (super-graph vs legacy fan-out); supports `--workspace`, `--tiers`, `--limit`, `--verbose` |

For FalkorDB deployment, backups, snapshot/restore, and disaster recovery, see `docs/super_brain/operations.md`.

## Key Files

| File | Purpose |
|------|---------|
| `lib/magus/super_brain/accessible_graphs.ex` | Auth boundary: which graphs an actor can read |
| `lib/magus/super_brain/ontology.ex` | 12 entity types, 8 predicates, trust tier multipliers |
| `lib/magus/super_brain/ontology/subtype_normalizer.ex` | Hand-maintained subtype synonym map |
| `lib/magus/super_brain/extraction.ex` | LLM extraction orchestrator (prompt → sanitize → return) |
| `lib/magus/super_brain/extraction/prompt.ex` | Strict-JSON extraction prompt with ontology + subtype examples |
| `lib/magus/super_brain/extraction/sanitizer.ex` | Atom-safe normalization for names/types/subtypes/predicates |
| `lib/magus/super_brain/episode.ex` | Append-only extraction log with supersede chain |
| `lib/magus/super_brain/super_graph.ex` | Per-accessor super graph metadata row |
| `lib/magus/super_brain/graph_router.ex` | Resource → graph name resolution |
| `lib/magus/super_brain/graph_weight.ex` | Per-graph and per-accessor weight overrides |
| `lib/magus/super_brain/extraction_budget.ex` | Usage-plan credit gating for extraction |
| `lib/magus/super_brain/workers/extract_base.ex` | Shared extraction pipeline (advisory lock, inline canonicalize, fan-out enqueue) |
| `lib/magus/super_brain/workers/extract_brain_page.ex` | Per-resource thin shim |
| `lib/magus/super_brain/workers/extract_memory.ex` | Per-resource thin shim |
| `lib/magus/super_brain/workers/extract_file_chunk.ex` | Per-resource thin shim |
| `lib/magus/super_brain/workers/extract_draft.ex` | Per-resource thin shim |
| `lib/magus/super_brain/workers/ingest_brain_connection.ex` | Explicit brain links at `:instruction` tier |
| `lib/magus/super_brain/workers/backfill_scheduler.ex` | Cron drainer for lag-affected users |
| `lib/magus/super_brain/workers/build_super_full.ex` | Per-accessor full rebuild + canonical id formula + importance score |
| `lib/magus/super_brain/workers/build_super_incremental.ex` | Delta fuse + per-episode `:RELATES_TO` aggregation + drift detection (mirrors canonical id formula) |
| `lib/magus/super_brain/workers/nightly_build_super_scheduler.ex` | 03:30 UTC cron enqueueing per-accessor `BuildSuperFull` |
| `lib/magus/super_brain/workers/super_graph_maintenance.ex` | 04:00 UTC cron for pruning + index refresh |
| `lib/magus/super_brain/workers/migration_sweeper.ex` | `*/10 * * * *` cron that rebuilds Layer 2 graphs whose `migration_marker` is behind |
| `lib/magus/super_brain/migration.ex` | Version constants (`entity_version/0`, `canonical_version/0`) bumped per migration |
| `lib/magus/super_brain/telemetry.ex` | Telemetry event registry (span and counter event names + helpers) |
| `lib/magus/super_brain/telemetry_handler.ex` | Logger-backed sink for every Super Brain event; attached at app startup |
| `lib/magus/super_brain/retrieval.ex` | Super-graph-first search with legacy fan-out fallback |
| `lib/magus/super_brain/retrieval/ranker.ex` | Pure ranking function for the legacy fan-out path |
| `lib/magus/super_brain/tools/search.ex` | Jido `super_brain.search` tool: semantic search exposed to agents |
| `lib/magus/agents/tools/super_brain/pin_fact.ex` | Jido `pin_fact` tool: creates an `:instruction`-tier brain connection |
| `lib/magus/agents/context/super_brain_rag_context.ex` | Per-turn automatic injection of the `<super_brain>` block into the system prompt |
| `lib/magus/super_brain/usage.ex` | `MessageUsage` writes for extraction calls (unified usage accounting) |
| `lib/magus/super_brain/llm_client.ex` + `llm_client/req_llm.ex` | LLM client behaviour + production adapter (Mox-mockable in tests) |
| `lib/mix/tasks/super_brain.rebuild.ex` | Drop + replay a graph from Postgres episodes |
| `lib/mix/tasks/super_brain.backfill.ex` | Prioritized backfill for a user |
| `lib/mix/tasks/super_brain.search.ex` | CLI retrieval for manual testing |
| `docs/super_brain/operations.md` | FalkorDB deployment, backup, restore, disaster recovery |
