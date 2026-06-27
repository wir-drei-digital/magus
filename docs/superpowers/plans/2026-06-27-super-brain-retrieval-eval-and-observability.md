# Super Brain: Retrieval Eval + Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a deterministic + live retrieval eval in `Magus.Eval`, build-time graph metrics, contradiction-aware agent context, and doc-drift fixes, so later super-graph phases are measurable and safe.

**Architecture:** A new `super_brain_retrieval` benchmark plugs into the existing `Magus.Eval` (`Benchmark`/`Subject`/`Runner`/`Scoreboard`) contract. Two subjects materialize the same JSON case fixtures: a deterministic one that seeds the L2 super graph directly with authored vectors (offline, runs in `mix test`), and a live one that seeds L1 and runs the real `BuildSuperFull` with real embeddings (behind `:e2e_live`). Observability adds a pure `GraphMetrics` module persisted to a new `SuperGraph.metrics` column plus richer retrieval telemetry. A pure `EdgeAggregation` module is extracted from the builder so the deterministic subject and the builder agree on edge shape.

**Tech Stack:** Elixir, Ash 3.x + AshPostgres, FalkorDB (Redis-protocol graph DB via `Magus.Graph`), `:telemetry`, ExUnit.

## Global Constraints

- NEVER run `mix ash.reset` (wipes data). Generate migrations with `mix ash.codegen <name>`, apply with `mix ash.migrate`.
- CI compiles with `--warnings-as-errors`; before any commit of new Elixir run `MIX_ENV=test mix compile --warnings-as-errors`.
- No em dashes in any prose, comment, or doc. Use colons, periods, commas, parentheses.
- The deterministic eval and the context/retrieval tests require a running FalkorDB and Postgres (the existing `test/magus/super_brain/retrieval_test.exs` already does). Live tests run via `bin/test-e2e-live` and are tagged `:e2e_live`.
- Shared checkout: scope every commit with `git commit -- <paths>` (never a bare `git commit`). End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- FalkorDB returns numeric scalars and booleans as strings in verbose mode; decode with `Magus.SuperBrain.FalkorValues` helpers. Embedding dim for the live path is `Magus.SuperBrain.EmbeddingConfig.dim/0` (1536). The deterministic path uses an authored dim of 8.
- Ash writes in workers/tests use `authorize?: false` (existing pattern for this subsystem).

---

### Task 1: Doc and comment drift fixes

**Files:**
- Modify: `lib/magus/super_brain/workers/build_super_full.ex` (the `canonical_id_for/2` comment, around lines 595-606)
- Modify: `docs/system/15-super-brain.md` (entity-type / predicate counts and node/edge shape)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing (documentation only).

- [ ] **Step 1: Read the current comment block**

Run: `sed -n '593,618p' lib/magus/super_brain/workers/build_super_full.ex`
Expected: the comment beginning "Canonical id formula delegates to ..." containing the line "Name is intentionally NOT in the hash".

- [ ] **Step 2: Replace the inverted comment**

In `lib/magus/super_brain/workers/build_super_full.ex`, replace the `defp canonical_id_for/2` doc comment so it states the truth. Replace this text:

```
  # Canonical id formula delegates to `Magus.SuperBrain.CanonicalId.for/4`
  # so the BuildSuperFull and BuildSuperIncremental paths converge on the
  # SAME canonical id for the same `(super_graph, type, normalized_subtype)`
  # tuple. Name is intentionally NOT in the hash: a future name pick (e.g.
  # "Daniel" -> "Daniel Smith") for the same cluster MUST resolve to the
  # same canonical id so caches survive across rebuilds.
```

with:

```
  # Canonical id formula delegates to `Magus.SuperBrain.CanonicalId.for/4`
  # so the BuildSuperFull and BuildSuperIncremental paths converge on the
  # SAME canonical id for the same `(super_graph, type, normalized_subtype,
  # name_key)` tuple. The name IS folded into the hash (via
  # `CanonicalId.name_key/1`): distinct names get distinct canonicals, while
  # same-named instances across graphs fuse. Different-named aliases
  # ("Daniel" vs "Daniel Smith") therefore stay separate until a future
  # LLM-judge fusion pass.
```

- [ ] **Step 3: Read the doc section that lists counts**

Run: `grep -n "entity type\|predicate\|12\|8 " docs/system/15-super-brain.md | head -40`
Expected: lines stating "12 entity types" and "8 predicates" (and a node/edge description).

- [ ] **Step 4: Correct the doc**

In `docs/system/15-super-brain.md`, update the ontology counts to 17 entity types and 18 predicates (matching `Magus.SuperBrain.Ontology`), and update the L2 node/edge description to the current shape: `CanonicalEntity`, `SourcePointer`, `CanonicalEntity -[:APPEARS_IN]-> SourcePointer`, and `CanonicalEntity -[:RELATES_TO {predicate, confidence, trust_tier, contested, predicate_breakdown, appearance_count, source_graphs}]-> CanonicalEntity`. Keep the prose style and avoid em dashes.

- [ ] **Step 5: Verify compile**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: compiles with no warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/magus/super_brain/workers/build_super_full.ex docs/system/15-super-brain.md
git commit -- lib/magus/super_brain/workers/build_super_full.ex docs/system/15-super-brain.md \
  -m "docs(super-brain): fix inverted canonical-id comment + ontology counts" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Render contested/relation signal in agent context

**Files:**
- Modify: `lib/magus/agents/context/super_brain_rag_context.ex` (`format_super_entity/2` plus new private helpers)
- Test: `test/magus/agents/context/super_brain_rag_context_test.exs`

**Interfaces:**
- Consumes: each retrieval entity already carries `:neighbors` as a list of `%{id, name, predicate, confidence, contested, predicate_breakdown}` (built by `Retrieval.fetch_canonical_neighbors/2`). `predicate_breakdown` is a decoded map (`%{predicate => count}`).
- Produces: no new public API; `format/1` output gains an indented relation line per entity when neighbors exist.

- [ ] **Step 1: Write the failing test**

Add to `test/magus/agents/context/super_brain_rag_context_test.exs` inside a new describe block:

```elixir
  describe "format/1 relation signal" do
    test "renders a contested line with the predicate breakdown" do
      entities = [
        %{
          name: "Plan A",
          primary_type: "decision",
          normalized_subtype: nil,
          sources: [%{graph_name: "brain:abc", source_refs: []}],
          neighbors: [
            %{
              id: "n1",
              name: "Ship Friday",
              predicate: "supports",
              confidence: 0.9,
              contested: true,
              predicate_breakdown: %{"supports" => 2, "contradicts" => 1}
            }
          ]
        }
      ]

      out = SuperBrainRagContext.format(entities)
      assert out =~ "contested: Ship Friday"
      assert out =~ "supports 2"
      assert out =~ "contradicts 1"
    end

    test "caps relation lines and prefers contested over plain relations" do
      neighbors =
        for i <- 1..5 do
          %{
            id: "n#{i}",
            name: "Rel #{i}",
            predicate: "relates_to",
            confidence: 0.5,
            contested: false,
            predicate_breakdown: %{"relates_to" => 1}
          }
        end

      entities = [
        %{
          name: "Hub",
          primary_type: "concept",
          normalized_subtype: nil,
          sources: [%{graph_name: "brain:abc", source_refs: []}],
          neighbors: neighbors
        }
      ]

      out = SuperBrainRagContext.format(entities)
      # At most 2 relation lines (the budget cap).
      assert length(for line <- String.split(out, "\n"), String.contains?(line, "relates_to:"), do: line) <= 2
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/magus/agents/context/super_brain_rag_context_test.exs -v`
Expected: the two new tests FAIL (no contested line rendered).

- [ ] **Step 3: Implement the relation rendering**

In `lib/magus/agents/context/super_brain_rag_context.ex`, add a module attribute near the others:

```elixir
  # Cap relation lines per entity so the per-message block stays bounded.
  @max_relation_lines 2
```

Change `format_super_entity/2` to append a relations block. Replace the function body's final `case entity_refs(e) do ... end` expression so its result is bound and the relations block is concatenated:

```elixir
  defp format_super_entity(e, titles) do
    name = Map.get(e, :name) || "?"
    type = Map.get(e, :primary_type) || Map.get(e, :type) || "?"
    subtype = Map.get(e, :normalized_subtype) || Map.get(e, :subtype)
    subtype_str = if is_binary(subtype) and subtype != "", do: "/#{subtype}", else: ""

    base = "- #{name} [#{type}#{subtype_str}]"

    refs_part =
      case entity_refs(e) do
        [] ->
          sources_str = e |> Map.get(:sources, []) |> Enum.map_join(", ", &short_source/1)
          if sources_str == "", do: "", else: " (seen in: #{sources_str})"

        refs ->
          rendered = render_refs(refs, titles)
          "\n" <> Enum.map_join(rendered, "\n", &"    #{&1}")
      end

    base <> refs_part <> relations_part(e)
  end

  # Render the contradiction/relation signal `Retrieval` already attaches as
  # `:neighbors`. Contested edges are surfaced first (always), otherwise the
  # highest-confidence relations, capped at `@max_relation_lines`.
  defp relations_part(e) do
    neighbors = Map.get(e, :neighbors, [])
    contested = Enum.filter(neighbors, &(Map.get(&1, :contested) == true))

    lines =
      case contested do
        [] ->
          neighbors
          |> Enum.sort_by(&(Map.get(&1, :confidence) || 0.0), :desc)
          |> Enum.take(@max_relation_lines)
          |> Enum.map(&relation_line/1)

        list ->
          list
          |> Enum.take(@max_relation_lines)
          |> Enum.map(&contested_line/1)
      end

    case lines do
      [] -> ""
      ls -> "\n" <> Enum.map_join(ls, "\n", &"    #{&1}")
    end
  end

  defp contested_line(n) do
    breakdown =
      n
      |> Map.get(:predicate_breakdown, %{})
      |> Enum.map_join(" / ", fn {pred, count} -> "#{pred} #{count}" end)

    "contested: #{Map.get(n, :name) || "?"} (#{breakdown})"
  end

  defp relation_line(n) do
    "#{Map.get(n, :predicate) || "relates_to"}: #{Map.get(n, :name) || "?"}"
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/magus/agents/context/super_brain_rag_context_test.exs -v`
Expected: all tests PASS (including the pre-existing ones, which pass entities without `:neighbors` and therefore render no relation line).

- [ ] **Step 5: Verify compile**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/magus/agents/context/super_brain_rag_context.ex test/magus/agents/context/super_brain_rag_context_test.exs
git commit -- lib/magus/agents/context/super_brain_rag_context.ex test/magus/agents/context/super_brain_rag_context_test.exs \
  -m "feat(super-brain): surface contested relations in agent context" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Extract pure `EdgeAggregation` from the builder

**Files:**
- Create: `lib/magus/super_brain/edge_aggregation.ex`
- Modify: `lib/magus/super_brain/workers/build_super_full.ex` (`aggregate_relates_to/3`, `max_trust_tier/1`, delete private `contested?/1` and `@tier_order`)
- Test: `test/magus/super_brain/edge_aggregation_test.exs`

**Interfaces:**
- Produces:
  - `Magus.SuperBrain.EdgeAggregation.aggregate(observations) :: [aggregate]` where an observation is `%{from: term, to: term, predicate: String.t() | nil, confidence: number, trust_tier: String.t() | nil, source_graph: String.t()}` and an aggregate is `%{from, to, predicate: String.t(), confidence: float, trust_tier: String.t(), source_graphs: [String.t()], predicate_breakdown: %{String.t() => non_neg_integer}, contested: boolean, appearance_count: non_neg_integer}`.
  - `EdgeAggregation.max_trust_tier([String.t() | nil]) :: String.t()`
  - `EdgeAggregation.contested?(%{String.t() => non_neg_integer}) :: boolean`

- [ ] **Step 1: Write the failing test**

Create `test/magus/super_brain/edge_aggregation_test.exs`:

```elixir
defmodule Magus.SuperBrain.EdgeAggregationTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.EdgeAggregation

  defp obs(from, to, predicate, opts \\ []) do
    %{
      from: from,
      to: to,
      predicate: predicate,
      confidence: Keyword.get(opts, :confidence, 0.5),
      trust_tier: Keyword.get(opts, :trust_tier, "evidence"),
      source_graph: Keyword.get(opts, :source_graph, "brain:a")
    }
  end

  test "groups by (from, to) and picks the modal predicate" do
    edges = [
      obs("a", "b", "supports"),
      obs("a", "b", "supports", source_graph: "brain:b"),
      obs("a", "b", "mentions")
    ]

    assert [agg] = EdgeAggregation.aggregate(edges)
    assert agg.from == "a" and agg.to == "b"
    assert agg.predicate == "supports"
    assert agg.appearance_count == 3
    assert Enum.sort(agg.source_graphs) == ["brain:a", "brain:b"]
    assert agg.predicate_breakdown == %{"supports" => 2, "mentions" => 1}
    assert agg.contested == false
  end

  test "flags contested when opposing predicates co-occur" do
    edges = [obs("a", "b", "supports"), obs("a", "b", "contradicts")]
    assert [agg] = EdgeAggregation.aggregate(edges)
    assert agg.contested == true
  end

  test "max_trust_tier prefers instruction over evidence over noise" do
    assert EdgeAggregation.max_trust_tier(["evidence", "instruction", "noise"]) == "instruction"
    assert EdgeAggregation.max_trust_tier([nil, nil]) == "evidence"
  end

  test "max confidence wins" do
    edges = [obs("a", "b", "supports", confidence: 0.3), obs("a", "b", "supports", confidence: 0.9)]
    assert [agg] = EdgeAggregation.aggregate(edges)
    assert agg.confidence == 0.9
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/magus/super_brain/edge_aggregation_test.exs`
Expected: FAIL with "module Magus.SuperBrain.EdgeAggregation is not available".

- [ ] **Step 3: Implement the module**

Create `lib/magus/super_brain/edge_aggregation.ex`:

```elixir
defmodule Magus.SuperBrain.EdgeAggregation do
  @moduledoc """
  Pure aggregation of Layer 1 RELATES_TO observations into a single Layer 2
  edge per `(from, to)` pair.

  Extracted from `BuildSuperFull` so the builder and the deterministic eval
  subject derive the same edge shape (predicate, predicate_breakdown,
  contested, trust_tier) from the same input. No I/O lives here; callers
  perform the FalkorDB writes.
  """

  alias Magus.SuperBrain.FalkorValues
  alias Magus.SuperBrain.Ontology

  # Trust-tier precedence for picking the strongest tier across a group.
  @tier_order %{"instruction" => 3, "evidence" => 2, "noise" => 1}

  @type observation :: %{
          from: term(),
          to: term(),
          predicate: String.t() | nil,
          confidence: number(),
          trust_tier: String.t() | nil,
          source_graph: String.t()
        }

  @doc "Aggregate L1 observations into one map per `(from, to)` pair."
  @spec aggregate([observation()]) :: [map()]
  def aggregate(observations) when is_list(observations) do
    observations
    |> Enum.group_by(fn o -> {o.from, o.to} end)
    |> Enum.map(fn {{from, to}, group} ->
      breakdown =
        group |> Enum.map(& &1.predicate) |> Enum.reject(&is_nil/1) |> Enum.frequencies()

      %{
        from: from,
        to: to,
        predicate: FalkorValues.most_common(Enum.map(group, & &1.predicate)),
        confidence: group |> Enum.map(& &1.confidence) |> Enum.max(fn -> 0.0 end),
        trust_tier: max_trust_tier(Enum.map(group, & &1.trust_tier)),
        source_graphs: group |> Enum.map(& &1.source_graph) |> Enum.uniq(),
        predicate_breakdown: breakdown,
        contested: contested?(breakdown),
        appearance_count: length(group)
      }
    end)
  end

  @doc "Strongest trust tier in the list, defaulting to \"evidence\"."
  @spec max_trust_tier([String.t() | nil]) :: String.t()
  def max_trust_tier(tiers) do
    tiers
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "evidence"
      list -> Enum.max_by(list, fn t -> Map.get(@tier_order, t, 0) end)
    end
  end

  @doc """
  True when the predicate-frequency map contains both halves of any opposed
  pair in `Ontology.contradicting_predicates/0`.
  """
  @spec contested?(map()) :: boolean()
  def contested?(breakdown) when is_map(breakdown) do
    contradicting = Ontology.contradicting_predicates()
    keys = Map.keys(breakdown)

    Enum.any?(keys, fn pred ->
      opposite = Map.get(contradicting, pred)
      opposite != nil and opposite in keys
    end)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/magus/super_brain/edge_aggregation_test.exs`
Expected: PASS.

- [ ] **Step 5: Refactor `BuildSuperFull` to use it**

In `lib/magus/super_brain/workers/build_super_full.ex`:

1. Add `alias Magus.SuperBrain.EdgeAggregation` with the other aliases.
2. In `aggregate_relates_to/3`, keep everything up to and including the `edges` list construction (the `entity_to_canonical` map, the per-graph MATCH, and the two `Enum.reject` filters). Then replace the `edge_groups`/`writes` block (from `edge_groups = Enum.group_by(...)` through the end of the reduce) with:

```elixir
    aggregates =
      edges
      |> Enum.map(fn e ->
        %{
          from: e.from_canonical,
          to: e.to_canonical,
          predicate: e.predicate,
          confidence: e.confidence,
          trust_tier: e.trust_tier,
          source_graph: e.source_graph
        }
      end)
      |> EdgeAggregation.aggregate()

    writes =
      Enum.reduce(aggregates, empty_writes(), fn agg, w_acc ->
        edge_result =
          Magus.Graph.upsert_edge(
            super_graph,
            %{
              from_label: "CanonicalEntity",
              from_id: agg.from,
              to_label: "CanonicalEntity",
              to_id: agg.to
            },
            "RELATES_TO",
            %{
              predicate: agg.predicate,
              confidence: agg.confidence,
              trust_tier: agg.trust_tier,
              source_graphs: agg.source_graphs,
              extractor: @extractor_version,
              contested: agg.contested,
              predicate_breakdown: Jason.encode!(agg.predicate_breakdown),
              appearance_count: agg.appearance_count
            }
          )

        tally(w_acc, edge_result)
      end)

    %{edge_count: length(aggregates), writes: writes}
```

3. Delete the now-unused private `contested?/1` function.
4. Replace the private `max_trust_tier/1` body with a delegation: `defp max_trust_tier(cluster_tiers), do: EdgeAggregation.max_trust_tier(cluster_tiers)`. Find its caller in `write_canonical/3` (`max_tier = max_trust_tier(cluster)`) and change it to `max_tier = EdgeAggregation.max_trust_tier(Enum.map(cluster, & &1.trust_tier))`; then delete the private `max_trust_tier/1` entirely.
5. Delete the `@tier_order` module attribute if no remaining references exist (grep first).

Run: `grep -n "@tier_order\|max_trust_tier\|contested?" lib/magus/super_brain/workers/build_super_full.ex`
Expected: no remaining references after the edits (the only tier/contested logic now lives in `EdgeAggregation`).

- [ ] **Step 6: Run the builder tests + compile**

Run: `MIX_ENV=test mix compile --warnings-as-errors && mix test test/magus/super_brain/ -v`
Expected: existing `BuildSuperFull` and super-brain tests PASS (no behavior change), `edge_aggregation_test.exs` PASSES.

- [ ] **Step 7: Commit**

```bash
git add lib/magus/super_brain/edge_aggregation.ex test/magus/super_brain/edge_aggregation_test.exs lib/magus/super_brain/workers/build_super_full.ex
git commit -- lib/magus/super_brain/edge_aggregation.ex test/magus/super_brain/edge_aggregation_test.exs lib/magus/super_brain/workers/build_super_full.ex \
  -m "refactor(super-brain): extract pure EdgeAggregation from builder" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Add `SuperGraph.metrics` column

**Files:**
- Modify: `lib/magus/super_brain/super_graph.ex` (new attribute + extend `:mark_built`)
- Create: a migration via `mix ash.codegen`
- Test: `test/magus/super_brain/super_graph_metrics_test.exs`

**Interfaces:**
- Produces: `SuperGraph` gains attribute `metrics :map` (default `%{}`), and the `:mark_built` action accepts `:metrics`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/super_brain/super_graph_metrics_test.exs`:

```elixir
defmodule Magus.SuperBrain.SuperGraphMetricsTest do
  use Magus.ResourceCase, async: false

  alias Magus.SuperBrain.SuperGraph

  test "mark_built persists a metrics map" do
    user = generate(user())

    {:ok, row} =
      SuperGraph
      |> Ash.Changeset.for_create(:create, %{
        accessor_type: :user,
        user_id: user.id,
        workspace_id: nil,
        graph_name: "super:user:#{user.id}"
      })
      |> Ash.create(authorize?: false)

    {:ok, built} =
      row
      |> Ash.Changeset.for_update(:mark_built, %{
        read_set_snapshot: [],
        canonical_entity_count: 3,
        canonical_edge_count: 2,
        last_build_duration_ms: 5,
        metrics: %{"isolated_entity_rate" => 0.0, "contested_edge_count" => 1}
      })
      |> Ash.update(authorize?: false)

    assert built.metrics["contested_edge_count"] == 1
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/magus/super_brain/super_graph_metrics_test.exs`
Expected: FAIL (unknown input `:metrics` / no such attribute).

- [ ] **Step 3: Add the attribute and extend the action**

In `lib/magus/super_brain/super_graph.ex`:

1. In the `attributes do` block, after `canonical_edge_count`, add:

```elixir
    attribute :metrics, :map do
      default %{}
      allow_nil? false
      public? true
    end
```

2. In the `:mark_built` action, add `:metrics` to the `accept` list so it reads:

```elixir
    update :mark_built do
      accept [
        :read_set_snapshot,
        :canonical_entity_count,
        :canonical_edge_count,
        :last_build_duration_ms,
        :metrics
      ]
```

- [ ] **Step 4: Generate and apply the migration**

Run: `mix ash.codegen add_super_graph_metrics`
Expected: creates `priv/repo/migrations/*_add_super_graph_metrics.exs` adding a `:metrics` (`:map`) column with default `%{}`.

Run: `mix ash.migrate`
Expected: migration applies cleanly.

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/magus/super_brain/super_graph_metrics_test.exs`
Expected: PASS.

- [ ] **Step 6: Verify compile + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/super_brain/super_graph.ex priv/repo/migrations test/magus/super_brain/super_graph_metrics_test.exs
git commit -- lib/magus/super_brain/super_graph.ex test/magus/super_brain/super_graph_metrics_test.exs $(git diff --cached --name-only -- priv/repo/migrations) \
  -m "feat(super-brain): add SuperGraph.metrics column" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Pure `GraphMetrics` module

**Files:**
- Create: `lib/magus/super_brain/graph_metrics.ex`
- Test: `test/magus/super_brain/graph_metrics_test.exs`

**Interfaces:**
- Produces: `Magus.SuperBrain.GraphMetrics.compute(inputs) :: map` where `inputs` is `%{canonical_count, relates_to_count, isolated_count, relates_to_fallback_count, contested_count, buckets}` (`buckets` is a list of `%{distinct_name_count: non_neg_integer}`) and the result is a string-keyed metrics map.

- [ ] **Step 1: Write the failing test**

Create `test/magus/super_brain/graph_metrics_test.exs`:

```elixir
defmodule Magus.SuperBrain.GraphMetricsTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.GraphMetrics

  test "computes the metric set from raw inputs" do
    inputs = %{
      canonical_count: 10,
      relates_to_count: 8,
      isolated_count: 3,
      relates_to_fallback_count: 2,
      contested_count: 1,
      buckets: [
        %{distinct_name_count: 1},
        %{distinct_name_count: 3},
        %{distinct_name_count: 2}
      ]
    }

    m = GraphMetrics.compute(inputs)

    assert m["isolated_entity_rate"] == 0.3
    assert m["relates_to_fallback_rate"] == 0.25
    assert m["edges_per_entity"] == 0.8
    assert m["contested_edge_count"] == 1
    assert m["ambiguous_bucket_count"] == 2
  end

  test "is safe on an empty graph (no divide by zero)" do
    inputs = %{
      canonical_count: 0,
      relates_to_count: 0,
      isolated_count: 0,
      relates_to_fallback_count: 0,
      contested_count: 0,
      buckets: []
    }

    m = GraphMetrics.compute(inputs)
    assert m["isolated_entity_rate"] == 0.0
    assert m["relates_to_fallback_rate"] == 0.0
    assert m["edges_per_entity"] == 0.0
    assert m["ambiguous_bucket_count"] == 0
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/magus/super_brain/graph_metrics_test.exs`
Expected: FAIL ("module ... not available").

- [ ] **Step 3: Implement the module**

Create `lib/magus/super_brain/graph_metrics.ex`:

```elixir
defmodule Magus.SuperBrain.GraphMetrics do
  @moduledoc """
  Pure graph-shape metrics for a Layer 2 super graph, computed at build time
  and persisted to `SuperGraph.metrics`. No I/O: the caller gathers the raw
  counts (via FalkorDB Cypher) and passes them in.

  Metrics:

    * `isolated_entity_rate` - fraction of canonicals with NO `RELATES_TO`
      edge (APPEARS_IN is excluded; every canonical has at least one).
    * `relates_to_fallback_rate` - fraction of edges whose predicate is the
      generic `relates_to`.
    * `edges_per_entity` - `RELATES_TO` count divided by canonical count.
    * `contested_edge_count` - edges flagged `contested`.
    * `ambiguous_bucket_count` - `(type, normalized_subtype)` buckets holding
      more than one distinct name. A coarse upper bound on identity-resolution
      opportunity; intentionally noisy (phase 3 refines it with similarity).
  """

  @type inputs :: %{
          canonical_count: non_neg_integer(),
          relates_to_count: non_neg_integer(),
          isolated_count: non_neg_integer(),
          relates_to_fallback_count: non_neg_integer(),
          contested_count: non_neg_integer(),
          buckets: [%{distinct_name_count: non_neg_integer()}]
        }

  @spec compute(inputs()) :: %{String.t() => number()}
  def compute(inputs) do
    %{
      "isolated_entity_rate" => rate(inputs.isolated_count, inputs.canonical_count),
      "relates_to_fallback_rate" => rate(inputs.relates_to_fallback_count, inputs.relates_to_count),
      "edges_per_entity" => rate(inputs.relates_to_count, inputs.canonical_count),
      "contested_edge_count" => inputs.contested_count,
      "ambiguous_bucket_count" =>
        Enum.count(inputs.buckets, fn b -> b.distinct_name_count > 1 end)
    }
  end

  defp rate(_numerator, 0), do: 0.0
  defp rate(numerator, denominator), do: numerator / denominator
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/magus/super_brain/graph_metrics_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/super_brain/graph_metrics.ex test/magus/super_brain/graph_metrics_test.exs
git commit -- lib/magus/super_brain/graph_metrics.ex test/magus/super_brain/graph_metrics_test.exs \
  -m "feat(super-brain): pure GraphMetrics module" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Compute and persist metrics in `BuildSuperFull`

**Files:**
- Modify: `lib/magus/super_brain/workers/build_super_full.ex` (gather metrics on staging, thread into `mark_built`)
- Test: extend `test/magus/super_brain/build_super_full_*` coverage via a focused metrics assertion (new file `test/magus/super_brain/build_super_full_metrics_test.exs`)

**Interfaces:**
- Consumes: `GraphMetrics.compute/1`, `FalkorValues.parse_number/2`, the staging graph name, `SuperGraph` `:mark_built` now accepting `:metrics` (Task 4).
- Produces: after a successful build, `SuperGraph.metrics` holds the computed map.

- [ ] **Step 1: Write the failing test**

Create `test/magus/super_brain/build_super_full_metrics_test.exs`:

```elixir
defmodule Magus.SuperBrain.BuildSuperFullMetricsTest do
  use Magus.ResourceCase, async: false

  alias Magus.SuperBrain.SuperGraph
  alias Magus.SuperBrain.Workers.BuildSuperFull

  require Ash.Query

  test "build persists graph metrics on the SuperGraph row" do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    graph = "brain:#{brain.id}"
    super_graph = "super:user:#{user.id}"

    on_exit(fn ->
      Magus.Graph.drop(graph)
      Magus.Graph.drop(super_graph)
    end)

    # Seed two L1 entities with one RELATES_TO so metrics are non-trivial.
    Magus.Graph.upsert_node(graph, "Entity", %{
      id: "e1", name: "Daniel", type: "person",
      embedding: List.duplicate(0.0, 1536), confidence: 0.9, trust_tier: "evidence"
    })

    Magus.Graph.upsert_node(graph, "Entity", %{
      id: "e2", name: "Aurora", type: "project",
      embedding: List.duplicate(0.0, 1536), confidence: 0.9, trust_tier: "evidence"
    })

    Magus.Graph.upsert_edge(
      graph,
      %{from_label: "Entity", from_id: "e1", to_label: "Entity", to_id: "e2"},
      "RELATES_TO",
      %{predicate: "works_on", confidence: 0.8, trust_tier: "evidence"}
    )

    :ok =
      BuildSuperFull.perform(%Oban.Job{
        args: %{"accessor_type" => "user", "user_id" => user.id, "workspace_id" => nil}
      })

    row =
      SuperGraph
      |> Ash.Query.filter(graph_name == ^super_graph)
      |> Ash.read_one!(authorize?: false)

    assert is_map(row.metrics)
    assert Map.has_key?(row.metrics, "isolated_entity_rate")
    assert Map.has_key?(row.metrics, "edges_per_entity")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/magus/super_brain/build_super_full_metrics_test.exs`
Expected: FAIL (`row.metrics` is the default `%{}`, missing keys).

- [ ] **Step 3: Gather metrics against staging and persist them**

In `lib/magus/super_brain/workers/build_super_full.ex`:

1. Add `alias Magus.SuperBrain.GraphMetrics` with the other aliases.

2. Add a private function that gathers the inputs from the staging graph and computes the metrics:

```elixir
  # Gather graph-shape metrics from the staging graph. Numeric scalars come
  # back as strings in FalkorDB's verbose mode, so coerce via FalkorValues.
  defp compute_graph_metrics(super_graph) do
    counts =
      case Magus.Graph.query(super_graph, """
           MATCH (c:CanonicalEntity)
           OPTIONAL MATCH (c)-[r:RELATES_TO]->()
           WITH count(DISTINCT c) AS canonicals,
                count(r) AS edges,
                sum(CASE WHEN r.predicate = 'relates_to' THEN 1 ELSE 0 END) AS fallback,
                sum(CASE WHEN r.contested = true THEN 1 ELSE 0 END) AS contested
           RETURN canonicals, edges, fallback, contested
           """, %{}) do
        {:ok, %{rows: [[canon, edges, fallback, contested]]}} ->
          %{
            canonical_count: trunc(FalkorValues.parse_number(canon, 0.0)),
            relates_to_count: trunc(FalkorValues.parse_number(edges, 0.0)),
            relates_to_fallback_count: trunc(FalkorValues.parse_number(fallback, 0.0)),
            contested_count: trunc(FalkorValues.parse_number(contested, 0.0))
          }

        _ ->
          %{canonical_count: 0, relates_to_count: 0, relates_to_fallback_count: 0, contested_count: 0}
      end

    isolated =
      case Magus.Graph.query(super_graph, """
           MATCH (c:CanonicalEntity)
           WHERE NOT (c)-[:RELATES_TO]-()
           RETURN count(c)
           """, %{}) do
        {:ok, %{rows: [[n]]}} -> trunc(FalkorValues.parse_number(n, 0.0))
        _ -> 0
      end

    buckets =
      case Magus.Graph.query(super_graph, """
           MATCH (c:CanonicalEntity)
           RETURN c.primary_type, c.normalized_subtype, count(DISTINCT c.name)
           """, %{}) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [_t, _st, names] ->
            %{distinct_name_count: trunc(FalkorValues.parse_number(names, 0.0))}
          end)

        _ ->
          []
      end

    GraphMetrics.compute(Map.merge(counts, %{isolated_count: isolated, buckets: buckets}))
  end
```

3. Thread the metrics into `mark_built`. In `do_build/2`, change the success branch so it computes metrics before the swap and passes them to `mark_built`. Replace the `with :ok <- check_write_errors(...) ... mark_built(super_row, read_set, canonical_count, edge_count, started_at)` chain so it reads:

```elixir
          metrics = compute_graph_metrics(staging_name)

          with :ok <- check_write_errors(staging_name, adjusted),
               :ok <- swap_into_live(staging_name, live_name),
               {:ok, _} <-
                 mark_built(super_row, read_set, canonical_count, edge_count, started_at, metrics) do
            :ok
```

4. Update `mark_built/5` to `mark_built/6` by adding a `metrics` parameter and including it in the update map:

```elixir
  defp mark_built(super_row, read_set, canonical_count, edge_count, started_at, metrics) do
    snapshot =
      Enum.map(read_set, fn graph_name ->
        %{
          "graph_name" => graph_name,
          "snapshot_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      end)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    Ash.update(
      super_row,
      %{
        read_set_snapshot: snapshot,
        canonical_entity_count: canonical_count,
        canonical_edge_count: edge_count,
        last_build_duration_ms: duration_ms,
        metrics: metrics
      },
      action: :mark_built,
      authorize?: false
    )
  end
```

Note: compute metrics from the STAGING graph (before the swap deletes it).

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/magus/super_brain/build_super_full_metrics_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full super-brain suite + compile**

Run: `MIX_ENV=test mix compile --warnings-as-errors && mix test test/magus/super_brain/`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/magus/super_brain/workers/build_super_full.ex test/magus/super_brain/build_super_full_metrics_test.exs
git commit -- lib/magus/super_brain/workers/build_super_full.ex test/magus/super_brain/build_super_full_metrics_test.exs \
  -m "feat(super-brain): compute + persist build-time graph metrics" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Retrieval telemetry metadata

**Files:**
- Modify: `lib/magus/super_brain/retrieval.ex` (`do_search/2`)
- Test: `test/magus/super_brain/retrieval_telemetry_test.exs`

**Interfaces:**
- Produces: the `[:super_brain, :retrieval]` telemetry span's stop metadata gains `:mode` (`:super_graph | :fan_out | :cold_start | :drift`) and `:result_count` (integer).

- [ ] **Step 1: Write the failing test**

Create `test/magus/super_brain/retrieval_telemetry_test.exs`:

```elixir
defmodule Magus.SuperBrain.RetrievalTelemetryTest do
  use Magus.ResourceCase, async: false

  alias Magus.SuperBrain.Retrieval

  test "emits mode + result_count in the retrieval span metadata" do
    user = generate(user())
    test_pid = self()

    :telemetry.attach(
      "retrieval-meta-test",
      [:super_brain, :retrieval, :stop],
      fn _event, _measure, meta, _config -> send(test_pid, {:meta, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("retrieval-meta-test") end)

    {:ok, _} =
      Retrieval.search(user, query: "anything", query_embedding: List.duplicate(0.0, 1536))

    assert_receive {:meta, meta}, 2_000
    assert Map.has_key?(meta, :mode)
    assert Map.has_key?(meta, :result_count)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/magus/super_brain/retrieval_telemetry_test.exs`
Expected: FAIL (`:mode` not in metadata).

- [ ] **Step 3: Thread mode + count through the span**

In `lib/magus/super_brain/retrieval.ex`, rewrite the body of `do_search/2`'s `:telemetry.span` so the `cond` yields a `{mode, result}` tuple and the span returns enriched metadata:

```elixir
    :telemetry.span([:super_brain, :retrieval], metadata, fn ->
      super_graph_name =
        AccessibleGraphs.super_graph_for(actor, workspace_context: workspace_context)

      super_row = fetch_super_graph_metadata(super_graph_name)

      {mode, result} =
        cond do
          super_row == nil or super_row.last_built_at == nil ->
            enqueue_initial_build(actor, workspace_context)
            {:cold_start, legacy_fan_out_search(actor, opts)}

          read_set_drifted?(super_row, actor, workspace_context) ->
            enqueue_rebuild(actor, workspace_context)
            {:drift, legacy_fan_out_search(actor, opts)}

          true ->
            {:super_graph, super_graph_search(super_graph_name, opts)}
        end

      enriched = Map.merge(metadata, %{mode: mode, result_count: result_count(result)})
      {result, enriched}
    end)
```

Add a private helper:

```elixir
  # Count results across the super-graph shape (`%{entities: [...]}`) and the
  # legacy fan-out shape (a bare list). Errors/unknown shapes count as 0.
  defp result_count({:ok, %{entities: entities}}) when is_list(entities), do: length(entities)
  defp result_count({:ok, list}) when is_list(list), do: length(list)
  defp result_count(_), do: 0
```

Note: the cold-start and drift branches both use the fan-out search, but the `mode` distinguishes WHY (a fresh super-graph build was enqueued vs a rebuild). `:fan_out` is reserved for any future direct fan-out entry that is neither cold-start nor drift.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/magus/super_brain/retrieval_telemetry_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the retrieval suite + compile**

Run: `MIX_ENV=test mix compile --warnings-as-errors && mix test test/magus/super_brain/retrieval_test.exs test/magus/super_brain/retrieval_telemetry_test.exs`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/magus/super_brain/retrieval.ex test/magus/super_brain/retrieval_telemetry_test.exs
git commit -- lib/magus/super_brain/retrieval.ex test/magus/super_brain/retrieval_telemetry_test.exs \
  -m "feat(super-brain): add mode + result_count to retrieval telemetry" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Eval `Metrics` module (pure scoring)

**Files:**
- Create: `lib/magus/eval/super_brain/metrics.ex`
- Test: `test/magus/eval/super_brain/metrics_test.exs`

**Interfaces:**
- Produces: `Magus.Eval.SuperBrain.Metrics.score(results, opts) :: %{aggregate: float, per_case: [map], per_category: map, known_gaps: map}`. Each `result` is `%{id, meta}` where `meta` carries `:expected` (`[%{"name" => .., "type" => ..}]` or atom-keyed), `:retrieved` (`[%{name, type}]`), `:k`, `:category`, `:supported`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/eval/super_brain/metrics_test.exs`:

```elixir
defmodule Magus.Eval.SuperBrain.MetricsTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.SuperBrain.Metrics

  defp result(id, expected, retrieved, opts) do
    %{
      id: id,
      meta: %{
        expected: expected,
        retrieved: retrieved,
        k: Keyword.get(opts, :k, 5),
        category: Keyword.get(opts, :category, "local_lookup"),
        supported: Keyword.get(opts, :supported, true)
      }
    }
  end

  test "supported aggregate is mean recall@k over supported cases" do
    results = [
      result("a", [%{"name" => "Daniel", "type" => "person"}],
        [%{name: "Daniel", type: "person"}], []),
      result("b", [%{"name" => "Aurora", "type" => "project"}],
        [%{name: "Other", type: "concept"}], [])
    ]

    scored = Metrics.score(results, [])
    assert scored.aggregate == 0.5
  end

  test "known gaps are tracked separately and excluded from aggregate" do
    results = [
      result("a", [%{"name" => "Daniel", "type" => "person"}],
        [%{name: "Daniel", type: "person"}], []),
      result("gap", [%{"name" => "Alias", "type" => "person"}],
        [%{name: "Nope", type: "person"}], supported: false, category: "alias_resolution")
    ]

    scored = Metrics.score(results, [])
    assert scored.aggregate == 1.0
    assert scored.known_gaps["alias_resolution"] == "0/1"
  end

  test "matching is case-insensitive on name and type" do
    results = [
      result("a", [%{"name" => "daniel", "type" => "Person"}],
        [%{name: "Daniel", type: "person"}], [])
    ]

    assert Metrics.score(results, []).aggregate == 1.0
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/magus/eval/super_brain/metrics_test.exs`
Expected: FAIL ("module ... not available").

- [ ] **Step 3: Implement the module**

Create `lib/magus/eval/super_brain/metrics.ex`:

```elixir
defmodule Magus.Eval.SuperBrain.Metrics do
  @moduledoc """
  Pure retrieval-quality scoring for the `super_brain_retrieval` benchmark.

  Reads the expected entity set and the retrieved canonicals from each
  result's `meta` and computes recall@k, hit@k, and MRR by matching on
  normalized `(name, type)`. The headline `aggregate` is the mean recall@k
  over SUPPORTED cases only; known-gap (xfail) cases are reported separately
  so unimplemented capabilities never drag the number down.
  """

  @spec score([map()], keyword()) :: %{
          aggregate: float(),
          per_case: [map()],
          per_category: map(),
          known_gaps: map()
        }
  def score(results, _opts) do
    per_case = Enum.map(results, &grade/1)
    supported = Enum.filter(per_case, & &1.supported)

    %{
      aggregate: mean(Enum.map(supported, & &1.recall_at_k)),
      per_case: per_case,
      per_category: per_category(per_case),
      known_gaps: known_gaps(per_case)
    }
  end

  defp grade(%{id: id, meta: meta}) do
    expected = normalize_set(get(meta, :expected) || [])
    retrieved = Enum.map(get(meta, :retrieved) || [], &normalize_one/1)
    k = get(meta, :k) || 5
    topk = Enum.take(retrieved, k)
    recall = recall_at_k(expected, topk)

    %{
      id: id,
      category: get(meta, :category) || "unknown",
      supported: get(meta, :supported) == true,
      recall_at_k: recall,
      hit_at_k: hit_at_k(expected, topk),
      mrr: mrr(expected, retrieved),
      correct?: recall == 1.0
    }
  end

  @doc false
  def recall_at_k([], _topk), do: 0.0

  def recall_at_k(expected, topk) do
    found = Enum.count(expected, fn e -> e in topk end)
    found / length(expected)
  end

  @doc false
  def hit_at_k(expected, topk), do: if(Enum.any?(expected, &(&1 in topk)), do: 1.0, else: 0.0)

  @doc false
  def mrr(expected, retrieved) do
    case Enum.find_index(retrieved, &(&1 in expected)) do
      nil -> 0.0
      idx -> 1.0 / (idx + 1)
    end
  end

  defp per_category(per_case) do
    per_case
    |> Enum.group_by(& &1.category)
    |> Map.new(fn {cat, items} ->
      {cat, mean(Enum.map(items, & &1.recall_at_k))}
    end)
  end

  defp known_gaps(per_case) do
    per_case
    |> Enum.reject(& &1.supported)
    |> Enum.group_by(& &1.category)
    |> Map.new(fn {cat, items} ->
      passing = Enum.count(items, & &1.correct?)
      {cat, "#{passing}/#{length(items)}"}
    end)
  end

  defp normalize_set(list), do: Enum.map(list, &normalize_one/1)

  defp normalize_one(%{} = m) do
    name = get(m, :name)
    type = get(m, :type)
    {down(name), down(type)}
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp down(nil), do: nil
  defp down(s), do: s |> to_string() |> String.downcase()

  defp mean([]), do: 0.0
  defp mean(list), do: Enum.sum(list) / length(list)
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/magus/eval/super_brain/metrics_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/eval/super_brain/metrics.ex test/magus/eval/super_brain/metrics_test.exs
git commit -- lib/magus/eval/super_brain/metrics.ex test/magus/eval/super_brain/metrics_test.exs \
  -m "feat(eval): pure retrieval scoring metrics for super-brain eval" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Eval `Fixture` parser

**Files:**
- Create: `lib/magus/eval/super_brain/fixture.ex`
- Test: `test/magus/eval/super_brain/fixture_test.exs`

**Interfaces:**
- Produces: `Magus.Eval.SuperBrain.Fixture.parse(map) :: %Fixture{entities: [..], edges: [..], sources: [..]}` where the input is the decoded `fixture` object of a case (string keys). `entities` are `%{key, name, type, normalized_subtype, embedding, trust_tier, confidence}`; `edges` are `%{from, to, predicate, confidence, trust_tier}`; `sources` are `%{entity, resource_type, resource_id}`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/eval/super_brain/fixture_test.exs`:

```elixir
defmodule Magus.Eval.SuperBrain.FixtureTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.SuperBrain.Fixture

  test "parses entities, edges and sources with defaults" do
    raw = %{
      "entities" => [
        %{"key" => "daniel", "name" => "Daniel", "type" => "person",
          "embedding" => [1, 0, 0], "confidence" => 0.9}
      ],
      "edges" => [%{"from" => "daniel", "to" => "aurora", "predicate" => "works_on"}],
      "sources" => [%{"entity" => "daniel", "resource_type" => "brain_page",
                      "resource_id" => "00000000-0000-4000-8000-000000000001"}]
    }

    f = Fixture.parse(raw)

    assert [e] = f.entities
    assert e.key == "daniel"
    assert e.name == "Daniel"
    assert e.normalized_subtype == nil
    assert e.trust_tier == "evidence"
    assert e.embedding == [1, 0, 0]

    assert [edge] = f.edges
    assert edge.from == "daniel" and edge.to == "aurora"
    assert edge.trust_tier == "evidence"

    assert [s] = f.sources
    assert s.entity == "daniel"
    assert s.resource_type == "brain_page"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/magus/eval/super_brain/fixture_test.exs`
Expected: FAIL ("module ... not available").

- [ ] **Step 3: Implement the module**

Create `lib/magus/eval/super_brain/fixture.ex`:

```elixir
defmodule Magus.Eval.SuperBrain.Fixture do
  @moduledoc """
  Parses the `fixture` object of a `super_brain_retrieval` case (decoded JSON
  with string keys) into a normalized struct that both eval subjects consume.
  The deterministic subject seeds these into the L2 super graph directly; the
  live subject seeds them into a Layer 1 graph and runs the real builder.
  """

  defstruct entities: [], edges: [], sources: []

  @type t :: %__MODULE__{entities: [map()], edges: [map()], sources: [map()]}

  @spec parse(map()) :: t()
  def parse(raw) when is_map(raw) do
    %__MODULE__{
      entities: Enum.map(Map.get(raw, "entities", []), &entity/1),
      edges: Enum.map(Map.get(raw, "edges", []), &edge/1),
      sources: Enum.map(Map.get(raw, "sources", []), &source/1)
    }
  end

  defp entity(e) do
    %{
      key: Map.fetch!(e, "key"),
      name: Map.fetch!(e, "name"),
      type: Map.fetch!(e, "type"),
      normalized_subtype: Map.get(e, "normalized_subtype"),
      embedding: Map.get(e, "embedding", []),
      trust_tier: Map.get(e, "trust_tier", "evidence"),
      confidence: Map.get(e, "confidence", 0.8)
    }
  end

  defp edge(e) do
    %{
      from: Map.fetch!(e, "from"),
      to: Map.fetch!(e, "to"),
      predicate: Map.get(e, "predicate", "relates_to"),
      confidence: Map.get(e, "confidence", 0.8),
      trust_tier: Map.get(e, "trust_tier", "evidence")
    }
  end

  defp source(s) do
    %{
      entity: Map.fetch!(s, "entity"),
      resource_type: Map.fetch!(s, "resource_type"),
      resource_id: Map.fetch!(s, "resource_id")
    }
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/magus/eval/super_brain/fixture_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/eval/super_brain/fixture.ex test/magus/eval/super_brain/fixture_test.exs
git commit -- lib/magus/eval/super_brain/fixture.ex test/magus/eval/super_brain/fixture_test.exs \
  -m "feat(eval): super-brain fixture parser" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: `SuperBrainRetrieval` benchmark + supported cases

**Files:**
- Create: `lib/magus/eval/benchmarks/super_brain_retrieval.ex`
- Create: `priv/eval/super_brain_retrieval/cases.json`
- Test: `test/magus/eval/benchmarks/super_brain_retrieval_test.exs`

**Interfaces:**
- Consumes: `Magus.Eval.SuperBrain.Metrics.score/2`.
- Produces: `Magus.Eval.Benchmarks.SuperBrainRetrieval` implementing `Magus.Eval.Benchmark`. `cases/2` reads `opts[:subject_kind]` (`:deterministic | :live`, default both) and filters cases by their `subjects` list. Each produced case has `ingest_items: [%{role: :fixture, text: <json>}]` carrying `%{"fixture" => .., "query_embedding" => ..}`, and `meta` carrying `expected/category/k/supported`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/eval/benchmarks/super_brain_retrieval_test.exs`:

```elixir
defmodule Magus.Eval.Benchmarks.SuperBrainRetrievalTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Benchmarks.SuperBrainRetrieval

  test "loads cases and carries the fixture in ingest_items" do
    {:ok, dataset} = SuperBrainRetrieval.load_dataset([])
    cases = SuperBrainRetrieval.cases(dataset, subject_kind: :deterministic)

    refute cases == []
    c = hd(cases)
    assert [%{role: :fixture, text: text}] = c.ingest_items
    assert {:ok, payload} = Jason.decode(text)
    assert Map.has_key?(payload, "fixture")
    assert Map.has_key?(payload, "query_embedding")
    assert Map.has_key?(c.meta, :expected)
  end

  test "subject_kind filters live-only cases out of deterministic runs" do
    {:ok, dataset} = SuperBrainRetrieval.load_dataset([])
    det = SuperBrainRetrieval.cases(dataset, subject_kind: :deterministic)
    refute Enum.any?(det, fn c -> c.meta.category == "same_name_fusion" end)
  end

  test "score delegates to Metrics shape" do
    results = [
      %{
        id: "x",
        meta: %{
          expected: [%{"name" => "Daniel", "type" => "person"}],
          retrieved: [%{name: "Daniel", type: "person"}],
          k: 5,
          category: "local_lookup",
          supported: true
        }
      }
    ]

    scored = SuperBrainRetrieval.score(results, [])
    assert scored.aggregate == 1.0
    assert Map.has_key?(scored, :known_gaps)
  end
end
```

- [ ] **Step 2: Create the supported-case dataset**

Create `priv/eval/super_brain_retrieval/cases.json` with the supported deterministic cases (live-only and xfail cases are added in Task 12). Use authored dim-8 embeddings and valid UUID `resource_id`s:

```json
[
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
        {"key": "daniel", "name": "Daniel", "type": "person", "normalized_subtype": null,
         "embedding": [1, 0, 0, 0, 0, 0, 0, 0], "trust_tier": "evidence", "confidence": 0.9},
        {"key": "aurora", "name": "Project Aurora", "type": "project", "normalized_subtype": null,
         "embedding": [0, 1, 0, 0, 0, 0, 0, 0], "trust_tier": "evidence", "confidence": 0.9}
      ],
      "edges": [{"from": "daniel", "to": "aurora", "predicate": "works_on", "confidence": 0.8}],
      "sources": [{"entity": "daniel", "resource_type": "brain_page",
                   "resource_id": "00000000-0000-4000-8000-000000000001"}]
    }
  },
  {
    "id": "contradiction_plan",
    "category": "contradiction_detection",
    "supported": true,
    "subjects": ["deterministic", "live"],
    "query": "what is the decision on shipping",
    "query_embedding": [0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    "k": 5,
    "expected": [{"name": "Ship Friday", "type": "decision"}],
    "fixture": {
      "entities": [
        {"key": "ship", "name": "Ship Friday", "type": "decision", "normalized_subtype": null,
         "embedding": [0, 0, 1, 0, 0, 0, 0, 0], "trust_tier": "evidence", "confidence": 0.9},
        {"key": "risk", "name": "Release Risk", "type": "concept", "normalized_subtype": null,
         "embedding": [0, 0, 0, 1, 0, 0, 0, 0], "trust_tier": "evidence", "confidence": 0.9}
      ],
      "edges": [
        {"from": "ship", "to": "risk", "predicate": "supports", "confidence": 0.8},
        {"from": "ship", "to": "risk", "predicate": "contradicts", "confidence": 0.7}
      ],
      "sources": [{"entity": "ship", "resource_type": "brain_page",
                   "resource_id": "00000000-0000-4000-8000-000000000002"}]
    }
  },
  {
    "id": "attribution_elixir",
    "category": "source_attribution",
    "supported": true,
    "subjects": ["deterministic", "live"],
    "query": "what do I know about Elixir",
    "query_embedding": [0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0],
    "k": 5,
    "expected": [{"name": "Elixir", "type": "concept"}],
    "fixture": {
      "entities": [
        {"key": "elixir", "name": "Elixir", "type": "concept", "normalized_subtype": null,
         "embedding": [0, 0, 0, 0, 1, 0, 0, 0], "trust_tier": "evidence", "confidence": 0.9}
      ],
      "edges": [],
      "sources": [{"entity": "elixir", "resource_type": "brain_page",
                   "resource_id": "00000000-0000-4000-8000-000000000003"}]
    }
  }
]
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/magus/eval/benchmarks/super_brain_retrieval_test.exs`
Expected: FAIL ("module ... not available").

- [ ] **Step 4: Implement the benchmark**

Create `lib/magus/eval/benchmarks/super_brain_retrieval.ex`:

```elixir
defmodule Magus.Eval.Benchmarks.SuperBrainRetrieval do
  @moduledoc """
  Retrieval-quality benchmark for the Layer 2 super graph. Each case carries a
  graph fixture (entities, edges, sources) plus an authored query embedding;
  the subject seeds the fixture and runs `Retrieval.search`, and `score/2`
  computes recall@k / hit@k / MRR against the expected entity set.

  The fixture rides in `ingest_items` (a single `:fixture`-role item) because
  the `Runner` only passes `ingest_items` to the subject; `meta` carries the
  scoring inputs (`expected/category/k/supported`). `cases/2` filters by
  `opts[:subject_kind]` so live-only cases (e.g. real fusion) are excluded
  from deterministic runs.
  """
  @behaviour Magus.Eval.Benchmark

  alias Magus.Eval.SuperBrain.Metrics

  @impl true
  def name, do: "super_brain_retrieval"

  @impl true
  def load_dataset(_opts) do
    path = Path.join(:code.priv_dir(:magus), "eval/super_brain_retrieval/cases.json")

    with {:ok, body} <- File.read(path), {:ok, data} <- Jason.decode(body) do
      {:ok, data}
    end
  end

  @impl true
  def cases(dataset, opts) do
    kind = opts[:subject_kind]

    dataset
    |> Enum.filter(&applies?(&1, kind))
    |> Enum.map(&to_case/1)
  end

  @impl true
  def emit_hypotheses(results, path) do
    body =
      Enum.map_join(results, "\n", fn r ->
        Jason.encode!(%{id: r.id, retrieved: get_in(r, [:meta, :retrieved]) || []})
      end)

    File.write!(path, body <> "\n")
    :ok
  end

  @impl true
  def score(results, opts), do: Metrics.score(results, opts)

  # A case applies when its `subjects` list includes the running kind. With no
  # `subject_kind` opt (e.g. a generic dataset inspection) all cases apply.
  defp applies?(_case, nil), do: true

  defp applies?(c, kind) do
    subjects = Map.get(c, "subjects", ["deterministic", "live"])
    to_string(kind) in subjects
  end

  defp to_case(c) do
    fixture_payload = %{"fixture" => c["fixture"], "query_embedding" => c["query_embedding"]}

    %{
      id: c["id"],
      question: c["query"],
      gold: primary_name(c["expected"]),
      ingest_items: [%{role: :fixture, text: Jason.encode!(fixture_payload)}],
      meta: %{
        expected: c["expected"],
        category: c["category"],
        k: c["k"] || 5,
        supported: c["supported"] == true
      }
    }
  end

  defp primary_name([%{"name" => name} | _]), do: name
  defp primary_name(_), do: ""
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/magus/eval/benchmarks/super_brain_retrieval_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/eval/benchmarks/super_brain_retrieval.ex priv/eval/super_brain_retrieval/cases.json test/magus/eval/benchmarks/super_brain_retrieval_test.exs
git commit -- lib/magus/eval/benchmarks/super_brain_retrieval.ex priv/eval/super_brain_retrieval/cases.json test/magus/eval/benchmarks/super_brain_retrieval_test.exs \
  -m "feat(eval): super_brain_retrieval benchmark + supported cases" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 11: Deterministic subject + regression test + mix task

**Files:**
- Create: `test/support/eval/subject/super_brain_deterministic.ex`
- Create: `test/magus/super_brain/eval/super_brain_retrieval_test.exs`
- Modify: `test/support/mix/tasks/magus.eval.ex` (register benchmark + `--subject`/`subject_kind`)

**Interfaces:**
- Consumes: `Magus.Eval.SuperBrain.Fixture`, `Magus.SuperBrain.EdgeAggregation`, `Magus.SuperBrain.AccessibleGraphs`, `Magus.Graph`, `Magus.Graph.Vector`, `Magus.SuperBrain.SuperGraph`, `Magus.SuperBrain.Retrieval`.
- Produces: `Magus.Eval.Subject.SuperBrainDeterministic` implementing `Magus.Eval.Subject`. `query/2` returns `%{answer, meta: %{retrieved: [%{name, type, score, ...}]}}`.

- [ ] **Step 1: Write the failing regression test**

Create `test/magus/super_brain/eval/super_brain_retrieval_test.exs`:

```elixir
defmodule Magus.SuperBrain.Eval.SuperBrainRetrievalTest do
  @moduledoc "Deterministic regression guard: supported cases must hold at recall 1.0; xfail gaps must still fail."
  use Magus.ResourceCase, async: false

  alias Magus.Eval.Benchmarks.SuperBrainRetrieval
  alias Magus.Eval.Runner
  alias Magus.Eval.Subject.SuperBrainDeterministic

  test "supported cases pass and known gaps still fail" do
    user = generate(user())

    {:ok, run} =
      Runner.run(SuperBrainRetrieval,
        subject: SuperBrainDeterministic,
        subject_kind: :deterministic,
        ctx: %{user: user},
        dry_run: true,
        recorded_at: "test"
      )

    assert run.aggregate == 1.0

    for c <- run.per_case, c.supported == false do
      refute c.correct?, "known-gap case #{c.id} unexpectedly passed; promote it to supported"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/magus/super_brain/eval/super_brain_retrieval_test.exs`
Expected: FAIL ("module Magus.Eval.Subject.SuperBrainDeterministic is not available").

- [ ] **Step 3: Implement the deterministic subject**

Create `test/support/eval/subject/super_brain_deterministic.ex`:

```elixir
defmodule Magus.Eval.Subject.SuperBrainDeterministic do
  @moduledoc """
  Offline eval subject: seeds a case's fixture straight into the Layer 2 super
  graph with authored low-dim (8) embeddings, then runs `Retrieval.search`.

  No embedder and no LLM: the authored query vector rides in via the fixture
  and is stashed on `ctx`. The `SuperGraph` row is marked built with a
  read-set snapshot that matches `AccessibleGraphs.for_actor/2`, so
  `Retrieval` takes the super-graph happy path instead of the fan-out
  fallback. Lives in test support (depends on `Magus.Generators`-style ctx).
  """
  @behaviour Magus.Eval.Subject

  alias Magus.Eval.SuperBrain.Fixture
  alias Magus.SuperBrain.AccessibleGraphs
  alias Magus.SuperBrain.EdgeAggregation
  alias Magus.SuperBrain.Retrieval
  alias Magus.SuperBrain.SuperGraph

  require Ash.Query

  @dim 8

  @impl true
  def reset(ctx) do
    super_graph = "super:user:#{ctx.user.id}"
    Magus.Graph.drop(super_graph)
    drop_super_row(ctx.user.id)
    {:ok, Map.put(ctx, :super_graph, super_graph)}
  end

  @impl true
  def ingest(ctx, [%{role: :fixture, text: text} | _]) do
    %{"fixture" => raw, "query_embedding" => query_embedding} = Jason.decode!(text)
    fixture = Fixture.parse(raw)
    super_graph = ctx.super_graph

    Magus.Graph.Vector.create_index(super_graph, "CanonicalEntity", "embedding",
      dim: @dim,
      similarity: :cosine
    )

    seed_canonicals(super_graph, fixture)
    seed_edges(super_graph, fixture)
    seed_sources(super_graph, fixture)
    seed_super_row(ctx.user, super_graph)

    {:ok, Map.put(ctx, :query_embedding, query_embedding)}
  end

  @impl true
  def query(ctx, question) do
    case Retrieval.search(ctx.user,
           query: question,
           query_embedding: ctx.query_embedding,
           limit: 10
         ) do
      {:ok, %{entities: entities}} ->
        {:ok, %{answer: top_name(entities), meta: %{retrieved: retrieved(entities)}}}

      {:ok, list} when is_list(list) ->
        {:ok, %{answer: "", meta: %{retrieved: legacy_retrieved(list)}}}

      _ ->
        {:ok, %{answer: "", meta: %{retrieved: []}}}
    end
  end

  # --- seeding ---

  defp seed_canonicals(super_graph, fixture) do
    Enum.each(fixture.entities, fn e ->
      Magus.Graph.upsert_node(super_graph, "CanonicalEntity", %{
        id: e.key,
        name: e.name,
        primary_type: e.type,
        normalized_subtype: e.normalized_subtype,
        embedding: e.embedding,
        trust_tier: e.trust_tier,
        importance_score: 1.0,
        source_count: 1
      })
    end)
  end

  defp seed_edges(super_graph, fixture) do
    fixture.edges
    |> Enum.map(fn edge ->
      %{
        from: edge.from,
        to: edge.to,
        predicate: edge.predicate,
        confidence: edge.confidence,
        trust_tier: edge.trust_tier,
        source_graph: "fixture"
      }
    end)
    |> EdgeAggregation.aggregate()
    |> Enum.each(fn agg ->
      Magus.Graph.upsert_edge(
        super_graph,
        %{from_label: "CanonicalEntity", from_id: agg.from, to_label: "CanonicalEntity", to_id: agg.to},
        "RELATES_TO",
        %{
          predicate: agg.predicate,
          confidence: agg.confidence,
          trust_tier: agg.trust_tier,
          contested: agg.contested,
          predicate_breakdown: Jason.encode!(agg.predicate_breakdown),
          appearance_count: agg.appearance_count
        }
      )
    end)
  end

  defp seed_sources(super_graph, fixture) do
    Enum.each(fixture.sources, fn s ->
      pointer_id = "ptr-" <> s.entity

      Magus.Graph.upsert_node(super_graph, "SourcePointer", %{
        id: pointer_id,
        graph_name: "fixture",
        source_node_id: s.entity,
        source_refs: Jason.encode!([%{resource_type: s.resource_type, resource_id: s.resource_id}])
      })

      Magus.Graph.upsert_edge(
        super_graph,
        %{from_label: "CanonicalEntity", from_id: s.entity, to_label: "SourcePointer", to_id: pointer_id},
        "APPEARS_IN",
        %{graph_name: "fixture", mention_count: 1, source_weight: 1.0}
      )
    end)
  end

  defp seed_super_row(user, super_graph) do
    snapshot =
      user
      |> AccessibleGraphs.for_actor(workspace_context: nil)
      |> Enum.reject(&String.starts_with?(&1, "super:"))
      |> Enum.sort()
      |> Enum.map(fn name -> %{"graph_name" => name} end)

    {:ok, row} =
      SuperGraph
      |> Ash.Changeset.for_create(:create, %{
        accessor_type: :user,
        user_id: user.id,
        workspace_id: nil,
        graph_name: super_graph
      })
      |> Ash.create(authorize?: false)

    {:ok, _} =
      row
      |> Ash.Changeset.for_update(:mark_built, %{
        read_set_snapshot: snapshot,
        canonical_entity_count: 0,
        canonical_edge_count: 0,
        last_build_duration_ms: 1
      })
      |> Ash.update(authorize?: false)
  end

  defp drop_super_row(user_id) do
    SuperGraph
    |> Ash.Query.filter(user_id == ^user_id and is_nil(workspace_id))
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))
  end

  # --- result shaping ---

  defp retrieved(entities) do
    Enum.map(entities, fn e ->
      %{
        name: Map.get(e, :name),
        type: Map.get(e, :primary_type) || Map.get(e, :type),
        score: Map.get(e, :score)
      }
    end)
  end

  defp legacy_retrieved(list) do
    Enum.map(list, fn r ->
      entity = Map.get(r, :entity) || %{}
      %{name: Map.get(entity, :name), type: Map.get(entity, :type), score: Map.get(r, :similarity)}
    end)
  end

  defp top_name([]), do: ""
  defp top_name([first | _]), do: Map.get(first, :name) || ""
end
```

- [ ] **Step 4: Run the regression test to verify it passes**

Run: `mix test test/magus/super_brain/eval/super_brain_retrieval_test.exs`
Expected: PASS (supported aggregate 1.0; no xfail cases yet, so the gap loop is vacuously true).

- [ ] **Step 5: Register the benchmark + `--subject` in the mix task**

In `test/support/mix/tasks/magus.eval.ex`:

1. Add to the `@benchmarks` map: `"super_brain_retrieval" => Magus.Eval.Benchmarks.SuperBrainRetrieval`.
2. Add `subject: :string` to the `OptionParser` strict list.
3. Map the `--subject` flag to a subject module and a `subject_kind`, defaulting to deterministic for this benchmark. After the existing `benchmark` resolution, add:

```elixir
    {subject_mod, subject_kind} =
      case opts[:subject] do
        "live" -> {Magus.Eval.Subject.Live, :live}
        "deterministic" -> {Magus.Eval.Subject.SuperBrainDeterministic, :deterministic}
        _ when benchmark == Magus.Eval.Benchmarks.SuperBrainRetrieval ->
          {Magus.Eval.Subject.SuperBrainDeterministic, :deterministic}
        _ -> {Magus.Eval.Subject.Live, nil}
      end
```

4. In `run_opts`, replace `subject: Magus.Eval.Subject.Live` with `subject: subject_mod` and add `subject_kind: subject_kind`.

- [ ] **Step 6: Verify the CLI runs (deterministic, offline)**

Run: `MIX_ENV=test mix magus.eval super_brain_retrieval --subject deterministic`
Expected: prints `super_brain_retrieval aggregate: 1.0` and a scoreboard path; appends one row to `eval/results/super_brain_retrieval.jsonl`.

- [ ] **Step 7: Compile + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add test/support/eval/subject/super_brain_deterministic.ex test/magus/super_brain/eval/super_brain_retrieval_test.exs test/support/mix/tasks/magus.eval.ex
git commit -- test/support/eval/subject/super_brain_deterministic.ex test/magus/super_brain/eval/super_brain_retrieval_test.exs test/support/mix/tasks/magus.eval.ex \
  -m "feat(eval): deterministic super-brain retrieval subject + regression guard" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 12: Known-gap xfail cases, live fusion case, and live subject

**Files:**
- Modify: `priv/eval/super_brain_retrieval/cases.json` (add xfail gaps + a live-only fusion case)
- Create: `test/support/eval/subject/super_brain_live.ex`
- Create: `test/e2e_live/super_brain_retrieval_eval_test.exs`

**Interfaces:**
- Consumes: `Magus.Eval.SuperBrain.Fixture`, `Magus.Files.EmbeddingModel`, `Magus.SuperBrain.Workers.BuildSuperFull`, `Magus.Generators`, `Magus.Graph`.
- Produces: `Magus.Eval.Subject.SuperBrainLive` implementing `Magus.Eval.Subject`.

- [ ] **Step 1: Add xfail + live-only cases to the dataset**

Append these objects to the `priv/eval/super_brain_retrieval/cases.json` array (before the closing `]`). `multi_hop` is the one deterministic xfail the recall@k metric can grade honestly today (FalkorDB is reachable only by a 2-hop traversal and is absent from today's top-1). `same_name_fusion` is a live-only supported case. `alias_resolution` and `temporal` are intentionally NOT added this phase: a name-based recall metric cannot grade fusion or time as fixed (see the spec's Categories section):

```json
,
  {
    "id": "multi_hop_team",
    "category": "multi_hop",
    "supported": false,
    "subjects": ["deterministic"],
    "query": "what technology does Daniel's project use",
    "query_embedding": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    "k": 1,
    "expected": [{"name": "FalkorDB", "type": "technology"}],
    "fixture": {
      "entities": [
        {"key": "daniel", "name": "Daniel", "type": "person", "normalized_subtype": null,
         "embedding": [1, 0, 0, 0, 0, 0, 0, 0], "trust_tier": "evidence", "confidence": 0.9},
        {"key": "aurora", "name": "Project Aurora", "type": "project", "normalized_subtype": null,
         "embedding": [0, 1, 0, 0, 0, 0, 0, 0], "trust_tier": "evidence", "confidence": 0.9},
        {"key": "falkor", "name": "FalkorDB", "type": "technology", "normalized_subtype": null,
         "embedding": [0, 0, 0, 0, 0, 1, 0, 0], "trust_tier": "evidence", "confidence": 0.9}
      ],
      "edges": [
        {"from": "daniel", "to": "aurora", "predicate": "works_on", "confidence": 0.8},
        {"from": "aurora", "to": "falkor", "predicate": "uses", "confidence": 0.8}
      ],
      "sources": [{"entity": "falkor", "resource_type": "brain_page",
                   "resource_id": "00000000-0000-4000-8000-000000000005"}]
    }
  },
  {
    "id": "same_name_fusion_daniel",
    "category": "same_name_fusion",
    "supported": true,
    "subjects": ["live"],
    "query": "who is Daniel",
    "query_embedding": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    "k": 5,
    "expected": [{"name": "Daniel", "type": "person"}],
    "fixture": {
      "entities": [
        {"key": "daniel_g1", "name": "Daniel", "type": "person", "normalized_subtype": null,
         "graph": "a", "trust_tier": "evidence", "confidence": 0.9},
        {"key": "daniel_g2", "name": "Daniel", "type": "person", "normalized_subtype": null,
         "graph": "b", "trust_tier": "evidence", "confidence": 0.9}
      ],
      "edges": [],
      "sources": []
    }
  }
```

Note: the deterministic regression test (Task 11) now exercises the `multi_hop` xfail and asserts it still fails. Re-run it after this edit.

- [ ] **Step 2: Verify the regression test still passes with xfail cases present**

Run: `mix test test/magus/super_brain/eval/super_brain_retrieval_test.exs`
Expected: PASS. Supported aggregate is still 1.0 (deterministic supported cases only), and the `multi_hop` case fails as required (the `refute c.correct?` loop holds). The `same_name_fusion` case is filtered out (live-only).

- [ ] **Step 3: Implement the live subject**

Create `test/support/eval/subject/super_brain_live.ex`:

```elixir
defmodule Magus.Eval.Subject.SuperBrainLive do
  @moduledoc """
  Live eval subject (`:e2e_live`): seeds a case's fixture into a real Layer 1
  brain graph with REAL embeddings, runs the real `BuildSuperFull` to
  materialize Layer 2, then runs `Retrieval.search` with a real query
  embedding.

  Entities are seeded directly (no LLM extraction) so the gold sets stay
  valid, but clustering/fusion, contested aggregation, importance scoring, the
  staged build + swap, and retrieval are all real. Embeddings come from
  `Magus.Files.EmbeddingModel` (the real OpenRouter path), which is
  independent of the mocked `:super_brain_embedder`. Requires
  `OPENROUTER_API_KEY`.
  """
  @behaviour Magus.Eval.Subject

  alias Magus.Eval.SuperBrain.Fixture
  alias Magus.Files.EmbeddingModel
  alias Magus.SuperBrain.Workers.BuildSuperFull

  @impl true
  def reset(ctx) do
    brain = Magus.Generators.generate(Magus.Generators.brain(user_id: ctx.user.id))
    super_graph = "super:user:#{ctx.user.id}"
    Magus.Graph.drop("brain:#{brain.id}")
    Magus.Graph.drop(super_graph)
    {:ok, ctx |> Map.put(:brain, brain) |> Map.put(:super_graph, super_graph)}
  end

  @impl true
  def ingest(ctx, [%{role: :fixture, text: text} | _]) do
    %{"fixture" => raw} = Jason.decode!(text)
    fixture = Fixture.parse(raw)
    graph = "brain:#{ctx.brain.id}"

    Enum.each(fixture.entities, fn e ->
      {:ok, embedding} = EmbeddingModel.embed(e.name)

      Magus.Graph.upsert_node(graph, "Entity", %{
        id: e.key,
        name: e.name,
        type: e.type,
        normalized_subtype: e.normalized_subtype,
        embedding: embedding,
        confidence: e.confidence,
        trust_tier: e.trust_tier
      })
    end)

    Enum.each(fixture.edges, fn edge ->
      Magus.Graph.upsert_edge(
        graph,
        %{from_label: "Entity", from_id: edge.from, to_label: "Entity", to_id: edge.to},
        "RELATES_TO",
        %{predicate: edge.predicate, confidence: edge.confidence, trust_tier: edge.trust_tier}
      )
    end)

    :ok =
      BuildSuperFull.perform(%Oban.Job{
        args: %{"accessor_type" => "user", "user_id" => ctx.user.id, "workspace_id" => nil}
      })

    {:ok, ctx}
  end

  @impl true
  def query(ctx, question) do
    {:ok, embedding} = EmbeddingModel.embed(question)

    case Magus.SuperBrain.Retrieval.search(ctx.user,
           query: question,
           query_embedding: embedding,
           limit: 10
         ) do
      {:ok, %{entities: entities}} ->
        {:ok, %{answer: "", meta: %{retrieved: shape(entities)}}}

      _ ->
        {:ok, %{answer: "", meta: %{retrieved: []}}}
    end
  end

  defp shape(entities) do
    Enum.map(entities, fn e ->
      %{name: Map.get(e, :name), type: Map.get(e, :primary_type) || Map.get(e, :type)}
    end)
  end
end
```

Note: the live-only `same_name_fusion` fixture seeds the SAME entity key into one brain graph here. To exercise real cross-graph fusion you may seed a second brain and split entities by their `graph` hint; for the first iteration, a single fused canonical from one graph is acceptable and the assertion is that retrieval returns exactly one `Daniel`.

- [ ] **Step 4: Write the live e2e test**

Create `test/e2e_live/super_brain_retrieval_eval_test.exs`:

```elixir
defmodule Magus.SuperBrainRetrievalEvalE2ETest do
  use Magus.LiveE2ECase, async: false

  @moduletag timeout: 600_000

  alias Magus.Eval.Benchmarks.SuperBrainRetrieval
  alias Magus.Eval.Runner
  alias Magus.Eval.Subject.SuperBrainLive

  test "live retrieval eval runs the real builder + embedder", %{user: user} do
    dir = Path.join(System.tmp_dir!(), "sbr_e2e_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, run} =
      Runner.run(SuperBrainRetrieval,
        subject: SuperBrainLive,
        subject_kind: :live,
        ctx: %{user: user},
        results_dir: dir,
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
      )

    assert is_number(run.aggregate)
    assert run.scoreboard_path && File.exists?(run.scoreboard_path)
  end
end
```

- [ ] **Step 5: Run the live test (requires keys + FalkorDB)**

Run: `bin/test-e2e-live test/e2e_live/super_brain_retrieval_eval_test.exs`
Expected: PASS (real embeddings + real build); records a scoreboard row in the temp dir.

- [ ] **Step 6: Compile + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add priv/eval/super_brain_retrieval/cases.json test/support/eval/subject/super_brain_live.ex test/e2e_live/super_brain_retrieval_eval_test.exs
git commit -- priv/eval/super_brain_retrieval/cases.json test/support/eval/subject/super_brain_live.ex test/e2e_live/super_brain_retrieval_eval_test.exs \
  -m "feat(eval): live super-brain retrieval subject + xfail roadmap cases" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] Run the full deterministic suite: `MIX_ENV=test mix compile --warnings-as-errors && mix test test/magus/super_brain/ test/magus/eval/ test/magus/agents/context/super_brain_rag_context_test.exs`
- [ ] Confirm `eval/results/super_brain_retrieval.jsonl` is NOT modified by `mix test` (only by the CLI). If it appears as a working-tree change after a test run, the regression test is missing `dry_run: true` (Task 11 Step 1).
- [ ] `git status` shows only intended files; nothing under `priv/repo/migrations` left uncommitted.
