defmodule Magus.SuperBrain.Migration do
  @moduledoc """
  Schema-version constants for the Super Brain graph layers.

  Graph identity changes (stable_id formulas, CanonicalId hashes,
  property shapes that downstream code reads back) are not Postgres
  migrations: they touch FalkorDB nodes that have no schema enforcement
  and no `mix ash.migrate` to bring them up to date. We track the
  expected version of each layer here, stamp every node write with the
  current version as a `migration_marker` property, and let
  `Magus.SuperBrain.Workers.MigrationSweeper` rebuild graphs whose
  markers fall behind.

  ## When to bump

  Bump the appropriate version in the same PR that introduces the
  graph-identity change. The MigrationSweeper detects the mismatch on
  the next tick (default cron: every 10 minutes) and enqueues
  `BuildSuperFull` for accessors whose Layer 2 graph still carries the
  old marker.

  | Layer | Bump when |
  |-------|-----------|
  | `entity_version/0` | Layer 1 `Entity` identity or required-property shape changes. Examples: `ExtractBase.stable_id/3` formula change, new required Entity property the canonicalize step reads. Layer 1 rebuild is heavy (re-runs LLM extraction) and is NOT auto-triggered: the sweeper records staleness for observability only; operator runs `mix super_brain.rebuild` (or content edits trigger natural re-extraction). |
  | `canonical_version/0` | Layer 2 `CanonicalEntity` aggregation changes. Examples: `CanonicalId` formula change, importance scoring formula change, cluster boundary change. The sweeper auto-rebuilds Layer 2 (cheap relative to Layer 1: replays existing extractions through the canonicalize+cluster step, no LLM calls). |

  ## Cross-layer ordering

  When a migration touches BOTH layers, the sweeper does NOT enforce
  Layer 1 finish-before-Layer 2 ordering: it reads the live Layer 1
  state at the moment `BuildSuperFull` runs. For iter5 this is safe
  because the Layer 1 change is additive (new `stable_id` shape
  produces distinct ids; `BuildSuperFull` reads all `:Entity` nodes
  regardless of id format). A future migration where Layer 2 must NOT
  read pre-migration Layer 1 entities needs explicit ordering: gate the
  `canonical_version/0` bump on a separate deploy AFTER the Layer 1
  rebuild has converged, or extend the sweeper to check read-set
  markers before enqueueing `BuildSuperFull`.

  ## Lifecycle

  After all graphs in production carry the current marker, the sweeper
  is a no-op (one cheap `MATCH (c:CanonicalEntity) WHERE ... RETURN
  count(c)` per accessor per tick). It stays running for the next
  migration.

  ## Iter history

    * iter5 (this iter): introduces the marker mechanism; both versions
      start at `1`. The transition from pre-iter5 graphs (no marker
      property) is the first migration the sweeper executes after
      deploy. CanonicalId hash and Layer 1 stable_id both changed in
      iter5; iter5 plan and the in-PR commit are the audit trail for
      what `1` represents.
  """

  @doc "Current Layer 1 (`:Entity`) marker. Bump when Entity identity or required property shape changes."
  def entity_version, do: 1

  @doc "Current Layer 2 (`:CanonicalEntity`) marker. Bump when CanonicalEntity aggregation formula changes."
  def canonical_version, do: 1
end
