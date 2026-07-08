# Super Brain Phase 3: Temporal ranking (supersedence, validity, recency)

Date: 2026-07-04
Status: Approved (design)
Scope: Third slice of the "super graph" upgrade roadmap. Makes claim
retrieval time-aware: the latest claim on a functional attribute wins
(supersedence), expired claims drop out (validity windows), and recency
gently breaks ties. Answers "what is the latest on X" and preserves the
history.

## Context

Phase 2 (Claims v1, merged) made claims the first-class knowledge unit and
deliberately stored `asserted_at`, `valid_from`, and `valid_to` "for the
temporal phase," but the retrieval ranker never uses them: `retrieval.ex`
still stubs `latest_evidence_at: DateTime.utc_now()` with the comment
"temporal recency is deferred," and `search_claims/2` returns claims in raw
pgvector KNN order (trust tier only filters inclusion in
`Claim.top_ids_by_embedding`; nothing rescores). So two claims that state
different values
for the same fact ("Aurora ships Q3", later "Aurora ships Q4") both surface,
ranked only by text similarity to the query, with no notion that the second
supersedes the first.

The Claims v1 eval encodes this exactly: the `temporal` case is a known-gap
xfail where the query embedding sits nearest the STALE claim (Q3) while the
gold answer is the current claim (Q4). It fails today by construction and is
the ready-made success signal for this phase.

The roadmap originally named identity resolution as Phase 3, but that was
reconsidered: its sizing metric (`ambiguous_bucket_count`) needs real graph
data to be meaningful, and `super_brain_enabled` is `false` (no production
corpus), so identity resolution would be a large speculative build against
unmeasured need. Temporal ranking instead builds directly on fields Claims
v1 already stores, flips a measurable eval xfail, and is lower risk.

### Key insight: supersedence is accessor-relative

"Aurora ships Q4" in a user's personal draft supersedes "Aurora ships Q3" in
a shared brain FOR THAT USER, but a teammate who cannot read the draft should
still see Q3 as current. So "is this claim superseded" is not a global
property of the claim: it depends on which claims the reader can access. A
single global `superseded_by_id` column would be wrong in shared-workspace
cases, and per-accessor materialized supersedence would be as heavy as the L2
super graph. This drove the storage decision below.

## Decisions

1. **Approach A: query-time resolution.** Supersedence, validity, and
   recency are computed at query time from only the claims the accessor can
   see. No schema change, no `superseded_by_id`, no background pass. Correct
   per-accessor by construction. Materialized supersedence (approach B) stays
   available later as a pure performance optimization if telemetry shows query
   cost.
2. **Full temporal scope:** supersedence + validity windows + recency, not a
   subset. Supersedence is the piece that flips the xfail and delivers
   current-state retrieval.
3. **A pure `Magus.SuperBrain.Temporal` module** holds the logic (functions
   over a claim list, `now` injected), mirroring the `EdgeAggregation` /
   `Dossier` purity pattern. Retrieval, context, and dossier consume it.

## Goals

- `search_claims` returns current claims, ranked with recency; superseded and
  expired claims are excluded from the default result but fetchable for
  history.
- The `<super_brain>` context block shows current facts and collapses a
  superseded fact to a compact trailer (`Aurora ships Q4 (was: Q3)`).
- `get_dossier` shows the current value per group plus a short history trail.
- The `temporal` eval xfail flips to a supported, passing case.
- New eval cases cover expired-validity, multi-valued non-supersedence, and
  accessor-relativity.

## Non-goals (this phase)

Materialized supersedence / a `superseded_by_id` column (deferred; approach B
stays a pure perf option). Identity resolution / alias fusion. The
contradiction inbox / proactive surfacing. `updates`-predicate-driven or
source-derived `asserted_at` refinement (the episode `extracted_at` proxy is
kept). Any UI beyond the context-block and dossier text. Temporal logic on
the entity super-graph path (`score_canonicals`); temporal lives on the claim
layer.

## Success criteria

- `mix test` deterministic eval: the `temporal` case is `supported: true` and
  passes at recall 1.0 (current-state retrieval returns Q4 for a query nearest
  the stale Q3).
- New deterministic cases pass: expired claim excluded from current; a
  multi-valued predicate is not superseded (both objects current); a
  superseding claim in an inaccessible graph does not supersede for the other
  accessor.
- The live `:e2e_live` eval adds one real-embedding temporal case that passes.
- `Temporal` has pure unit tests for each rule.
- Full `test/magus/super_brain/` suite stays green; no schema migration.

## Architecture

### The pure module: `Magus.SuperBrain.Temporal`

```
Temporal.resolve(claims :: [Claim.t()], now: DateTime.t()) ::
  %{current: [%{claim: Claim.t(), score_factors: %{recency: float}}],
    historic: [%{claim: Claim.t(), reason: :superseded | :expired | :future}]}
```

Pure: `now` is injected (never `DateTime.utc_now()` inside the module) so the
eval can pin time and the functions stay deterministic. Input is a set of
accessible claims (the caller has already applied the graph allow-list). The
module never does I/O.

Resolution order:

1. **Validity partition.** A claim is `:expired` when `valid_to != nil and
   DateTime.compare(valid_to, now) == :lt`; `:future` when `valid_from != nil
   and DateTime.compare(valid_from, now) == :gt`; otherwise in-window. (All
   DateTime ordering in the module goes through `DateTime.compare/2` or
   sorters given the `DateTime` module, never bare `<` / `>`, which compare
   struct terms.) Expired and future claims go straight to `historic` with
   their reason. `valid_from` / `valid_to` are nullable; a claim with neither
   is always in-window.
2. **Supersedence** over the in-window claims (see rules below): the winner of
   each group is `current`, the losers go to `historic` with reason
   `:superseded`.
3. **Recency scoring** on the `current` claims (see below).

### Supersedence rules

Claim B supersedes claim A (both in-window, both accessible) when either:

- **Value-change (functional predicates):** `A.subject_key == B.subject_key`
  AND `A.predicate == B.predicate` AND
  `Ontology.single_valued_predicate?(B.predicate)` AND both claims have
  `:affirms` polarity AND B is newer. "Newer" is `asserted_at` descending
  (nil sorts oldest; every write path stamps it, but the pure module stays
  total), tie-broken by `valid_from` (nil sorts oldest) then `id` descending
  (arbitrary but pins a deterministic total order). This covers both a
  changed object (Q3 -> Q4) and a re-assertion of the same object. It is the
  rule the `temporal` xfail exercises. The `:affirms`-only restriction is
  load-bearing: a newer "Aurora does NOT ship in Q3" (`:negates`, the only
  other value `Claim.polarity` allows) must not supersede "Aurora ships in
  Q4"; a negation makes no positive value claim, so it participates only in
  polarity-flip on its exact triple, and it can itself only be superseded
  the same way (a newer `:affirms` on that triple).
- **Polarity flip (any predicate):** `A.subject_key == B.subject_key` AND
  `A.predicate == B.predicate` AND `A.object_key == B.object_key` AND
  `A.polarity != B.polarity` AND B is newer. A direct affirm-then-negate on
  the exact same triple is an unambiguous supersedence regardless of
  predicate.

Grouping keys:
- Value-change groups by `(subject_key, predicate)`.
- Polarity-flip groups by `(subject_key, predicate, object_key)`.

A claim not matching either rule against any newer sibling stays `current`.
Multi-valued facts (e.g. `relates_to`, `mentions`) never supersede by value;
their objects all stay current and are ordered by recency only.

`Ontology.single_valued_predicates/0` is a new curated set, seeded with
`occurs_at` (an event or deadline has one time), consumed through
`Ontology.single_valued_predicate?/1`. The membership check must live behind
that function because of a type seam: `Claim.predicate` is a string column
while the existing ontology predicate lists are atoms (`~w(...)a`), so a raw
`predicate in atom_set` test would silently never match; the helper accepts
binary or atom and compares in string space. The set is intentionally small
and conservative: expanding it is an eval-tuned knob, and a wrong inclusion
would suppress legitimately-coexisting facts, so predicates are added only
with a supporting eval case. Everything not in the set is multi-valued.

### Recency

Among `current` claims, a gentle exponential decay on `asserted_at` revives
the decay the legacy fan-out ranker intended (`Retrieval.Ranker`, 90-day
half-life) but the claim path never had:

```
recency_factor = 0.5 + 0.5 * :math.exp(-age_days * ln(2) / 90)
```

Age is `max(0, DateTime.diff(now, asserted_at)) / 86_400` (fractional days);
a nil `asserted_at` takes the floor factor 0.5. The factor lives in `[0.5, 1.0]`: a nudge, not a cliff, so
a slightly older but strongly-matching claim still beats a fresh weak one.
`asserted_at` is the extraction-time stamp Claims v1 writes
(`DateTime.utc_now()` at claim write inside the extraction, a proxy for when
the statement was made); this phase keeps that proxy and documents it as the
ordering signal.

### The claim score

Today the claim path has no explicit score: `search_claims` returns claims in
pgvector KNN order, and trust tier only gates inclusion. (The
`vector_similarity x trust_tier_multiplier x ...` product exists only on the
entity path, `score_canonicals`, which is out of scope.) This phase
introduces an explicit per-claim score, used for ordering only, not exposed
in the return:

```
score = vector_similarity x trust_tier_multiplier x recency_factor
```

Mechanics this implies:

- `Claim.top_ids_by_embedding` (or a sibling query) returns
  `(id, similarity)` pairs instead of bare ids; similarity is
  `1 - cosine_distance`, clamped to `[0, 1]`.
- The group-completion read computes the same similarity expression for its
  rows in the same query, so completions are scoreable even though they never
  went through the KNN.
- A claim with a nil embedding scores similarity 0.0, and the completion read
  must NOT filter out nil embeddings (the KNN does): a nil-embedding
  superseder still supersedes and still appears in `current`, just ranked
  last.
- Trust tier becomes a rank multiplier in addition to the existing inclusion
  filter (`Ontology.trust_tier_multiplier/1`: instruction 1.5, evidence 1.0),
  mirroring the entity path.

Superseded and expired claims are excluded from the ranked `current` result
(not merely down-weighted), so they can never crowd out a current fact, and
are returned separately only when history is requested.

## Retrieval integration: the recall fix

The pgvector KNN can return a stale claim without its superseder (the fresh
claim is orthogonal to a query that matches the stale one, exactly the
`temporal` xfail geometry). So `search_claims/2` resolves current-state in two
steps:

1. **Candidates:** the existing pgvector KNN over accessible claims
   (`Claim.top_ids_by_embedding` + `load_claims_in_order`), same filters and
   order, now also surfacing each hit's similarity (see The claim score).
2. **Group completion:** collect the `(subject_key, predicate)` pairs (and the
   `(subject_key, predicate, object_key)` triples for polarity) among the
   candidates, then one batched read of ALL accessible claims in those groups
   (`graph_name in ^accessible AND subject_key in ^keys AND predicate in
   ^preds`, loaded with `:episode`). This surfaces the superseders the KNN
   missed. It is one extra query per retrieval, batched, and scoped to the
   same accessor allow-list, so it cannot leak. The `subject_key in ... AND
   predicate in ...` form over-fetches the cross product when candidates have
   heterogeneous subjects and predicates; after resolution, drop any claim
   that was not a candidate and does not share an exact group with one, so
   completion can promote a superseder but never introduce an unrelated group
   into the ranked result.

The completion read re-fetches the candidates themselves (every candidate
sits in its own group), so the two lists are deduplicated by id before
resolution, keeping the candidate entry:
`Enum.uniq_by(candidates ++ completions, & &1.id)`. Then
`Temporal.resolve(deduped, now: now)` yields `current` / `historic`;
`search_claims` returns `current` ranked by score.

`search_claims/2` gains an option `include_historic: false` (default). The
return shapes are exact:

- Default: `{:ok, [Claim.t()]}`, the ranked `current` claims. This is the
  same plain list the existing callers pattern-match today
  (`tools/search.ex`, the context builder pre-change), so they keep working
  unchanged.
- `include_historic: true` (the context builder passes this to render
  superseded trailers):
  `{:ok, %{current: [Claim.t()], historic: [%{claim: Claim.t(), reason:
  :superseded | :expired | :future}]}}`, `current` ranked identically to the
  default shape.

The kill switch, tier filter, and accessible-graph allow-list are unchanged.
The dossier does not go through `search_claims` at all (see Surfacing).

## Surfacing

- **`<super_brain>` context block** (`super_brain_rag_context.ex`): renders
  `current` claims as today. For a fact whose group has a superseded prior,
  append a compact trailer built from the historic claim's object:
  `- "Aurora ships in Q4." (page ..., 2026-06-12) (was: Q3)`. Expired claims
  are omitted from the block. This stays within the existing per-entity and
  per-message caps. Trailers render only for single-valued predicates,
  because on multi-valued predicates the only superseded entries are
  polarity flips on one exact triple, and a group-level trailer would
  assert false history for sibling objects.
- **`get_dossier`** (`dossier.ex` + `get_dossier.ex`): each group shows the
  current value plus a short history trail, e.g. `occurs_at Q4 (current);
  history: Q3 [superseded]`. Expired facts are labeled `[expired]`. The tool
  does not use `search_claims`: it already fetches every claim for the entity
  key via the `:for_entity_keys` read, which is history-complete by
  construction. So `get_dossier` only threads `now` in and runs
  `Temporal.resolve` over the raw claim structs (before mapping to the
  reduced dossier-claim shape); the pure `Dossier` module gains the
  current-vs-historic split in its output.

## Eval

Builds on the Claims v1 eval framework.

- **Flip the `temporal` xfail** in `priv/eval/super_brain_retrieval/cases.json`
  from `supported: false` to `supported: true`. The fixture is unchanged
  (Aurora `occurs_at` Q3 asserted earlier, Q4 asserted later, query nearest
  Q3, `k: 1`); it now passes because `occurs_at` is single-valued and Q4
  supersedes Q3, so current-state retrieval returns Q4. This is the conscious
  promotion the Phase 1 eval was built to force.
- **New supported deterministic cases** (both subjects unless noted):
  - `temporal_expired`: a claim with `valid_to` in the past is excluded from
    current; the in-window claim is returned.
  - `temporal_multivalued`: two `relates_to` claims (multi-valued) with
    different objects are BOTH current (no false supersedence).
  - `temporal_accessor` (deterministic only): a superseding claim seeded in a
    graph NOT in the accessor's allow-list does not supersede the older
    accessible claim, so the older one stays current. This pins the
    accessor-relativity property that justified approach A.
- The deterministic subject seeds these with authored `asserted_at` /
  `valid_from` / `valid_to` and passes a fixed `now` through to
  `Temporal.resolve`. The eval `Fixture` claim entries gain `asserted_at` /
  `valid_from` / `valid_to` (the subject today stamps `DateTime.utc_now()`
  and the parser drops the authored values) plus an optional `graph`
  discriminator, defaulting to the accessor's `memories:user:<id>`:
  `temporal_accessor` needs it to seed the superseder in a graph outside the
  allow-list, which the current `seed_claims` (one hardcoded graph) cannot
  express. Off-graph claims keep `source_user_id` = the fixture user and get
  their own episode in that graph, so the subject's `reset/1` sweep (which
  deletes by `source_user_id`) still cleans them up. The case gains a `now`
  field; the benchmark forwards it into the subject ctx.
- The live subject adds one real-embedding temporal case behind `:e2e_live`.
- `Temporal` gets direct pure unit tests (each supersedence rule, validity
  partition, recency monotonicity, tie-breaking, empty input).

### Deterministic `now` threading

The deterministic eval must pin `now` so recency and validity are
reproducible. `now` rides in the case (a fixed ISO timestamp), the benchmark
forwards it into the subject `ctx`, and the subject passes it to
`search_claims` (which passes it to `Temporal.resolve`). `search_claims` gains
an optional `:now` (default `DateTime.utc_now()` in production, pinned in the
eval). This keeps production behavior unchanged while making the eval
deterministic, and keeps `Temporal` pure.

## Testing strategy

- `Magus.SuperBrain.Temporal`: pure unit tests for validity partition,
  value-change supersedence (single-valued only), polarity-flip supersedence,
  recency decay bounds and monotonicity, tie-breaking, and the
  current/historic split.
- `search_claims/2`: the two-step group-completion fetch returns the
  superseder even when the KNN did not; accessor allow-list still isolates;
  `include_historic` toggles the historic payload. FK-safe seeding (real user
  + episode, per the Claims v1 conventions).
- Context block: superseded trailer renders, expired omitted, caps hold.
- Dossier: current-vs-historic split and the history trail render.
- Eval: the flipped `temporal` case plus the three new cases pass
  deterministically; the regression test asserts the supported aggregate
  stays 1.0 with `temporal` now in the supported set. Live case behind
  `:e2e_live`.
- Full `test/magus/super_brain/` suite green; no migration.

## Risks and mitigations

- **Single-valued set is a correctness knob.** A wrong inclusion suppresses
  coexisting facts. Mitigation: seed with only `occurs_at`, require an eval
  case for each addition, and default everything else to multi-valued.
- **Group-completion query cost.** One extra batched read per retrieval on the
  per-turn hot path. Mitigation: it is a single read narrowed by the indexed
  `graph_name` and `subject_key` columns (predicate is filtered in-row, not
  indexed) and scoped to the retrieved groups; if telemetry shows cost,
  approach B (materialization) is the escalation, out of scope now.
- **`asserted_at` is a proxy** (stamped at extraction write time), so
  re-extraction of old content stamps it "now" and can reorder history.
  Mitigation: documented;
  source-derived timestamps are a later refinement; supersedence still
  prefers the most-recently-extracted statement, which is the correct default
  for "what does the system currently believe."
- **Accessor-relativity is the load-bearing property.** Mitigation: the
  `temporal_accessor` eval case pins it, and query-time resolution over the
  allow-list-filtered set makes it correct by construction.

## Build sequence (for the implementation plan)

1. `Ontology.single_valued_predicates/0` (seed `occurs_at`) +
   `Ontology.single_valued_predicate?/1` (binary or atom, string-space
   compare) + `Magus.SuperBrain.Temporal` pure module + unit tests.
2. `search_claims/2`: surface similarity from the KNN and completion queries
   (the explicit claim score), two-step group-completion fetch,
   `Temporal.resolve` integration, `:now` and `:include_historic` options +
   tests.
3. Context block superseded-trailer + expired omission + tests.
4. `Dossier` current-vs-historic split + `get_dossier` history trail + tests.
5. Eval: `Fixture` temporal fields + `now` threading; flip the `temporal`
   xfail; add `temporal_expired` / `temporal_multivalued` / `temporal_accessor`;
   deterministic subject seeds them; regression test update.
6. Live subject temporal case (`:e2e_live`).
7. Docs: update `docs/system/15-super-brain.md` (temporal ranking, the
   Temporal module, current-vs-historic surfacing).
