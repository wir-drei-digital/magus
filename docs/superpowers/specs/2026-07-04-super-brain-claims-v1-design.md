# Super Brain Phase 2: Claims v1 (claim extraction, storage, recall, dossier)

Date: 2026-07-04
Status: Approved (design)
Scope: Second slice of the "super graph" upgrade roadmap. Introduces claims
(the actual sentences, with provenance, polarity, and time fields) as the
first-class knowledge unit, stored in Postgres, recalled by embedding, and
consumed through a rewritten context block and a new dossier tool.

## Context

Phase 1 (retrieval eval + observability, PR magus#2) built the measurement
substrate. A follow-up analysis pass concluded that the super graph is
"a well-engineered index of names": extraction stores only
`(name, type, subtype)` entities and bare predicate edges, so the actual
knowledge (the sentence) is discarded at extraction time. Every downstream
weakness follows: embeddings cover entity names, so recall matches name
similarity rather than fact similarity; edges assert nothing checkable;
the `<super_brain>` context block is the only per-turn context block that
carries no propositional content; and the stated purpose of the system
("what do I know about X", `docs/system/15-super-brain.md:5`) cannot be
answered.

Four pillars justify a knowledge graph over plain vector RAG: identity,
aggregation, consistency, and time. This phase moves three of them
(aggregation, consistency, time-as-data) from zero to visible. Identity
resolution stays a later phase, gated on the `ambiguous_bucket_count`
metric Phase 1 added.

Decisions taken during brainstorming:

1. **Scope: spine + dossier tool.** Claim extraction, storage, recall, and
   the rewritten context block, plus one visible surface: a `get_dossier`
   agent tool. Contradiction inbox, memory hydrate, and UI stay out.
2. **Storage: Postgres-first.** Claims are rows in a new
   `super_brain_claims` table with a pgvector embedding. FalkorDB gets no
   claim nodes in v1; the graph stays entity-level and the entire L2 build
   path is untouched. This follows the codebase principle that the graph is
   a derived, disposable index over Layer 0.
3. **Backfill: forward-only plus an on-demand task.** New and edited
   content produces claims immediately. A manual mix task re-extracts a
   user's stale content on demand. No automatic fleet-wide re-extraction.

## Goals

- Extraction produces claims: subject, predicate, object, polarity, the
  supporting sentence, confidence, and optional validity dates. One LLM
  call, same as today.
- Claims are durable Postgres rows with provenance (episode) and a
  pgvector embedding over the claim text.
- Retrieval gains claim recall: queries match fact text, not only entity
  names.
- The `<super_brain>` block renders claims with citations; entities
  without claims degrade to today's rendering.
- A `get_dossier` tool answers "everything known about X": grouped,
  provenance-linked, conflict-flagged, ordered by currency.
- L1 `RELATES_TO` edges derive from claims, so `contested` and
  `predicate_breakdown` reflect grounded predicates. The extraction
  prompt's edge-density quota is removed.
- The Phase 1 eval grows claim-recall cases and one temporal xfail.

## Non-goals (this phase)

Identity resolution / alias fusion (phase 3), temporal ranking and
cross-claim supersede links, contradiction notifications or inbox, memory
hydrate, any UI surface, community summaries or PPR-style traversal,
literal-valued objects (`object_value`), and changes to `pin_fact`.
FalkorDB claim nodes are explicitly deferred: if a later traversal phase
needs claims along paths, it either projects them into the graph then or
traverses entities in-graph and hydrates claim rows from Postgres by
endpoint keys.

## Success criteria

- `mix test` runs a deterministic claim-recall eval case set at recall
  1.0, plus a `temporal` xfail that fails until temporal ranking exists.
- The live `:e2e_live` eval seeds claims with real embeddings and passes
  claim recall through the real pgvector path.
- `get_dossier` on seeded data returns grouped claims with sources,
  polarity conflicts flagged, ordered by latest `asserted_at`.
- The `<super_brain>` block renders claim lines with citations; a
  claim-less entity renders exactly today's name + refs line.
- The existing full feature suite stays green with zero builder changes
  (`BuildSuperFull`, `BuildSuperIncremental`, `EdgeAggregation` untouched).
- `mix super_brain.backfill_claims --user <id>` re-extracts a user's
  stale resources end-to-end in dev.

## Data model

New Ash resource `Magus.SuperBrain.Claim` (table `super_brain_claims`),
registered in the `Magus.SuperBrain` domain:

| Attribute | Type | Notes |
|---|---|---|
| `id` | uuid pk | |
| `graph_name` | string, indexed | L1 source graph; the auth key |
| `episode_id` | uuid FK to `super_brain_episodes`, indexed | provenance; episode carries `resource_type`, `resource_id`, `extracted_at` |
| `source_user_id` | uuid, indexed | mirrors `Episode.source_user_id`; account deletion and per-user ops |
| `subject_name` / `subject_type` / `subject_key` | string / string / string, `subject_key` indexed | key = downcased, whitespace-collapsed name (same normalization as canonical buckets) |
| `object_name` / `object_type` / `object_key` | string / string / string, `object_key` indexed | entity endpoints only in v1 |
| `predicate` | string | canonical or free-form snake_case, same vocabulary as today (`Ontology.classify_predicate/1`) |
| `polarity` | atom `:affirms \| :negates`, default `:affirms` | negation capture |
| `claim_text` | string, required, capped 500 chars | the supporting sentence |
| `confidence` | float | |
| `trust_tier` | atom `:instruction \| :evidence \| :noise` | computed via `Ontology.compute_trust_tier/2` with the episode's ontology source pathway, like entities |
| `asserted_at` | utc_datetime | v1: the episode's `extracted_at` (proxy for source time; refined in the temporal phase) |
| `valid_from` / `valid_to` | utc_datetime, nullable | only when the text states them |
| `embedding` | `Magus.Files.Types.Vector` (1536), nullable | over `claim_text`; null rows are skipped in search and backfillable |
| timestamps | | |

Migration notes:

- New table, no risk to existing data. Vector index settings (HNSW vs
  ivfflat, distance op) MUST mirror the `file_chunks.embedding` index:
  diff the sibling migration rather than trusting resource defaults
  (Ash codegen loses migration-only settings).
- FK to episodes: episodes are append-only and never deleted, so no
  cascade behavior is load-bearing; declare `on_delete: :delete` for
  hygiene.

Authorization: `Claim` is an internal resource, like `SuperGraph` (which
declares no policies at all) and `Episode` (whose policy block Claim's
mirrors in shape: an AI-agent read bypass plus an actor-scoped human read
policy, with writes forbidden outright since only the extraction pipeline
writes claims). Every read path additionally filters
`graph_name in accessible_graphs` where the allow-list comes from
`Magus.SuperBrain.AccessibleGraphs.for_actor/2`, the exact trust model
FalkorDB queries use today (authorization lives in `AccessibleGraphs`,
not the store). Writes happen inside extraction workers with
`authorize?: false`, the documented Super Brain internal pattern
(`retrieval.ex:116` reads the same way).

### Lifecycle: claims mirror what sources currently say

`ExtractBase.supersede_prior/4` (`extract_base.ex:458`) already drives
prior episodes to `:superseded` and deletes their graph footprint. It
gains one step: delete the prior episodes' claim rows in the same
persistence transaction. The new episode then inserts the source's
current claims. Consequences:

- The claims table always mirrors the latest extraction per source,
  exactly like L1 entity upserts.
- No `superseded_by_id` in v1. Same-source replacement covers content
  edits; cross-source factual supersedence ("we ship Q3" later corrected
  by a different source) is temporal-phase work, and adding a column
  later is a trivial migration.
- Episodes store `raw_text`, not extraction output, so replay
  (`mix super_brain.rebuild`) re-extracts via LLM; claims regenerate as
  a side effect of that existing mechanism. No snapshot format change.

## Extraction

One LLM call, same as today. The prompt
(`lib/magus/super_brain/extraction/prompt.ex`) changes:

- The `edges` output section is replaced by `claims`:

```json
{
  "entities": [ { "name": "...", "type": "...", "subtype": null, "confidence": 0.9 } ],
  "claims": [
    {
      "subject_name": "must match an entity name",
      "predicate": "one of: <canonical>, or free-form snake_case",
      "object_name": "must match an entity name",
      "polarity": "affirms | negates",
      "claim_text": "the sentence from the content that supports this claim (max 500 chars)",
      "confidence": 0.0,
      "valid_from": "ISO 8601 date or null, only when the text states it",
      "valid_to": "ISO 8601 date or null"
    }
  ]
}
```

- The edge-density quota (`prompt.ex:146`, "aim for roughly N/2 edges...
  emit with lower confidence rather than omitting") is DELETED and
  replaced by its inverse: every claim must be supported by a sentence in
  the content, quoted or minimally normalized into `claim_text`; prefer
  fewer, well-grounded claims; never manufacture relations to connect
  entities.
- The predicate-family guidance (temporal, identity, spatial, causal) is
  kept and now applies to claims.

`Extraction.Sanitizer` extends to claims:

- `subject_name` / `object_name` must match an extracted entity after
  normalization (downcase, trim, collapse whitespace); non-matching
  claims are dropped and counted (see Observability).
- `predicate` through the existing atom-safe `classify_predicate/1`
  path; `polarity` whitelisted to `affirms | negates`, default
  `affirms`; `claim_text` trimmed and capped at 500 chars, required;
  dates parsed as ISO 8601 with graceful nil; `confidence` clamped to
  [0, 1].
- Low-confidence claims are kept and tiered `:noise` (mirroring entity
  behavior), not dropped: retrieval already filters tiers.

`ExtractBase` persistence phase (inside the existing transaction):

1. Write entities and the Episode node as today.
2. Bulk-insert `Claim` rows (`Ash.bulk_create`, `authorize?: false`),
   with `trust_tier` computed per claim via
   `Ontology.compute_trust_tier(confidence, source: ontology_source)`.
3. Derive L1 `RELATES_TO` edge observations FROM claims: one edge per
   claim `(subject, predicate, object, confidence, trust_tier)`, written
   exactly where edges are written today (`extract_base.ex:757`). The
   builders, `EdgeAggregation`, and the whole L2 path are untouched;
   `predicate_breakdown` and `contested` now reflect claim-grounded
   predicates.
4. Embed claim texts via the configured batch extraction embedder
   (`:super_brain_extraction_embedder`, 1536-dim) and store on the rows.
   Embedding failure logs, leaves `embedding` null, and does not fail
   the extraction.

Each `Extract*` worker bumps its `extractor_version/0`
(`extract_base.ex:121`) so pre-claims and post-claims episodes are
distinguishable (this drives backfill detection).

Cost: call count unchanged (the `ExtractionBudget` model is call-based),
roughly 2x output tokens per extraction, plus one embedding per claim
through the existing batch path. All visible in `MessageUsage`.

## Retrieval

New `Magus.SuperBrain.Retrieval.search_claims/2`:

- Options: `:query_embedding` (required), `:workspace_context`,
  `:trust_tiers` (default `[:instruction, :evidence]`), `:limit`
  (default 10, aligned with the context block's total claim cap),
  `:accessible_graphs` (optional precomputed allow-list).
- Implementation: a raw-SQL KNN helper (`top_claim_ids`) using a Pgvector
  binary parameter, mirroring `Magus.Files.Chunk.top_chunk_ids`
  (`chunk.ex:50` documents why: AshPostgres inlines 1536-dim vectors
  into the SQL string and OOMs Postgres on the naive sort path), filtered
  by `graph_name = ANY(accessible)` and tier, then an Ash read of the
  winning rows with episode loaded for provenance.
- Ranking: `cosine_similarity x trust_tier_multiplier`, `asserted_at`
  descending as tie-break. Temporal RANKING is deferred; the fields are
  data only.
- `Retrieval.search/2` (entity path) also accepts `:accessible_graphs`
  so the per-turn caller computes `AccessibleGraphs.for_actor/2` once
  and shares it between both searches and the drift check.
- Respects the `Magus.SuperBrain.enabled?()` kill switch exactly like
  `search/2`.
- Claim recall is independent of super-graph state: it works identically
  during cold start and read-set drift (when the entity path falls back
  to the L1 fan-out), so new users get claim recall from their first
  extraction.

## Context render

`SuperBrainRagContext` calls `Retrieval.search/2` and
`Retrieval.search_claims/2` with the one shared query embedding, then
renders claims grouped under subject entities:

```
<super_brain>
Distilled knowledge from your sources relevant to this query (each line cites its source):

## Project Aurora [project]
- "Daniel decided Aurora ships without the npm wrapper." (page "Distribution" in brain "Magus", 2026-06-12)
- CONFLICT: "Aurora targets Q3." vs "Aurora moved to Q4." (draft "Planning" / page "Roadmap")

## Daniel [person] (no claims yet; seen in: memories:user, brain "Magus")

To read a source: brain page -> read_brain.read_page (page_id), draft -> read_draft (draft_id)
</super_brain>
```

Rules:

- Grouping: retrieved entities (existing KNN) provide headers; retrieved
  claims nest under their subject's header when it is present, otherwise
  claims introduce their own header from their subject fields.
- Conflict marker: claims sharing `(subject_key, predicate, object_key)`
  with opposite polarity render as one CONFLICT line showing both texts.
- Budget: per-entity claim cap 3, total claim cap 10, and a hard
  character ceiling on the whole block; overflow collapses to the
  existing `+N more` style.
- Degradation: an entity with no claims renders exactly today's
  name + refs line (including the Phase 1 contested-relation lines,
  which are kept only for this claim-less fallback). Source titles reuse
  the existing batched resolution (`super_brain_rag_context.ex:154`),
  now keyed off claim episodes as well.

## Dossier tool

`get_dossier` (Jido tool, `lib/magus/super_brain/tools/get_dossier.ex`,
registered in `ToolBuilder.main_tools` and `sub_agent_tools` next to
`super_brain_search`):

- Params: `entity_name` (required), `entity_type` (optional
  disambiguator), `limit` (optional, groups cap).
- Core logic in a pure `Magus.SuperBrain.Dossier` module (no I/O,
  unit-tested): given the entity's claims (as subject and as object),
  group by `(predicate, other_endpoint_key, polarity)`; per group emit
  distinct claim texts (capped), evidence count, max trust tier, source
  refs, and the `asserted_at` range; split "facts about X" (subject)
  from "X referenced by" (object); a conflicts section lists
  opposite-polarity groups on the same triple plus
  `Ontology.contradicting_predicates/0` pairs across groups; groups
  order by latest `asserted_at` so current knowledge leads.
- The tool wrapper normalizes the name to a key, fetches accessible
  claims (subject_key or object_key match, `graph_name` allow-list,
  row cap ~500), resolves source titles, and formats.
- Zero-claims fallback: return the L2 entity view instead (canonical
  types, neighbors, sources via the existing `Retrieval` enrichment) so
  the tool is useful before any backfill.
- `display_name/0` and `summarize_output/1` per tool conventions.

Tool description pass (rides along, descriptions only):

- `get_dossier`: "Everything known about one entity across all sources:
  grouped facts with citations, conflicts flagged, newest first."
- `super_brain_search`: gains top claims per entity in its output and a
  rewritten description ("distilled cross-source facts with citations").
- `search_files` / `search_memories`: one-line disambiguation each (raw
  document excerpts vs conversation memories), fixing the current
  near-synonym overlap.

## Backfill

`mix super_brain.backfill_claims --user <id> [--dry-run]`:

- Detection: latest `:extracted` episode per resource whose
  `extractor_version` differs from its worker's current
  `extractor_version/0` (workers bump their version when claims land, so
  a mismatch means pre-claims extraction; unrelated future bumps also
  qualifying is acceptable for an on-demand task).
- Enqueues the normal extraction workers with a new `force: true` job
  arg. `ExtractBase.gate_on_fingerprint/3` (`extract_base.ex:362`) skips
  unchanged content today; `force` bypasses the gate (both the pre-LLM
  check and the in-transaction recheck), so unchanged content re-extracts
  exactly once through the normal supersede path. Nothing else sets
  `force`, preserving the forward-only decision.
- Budget-gated and advisory-locked like any extraction. `--dry-run`
  prints the resource count per graph without enqueueing.

## Eval extension

Builds on the Phase 1 framework and therefore depends on PR magus#2
landing first.

- `Magus.Eval.SuperBrain.Metrics` gains a claim matcher: expected sets of
  normalized `(subject, predicate, object)` triples scored with the same
  recall@k / hit@k / mrr machinery. Case meta gains
  `"target": "entities" | "claims"` to select the matcher.
- `Magus.Eval.SuperBrain.Fixture` gains a `claims` section. Because
  pgvector columns are fixed at 1536 dims, authored claim vectors use a
  compact basis form (`{"hot": 0}` expands to a 1536-dim one-hot vector);
  entity fixtures stay dim-8 FalkorDB vectors as in Phase 1. Cases that
  exercise the claim path author a second query embedding
  (`claim_query_embedding`, basis form) alongside the dim-8
  `query_embedding`; the deterministic subject routes each to its path.
- `Subject.SuperBrainDeterministic`: `ingest/2` additionally inserts
  `Claim` rows (basis-expanded embeddings) tied to a seeded episode;
  `query/2` also calls `search_claims/2` and returns retrieved triples in
  the result meta.
- `Subject.SuperBrainLive`: seeds claims with REAL embeddings via
  `Magus.Files.EmbeddingModel` (the Phase 1 pattern) and exercises the
  real pgvector path.
- New cases:
  - `claim_recall` (supported, both subjects): the query embedding sits
    near a claim text embedding and near no entity name; recall proves
    the fact-text substrate.
  - `temporal` (xfail, `supported: false`, deterministic): two claims on
    the same triple; gold is the currently-valid one; the stale claim is
    embedding-closer and outranks it under similarity-only ranking. Flips
    when temporal ranking lands (this satisfies the Phase 1 promotion
    criterion for encoding the temporal gap).
  - `alias_resolution` remains NOT encoded (needs the identity phase).
- The deterministic regression test extends its assertions: supported
  aggregate stays 1.0 including claim cases; the temporal xfail must
  fail.

Dossier grouping and polarity-conflict logic are pure functions and are
covered by unit tests, not eval cases; the eval stays retrieval-focused.

## Observability

- Extraction telemetry gains `claims_emitted` and `claims_dropped`
  counts in the existing `[:super_brain, :extract]` span metadata, so
  sanitizer strictness (endpoint-match drops) is visible from day one.
- No `GraphMetrics` changes: the graph shape is unchanged. Existing
  Phase 1 metrics (`relates_to_fallback_rate`, `contested_edge_count`)
  become the before/after gauges for quota removal and claim-grounded
  predicates.

## Testing strategy

- `Claim` resource: create/bulk-create, supersede-deletion, allow-list
  reads (unit + integration with seeded episodes).
- Sanitizer claims: endpoint matching, polarity default, text cap, date
  parsing, drop counting (pure unit tests).
- Prompt: schema snapshot test asserting the claims section and the
  absence of the density quota.
- `ExtractBase`: integration test (mock LLM emitting claims) asserting
  claim rows, derived L1 edges, supersede-deletes, telemetry counts.
  Scope assertions to seeded rows (the shared test DB carries leaked
  committed rows; never assert global counts).
- `search_claims/2`: seeded pgvector recall, tier filtering, allow-list
  isolation (user A cannot retrieve user B's claims).
- Context render: claim lines with citations, CONFLICT line, caps, and
  the claim-less fallback (extend the existing
  `super_brain_rag_context` test).
- Dossier: pure module unit tests (grouping, conflicts, ordering) plus a
  tool integration test with the zero-claims fallback.
- Backfill task: detection predicate + force-gate bypass (integration,
  `--dry-run` covered).
- Eval: deterministic regression in normal `mix test` (dry_run: true),
  live `:e2e_live` extension.
- `MIX_ENV=test mix compile --warnings-as-errors` before push.

## Risks and mitigations

- **Claim quality** (paraphrase drift, hallucinated support): the prompt
  demands textual support with the existing confidence floor; the
  sanitizer caps and endpoint-matches; `claims_dropped` makes silent
  loss visible; the live eval catches recall rot.
- **Sanitizer strictness** dropping validly-worded claims: normalized
  comparison (downcase/trim/collapse) before matching; drops are counted,
  not silent.
- **Cost growth**: same call count; ~2x output tokens; one embedding per
  claim; all in `MessageUsage`. The budget ceiling is call-based and
  unchanged.
- **Context block growth**: hard caps (3 per entity, 10 total, char
  ceiling) keep the per-turn footprint near today's.
- **pgvector at scale**: claims per episode are bounded (typically 5 to
  20), supersede deletes keep the table proportional to live content,
  and the index mirrors the proven `file_chunks` settings.
- **Blast radius**: builders, FalkorDB schema, and the entity retrieval
  path are untouched; the Phase 1 deterministic eval keeps guarding
  entity retrieval at 1.0; the full feature suite is the regression net.

## Dependencies and sequencing

- **PR magus#2 (Phase 1) must land on main first**: this phase extends
  the eval modules (`Metrics`, `Fixture`, subjects, cases.json) and
  relies on `EdgeAggregation` being in lib. Recommendation: merge PR #2
  (already reviewed as ready), then branch Claims v1 from main.

## Build sequence (for the implementation plan)

1. `Claim` resource + migration (mirror `file_chunks` vector index) +
   resource unit tests.
2. Prompt v2 (claims section, quota removed) + sanitizer claims + unit
   tests.
3. `ExtractBase` wiring: claim persistence, claims-derived L1 edges,
   supersede-deletes, telemetry counts, worker `extractor_version`
   bumps + integration tests.
4. `Retrieval.search_claims/2` (raw-SQL KNN + Ash read) +
   `:accessible_graphs` sharing + tests.
5. Context block rewrite + tests.
6. `Magus.SuperBrain.Dossier` (pure) + `get_dossier` tool + ToolBuilder
   registration + tests.
7. `super_brain_search` claim output + tool description pass
   (`super_brain_search`, `search_files`, `search_memories`).
8. `mix super_brain.backfill_claims` + `force` gate arg + tests.
9. Eval: Metrics claim matcher, Fixture claims + basis vectors + dual
   query embeddings, deterministic subject, `claim_recall` cases,
   `temporal` xfail, regression test update.
10. Live subject claims + `:e2e_live` extension.
11. `docs/system/15-super-brain.md` update (claims layer, new tool,
    backfill task).
