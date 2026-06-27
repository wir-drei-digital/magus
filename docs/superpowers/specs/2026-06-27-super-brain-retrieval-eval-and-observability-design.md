# Super Brain: Retrieval Eval + Observability (Phase 1)

Date: 2026-06-27
Status: Approved (design, revised after review)
Scope: First slice of the "super graph" upgrade roadmap. Stands up the
guardrails and free wins that make every later phase (claim/evidence
storage, identity resolution, query-planned retrieval) safe to attempt.

## Context

An architecture readout flagged that the Super Brain is "operationally strong
but semantically an entity index." A code-grounded pass confirmed the storage
model and surfaced four facts that shape this phase:

1. **L2 storage model.** The super graph is
   `CanonicalEntity -[:RELATES_TO {predicate, confidence, trust_tier,
   contested, predicate_breakdown, appearance_count, source_graphs}]->
   CanonicalEntity`, plus `CanonicalEntity -[:APPEARS_IN]-> SourcePointer`.
   No claim node, no source spans, no temporal validity. (Confirmed in
   `lib/magus/super_brain/workers/build_super_full.ex`.)

2. **Already past a bare index.** Trust tiers (`:instruction | :evidence |
   :noise`) live in `Magus.SuperBrain.Ontology`; L2 edges already carry a
   `contested` boolean and a `predicate_breakdown` JSON, computed at build
   time from `Ontology.contradicting_predicates/0`
   (`build_super_full.ex:868`).

3. **Context is the weak link, and it is half-wired.**
   `Retrieval.fetch_canonical_neighbors/2` (`retrieval.ex:340`) already
   fetches each neighbor's `predicate`, `confidence`, `contested`, and
   `predicate_breakdown` and attaches them to every entity as `:neighbors`.
   `SuperBrainRagContext.format_super_entity/2`
   (`super_brain_rag_context.ex:90`) then drops all of it and prints only
   `name [type] + source refs`.

4. **Documentation drift.** `build_super_full.ex` line ~598 says "Name is
   intentionally NOT in the hash" directly above the call that passes the
   name into `CanonicalId.for/4`, which hashes it
   (`canonical_id.ex:63`). The comment is the inverse of the code.
   `docs/system/15-super-brain.md` still says 12 entity types / 8
   predicates; the code has 17 / 18 (`ontology.ex:42`).

The eval-before-optimizing principle from the readout is treated as
foundational here, not deferred: without a fixed retrieval eval, the later
graph changes "feel better while silently regressing."

## Goals

- A deterministic, offline retrieval eval integrated into the existing
  `Magus.Eval` framework, runnable both via `mix magus.eval` and as a
  normal `mix test` regression guard.
- A live variant of the same eval that exercises the real builder and real
  embeddings, behind the existing `:e2e_live` tag.
- Build-time graph-shape metrics on the `SuperGraph` row, plus richer
  retrieval telemetry.
- Render the contested/relation signal the agent context already fetches.
- Fix the documentation drift.

## Non-goals (this phase)

Claim/evidence nodes, identity-resolution implementation, new retrieval
modes (multi-hop traversal, temporal, global/community), and any admin UI.
Those are phases 2 to 6. This phase only builds the measurement substrate
and the zero-risk fixes. The eval encodes the later phases as known-gap
xfail cases so they become measurable when implemented.

## Success criteria

- `MIX_ENV=test mix magus.eval super_brain_retrieval` prints an aggregate
  recall and writes a diffable JSONL row to
  `eval/results/super_brain_retrieval.jsonl`.
- A normal `mix test` run executes the deterministic eval and fails on any
  regression in the supported case set, WITHOUT writing to
  `eval/results/*.jsonl` (it runs with `dry_run: true`).
- The live eval runs the real `BuildSuperFull` over a deterministic L1
  fixture with real embeddings behind `:e2e_live`.
- The agent `<super_brain>` block surfaces contradiction signal for
  contested entities.
- `docs/system/15-super-brain.md` and the `build_super_full.ex` comment
  match the code.

## Architecture

The `Magus.Eval` framework is QA-shaped: a `Benchmark` produces cases
(`{id, question, gold, ingest_items, meta}`); a `Subject` implements
`reset/ingest/query`; the `Runner` loops cases through the subject and a
`Scoreboard` appends one JSONL row per run. Crucially, `Runner.run_case/3`
(`runner.ex:48`) threads `ctx` through `reset -> ingest -> query` and passes
only `c.ingest_items` to `ingest` and only `c.question` to `query`; the case
`meta` is merged into the result `meta` and reaches `score/2`, but is NOT
handed to the subject.

Approach A (retrieval-only over a seeded graph fixture) maps onto this
contract WITHOUT changing `Runner` or the `Subject` behaviour:

- The graph fixture (entities, edges, sources, and the authored
  `query_embedding`) is carried as a single `ingest_items` element of the
  form `%{role: :fixture, text: Jason.encode!(fixture)}`. This widens the
  `role` field from `:user | :assistant` to also allow `:fixture`; the
  generic `Runner` passes it through opaquely, and the `Subject` behaviour
  already types `role` as `atom`.
- `ingest/2` decodes that fixture, materializes the graph, and stashes the
  authored `query_embedding` onto the returned `ctx`.
- `query/2` reads `ctx.query_embedding` (deterministic) or embeds
  `c.question` for real (live), then calls `Retrieval.search`, returning the
  ranked canonicals in its result `meta`.
- The expected entity set, `category`, `k`, and `supported` flag live in the
  case `meta` so `score/2` can read them from the merged result `meta`.

### New modules

**Eval core (lib, no test-only deps):**

- `Magus.Eval.Benchmarks.SuperBrainRetrieval` implements
  `Magus.Eval.Benchmark`.
  - `name/0` returns `"super_brain_retrieval"`.
  - `load_dataset/1` reads
    `priv/eval/super_brain_retrieval/cases.json`.
  - `cases/2` splits each JSON case into
    `%{id, question: query, gold: primary_expected_name,
    ingest_items: [%{role: :fixture, text: Jason.encode!(fixture)}],
    meta: %{expected, category, k, supported}}`, and filters the dataset by
    `opts[:subject_kind]` so live-only cases (see Categories) are excluded
    from deterministic runs.
  - `score/2` delegates to `Magus.Eval.SuperBrain.Metrics`; returns
    `%{aggregate, per_case, per_category, known_gaps}`.
  - `emit_hypotheses/2` writes one JSON line per case with the retrieved
    entity ids/names.
- `Magus.Eval.SuperBrain.Metrics` holds pure scoring functions:
  `hit_at_k/2`, `recall_at_k/2`, `mrr/2`, and aggregation over a case list
  with per-category and known-gap breakdowns. No I/O, unit-tested in
  isolation.
- `Magus.Eval.SuperBrain.Fixture` parses a case's graph spec
  (`entities`, `edges`, `sources`, `expected`, `query_embedding`) from the
  decoded JSON into a normalized struct that both subjects consume. This is
  the single shared contract between the deterministic and live subjects.
- `Magus.SuperBrain.EdgeAggregation` (new, lib) holds the pure
  RELATES_TO aggregation currently inlined as the private
  `BuildSuperFull.aggregate_relates_to/3` (`build_super_full.ex:762`):
  given a list of L1-style edge observations, group by `(from, to)` and
  return one aggregate per pair with `predicate` (most common),
  `predicate_breakdown` (frequencies), `contested` (via
  `Ontology.contradicting_predicates/0`), `confidence`, `trust_tier`,
  `source_graphs`, and `appearance_count`. `BuildSuperFull` is refactored to
  compute via this module and then perform its FalkorDB upserts; the
  deterministic subject and unit tests reuse it. This removes the
  duplicate `contested?/1` logic the spec would otherwise have to mirror.

**Eval subjects (test/support, alongside `Subject.Live`):**

- `Magus.Eval.Subject.SuperBrainDeterministic` implements
  `Magus.Eval.Subject`.
  - `reset/1` ensures a clean eval user (from `ctx`) and drops that user's
    `super:user:<id>` graph plus any prior `SuperGraph` row, so each case
    starts empty.
  - `ingest/2` decodes the fixture from the single `:fixture` item and seeds
    the L2 super graph directly: `CanonicalEntity` nodes with hand-authored
    low-dim embeddings (dim 8); one `RELATES_TO` edge per `(from, to)` pair
    computed by `Magus.SuperBrain.EdgeAggregation.aggregate/1` over the
    fixture's L1-style edge observations (so the deterministic edge, including
    `contested` and `predicate_breakdown`, matches what the builder emits);
    `SourcePointer` nodes; and `APPEARS_IN` edges. It creates the
    `CanonicalEntity.embedding` vector index at dim 8 on the fresh graph,
    upserts a `SuperGraph` row marked `:ok` with
    `read_set_snapshot = AccessibleGraphs.for_actor(user) |> reject(super)
    |> sort` so `Retrieval`'s drift check passes, and stashes the authored
    `query_embedding` onto `ctx`.
  - `query/2` calls `Retrieval.search(user, query: c.question,
    query_embedding: ctx.query_embedding, limit:)` and returns
    `%{answer: top_name, meta: %{retrieved: [%{id, name, type, score, rank,
    sources, neighbors}]}}`.
  - Because it seeds an already-fused L2, the deterministic subject tests
    retrieval over a canonical, NOT the fusion step itself (so
    `same_name_fusion` is a live-only case; see Categories).
- `Magus.Eval.Subject.SuperBrainLive` implements `Magus.Eval.Subject`,
  tagged for `:e2e_live` use.
  - `reset/1` creates a real personal brain via `Magus.Generators` (so
    `AccessibleGraphs.for_actor` discovers `brain:<id>`) and drops any
    stale L1/L2 graphs for the user.
  - `ingest/2` seeds the L1 `brain:<id>` graph directly with `Entity`
    nodes, `RELATES_TO` edges, and `Episode -[:HAS_ENTITY]->` provenance,
    then runs `Magus.SuperBrain.Workers.BuildSuperFull.perform` for the
    accessor to materialize L2. Entity embeddings are produced by the real
    embedder (see Embeddings below).
  - `query/2` embeds `c.question` with the real embedder and calls
    `Retrieval.search`.

The live subject deliberately seeds L1 entities directly and skips LLM
extraction: entity content stays deterministic, so the gold expected sets
remain valid, while clustering/fusion, contested aggregation, importance
scoring, the staged build + swap, and retrieval are all real. Extraction
quality (raw text to entities) is approach B and out of scope.

### Embeddings (deterministic vs live)

The deterministic subject uses only authored vectors and never calls an
embedder.

The live subject needs REAL embeddings, but in the test env (which
`:e2e_live` runs under) `config/test.exs:87,90` point
`:super_brain_embedder` and `:super_brain_extraction_embedder` at
`EmbedderMock` / `BatchEmbedderMock`. To get real recall, the live subject
embeds both entity names and the query via `Magus.Files.EmbeddingModel`
(the real OpenRouter path production retrieval uses for query embeddings),
which is independent of those two config keys and therefore unaffected by the
mocks. This requires `OPENROUTER_API_KEY`, already mandated by `:e2e_live`.
Entity and query embeddings thus share one model/space, and
`EmbeddingModel`'s dim equals `EmbeddingConfig.dim()` (both resolve the
`:embeddings` role), so the L1 index dim, the averaged canonical embedding,
and the query vector all agree. `BuildSuperFull` itself calls no embedder
(it averages existing L1 embeddings), so the mocked extraction embedder is
never on this path.

### Data: cases.json

A JSON array. Each case:

```json
{
  "id": "local_lookup_daniel",
  "category": "local_lookup",
  "supported": true,
  "subjects": ["deterministic", "live"],
  "query": "who is Daniel",
  "query_embedding": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
  "k": 5,
  "expected": [{"name": "Daniel", "type": "person"}],
  "fixture": {
    "entities": [
      {"key": "daniel", "name": "Daniel", "type": "person",
       "normalized_subtype": null, "embedding": [1,0,0,0,0,0,0,0],
       "trust_tier": "evidence", "confidence": 0.9},
      {"key": "aurora", "name": "Project Aurora", "type": "project",
       "embedding": [0,1,0,0,0,0,0,0], "trust_tier": "evidence"}
    ],
    "edges": [
      {"from": "daniel", "to": "aurora", "predicate": "works_on",
       "confidence": 0.8}
    ],
    "sources": [
      {"entity": "daniel", "resource_type": "brain_page",
       "resource_id": "00000000-0000-4000-8000-000000000001"}
    ]
  }
}
```

Notes:
- `subjects` selects which subject(s) a case applies to (default both).
  Fusion cases are `["live"]` only.
- `query_embedding` is authored for the deterministic subject (carried into
  `ctx` by `ingest`). The live subject ignores it and embeds `query` for
  real.
- Entity `embedding` is authored for the deterministic subject and ignored
  by the live subject (which embeds `name`).
- `expected` matches on normalized `(name, type)` against retrieved
  canonicals, sidestepping opaque content-hash ids.
- `fixture.edges` are L1-style observations (one per observed relation);
  multiple entries for the same `(from, to)` pair represent repeated or
  conflicting observations. Both subjects derive the single L2 `RELATES_TO`
  identically via `EdgeAggregation.aggregate/1`: the deterministic subject
  applies it in code, the live subject seeds the L1 edges and lets the real
  builder apply it. A `contested` case supplies opposing predicates (for
  example `supports` and `contradicts`) for one pair.
- `resource_id` values MUST be valid UUIDs. `SuperBrainRagContext` title
  resolution filters Postgres by UUID columns
  (`super_brain_rag_context.ex:170`), so non-UUID ids would be silently
  dropped if a ref ever flows into `format/1`. The live subject points
  `brain_page` refs at a real created page id so end-to-end attribution
  resolves.

### Categories and the xfail roadmap

Supported now (must pass, recall@k == 1.0 by fixture construction):
- `local_lookup` (both subjects) — vector recall of a single entity.
- `contradiction_detection` (both) — the hit carries a `contested` neighbor
  with the expected `predicate_breakdown`.
- `source_attribution` (both) — the hit carries the expected source ref.
- `same_name_fusion` (live only) — two L1 graphs each hold a same-named
  entity; after the real `BuildSuperFull`, retrieval returns ONE fused
  canonical. The deterministic subject cannot test this because it seeds an
  already-fused L2; genuine fusion is build-time and is also covered by the
  existing `BuildSuperFull` tests.

Known-gap xfail (`supported: false`, expected to fail until the named
phase; flipping to passing is a signal to promote the case):
- `alias_resolution` (different surface names, for example "Daniel" vs
  "Daniel Smith") — phase 3 identity resolution.
- `multi_hop` (2+ hop reasoning) — phase 5/6 traversal.
- `temporal` (validity windows / current-vs-historic) — phase 6.

### Scoring

`Metrics.score/2`:
- Per case: `hit@k`, `recall@k`, `mrr`, `correct?` (recall@k == 1.0).
- `aggregate` = mean recall@k over `supported` cases only.
- `per_category` = accuracy per category (mirrors LongMemEval's
  `per_ability`).
- `known_gaps` = `%{category => "passing/total"}` over `supported: false`
  cases, tracked separately so the headline aggregate is not dragged down
  by intentionally-unimplemented capabilities.

### Runner / mix task integration

- `Magus.Eval.Runner` and `Magus.Eval.Scoreboard` are reused unchanged.
  When not in `dry_run`, Scoreboard writes
  `eval/results/super_brain_retrieval.jsonl`, git-sha tagged and diffable.
- The EXISTING test-support task
  `test/support/mix/tasks/magus.eval.ex` is extended IN PLACE (it stays in
  `test/support/` because it depends on test-only generators and live
  helpers; it is NOT moved to `lib/`). It gains a
  `--subject deterministic|live` option mapping to the two subject modules,
  passes a matching `subject_kind` into `run_opts` (so `cases/2` filters),
  and registers `"super_brain_retrieval"` in its benchmark map.
- The deterministic path requires Postgres + FalkorDB but no LLM/embedding
  API key: `Harness.setup` only builds DB fixtures and swaps an (unused)
  LLM client, and the deterministic subject calls neither the embedder nor
  the agent.

### Where it runs

- `test/magus/super_brain/eval/super_brain_retrieval_test.exs`: drives the
  deterministic subject through `Runner.run` with `subject_kind:
  :deterministic` and `dry_run: true` (so it does NOT append to
  `eval/results/*.jsonl`), asserting on the returned `scored` map: the
  supported aggregate is 1.0 and every `supported: false` case still fails
  (a newly-passing gap fails this assertion, forcing a conscious promotion).
  Runs in a normal `mix test` (and therefore `mix precommit`).
- `test/e2e_live/super_brain_retrieval_eval_test.exs`: drives the live
  subject, tagged `:e2e_live`.

## Observability

- `Magus.SuperBrain.GraphMetrics` (lib): pure functions computing
  - `isolated_entity_rate` — fraction of `CanonicalEntity` nodes with no
    `RELATES_TO` edge (APPEARS_IN is excluded, since every canonical has at
    least one APPEARS_IN, so "no edges at all" would be meaningless).
  - `relates_to_fallback_rate` — fraction of edges whose `predicate` is the
    generic `relates_to`.
  - `ambiguous_bucket_count` — count of `(type, normalized_subtype)` buckets
    holding more than one distinct `name_key`. This is a coarse upper bound
    on identity-resolution opportunity and WILL be noisy (unrelated
    same-typed entities inflate it); phase 3 refines it with lexical /
    embedding similarity thresholds. Named `ambiguous_bucket_count`, not
    `alias_candidate_count`, to avoid implying confirmed aliases.
  - `contested_edge_count` — number of edges with `contested == true`.
  - `edges_per_entity` — `RELATES_TO` edge count divided by canonical count.

  Inputs are FalkorDB query results; no I/O in the module itself so it is
  unit-testable.
- `BuildSuperFull` computes these against the staging graph before the swap
  and persists them.
- `SuperGraph` gains a `metrics :map` attribute (default `%{}`), written via
  the existing `:mark_built` action (extended to accept `metrics`). One JSON
  column rather than a column per metric; requires an `ash.codegen`
  migration.
- `Retrieval` enriches the existing `[:super_brain, :retrieval]` telemetry
  span metadata with `mode` (`:super_graph | :fan_out | :cold_start |
  :drift`) and `result_count`. No new telemetry infrastructure.
- Out of scope: an admin dashboard. Metrics are available on the row, via
  telemetry, and through the eval scoreboard.

## Context render

`SuperBrainRagContext.format_super_entity/2` is changed to render the
`:neighbors` already attached by `Retrieval`:
- Contested edges are always shown, compact:
  `contested: <neighbor> (supports 2 / contradicts 1)`, derived from
  `predicate_breakdown`.
- Otherwise the top 1 to 2 highest-confidence relations are shown as
  `<predicate>: <neighbor>`.
- A per-entity cap and a total-relation-lines budget keep the per-message
  block bounded; overflow collapses to the existing `+N more` style.

This is a pure formatting change covered by the existing
`super_brain_rag_context` test (extended with a contested fixture whose
refs use valid UUIDs).

## Drift / docs

- Rewrite the `canonical_id_for/2` comment in `build_super_full.ex` to state
  that the name IS folded into the canonical-id hash (matching
  `CanonicalId`).
- Update `docs/system/15-super-brain.md` to 17 entity types / 18 predicates
  and the current node/edge shape (`CanonicalEntity`, `SourcePointer`,
  `APPEARS_IN`, and `RELATES_TO` with `contested` / `predicate_breakdown`).

## Testing strategy

- `Magus.SuperBrain.EdgeAggregation` — pure unit tests for grouping,
  most-common predicate, `predicate_breakdown`, and `contested`; the
  `BuildSuperFull` refactor is covered by existing builder tests (no
  behaviour change).
- `Magus.Eval.SuperBrain.Metrics` — pure unit tests for `hit@k`,
  `recall@k`, `mrr`, aggregation, and the known-gap split.
- `Magus.Eval.SuperBrain.Fixture` — parse/normalize unit tests.
- `Magus.SuperBrain.GraphMetrics` — pure unit tests over synthetic
  query-result inputs.
- Deterministic eval regression test (above) in normal `mix test`, with
  `dry_run: true`.
- Live eval test behind `:e2e_live`.
- Extended `super_brain_rag_context` test asserting the contested line
  renders and the budget cap holds.

## Risks and mitigations

- **Authored-vector realism.** The deterministic eval guards ranking logic,
  not semantic recall. Mitigation: the live subject covers real embeddings;
  the deterministic suite is explicitly the fast logic guardrail.
- **Deterministic subject must satisfy Retrieval's preconditions** (built
  row, non-drifted snapshot, vector index present). Mitigation: `ingest`
  computes the snapshot via the same `AccessibleGraphs.for_actor` call
  Retrieval uses, and creates the index before seeding (mirrors
  `retrieval_test.exs`).
- **`role: :fixture` widens the eval_case shape.** It is a benign widening
  the generic `Runner` passes through opaquely; the `Subject` behaviour
  already types `role` as `atom`. Mitigation: documented here and in the
  benchmark moduledoc; no core code changes.
- **Live build flake** (FalkorDB `GRAPH.COPY` fork failures, embedder
  latency). Mitigation: it is `:e2e_live`-only and reuses the worker's
  existing retry/threshold handling.
- **`mix test` now touches FalkorDB.** The deterministic eval needs a
  running FalkorDB like the existing `retrieval_test.exs` already does, so
  this adds no new external dependency to the default suite.

## Build sequence (for the implementation plan)

1. Drift/doc fixes (zero-risk warmup).
2. Context render + extended context test.
3. Extract `Magus.SuperBrain.EdgeAggregation` (pure) from
   `BuildSuperFull.aggregate_relates_to`; builder delegates; unit tests.
   (Prereq for the deterministic subject and a small standalone refactor.)
4. `GraphMetrics` + `SuperGraph.metrics` column (`ash.codegen`) +
   `BuildSuperFull` wiring + retrieval telemetry metadata.
5. Eval core: `Metrics`, `Fixture`, `Benchmark`, `cases.json` (supported
   deterministic cases first, then live-only fusion, then xfail gaps).
6. `SuperBrainDeterministic` subject + deterministic regression test
   (`dry_run: true`) + extend the test-support `magus.eval` task
   (`--subject`, `subject_kind`, register benchmark).
7. `SuperBrainLive` subject + `:e2e_live` test (real `EmbeddingModel`
   embeddings).
