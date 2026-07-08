# Super Brain Temporal Ranking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make claim retrieval time-aware: the latest claim on a functional attribute wins (supersedence), expired claims drop out (validity windows), recency gently breaks ties, and history stays fetchable.

**Architecture:** A pure `Magus.SuperBrain.Temporal` module resolves supersedence, validity, and recency at query time over only the accessor's accessible claims (correct per accessor by construction; no schema change). `Retrieval.search_claims/2` gains a two-step group-completion fetch so the pgvector KNN cannot miss a superseder, plus an explicit score `vector_similarity x trust_tier_multiplier x recency_factor`. The context block renders `(was: X)` trailers, the dossier gains a history trail, and the eval flips the `temporal` xfail to supported.

**Tech Stack:** Elixir, Ash 3.x, AshPostgres + pgvector (raw Ecto for KNN), ExUnit. No migration.

**Spec:** `docs/superpowers/specs/2026-07-04-super-brain-temporal-ranking-design.md` (the authority when in doubt).

## Global Constraints

- No em dashes anywhere: not in code, comments, docs, or commit messages. Use colons, commas, periods.
- Never run `mix ash.reset`. This feature needs NO migration; if you think you need one, stop and escalate.
- Scope every commit: `git commit -- <explicit paths>` (never `git add -A` / bare `git commit -a`; the checkout may be shared).
- End every commit message with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- All DateTime ordering via `DateTime.compare/2` or sorters given the `DateTime` module (`{:desc, DateTime}`), never bare `<` / `>` / `-` on DateTime structs.
- `Magus.SuperBrain.Temporal` never calls `DateTime.utc_now()`; `now` is always injected by callers.
- `authorize?: false` is the documented super_brain internal read/write pattern (auth boundary is the `AccessibleGraphs.for_actor/2` graph allow-list, not per-row policies). Follow existing call sites.
- Score formula, exactly: `vector_similarity x trust_tier_multiplier x recency_factor`. Recency, exactly: `0.5 + 0.5 * :math.exp(-age_days * :math.log(2) / 90)`, floored at 0.5.
- Value-change supersedence applies ONLY between claims that BOTH have `:affirms` polarity (Claim.polarity is `:affirms | :negates`; there is no `:denies`).
- `Claim.predicate` is a string; ontology predicate lists are atoms. All predicate membership checks go through `Ontology.single_valued_predicate?/1` (string-space compare).
- New Elixir code must compile clean under `MIX_ENV=test mix compile --warnings-as-errors` (CI gate).
- If running in a worktree next to other active agents, use a dedicated test DB partition: prefix test commands with `MIX_TEST_PARTITION=_wtemporal` (first run creates/migrates it).

## Conventions used by every task

- DB-touching tests: `use Magus.ResourceCase, async: false`, seed users with `user = generate(user())`.
- `Claim.episode_id` is a hard DB FK. Never fabricate an episode UUID; create a real `Magus.SuperBrain.Episode` first (the `seed_episode/2` helper below appears verbatim in existing claim tests; copy it into new test modules that need it).
- Claim embeddings are `vector(1536)`. Tests use `one_hot(i)`: a 1536-length list with 1.0 at index `i`.
- The super_brain feature flag is on in the test env; no flag setup needed in tests.
- Run a single file: `mix test test/path/file_test.exs`. Whole feature check: `mix test test/magus/super_brain test/magus/eval test/magus/agents/context/super_brain_rag_context_test.exs`.

---

### Task 1: Ontology single-valued predicates + the pure Temporal module

**Files:**
- Modify: `lib/magus/super_brain/ontology.ex` (add after the existing `trust_tier_multiplier/1` clauses, around line 141)
- Create: `lib/magus/super_brain/temporal.ex`
- Test: `test/magus/super_brain/ontology_test.exs` (append a describe block)
- Test: create `test/magus/super_brain/temporal_test.exs`

**Interfaces:**
- Consumes: nothing new (pure additions).
- Produces (later tasks call these, signatures are load-bearing):
  - `Magus.SuperBrain.Ontology.single_valued_predicates/0 :: [String.t()]` (seeded `["occurs_at"]`)
  - `Magus.SuperBrain.Ontology.single_valued_predicate?/1 :: (String.t() | atom()) -> boolean()`
  - `Magus.SuperBrain.Temporal.resolve(claims, now: DateTime.t()) :: %{current: [%{claim: claim, score_factors: %{recency: float()}}], historic: [%{claim: claim, reason: :superseded | :expired | :future}]}` where `claim` is any map/struct with keys `id`, `subject_key`, `predicate`, `object_key`, `polarity`, `asserted_at`, `valid_from`, `valid_to` (works on `Claim` structs and plain maps alike)
  - `Magus.SuperBrain.Temporal.recency_factor(claim, now) :: float()` in `[0.5, 1.0]`

- [ ] **Step 1: Write the failing Ontology tests**

Append to `test/magus/super_brain/ontology_test.exs` (inside the top-level module, after the last existing describe block):

```elixir
  describe "single_valued_predicates/0 and single_valued_predicate?/1" do
    test "the curated set is seeded with occurs_at only, as strings" do
      assert Magus.SuperBrain.Ontology.single_valued_predicates() == ["occurs_at"]
    end

    test "accepts binaries (how Claim stores predicate) and atoms (ontology lists)" do
      assert Magus.SuperBrain.Ontology.single_valued_predicate?("occurs_at")
      assert Magus.SuperBrain.Ontology.single_valued_predicate?(:occurs_at)
      refute Magus.SuperBrain.Ontology.single_valued_predicate?("relates_to")
      refute Magus.SuperBrain.Ontology.single_valued_predicate?(:relates_to)
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/magus/super_brain/ontology_test.exs`
Expected: FAIL with `UndefinedFunctionError` for `single_valued_predicates/0`.

- [ ] **Step 3: Implement the Ontology additions**

In `lib/magus/super_brain/ontology.ex`, add near the other module attributes (after `@instruction_sources`, around line 57):

```elixir
  # Predicates whose subject can hold only one current object (functional
  # attributes): a newer :affirms claim on the same (subject, predicate)
  # supersedes an older one. Strings, because Claim.predicate is a string
  # column. Deliberately tiny: a wrong inclusion suppresses
  # legitimately-coexisting facts, so additions require a supporting eval
  # case (see the temporal ranking spec).
  @single_valued_predicates ~w(occurs_at)
```

Then add after the `trust_tier_multiplier/1` clauses (after line 141):

```elixir
  @doc "Curated set of single-valued (functional) predicates, as strings."
  def single_valued_predicates, do: @single_valued_predicates

  @doc """
  Whether `predicate` is single-valued. Claim rows store `predicate` as a
  string while the ontology predicate lists are atoms, so this accepts both
  and compares in string space (a raw atom-set membership test against a
  string predicate would silently never match).
  """
  def single_valued_predicate?(predicate) when is_atom(predicate),
    do: predicate |> Atom.to_string() |> single_valued_predicate?()

  def single_valued_predicate?(predicate) when is_binary(predicate),
    do: predicate in @single_valued_predicates
```

- [ ] **Step 4: Run to verify the Ontology tests pass**

Run: `mix test test/magus/super_brain/ontology_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the failing Temporal tests**

Create `test/magus/super_brain/temporal_test.exs`:

```elixir
defmodule Magus.SuperBrain.TemporalTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.Temporal

  @now ~U[2026-07-01 00:00:00Z]

  # Temporal is duck-typed over claim-shaped maps; no DB needed. Explicit ids
  # keep the id tie-break assertable.
  defp claim(overrides) do
    Map.merge(
      %{
        id: "id-#{System.unique_integer([:positive])}",
        subject_key: "aurora",
        predicate: "occurs_at",
        object_key: "q3",
        object_name: "Q3",
        polarity: :affirms,
        asserted_at: ~U[2026-05-01 00:00:00Z],
        valid_from: nil,
        valid_to: nil
      },
      Map.new(overrides)
    )
  end

  defp current_ids(resolved), do: Enum.map(resolved.current, & &1.claim.id)
  defp historic_ids(resolved), do: Enum.map(resolved.historic, & &1.claim.id)

  describe "validity partition" do
    test "expired claims (valid_to before now) go historic with :expired" do
      c = claim(%{id: "a", valid_to: ~U[2026-06-30 00:00:00Z]})
      resolved = Temporal.resolve([c], now: @now)

      assert resolved.current == []
      assert [%{claim: %{id: "a"}, reason: :expired}] = resolved.historic
    end

    test "future claims (valid_from after now) go historic with :future" do
      c = claim(%{id: "a", valid_from: ~U[2026-07-02 00:00:00Z]})
      resolved = Temporal.resolve([c], now: @now)

      assert resolved.current == []
      assert [%{claim: %{id: "a"}, reason: :future}] = resolved.historic
    end

    test "a claim with no validity window is always in-window" do
      resolved = Temporal.resolve([claim(%{id: "a"})], now: @now)
      assert current_ids(resolved) == ["a"]
      assert resolved.historic == []
    end

    test "boundary: valid_to exactly at now is still in-window" do
      c = claim(%{id: "a", valid_to: @now})
      resolved = Temporal.resolve([c], now: @now)
      assert current_ids(resolved) == ["a"]
    end
  end

  describe "value-change supersedence (single-valued predicates)" do
    test "the newer affirms claim wins; the older goes historic :superseded" do
      q3 = claim(%{id: "q3", asserted_at: ~U[2026-05-01 00:00:00Z]})

      q4 =
        claim(%{
          id: "q4",
          object_key: "q4",
          object_name: "Q4",
          asserted_at: ~U[2026-06-01 00:00:00Z]
        })

      resolved = Temporal.resolve([q3, q4], now: @now)

      assert current_ids(resolved) == ["q4"]
      assert [%{claim: %{id: "q3"}, reason: :superseded}] = resolved.historic
    end

    test "a re-assertion of the same object supersedes the older assertion" do
      old = claim(%{id: "old", asserted_at: ~U[2026-05-01 00:00:00Z]})
      new = claim(%{id: "new", asserted_at: ~U[2026-06-01 00:00:00Z]})

      resolved = Temporal.resolve([old, new], now: @now)
      assert current_ids(resolved) == ["new"]
      assert historic_ids(resolved) == ["old"]
    end

    test "multi-valued predicates never supersede by value: both stay current" do
      a = claim(%{id: "a", predicate: "relates_to", object_key: "x"})

      b =
        claim(%{
          id: "b",
          predicate: "relates_to",
          object_key: "y",
          asserted_at: ~U[2026-06-01 00:00:00Z]
        })

      resolved = Temporal.resolve([a, b], now: @now)
      assert Enum.sort(current_ids(resolved)) == ["a", "b"]
      assert resolved.historic == []
    end

    test "a newer negation of one object does NOT supersede an affirmation of another" do
      q4 =
        claim(%{
          id: "q4",
          object_key: "q4",
          object_name: "Q4",
          asserted_at: ~U[2026-05-15 00:00:00Z]
        })

      not_q3 =
        claim(%{
          id: "not-q3",
          polarity: :negates,
          asserted_at: ~U[2026-06-01 00:00:00Z]
        })

      resolved = Temporal.resolve([q4, not_q3], now: @now)
      # Both current: the negation only speaks about Q3, not Q4.
      assert Enum.sort(current_ids(resolved)) == ["not-q3", "q4"]
    end

    test "an expired newer claim does not supersede (resolution is over in-window only)" do
      old = claim(%{id: "old", asserted_at: ~U[2026-05-01 00:00:00Z]})

      newer_expired =
        claim(%{
          id: "newer",
          object_key: "q4",
          asserted_at: ~U[2026-06-01 00:00:00Z],
          valid_to: ~U[2026-06-15 00:00:00Z]
        })

      resolved = Temporal.resolve([old, newer_expired], now: @now)
      assert current_ids(resolved) == ["old"]
      assert [%{claim: %{id: "newer"}, reason: :expired}] = resolved.historic
    end
  end

  describe "polarity-flip supersedence (exact triple, any predicate)" do
    test "a newer negation supersedes the older affirmation of the same triple" do
      yes = claim(%{id: "yes", predicate: "relates_to", asserted_at: ~U[2026-05-01 00:00:00Z]})

      no =
        claim(%{
          id: "no",
          predicate: "relates_to",
          polarity: :negates,
          asserted_at: ~U[2026-06-01 00:00:00Z]
        })

      resolved = Temporal.resolve([yes, no], now: @now)
      assert current_ids(resolved) == ["no"]
      assert [%{claim: %{id: "yes"}, reason: :superseded}] = resolved.historic
    end

    test "a newer affirmation supersedes the older negation of the same triple" do
      no = claim(%{id: "no", polarity: :negates, asserted_at: ~U[2026-05-01 00:00:00Z]})
      yes = claim(%{id: "yes", asserted_at: ~U[2026-06-01 00:00:00Z]})

      resolved = Temporal.resolve([no, yes], now: @now)
      assert current_ids(resolved) == ["yes"]
      assert historic_ids(resolved) == ["no"]
    end
  end

  describe "the newer-than total order" do
    test "equal asserted_at falls back to valid_from; nil valid_from sorts oldest" do
      same = ~U[2026-05-01 00:00:00Z]
      a = claim(%{id: "a", asserted_at: same, valid_from: nil})

      b =
        claim(%{
          id: "b",
          object_key: "q4",
          asserted_at: same,
          valid_from: ~U[2026-05-02 00:00:00Z]
        })

      resolved = Temporal.resolve([a, b], now: @now)
      assert current_ids(resolved) == ["b"]
    end

    test "full tie falls back to id descending" do
      same = ~U[2026-05-01 00:00:00Z]
      a = claim(%{id: "id-a", asserted_at: same})
      b = claim(%{id: "id-b", object_key: "q4", asserted_at: same})

      resolved = Temporal.resolve([a, b], now: @now)
      assert current_ids(resolved) == ["id-b"]
    end

    test "nil asserted_at sorts oldest" do
      a = claim(%{id: "a", asserted_at: nil})
      b = claim(%{id: "b", object_key: "q4", asserted_at: ~U[2026-01-01 00:00:00Z]})

      resolved = Temporal.resolve([a, b], now: @now)
      assert current_ids(resolved) == ["b"]
      assert historic_ids(resolved) == ["a"]
    end
  end

  describe "recency_factor/2" do
    test "age zero gives 1.0" do
      c = claim(%{asserted_at: @now})
      assert_in_delta Temporal.recency_factor(c, @now), 1.0, 1.0e-9
    end

    test "90 days of age gives 0.75 (half of the decaying part)" do
      c = claim(%{asserted_at: DateTime.add(@now, -90, :day)})
      assert_in_delta Temporal.recency_factor(c, @now), 0.75, 1.0e-6
    end

    test "monotonically decreasing with age, floored at 0.5" do
      fresh = claim(%{asserted_at: DateTime.add(@now, -1, :day)})
      old = claim(%{asserted_at: DateTime.add(@now, -400, :day)})
      ancient = claim(%{asserted_at: DateTime.add(@now, -40_000, :day)})

      f = Temporal.recency_factor(fresh, @now)
      o = Temporal.recency_factor(old, @now)
      a = Temporal.recency_factor(ancient, @now)

      assert f > o
      assert o > a
      assert a >= 0.5
      assert f <= 1.0
    end

    test "nil asserted_at takes the floor 0.5" do
      assert Temporal.recency_factor(claim(%{asserted_at: nil}), @now) == 0.5
    end

    test "a future asserted_at clamps age to zero (factor 1.0)" do
      c = claim(%{asserted_at: DateTime.add(@now, 10, :day)})
      assert_in_delta Temporal.recency_factor(c, @now), 1.0, 1.0e-9
    end
  end

  describe "resolve/2 output shape" do
    test "empty input yields empty partitions" do
      assert Temporal.resolve([], now: @now) == %{current: [], historic: []}
    end

    test "current entries carry score_factors with the recency factor" do
      resolved = Temporal.resolve([claim(%{id: "a", asserted_at: @now})], now: @now)
      assert [%{claim: %{id: "a"}, score_factors: %{recency: r}}] = resolved.current
      assert_in_delta r, 1.0, 1.0e-9
    end
  end
end
```

- [ ] **Step 6: Run to verify failure**

Run: `mix test test/magus/super_brain/temporal_test.exs`
Expected: FAIL to compile with `module Magus.SuperBrain.Temporal is not available` (or UndefinedFunctionError).

- [ ] **Step 7: Implement the Temporal module**

Create `lib/magus/super_brain/temporal.ex`:

```elixir
defmodule Magus.SuperBrain.Temporal do
  @moduledoc """
  Pure temporal resolution over a list of accessible claims: validity
  windows, supersedence, and recency scoring.

  Callers apply the accessible-graph allow-list BEFORE calling in.
  Supersedence computed over exactly the claims the accessor can see is what
  makes the result correct per accessor: a superseder the accessor cannot
  read must not hide a claim they can read.

  Duck-typed: works on `Magus.SuperBrain.Claim` structs and plain maps alike,
  reading `id`, `subject_key`, `predicate`, `object_key`, `polarity`,
  `asserted_at`, `valid_from`, `valid_to`.

  No I/O and no clock reads: `now` is always injected so the eval can pin
  time. All DateTime ordering goes through `DateTime.compare/2`, never bare
  comparison operators (which compare struct terms).
  """

  alias Magus.SuperBrain.Ontology

  @recency_half_life_days 90
  @recency_floor 0.5

  @doc """
  Partitions `claims` into current and historic at `now`.

  Resolution order: validity partition first (expired and future claims go
  straight to historic), then supersedence over the in-window claims, then
  recency scoring on the survivors.

      %{
        current: [%{claim: claim, score_factors: %{recency: float}}],
        historic: [%{claim: claim, reason: :superseded | :expired | :future}]
      }

  `current` carries no ordering contract (callers rank by their own score).
  """
  def resolve(claims, opts) do
    now = Keyword.fetch!(opts, :now)

    {in_window, out_of_window} = partition_validity(claims, now)
    {kept, superseded} = drop_superseded(in_window)

    %{
      current:
        Enum.map(kept, fn c ->
          %{claim: c, score_factors: %{recency: recency_factor(c, now)}}
        end),
      historic: out_of_window ++ Enum.map(superseded, &%{claim: &1, reason: :superseded})
    }
  end

  @doc """
  Recency factor in `[0.5, 1.0]`:
  `0.5 + 0.5 * exp(-age_days * ln(2) / 90)`. The decaying half halves every
  90 days; the floor keeps recency a nudge, not a cliff. A nil `asserted_at`
  takes the floor (the column is nullable; every write path stamps it, but
  this module stays total).
  """
  def recency_factor(%{asserted_at: nil}, _now), do: @recency_floor

  def recency_factor(%{asserted_at: asserted_at}, now) do
    age_days = max(0, DateTime.diff(now, asserted_at)) / 86_400

    @recency_floor +
      (1.0 - @recency_floor) *
        :math.exp(-age_days * :math.log(2) / @recency_half_life_days)
  end

  # --- validity -------------------------------------------------------------

  defp partition_validity(claims, now) do
    claims
    |> Enum.reduce({[], []}, fn c, {in_w, out} ->
      case validity_reason(c, now) do
        nil -> {[c | in_w], out}
        reason -> {in_w, [%{claim: c, reason: reason} | out]}
      end
    end)
    |> then(fn {in_w, out} -> {Enum.reverse(in_w), Enum.reverse(out)} end)
  end

  defp validity_reason(c, now) do
    cond do
      c.valid_to != nil and DateTime.compare(c.valid_to, now) == :lt -> :expired
      c.valid_from != nil and DateTime.compare(c.valid_from, now) == :gt -> :future
      true -> nil
    end
  end

  # --- supersedence ----------------------------------------------------------

  # O(n^2) pairwise check; n is a retrieval working set (tens of claims), not
  # a corpus. A claim survives when no other in-window claim supersedes it.
  defp drop_superseded(claims) do
    Enum.split_with(claims, fn c -> not superseded_by_any?(c, claims) end)
  end

  defp superseded_by_any?(a, claims) do
    Enum.any?(claims, fn b -> b.id != a.id and supersedes?(b, a) end)
  end

  # Claim B supersedes claim A (both in-window, both accessible) when either
  # rule matches. See the temporal ranking spec, "Supersedence rules".
  defp supersedes?(b, a), do: value_change?(b, a) or polarity_flip?(b, a)

  # Value-change: same (subject_key, predicate), predicate single-valued,
  # BOTH :affirms, B newer. The :affirms restriction is load-bearing: a newer
  # negation of one object must not supersede an affirmation of another.
  defp value_change?(b, a) do
    a.subject_key == b.subject_key and
      a.predicate == b.predicate and
      a.polarity == :affirms and b.polarity == :affirms and
      Ontology.single_valued_predicate?(b.predicate) and
      newer?(b, a)
  end

  # Polarity flip: opposite polarity on the exact same triple, B newer. An
  # affirm-then-negate (or the reverse) is unambiguous for any predicate.
  defp polarity_flip?(b, a) do
    a.subject_key == b.subject_key and
      a.predicate == b.predicate and
      a.object_key == b.object_key and
      a.polarity != b.polarity and
      newer?(b, a)
  end

  # Total "newer than" order: asserted_at, then valid_from (nil sorts oldest
  # for both), then id descending. Ids are UUIDv7 (time-ordered), so the
  # final tie-break is deterministic and roughly insertion-ordered.
  defp newer?(b, a), do: compare_recency(b, a) == :gt

  defp compare_recency(b, a) do
    with :eq <- compare_nillable(b.asserted_at, a.asserted_at),
         :eq <- compare_nillable(b.valid_from, a.valid_from) do
      cond do
        b.id > a.id -> :gt
        b.id < a.id -> :lt
        true -> :eq
      end
    end
  end

  defp compare_nillable(nil, nil), do: :eq
  defp compare_nillable(nil, _), do: :lt
  defp compare_nillable(_, nil), do: :gt
  defp compare_nillable(x, y), do: DateTime.compare(x, y)
end
```

- [ ] **Step 8: Run to verify all Task 1 tests pass**

Run: `mix test test/magus/super_brain/temporal_test.exs test/magus/super_brain/ontology_test.exs`
Expected: PASS, 0 failures.

- [ ] **Step 9: Commit**

```bash
git commit -m "feat(super-brain): temporal resolution module + single-valued predicates

Pure Magus.SuperBrain.Temporal: validity partition, affirms-only
value-change supersedence, polarity-flip supersedence, 90-day
half-life recency floored at 0.5. Ontology gains the curated
single_valued_predicates set (occurs_at) behind
single_valued_predicate?/1 (string-space compare; Claim.predicate is
a string, ontology lists are atoms).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/super_brain/temporal.ex lib/magus/super_brain/ontology.ex test/magus/super_brain/temporal_test.exs test/magus/super_brain/ontology_test.exs
```

---

### Task 2: Time-aware `search_claims/2` (similarity surfacing, group completion, resolve, score)

**Files:**
- Modify: `lib/magus/super_brain/claim.ex` (replace `top_ids_by_embedding/4`, lines 180-201; add `group_hits_by_embedding/5`)
- Modify: `lib/magus/super_brain/retrieval.ex` (rewrite `search_claims/2`, lines 95-110; add private `completion_hits/4`; extend the `@doc` above `search_claims`)
- Test: `test/magus/super_brain/retrieval_claims_test.exs` (extend)

**Interfaces:**
- Consumes (from Task 1): `Magus.SuperBrain.Temporal.resolve(claims, now: now)` returning `%{current: [%{claim: c, score_factors: %{recency: float}}], historic: [%{claim: c, reason: atom}]}`; `Magus.SuperBrain.Ontology.trust_tier_multiplier/1` (already exists: `:instruction` 1.5, `:evidence` 1.0, `:noise` 0.2).
- Produces:
  - `Magus.SuperBrain.Claim.top_hits_by_embedding(embedding, graph_names, tiers, limit) :: [{binary_id, float_similarity}]` (replaces `top_ids_by_embedding/4`; the ONLY caller is `retrieval.ex:105`, verified by grep; no test references it directly)
  - `Magus.SuperBrain.Claim.group_hits_by_embedding(graph_names, subject_keys, predicates, tiers, embedding) :: [{binary_id, float_similarity}]`
  - `Retrieval.search_claims(actor, opts)` new opts: `:now` (DateTime, default `DateTime.utc_now()`), `:include_historic` (boolean, default false). Return: default `{:ok, [Claim.t()]}` ranked current; with `include_historic: true`, `{:ok, %{current: [Claim.t()], historic: [%{claim: Claim.t(), reason: :superseded | :expired | :future}]}}`. Kill switch off returns `{:ok, []}` or `{:ok, %{current: [], historic: []}}` respectively.

- [ ] **Step 1: Write the failing tests**

Append inside `test/magus/super_brain/retrieval_claims_test.exs` (before the private helpers; extend `seed_claim/4` as shown at the end of this step):

```elixir
  describe "temporal ranking" do
    test "returns the superseder even when the KNN query is nearest the stale claim" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      # Stale claim matches the query embedding exactly; the superseder is
      # orthogonal (the temporal xfail geometry).
      seed_claim(graph, user.id, "Aurora ships in Q3.",
        embedding: one_hot(7),
        predicate: "occurs_at",
        object: "Q3",
        asserted_at: ~U[2026-05-01 00:00:00Z]
      )

      seed_claim(graph, user.id, "Aurora now ships in Q4.",
        embedding: one_hot(9),
        predicate: "occurs_at",
        object: "Q4",
        asserted_at: ~U[2026-06-01 00:00:00Z]
      )

      assert {:ok, [claim]} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 1
               )

      assert claim.object_name == "Q4"
    end

    test "a superseder in an inaccessible graph does not supersede (accessor-relative)" do
      user = generate(user())
      graph = "memories:user:#{user.id}"
      other_user = generate(user())
      other_graph = "memories:user:#{other_user.id}"

      seed_claim(graph, user.id, "Aurora ships in Q3.",
        embedding: one_hot(7),
        predicate: "occurs_at",
        object: "Q3",
        asserted_at: ~U[2026-05-01 00:00:00Z]
      )

      seed_claim(other_graph, other_user.id, "Aurora now ships in Q4.",
        embedding: one_hot(9),
        predicate: "occurs_at",
        object: "Q4",
        asserted_at: ~U[2026-06-01 00:00:00Z]
      )

      assert {:ok, [claim]} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5
               )

      assert claim.object_name == "Q3"
    end

    test "include_historic: true returns the exact map shape with reasons" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      seed_claim(graph, user.id, "Aurora ships in Q3.",
        embedding: one_hot(7),
        predicate: "occurs_at",
        object: "Q3",
        asserted_at: ~U[2026-05-01 00:00:00Z]
      )

      seed_claim(graph, user.id, "Aurora now ships in Q4.",
        embedding: one_hot(9),
        predicate: "occurs_at",
        object: "Q4",
        asserted_at: ~U[2026-06-01 00:00:00Z]
      )

      assert {:ok, %{current: [current], historic: [historic]}} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5,
                 include_historic: true
               )

      assert current.object_name == "Q4"
      assert %{claim: %Claim{object_name: "Q3"}, reason: :superseded} = historic
    end

    test "the :now option gates validity windows deterministically" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      seed_claim(graph, user.id, "Aurora uses OldVendor.",
        embedding: one_hot(7),
        predicate: "relates_to",
        object: "OldVendor",
        asserted_at: ~U[2026-05-01 00:00:00Z],
        valid_to: ~U[2026-06-30 00:00:00Z]
      )

      # Before expiry: included.
      assert {:ok, [_]} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5,
                 now: ~U[2026-06-01 00:00:00Z]
               )

      # After expiry: excluded from current.
      assert {:ok, []} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5,
                 now: ~U[2026-07-01 00:00:00Z]
               )
    end

    test "a nil-embedding superseder still supersedes and appears in current" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      seed_claim(graph, user.id, "Aurora ships in Q3.",
        embedding: one_hot(7),
        predicate: "occurs_at",
        object: "Q3",
        asserted_at: ~U[2026-05-01 00:00:00Z]
      )

      # Embedding failure leaves nil; the completion read must still fetch it.
      seed_claim(graph, user.id, "Aurora now ships in Q4.",
        embedding: nil,
        predicate: "occurs_at",
        object: "Q4",
        asserted_at: ~U[2026-06-01 00:00:00Z]
      )

      assert {:ok, [claim]} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5
               )

      assert claim.object_name == "Q4"
    end

    test "group completion cannot introduce an unrelated group into the result" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      # Two candidates with heterogeneous subjects AND predicates, so the
      # cross-product fetch would pull (aurora, works_on) too.
      seed_claim(graph, user.id, "Aurora ships in Q3.",
        embedding: one_hot(7),
        predicate: "occurs_at",
        object: "Q3"
      )

      seed_claim(graph, user.id, "Bob works on the platform.",
        embedding: one_hot(8),
        subject: "Bob",
        predicate: "works_on",
        object: "platform"
      )

      # Cross-product group member: subject aurora x predicate works_on.
      # Orthogonal to the query so it can never be a KNN candidate itself.
      seed_claim(graph, user.id, "Aurora works on sneaky things.",
        embedding: one_hot(11),
        predicate: "works_on",
        object: "sneaky"
      )

      # limit: 2 is load-bearing: the KNN returns the nearest `limit` claims
      # regardless of distance, so a larger limit would make the sneaky claim
      # a candidate itself and defeat the point of the test. With limit 2 the
      # two 0.707-similarity claims strictly beat the orthogonal one.
      query = one_hot(7) |> List.replace_at(8, 1.0)

      assert {:ok, claims} =
               Retrieval.search_claims(user,
                 query_embedding: query,
                 accessible_graphs: [graph],
                 limit: 2
               )

      texts = claims |> Enum.map(& &1.claim_text) |> Enum.sort()
      assert texts == ["Aurora ships in Q3.", "Bob works on the platform."]
    end

    test "among current claims, fresher asserted_at ranks first at equal similarity" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      seed_claim(graph, user.id, "Aurora relates to VendorOld.",
        embedding: one_hot(7),
        predicate: "relates_to",
        object: "VendorOld",
        asserted_at: DateTime.add(DateTime.utc_now(), -200, :day)
      )

      seed_claim(graph, user.id, "Aurora relates to VendorNew.",
        embedding: one_hot(7),
        predicate: "relates_to",
        object: "VendorNew",
        asserted_at: DateTime.utc_now()
      )

      assert {:ok, [first, second]} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5
               )

      assert first.object_name == "VendorNew"
      assert second.object_name == "VendorOld"
    end
  end
```

Replace the existing `seed_claim/4` helper with this keyword-options version (the existing call sites `seed_claim(graph, user.id, "text", one_hot(0))` must be updated to `seed_claim(graph, user.id, "text", embedding: one_hot(0))`):

```elixir
  defp seed_claim(graph, uid, text, opts \\ []) do
    ep = seed_episode(graph, uid)
    subject = Keyword.get(opts, :subject, "Aurora")
    object = Keyword.get(opts, :object, "wrapper")

    Claim
    |> Ash.Changeset.for_create(:create, %{
      graph_name: graph,
      episode_id: ep.id,
      source_user_id: uid,
      subject_name: subject,
      subject_key: Magus.SuperBrain.Naming.key(subject),
      object_name: object,
      object_key: Magus.SuperBrain.Naming.key(object),
      predicate: Keyword.get(opts, :predicate, "relates_to"),
      polarity: Keyword.get(opts, :polarity, :affirms),
      claim_text: text,
      confidence: 0.8,
      trust_tier: :evidence,
      asserted_at: Keyword.get(opts, :asserted_at, DateTime.utc_now()),
      valid_from: Keyword.get(opts, :valid_from),
      valid_to: Keyword.get(opts, :valid_to),
      embedding: Keyword.get(opts, :embedding)
    })
    |> Ash.create(authorize?: false)
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/magus/super_brain/retrieval_claims_test.exs`
Expected: FAIL (superseder tests return the stale claim; `include_historic` shape mismatch; existing first test still passes after the helper-call update).

- [ ] **Step 3: Replace the Claim query functions**

In `lib/magus/super_brain/claim.ex`, replace `top_ids_by_embedding/4` (lines 180-201, spec line included) with:

```elixir
  @doc """
  Top-`limit` claims by cosine similarity to `embedding`, restricted to
  `graph_names` and string `tiers`. Returns `{id, similarity}` pairs in
  descending-similarity order; similarity is `1 - cosine_distance`, clamped
  to [0.0, 1.0]. Nil-embedding claims cannot be KNN candidates and are
  excluded here; `group_hits_by_embedding/5` includes them so a
  not-yet-embedded superseder still participates in temporal resolution.
  """
  @spec top_hits_by_embedding([float()], [String.t()], [String.t()], integer()) ::
          [{binary(), float()}]
  def top_hits_by_embedding([], _graph_names, _tiers, _limit), do: []
  def top_hits_by_embedding(_embedding, [], _tiers, _limit), do: []
  def top_hits_by_embedding(_embedding, _graph_names, [], _limit), do: []

  def top_hits_by_embedding(embedding, graph_names, tiers, limit) do
    import Ecto.Query

    vector = Pgvector.new(embedding)

    from(c in "super_brain_claims",
      where: not is_nil(c.embedding),
      where: c.graph_name in ^graph_names,
      where: c.trust_tier in ^tiers,
      select: {c.id, fragment("1 - (? <=> ?)", c.embedding, ^vector)},
      order_by: [asc: fragment("? <=> ?", c.embedding, ^vector)],
      limit: ^limit
    )
    |> Magus.Repo.all()
    |> Enum.map(fn {id, similarity} ->
      {Ecto.UUID.load!(id), clamp_similarity(similarity)}
    end)
  end

  @doc """
  All claims in the `(subject_keys x predicates)` cross product, restricted
  to `graph_names` and string `tiers`: the group-completion read that
  surfaces superseders the KNN missed. Returns `{id, similarity}` pairs
  (unordered); nil-embedding claims are INCLUDED with similarity 0.0.
  Narrowed by the indexed graph_name and subject_key columns; predicate is
  filtered in-row.
  """
  @spec group_hits_by_embedding(
          [String.t()],
          [String.t()],
          [String.t()],
          [String.t()],
          [float()]
        ) :: [{binary(), float()}]
  def group_hits_by_embedding([], _keys, _preds, _tiers, _embedding), do: []
  def group_hits_by_embedding(_graphs, [], _preds, _tiers, _embedding), do: []
  def group_hits_by_embedding(_graphs, _keys, [], _tiers, _embedding), do: []
  def group_hits_by_embedding(_graphs, _keys, _preds, [], _embedding), do: []

  def group_hits_by_embedding(graph_names, subject_keys, predicates, tiers, embedding) do
    import Ecto.Query

    vector = Pgvector.new(embedding)

    from(c in "super_brain_claims",
      where: c.graph_name in ^graph_names,
      where: c.trust_tier in ^tiers,
      where: c.subject_key in ^subject_keys,
      where: c.predicate in ^predicates,
      select:
        {c.id,
         fragment(
           "CASE WHEN ? IS NULL THEN NULL ELSE 1 - (? <=> ?) END",
           c.embedding,
           c.embedding,
           ^vector
         )}
    )
    |> Magus.Repo.all()
    |> Enum.map(fn {id, similarity} ->
      {Ecto.UUID.load!(id), clamp_similarity(similarity)}
    end)
  end

  defp clamp_similarity(nil), do: 0.0
  defp clamp_similarity(s), do: s |> max(0.0) |> min(1.0)
```

- [ ] **Step 4: Rewrite `search_claims/2` in `lib/magus/super_brain/retrieval.ex`**

Extend the `@doc` options list above `search_claims` (after the `:accessible_graphs` bullet, keeping the existing bullets) with:

```
    * `:now`: the resolution instant for validity windows and recency.
      Defaults to `DateTime.utc_now()`; the deterministic eval pins it.
    * `:include_historic`: when `true`, returns
      `{:ok, %{current: claims, historic: [%{claim: c, reason: r}]}}` where
      `reason` is `:superseded | :expired | :future`. Defaults to `false`
      (plain `{:ok, claims}` list, ranked current only).
```

Replace the whole `search_claims/2` function (lines 95-110) with:

```elixir
  def search_claims(actor, opts) do
    include_historic = Keyword.get(opts, :include_historic, false)

    if Magus.SuperBrain.enabled?() do
      embedding = Keyword.fetch!(opts, :query_embedding)
      limit = Keyword.get(opts, :limit, 10)
      now = Keyword.get(opts, :now) || DateTime.utc_now()

      tiers =
        opts |> Keyword.get(:trust_tiers, @default_trust_tiers) |> Enum.map(&Atom.to_string/1)

      graphs = accessible_graphs(actor, opts)

      candidate_hits = Magus.SuperBrain.Claim.top_hits_by_embedding(embedding, graphs, tiers, limit)
      candidate_ids = Enum.map(candidate_hits, &elem(&1, 0))
      candidates = load_claims_in_order(candidate_ids)

      completion_hits = completion_hits(candidates, graphs, tiers, embedding)

      # The completion read re-fetches the candidates (each candidate sits in
      # its own group); dedupe by id keeping the candidate entry.
      all_hits = Enum.uniq_by(candidate_hits ++ completion_hits, &elem(&1, 0))
      similarity_by_id = Map.new(all_hits)

      candidate_id_set = MapSet.new(candidate_ids)

      completion_only_ids =
        completion_hits
        |> Enum.map(&elem(&1, 0))
        |> Enum.reject(&MapSet.member?(candidate_id_set, &1))
        |> Enum.uniq()

      claims = candidates ++ load_claims_in_order(completion_only_ids)

      resolved = Magus.SuperBrain.Temporal.resolve(claims, now: now)

      # The completion fetch is a (subject_key x predicate) cross product and
      # can over-fetch groups no candidate belongs to; keep only claims that
      # were candidates or share an exact group with one, so completion can
      # promote a superseder but never introduce an unrelated group.
      candidate_groups = MapSet.new(candidates, &{&1.subject_key, &1.predicate})

      relevant? = fn c ->
        MapSet.member?(candidate_id_set, c.id) or
          MapSet.member?(candidate_groups, {c.subject_key, c.predicate})
      end

      current =
        resolved.current
        |> Enum.filter(fn %{claim: c} -> relevant?.(c) end)
        |> Enum.map(fn %{claim: c, score_factors: %{recency: recency}} ->
          similarity = Map.get(similarity_by_id, c.id, 0.0)
          tier_mult = Magus.SuperBrain.Ontology.trust_tier_multiplier(c.trust_tier)
          {c, similarity * tier_mult * recency}
        end)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(limit)
        |> Enum.map(&elem(&1, 0))

      if include_historic do
        historic = Enum.filter(resolved.historic, fn %{claim: c} -> relevant?.(c) end)
        {:ok, %{current: current, historic: historic}}
      else
        {:ok, current}
      end
    else
      if include_historic do
        {:ok, %{current: [], historic: []}}
      else
        {:ok, []}
      end
    end
  end

  # Group-completion inputs derived from the KNN candidates: the distinct
  # subject_keys and predicates whose groups must be completed.
  defp completion_hits([], _graphs, _tiers, _embedding), do: []

  defp completion_hits(candidates, graphs, tiers, embedding) do
    subject_keys = candidates |> Enum.map(& &1.subject_key) |> Enum.uniq()
    predicates = candidates |> Enum.map(& &1.predicate) |> Enum.uniq()

    Magus.SuperBrain.Claim.group_hits_by_embedding(
      graphs,
      subject_keys,
      predicates,
      tiers,
      embedding
    )
  end
```

`load_claims_in_order/1` and `accessible_graphs/2` stay unchanged. Reference `Magus.SuperBrain.Temporal` fully qualified (matching how `Magus.SuperBrain.Claim` and `Magus.SuperBrain.Ontology` are referenced in this file); add no new aliases.

- [ ] **Step 5: Run to verify all Task 2 tests pass**

Run: `mix test test/magus/super_brain/retrieval_claims_test.exs test/magus/super_brain/temporal_test.exs`
Expected: PASS.

- [ ] **Step 6: Run the neighbors that consume search_claims**

Run: `mix test test/magus/super_brain/tools/search_test.exs test/magus/agents/context/super_brain_rag_context_test.exs test/magus/super_brain/kill_switch_test.exs test/magus/super_brain/claim_test.exs test/magus/super_brain/eval/super_brain_retrieval_test.exs`
Expected: PASS (default return shape is unchanged; if `claim_test.exs` referenced `top_ids_by_embedding` it would have shown in the repo grep, and it does not).

The last file is the deterministic eval regression guard (`aggregate == 1.0` for supported cases; every `supported: false` case must still fail). It MUST still pass here even though supersedence now works: the eval subject stamps `DateTime.utc_now()` on every seeded claim until Task 5 honors authored timestamps, so in the `temporal_ship_quarter` fixture the Q3 claim (seeded second) gets the newer stamp and wins, which is NOT the expected Q4. The case therefore keeps failing until Task 5 flips it together with the subject change; do not flip `supported` in this task.

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(super-brain): time-aware search_claims with supersedence and recency

top_hits_by_embedding surfaces (id, similarity) pairs; a
group-completion read fetches every accessible claim in the candidate
(subject_key, predicate) groups (nil embeddings included, similarity
0.0) so the KNN cannot miss a superseder. Temporal.resolve partitions
current vs historic; current is ranked by
similarity x tier multiplier x recency and cross-product completion
groups are post-filtered out. New opts :now and :include_historic.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/super_brain/claim.ex lib/magus/super_brain/retrieval.ex test/magus/super_brain/retrieval_claims_test.exs
```

---

### Task 3: Superseded trailer in the `<super_brain>` context block

**Files:**
- Modify: `lib/magus/agents/context/super_brain_rag_context.ex`
- Test: `test/magus/agents/context/super_brain_rag_context_test.exs` (extend)

**Interfaces:**
- Consumes (from Task 2): `Retrieval.search_claims(user, ..., include_historic: true)` returning `{:ok, %{current: [Claim.t()], historic: [%{claim: Claim.t(), reason: :superseded | :expired | :future}]}}`.
- Produces: `format_with_claims/3` (entities, claims, historic with `historic \\ []` default so existing 2-arity callers and tests keep working).

- [ ] **Step 1: Write the failing tests**

Append to `test/magus/agents/context/super_brain_rag_context_test.exs` (claims here are plain maps; `format_with_claims` is duck-typed and the existing tests in this file already pass maps):

```elixir
  describe "superseded trailers" do
    defp temporal_claim(overrides) do
      Map.merge(
        %{
          subject_key: "aurora",
          subject_name: "Aurora",
          subject_type: "project",
          object_key: "q4",
          object_name: "Q4",
          predicate: "occurs_at",
          polarity: :affirms,
          claim_text: "Aurora now ships in Q4.",
          asserted_at: ~U[2026-06-01 00:00:00Z],
          episode: nil
        },
        Map.new(overrides)
      )
    end

    test "a superseded prior renders as a (was: X) trailer on the current line" do
      current = temporal_claim(%{})

      prior =
        temporal_claim(%{
          object_key: "q3",
          object_name: "Q3",
          claim_text: "Aurora ships in Q3.",
          asserted_at: ~U[2026-05-01 00:00:00Z]
        })

      block =
        Magus.Agents.Context.SuperBrainRagContext.format_with_claims(
          [],
          [current],
          [%{claim: prior, reason: :superseded}]
        )

      assert block =~ ~s(- "Aurora now ships in Q4.")
      assert block =~ "(was: Q3)"
    end

    test "expired and future historic claims produce no trailer and no line" do
      current = temporal_claim(%{})

      expired =
        temporal_claim(%{
          object_key: "q3",
          object_name: "Q3",
          claim_text: "Aurora ships in Q3.",
          asserted_at: ~U[2026-05-01 00:00:00Z]
        })

      block =
        Magus.Agents.Context.SuperBrainRagContext.format_with_claims(
          [],
          [current],
          [%{claim: expired, reason: :expired}]
        )

      refute block =~ "(was:"
      refute block =~ "Aurora ships in Q3."
    end

    test "a superseded re-assertion of the same object renders no trailer" do
      current = temporal_claim(%{})

      same_object_prior =
        temporal_claim(%{
          claim_text: "Aurora ships in Q4 for sure.",
          asserted_at: ~U[2026-05-01 00:00:00Z]
        })

      block =
        Magus.Agents.Context.SuperBrainRagContext.format_with_claims(
          [],
          [current],
          [%{claim: same_object_prior, reason: :superseded}]
        )

      refute block =~ "(was:"
    end

    test "format_with_claims/2 still works (historic defaults to empty)" do
      block =
        Magus.Agents.Context.SuperBrainRagContext.format_with_claims([], [temporal_claim(%{})])

      assert block =~ ~s(- "Aurora now ships in Q4.")
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/magus/agents/context/super_brain_rag_context_test.exs`
Expected: FAIL with `UndefinedFunctionError` for `format_with_claims/3`.

- [ ] **Step 3: Implement the trailer**

In `lib/magus/agents/context/super_brain_rag_context.ex`:

Replace the `search_claims` call in `do_build/3` (lines 65-70) with:

```elixir
        {:ok, %{current: claims, historic: historic}} =
          Retrieval.search_claims(user,
            query_embedding: embedding,
            workspace_context: workspace_context,
            limit: @max_claims,
            include_historic: true
          )
```

Update the emptiness check and the format call right below (lines 72-76) to:

```elixir
        if entities == [] and claims == [] do
          nil
        else
          format_with_claims(entities, claims, historic)
        end
```

Change `format_with_claims/2` to `format_with_claims/3` (keep the `@doc false` comment block; extend its text with one sentence: "Historic entries with reason `:superseded` render as a compact `(was: X)` trailer on the current line of their group; expired and future entries are omitted entirely."):

```elixir
  def format_with_claims(entities, claims, historic \\ []) do
    claims = Enum.take(claims, @max_claims)
    titles = resolve_titles_for_claims(claims)
    superseded = superseded_by_group(historic)
    by_subject = Enum.group_by(claims, & &1.subject_key)
    entity_keys = entities |> Enum.map(&Naming.key(Map.get(&1, :name))) |> MapSet.new()

    entity_sections =
      Enum.map(entities, fn e ->
        key = e |> Map.get(:name) |> Naming.key()
        entity_claims = Map.get(by_subject, key, []) |> Enum.take(@max_claims_per_entity)
        render_entity_section(e, entity_claims, titles, superseded)
      end)

    orphan_sections =
      by_subject
      |> Enum.reject(fn {k, _group} -> MapSet.member?(entity_keys, k) end)
      |> Enum.map(fn {_k, group} -> render_orphan_section(group, titles, superseded) end)

    sections = Enum.join(entity_sections ++ orphan_sections, "\n\n")

    """
    <super_brain>
    Distilled knowledge from your sources relevant to this query (each line cites its source).

    #{sections}
    </super_brain>\
    """
  end
```

Thread the new argument through the section renderers (same functions, one extra parameter):

```elixir
  defp render_orphan_section(group, titles, superseded) do
    first = hd(group)
    name = first.subject_name
    type = Map.get(first, :subject_type) || "?"

    lines =
      group
      |> Enum.take(@max_claims_per_entity)
      |> group_conflicts()
      |> Enum.map(&claim_line(&1, titles, superseded))

    "## #{name} [#{type}]\n" <> Enum.join(lines, "\n")
  end

  defp render_entity_section(e, [], _titles, _superseded), do: format_super_entity(e, %{})

  defp render_entity_section(e, entity_claims, titles, superseded) do
    name = Map.get(e, :name) || "?"
    type = Map.get(e, :primary_type) || Map.get(e, :type) || "?"
    header = "## #{name} [#{type}]"
    lines = entity_claims |> group_conflicts() |> Enum.map(&claim_line(&1, titles, superseded))
    header <> "\n" <> Enum.join(lines, "\n")
  end
```

Update `claim_line` and add the trailer helpers (replace the existing `claim_line/2` clauses):

```elixir
  defp claim_line({:single, c}, titles, superseded) do
    "- \"#{c.claim_text}\" (#{cite(c, titles)})#{was_trailer(c, superseded)}"
  end

  defp claim_line({:conflict, [a, b | _]}, titles, _superseded) do
    "- CONFLICT: \"#{a.claim_text}\" (#{cite(a, titles)}) vs \"#{b.claim_text}\" (#{cite(b, titles)})"
  end

  # Newest superseded prior per (subject_key, predicate) group, for the
  # "(was: X)" trailer. Only :superseded entries produce trailers; expired
  # and future claims are omitted from the block entirely.
  defp superseded_by_group(historic) do
    historic
    |> Enum.filter(&(&1.reason == :superseded))
    |> Enum.group_by(fn %{claim: c} -> {c.subject_key, c.predicate} end)
    |> Map.new(fn {group_key, entries} ->
      newest =
        entries
        |> Enum.map(& &1.claim)
        |> Enum.max_by(&(&1.asserted_at || ~U[1970-01-01 00:00:00Z]), DateTime)

      {group_key, newest}
    end)
  end

  defp was_trailer(c, superseded) do
    case Map.get(superseded, {c.subject_key, c.predicate}) do
      nil ->
        ""

      prior ->
        # A superseded re-assertion of the same object needs no trailer.
        if prior.object_key == c.object_key, do: "", else: " (was: #{prior.object_name})"
    end
  end
```

- [ ] **Step 4: Run to verify all context tests pass**

Run: `mix test test/magus/agents/context/super_brain_rag_context_test.exs`
Expected: PASS (new trailer tests plus every pre-existing test in the file).

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(super-brain): superseded (was: X) trailer in the context block

The context builder asks search_claims for historic claims and renders
the newest superseded prior of each (subject, predicate) group as a
compact trailer on the current line. Expired and future claims are
omitted entirely. format_with_claims/3 defaults historic to [] so
existing callers are unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/agents/context/super_brain_rag_context.ex test/magus/agents/context/super_brain_rag_context_test.exs
```

---

### Task 4: Dossier current-vs-historic split + `get_dossier` history trail

**Files:**
- Modify: `lib/magus/super_brain/dossier.ex`
- Modify: `lib/magus/super_brain/tools/get_dossier.ex`
- Test: `test/magus/super_brain/dossier_test.exs` (extend)
- Test: `test/magus/super_brain/tools/get_dossier_test.exs` (extend)

**Interfaces:**
- Consumes (from Task 1): `Magus.SuperBrain.Temporal.resolve(claims, now: now)`.
- Produces: `Dossier.build/2` result gains a `history: [map()]` key. Input claims may carry `:status` (`:current | :superseded | :expired | :future`); absent status defaults to `:current` so existing callers are unchanged. `facts` / `referenced_by` are built from current claims only; `conflicts` stays computed over ALL claims (a polarity flip is always resolved by supersedence, so a current-only conflict scan would go permanently empty; the contested-triple signal stays and `history` explains which side lost).

**Scope note (spec-consistent):** `get_dossier` resolves ONLY the subject-side claims through `Temporal`. The `:for_entity_keys` fetch is history-complete for the entity's own `(subject, predicate)` groups, but object-side groups (claims where the entity is the object) belong to OTHER subjects whose sibling claims were not fetched, so resolving them would produce false "current" verdicts. Object-side claims pass through untagged (status `:current`), exactly as today.

- [ ] **Step 1: Write the failing Dossier tests**

Append to `test/magus/super_brain/dossier_test.exs` (reuse the file's existing `claim/1` helper):

```elixir
  describe "current-vs-historic split" do
    test "facts come from current claims; historic land in history with status" do
      current =
        claim(%{
          object_key: "q4",
          object_name: "Q4",
          claim_text: "Aurora now ships in Q4.",
          asserted_at: ~U[2026-06-01 00:00:00Z],
          status: :current
        })

      superseded =
        claim(%{
          claim_text: "Aurora ships in Q3.",
          asserted_at: ~U[2026-05-01 00:00:00Z],
          status: :superseded
        })

      d = Dossier.build("aurora", [current, superseded])

      assert [%{other_name: "Q4"}] = d.facts
      assert [%{object_name: "Q3", status: :superseded, predicate: "occurs_at"}] = d.history
    end

    test "expired claims carry the :expired status in history" do
      expired =
        claim(%{
          claim_text: "Aurora uses OldVendor.",
          predicate: "relates_to",
          object_key: "oldvendor",
          object_name: "OldVendor",
          status: :expired
        })

      d = Dossier.build("aurora", [expired])

      assert d.facts == []
      assert [%{status: :expired, object_name: "OldVendor"}] = d.history
    end

    test "history is ordered newest-first by asserted_at" do
      older =
        claim(%{
          object_name: "Q2",
          object_key: "q2",
          asserted_at: ~U[2026-04-01 00:00:00Z],
          status: :superseded
        })

      newer =
        claim(%{
          object_name: "Q3",
          object_key: "q3",
          asserted_at: ~U[2026-05-01 00:00:00Z],
          status: :superseded
        })

      d = Dossier.build("aurora", [older, newer])
      assert Enum.map(d.history, & &1.object_name) == ["Q3", "Q2"]
    end

    test "untagged claims default to current (backward compatible) and history is empty" do
      d = Dossier.build("aurora", [claim(%{})])
      assert [_] = d.facts
      assert d.history == []
    end

    test "conflicts stay computed over all claims, including historic" do
      yes = claim(%{polarity: :affirms, claim_text: "Aurora ships in Q3.", status: :superseded})

      no =
        claim(%{
          polarity: :negates,
          claim_text: "Aurora does not ship in Q3.",
          asserted_at: ~U[2026-06-15 00:00:00Z],
          status: :current
        })

      d = Dossier.build("aurora", [yes, no])
      assert length(d.conflicts) == 1
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/magus/super_brain/dossier_test.exs`
Expected: FAIL (no `history` key in the build result).

- [ ] **Step 3: Implement the Dossier split**

In `lib/magus/super_brain/dossier.ex`, replace `build/2` (lines 11-24, including the `@spec`) with:

```elixir
  @spec build(String.t(), [map()]) :: %{
          facts: [map()],
          referenced_by: [map()],
          history: [map()],
          conflicts: [map()]
        }
  def build(entity_key, claims) do
    # Claims may carry :status from temporal resolution (:current |
    # :superseded | :expired | :future); absent status means current, so
    # pre-temporal callers keep their exact behavior.
    {current, historic} =
      Enum.split_with(claims, &(Map.get(&1, :status, :current) == :current))

    {as_subject, as_object} = Enum.split_with(current, &(&1.subject_key == entity_key))

    %{
      facts: group(as_subject, :object),
      referenced_by: group(as_object, :subject),
      history: history(historic),
      # Conflicts stay computed over ALL claims: a polarity flip is always
      # resolved by supersedence (one side wins), so a current-only conflict
      # scan would go permanently empty. The contested-triple signal stays,
      # and history explains which side lost and why.
      conflicts: conflicts(claims)
    }
  end

  # Non-current claims, newest-first, labeled with why they dropped out.
  # Only subject-side claims arrive tagged (see GetDossier), so the history
  # reads as the entity's own attribute history.
  defp history(historic) do
    historic
    |> Enum.sort_by(&(&1.asserted_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
    |> Enum.map(fn c ->
      %{
        predicate: c.predicate,
        object_key: c.object_key,
        object_name: c.object_name,
        polarity: c.polarity,
        status: c.status,
        claim_text: c.claim_text,
        asserted_at: c.asserted_at
      }
    end)
  end
```

The module's existing `moduledoc` first paragraph gains one sentence at the end: "Claims may arrive tagged with a temporal `:status`; non-current claims are split into a `history` list instead of the fact groups."

- [ ] **Step 4: Run to verify the Dossier tests pass**

Run: `mix test test/magus/super_brain/dossier_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the failing `get_dossier` test**

Append to `test/magus/super_brain/tools/get_dossier_test.exs` (this file already has `seed_claim/3` for simple claims; add the temporal test with its own richer seeding helper to avoid disturbing existing helpers):

```elixir
  test "superseded and expired facts move to the history trail" do
    user = generate(user())
    graph = "memories:user:#{user.id}"

    seed_temporal_claim(graph, user.id, "Aurora ships in Q3.",
      predicate: "occurs_at",
      object: "Q3",
      asserted_at: ~U[2026-05-01 00:00:00Z]
    )

    seed_temporal_claim(graph, user.id, "Aurora now ships in Q4.",
      predicate: "occurs_at",
      object: "Q4",
      asserted_at: ~U[2026-06-01 00:00:00Z]
    )

    seed_temporal_claim(graph, user.id, "Aurora uses OldVendor.",
      predicate: "relates_to",
      object: "OldVendor",
      asserted_at: ~U[2026-05-01 00:00:00Z],
      valid_to: ~U[2026-06-01 00:00:00Z]
    )

    assert {:ok, result} = GetDossier.run(%{entity_name: "Aurora"}, %{user_id: user.id})

    fact_objects = Enum.map(result.facts, & &1.other_name)
    assert "Q4" in fact_objects
    refute "Q3" in fact_objects
    refute "OldVendor" in fact_objects

    statuses = Map.new(result.history, &{&1.object_name, &1.status})
    assert statuses["Q3"] == :superseded
    assert statuses["OldVendor"] == :expired
  end
```

And the helper (append next to the file's existing private helpers, reusing its existing `seed_episode/2` if present; if the file's episode helper has a different name, use that one):

```elixir
  defp seed_temporal_claim(graph, uid, text, opts) do
    ep = seed_episode(graph, uid)
    object = Keyword.fetch!(opts, :object)

    Magus.SuperBrain.Claim
    |> Ash.Changeset.for_create(:create, %{
      graph_name: graph,
      episode_id: ep.id,
      source_user_id: uid,
      subject_name: "Aurora",
      subject_key: "aurora",
      object_name: object,
      object_key: Magus.SuperBrain.Naming.key(object),
      predicate: Keyword.fetch!(opts, :predicate),
      polarity: :affirms,
      claim_text: text,
      confidence: 0.8,
      trust_tier: :evidence,
      asserted_at: Keyword.fetch!(opts, :asserted_at),
      valid_to: Keyword.get(opts, :valid_to),
      embedding: nil
    })
    |> Ash.create(authorize?: false)
  end
```

If `get_dossier_test.exs` has no `seed_episode/2` of its own, copy the exact helper from `test/magus/super_brain/retrieval_claims_test.exs` (lines 40-54).

- [ ] **Step 6: Run to verify failure**

Run: `mix test test/magus/super_brain/tools/get_dossier_test.exs`
Expected: FAIL (Q3 and OldVendor still appear in facts; no `history` key).

- [ ] **Step 7: Wire temporal resolution into `get_dossier`**

In `lib/magus/super_brain/tools/get_dossier.ex`:

Add `Temporal` to the alias line (line 25):

```elixir
  alias Magus.SuperBrain.{AccessibleGraphs, Claim, Dossier, Naming, Retrieval, Temporal}
```

In `build_dossier/4`, replace the block from `if filtered == [] do` through `{:ok, Map.put(d, :entity, name)}` (lines 69-86) with:

```elixir
      if filtered == [] do
        fallback(name, user, context)
      else
        limit = get_param(params, :limit, 20)

        # Temporal resolution runs over the subject-side claims only: the
        # :for_entity_keys fetch is history-complete for THIS entity's
        # (subject, predicate) groups, but object-side groups belong to
        # other subjects whose sibling claims were not fetched, so resolving
        # them would yield false current verdicts. Object-side claims pass
        # through untagged (status defaults to :current in Dossier.build).
        now = DateTime.utc_now()
        {as_subject, as_object} = Enum.split_with(filtered, &(&1.subject_key == key))
        resolved = Temporal.resolve(as_subject, now: now)

        tagged =
          Enum.map(resolved.current, fn %{claim: c} -> {c, :current} end) ++
            Enum.map(resolved.historic, fn %{claim: c, reason: r} -> {c, r} end) ++
            Enum.map(as_object, fn c -> {c, :current} end)

        d =
          Dossier.build(
            key,
            Enum.map(tagged, fn {c, status} ->
              c |> to_dossier_claim() |> Map.put(:status, status)
            end)
          )

        # Cap the returned groups to `limit`. facts / referenced_by / history
        # are already ordered newest-first by Dossier.build, so this keeps the
        # most recent entries. `conflicts` is intentionally left uncapped: it
        # is the conflict summary and should surface every conflicting triple.
        d = %{
          d
          | facts: Enum.take(d.facts, limit),
            referenced_by: Enum.take(d.referenced_by, limit),
            history: Enum.take(d.history, limit)
        }

        {:ok, Map.put(d, :entity, name)}
      end
```

- [ ] **Step 8: Run to verify all Task 4 tests pass**

Run: `mix test test/magus/super_brain/tools/get_dossier_test.exs test/magus/super_brain/dossier_test.exs`
Expected: PASS (new tests plus every pre-existing test; the pre-existing tests seed claims with distinct objects on `relates_to` or single claims, none of which the temporal rules supersede).

- [ ] **Step 9: Commit**

```bash
git commit -m "feat(super-brain): dossier current-vs-historic split with history trail

Dossier.build reads an optional :status tag per claim: current claims
form facts/referenced_by, non-current claims land in a newest-first
history list labeled :superseded/:expired/:future. Conflicts stay
computed over all claims (a polarity flip always resolves, so a
current-only scan would go empty). get_dossier resolves subject-side
claims through Temporal at DateTime.utc_now(); object-side groups are
supersedence-incomplete by fetch construction and pass through
untagged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/super_brain/dossier.ex lib/magus/super_brain/tools/get_dossier.ex test/magus/super_brain/dossier_test.exs test/magus/super_brain/tools/get_dossier_test.exs
```

---

### Task 5: Deterministic eval, flip the temporal xfail, three new temporal cases

**Files:**
- Modify: `lib/magus/eval/super_brain/fixture.ex` (claim parsing gains temporal fields + graph)
- Modify: `lib/magus/eval/benchmarks/super_brain_retrieval.ex` (forward `now` in the fixture payload)
- Modify: `test/support/eval/subject/super_brain_deterministic.ex` (authored timestamps, per-claim graph, `now` threading)
- Modify: `priv/eval/super_brain_retrieval/cases.json` (flip `temporal_ship_quarter` to supported; add three cases)
- Test: `test/magus/eval/super_brain/fixture_test.exs` (extend)
- Test: `test/magus/eval/benchmarks/super_brain_retrieval_test.exs` (update the deterministic count)

**Interfaces:**
- Consumes (from Task 2): `Retrieval.search_claims(user, opts)` with `:now`.
- Produces: `Fixture` claim maps gain `asserted_at` / `valid_from` / `valid_to` (`DateTime.t() | nil`) and `graph` (`String.t() | nil`); the fixture payload carries a top-level `"now"` ISO string the subject stashes on ctx.

**How the eval fits together (context for the implementer):** each case in `cases.json` carries a `fixture` (entities + claims) and authored one-hot embeddings (`{"hot": i}` expands to a 1536-dim one-hot for claims). The benchmark (`super_brain_retrieval.ex`) wraps the fixture in a single `ingest_items` payload; the deterministic subject (`super_brain_deterministic.ex`) seeds it into Postgres/FalkorDB per case (with `reset/1` isolation between cases) and runs the real `Retrieval.search_claims`; `Metrics.score` computes recall@k over `(subject, predicate, object)` triples. The `temporal_ship_quarter` case already exists with `"supported": false` (a tracked xfail): its query embedding sits nearest the STALE Q3 claim while the gold answer is Q4. Task 2's supersedence makes it pass; this task promotes it.

- [ ] **Step 1: Write the failing Fixture test**

Append to `test/magus/eval/super_brain/fixture_test.exs`:

```elixir
  test "claims parse temporal fields and the graph discriminator" do
    raw = %{
      "claims" => [
        %{
          "subject" => "Aurora",
          "predicate" => "occurs_at",
          "object" => "Q4",
          "claim_text" => "Aurora now ships in Q4.",
          "asserted_at" => "2026-06-01T00:00:00Z",
          "valid_from" => "2026-06-01T00:00:00Z",
          "valid_to" => "2026-12-31T00:00:00Z",
          "graph" => "teammate"
        },
        %{
          "subject" => "Aurora",
          "predicate" => "occurs_at",
          "object" => "Q3",
          "claim_text" => "Aurora ships in Q3."
        }
      ]
    }

    fixture = Magus.Eval.SuperBrain.Fixture.parse(raw)
    [with_temporal, without] = fixture.claims

    assert with_temporal.asserted_at == ~U[2026-06-01 00:00:00Z]
    assert with_temporal.valid_from == ~U[2026-06-01 00:00:00Z]
    assert with_temporal.valid_to == ~U[2026-12-31 00:00:00Z]
    assert with_temporal.graph == "teammate"

    assert without.asserted_at == nil
    assert without.valid_from == nil
    assert without.valid_to == nil
    assert without.graph == nil
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/magus/eval/super_brain/fixture_test.exs`
Expected: FAIL with `KeyError` (no `asserted_at` key on the parsed claim).

- [ ] **Step 3: Extend the Fixture parser**

In `lib/magus/eval/super_brain/fixture.ex`, replace `claim/1` (lines 58-69) with:

```elixir
  defp claim(c) do
    %{
      subject: Map.fetch!(c, "subject"),
      predicate: Map.fetch!(c, "predicate"),
      object: Map.fetch!(c, "object"),
      claim_text: Map.fetch!(c, "claim_text"),
      polarity: Map.get(c, "polarity", "affirms"),
      embedding: Map.get(c, "embedding"),
      trust_tier: Map.get(c, "trust_tier", "evidence"),
      confidence: Map.get(c, "confidence", 0.8),
      asserted_at: parse_datetime(Map.get(c, "asserted_at")),
      valid_from: parse_datetime(Map.get(c, "valid_from")),
      valid_to: parse_datetime(Map.get(c, "valid_to")),
      graph: Map.get(c, "graph")
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    {:ok, dt, _offset} = DateTime.from_iso8601(iso)
    dt
  end
```

- [ ] **Step 4: Run to verify the Fixture test passes**

Run: `mix test test/magus/eval/super_brain/fixture_test.exs`
Expected: PASS.

- [ ] **Step 5: Forward `now` through the benchmark**

In `lib/magus/eval/benchmarks/super_brain_retrieval.ex`, extend `fixture_payload` in `to_case/1` (lines 63-67) to:

```elixir
    fixture_payload = %{
      "fixture" => c["fixture"],
      "query_embedding" => c["query_embedding"],
      "claim_query_embedding" => c["claim_query_embedding"],
      "now" => c["now"]
    }
```

- [ ] **Step 6: Teach the deterministic subject authored timestamps, per-claim graphs, and `now`**

In `test/support/eval/subject/super_brain_deterministic.ex`:

Extend `ingest/2`: destructure stays the same, and the returned ctx (lines 62-65) becomes:

```elixir
    {:ok,
     ctx
     |> Map.put(:query_embedding, query_embedding)
     |> Map.put(:claim_query_embedding, expand(Map.get(decoded, "claim_query_embedding")))
     |> Map.put(:now, parse_now(Map.get(decoded, "now")))}
```

Add next to `expand/1` (after line 221):

```elixir
  defp parse_now(nil), do: nil

  defp parse_now(iso) when is_binary(iso) do
    {:ok, dt, _offset} = DateTime.from_iso8601(iso)
    dt
  end
```

Replace the claims branch of `query/2` (lines 70-78) with:

```elixir
    if ctx[:claim_query_embedding] do
      base_opts = [
        query_embedding: ctx.claim_query_embedding,
        accessible_graphs: ["memories:user:#{ctx.user.id}"],
        limit: 10
      ]

      opts = if ctx[:now], do: Keyword.put(base_opts, :now, ctx.now), else: base_opts
      {:ok, claims} = Retrieval.search_claims(ctx.user, opts)

      {:ok, %{answer: "", meta: %{retrieved: Enum.map(claims, &claim_triple/1)}}}
    else
```

Replace `seed_claims/2` (lines 227-256) with:

```elixir
  # Seeds `fixture.claims` under one real Episode per distinct graph:
  # `Claim.episode_id` is a hard DB foreign key, so a fabricated UUID would
  # violate the constraint on insert. The `graph` discriminator lets
  # `temporal_accessor` seed a superseder OUTSIDE the accessor's allow-list
  # (query/2 passes only memories:user:<id>); source_user_id stays the
  # fixture user so reset/1's source_user_id sweep still deletes off-list
  # rows. A no-op when the fixture carries no claims.
  defp seed_claims(_user, %{claims: []}), do: :ok

  defp seed_claims(user, fixture) do
    default_graph = "memories:user:#{user.id}"

    fixture.claims
    |> Enum.group_by(&claim_graph(&1, default_graph))
    |> Enum.each(fn {graph, claims} ->
      ep = seed_episode(graph, user.id)
      Enum.each(claims, &create_claim(&1, graph, ep.id, user.id))
    end)

    :ok
  end

  defp claim_graph(%{graph: nil}, default), do: default
  defp claim_graph(%{graph: name}, _default), do: "eval:offlist:" <> name

  defp create_claim(c, graph, episode_id, user_id) do
    {:ok, _} =
      Claim
      |> Ash.Changeset.for_create(:create, %{
        graph_name: graph,
        episode_id: episode_id,
        source_user_id: user_id,
        subject_name: c.subject,
        subject_key: Naming.key(c.subject),
        object_name: c.object,
        object_key: Naming.key(c.object),
        predicate: c.predicate,
        polarity: String.to_existing_atom(c.polarity),
        claim_text: c.claim_text,
        confidence: c.confidence,
        trust_tier: :evidence,
        asserted_at: c.asserted_at || DateTime.utc_now(),
        valid_from: c.valid_from,
        valid_to: c.valid_to,
        embedding: c.embedding && Fixture.expand_basis(c.embedding)
      })
      |> Ash.create(authorize?: false)
  end
```

- [ ] **Step 7: Flip the xfail and add the three cases**

In `priv/eval/super_brain_retrieval/cases.json`:

1. In the `temporal_ship_quarter` case, change `"supported": false` to `"supported": true`. Nothing else in that case changes (its claims already author `asserted_at`; with no validity fields and single current winner, wall-clock `now` is fine).

2. Append these three case objects to the top-level array:

```json
{
  "id": "temporal_expired_vendor",
  "category": "temporal",
  "supported": true,
  "target": "claims",
  "subjects": ["deterministic"],
  "query": "which vendor does Aurora use",
  "query_embedding": [0, 0, 0, 0, 0, 0, 0, 0],
  "claim_query_embedding": { "hot": 11 },
  "now": "2026-07-01T00:00:00Z",
  "k": 1,
  "expected": [
    { "subject": "Aurora", "predicate": "relates_to", "object": "NewVendor" }
  ],
  "fixture": {
    "entities": [
      {
        "key": "aurora",
        "name": "Aurora",
        "type": "project",
        "embedding": [1, 0, 0, 0, 0, 0, 0, 0]
      }
    ],
    "edges": [],
    "sources": [],
    "claims": [
      {
        "subject": "Aurora",
        "predicate": "relates_to",
        "object": "OldVendor",
        "claim_text": "Aurora uses OldVendor for hosting.",
        "embedding": { "hot": 11 },
        "asserted_at": "2026-06-20T00:00:00Z",
        "valid_to": "2026-06-30T00:00:00Z"
      },
      {
        "subject": "Aurora",
        "predicate": "relates_to",
        "object": "NewVendor",
        "claim_text": "Aurora uses NewVendor for hosting.",
        "embedding": { "hot": 13 },
        "asserted_at": "2026-06-25T00:00:00Z"
      }
    ]
  }
},
{
  "id": "temporal_multivalued_vendors",
  "category": "temporal",
  "supported": true,
  "target": "claims",
  "subjects": ["deterministic"],
  "query": "what does Aurora relate to",
  "query_embedding": [0, 0, 0, 0, 0, 0, 0, 0],
  "claim_query_embedding": { "hot": 17 },
  "k": 2,
  "expected": [
    { "subject": "Aurora", "predicate": "relates_to", "object": "VendorA" },
    { "subject": "Aurora", "predicate": "relates_to", "object": "VendorB" }
  ],
  "fixture": {
    "entities": [
      {
        "key": "aurora",
        "name": "Aurora",
        "type": "project",
        "embedding": [1, 0, 0, 0, 0, 0, 0, 0]
      }
    ],
    "edges": [],
    "sources": [],
    "claims": [
      {
        "subject": "Aurora",
        "predicate": "relates_to",
        "object": "VendorA",
        "claim_text": "Aurora relates to VendorA.",
        "embedding": { "hot": 17 },
        "asserted_at": "2026-05-01T00:00:00Z"
      },
      {
        "subject": "Aurora",
        "predicate": "relates_to",
        "object": "VendorB",
        "claim_text": "Aurora relates to VendorB.",
        "embedding": { "hot": 19 },
        "asserted_at": "2026-06-01T00:00:00Z"
      }
    ]
  }
},
{
  "id": "temporal_accessor_ship_quarter",
  "category": "temporal",
  "supported": true,
  "target": "claims",
  "subjects": ["deterministic"],
  "query": "when does Aurora ship",
  "query_embedding": [0, 0, 0, 0, 0, 0, 0, 0],
  "claim_query_embedding": { "hot": 23 },
  "k": 1,
  "expected": [
    { "subject": "Aurora", "predicate": "occurs_at", "object": "Q3" }
  ],
  "fixture": {
    "entities": [
      {
        "key": "aurora",
        "name": "Aurora",
        "type": "project",
        "embedding": [1, 0, 0, 0, 0, 0, 0, 0]
      }
    ],
    "edges": [],
    "sources": [],
    "claims": [
      {
        "subject": "Aurora",
        "predicate": "occurs_at",
        "object": "Q3",
        "claim_text": "Aurora ships in Q3.",
        "embedding": { "hot": 23 },
        "asserted_at": "2026-05-01T00:00:00Z"
      },
      {
        "subject": "Aurora",
        "predicate": "occurs_at",
        "object": "Q4",
        "claim_text": "Aurora now ships in Q4.",
        "embedding": { "hot": 29 },
        "asserted_at": "2026-06-01T00:00:00Z",
        "graph": "teammate"
      }
    ]
  }
}
```

Case design intent, for review: `temporal_expired_vendor` isolates validity (multi-valued predicate so supersedence cannot mask it; the expired claim is the query's nearest neighbor). `temporal_multivalued_vendors` pins that multi-valued facts coexist (no false supersedence; both objects retrieved at k 2). `temporal_accessor_ship_quarter` pins accessor-relativity (the Q4 superseder sits in an off-allow-list graph, so Q3 stays current FOR THIS ACCESSOR; this is the property that justified query-time resolution).

- [ ] **Step 8: Update the deterministic-count regression test**

In `test/magus/eval/benchmarks/super_brain_retrieval_test.exs`, replace lines 23-25:

```elixir
    # 9 cases include "deterministic" in subjects (local_lookup, contradiction,
    # attribution, multi_hop, claim_recall, temporal_ship_quarter,
    # temporal_expired, temporal_multivalued, temporal_accessor)
    assert length(det) == 9
```

- [ ] **Step 9: Run the eval-adjacent suites**

Run: `mix test test/magus/eval test/magus/super_brain`
Expected: PASS. `test/magus/super_brain/eval/super_brain_retrieval_test.exs` is the end-to-end deterministic regression guard: it runs the FULL deterministic eval (including the flipped case and the three new ones) and asserts `run.aggregate == 1.0` over supported cases plus `refute c.correct?` for every remaining `supported: false` case (only `multi_hop_team` after this task). Its assertions are generic, so it needs NO edit; it is how the spec's "supported aggregate stays 1.0 with temporal in the supported set" criterion is enforced. If it fails here, the temporal cases themselves are wrong; fix the cases or the subject, not the guard.

- [ ] **Step 10: Commit**

```bash
git commit -m "test(eval): temporal eval cases; flip the temporal xfail to supported

Fixture claims parse asserted_at / valid_from / valid_to and an
optional graph discriminator; the benchmark forwards a per-case now
that the deterministic subject threads into search_claims. Three new
supported cases pin expired-validity exclusion, multi-valued
coexistence, and accessor-relative supersedence; temporal_ship_quarter
is promoted from known-gap to supported.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/eval/super_brain/fixture.ex lib/magus/eval/benchmarks/super_brain_retrieval.ex test/support/eval/subject/super_brain_deterministic.ex priv/eval/super_brain_retrieval/cases.json test/magus/eval/super_brain/fixture_test.exs test/magus/eval/benchmarks/super_brain_retrieval_test.exs
```

---

### Task 6: Live temporal eval case (`:e2e_live`)

**Files:**
- Modify: `test/support/eval/subject/super_brain_live.ex` (authored temporal fields when seeding claims)
- Modify: `priv/eval/super_brain_retrieval/cases.json` (add one live-only case)
- Modify: `test/e2e_live/super_brain_retrieval_eval_test.exs` (assert the temporal live case)
- Modify: `test/magus/eval/benchmarks/super_brain_retrieval_test.exs` (only if its deterministic count assertion would change: it does NOT; the new case is live-only)

**Interfaces:**
- Consumes (from Task 5): `Fixture` claim maps with `asserted_at` / `valid_from` / `valid_to` (the live subject ignores `graph`; the accessor case is deterministic-only by design).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Add the live case to `priv/eval/super_brain_retrieval/cases.json`**

Append to the top-level array:

```json
{
  "id": "temporal_ship_quarter_live",
  "category": "temporal",
  "supported": true,
  "target": "claims",
  "subjects": ["live"],
  "query": "when does project Aurora ship",
  "query_embedding": [0, 0, 0, 0, 0, 0, 0, 0],
  "claim_query_embedding": { "hot": 7 },
  "k": 1,
  "expected": [
    { "subject": "Aurora", "predicate": "occurs_at", "object": "Q4" }
  ],
  "fixture": {
    "entities": [
      {
        "key": "aurora",
        "name": "Aurora",
        "type": "project",
        "embedding": [1, 0, 0, 0, 0, 0, 0, 0]
      }
    ],
    "edges": [],
    "sources": [],
    "claims": [
      {
        "subject": "Aurora",
        "predicate": "occurs_at",
        "object": "Q3",
        "claim_text": "Aurora ships in the third quarter.",
        "asserted_at": "2026-05-01T00:00:00Z"
      },
      {
        "subject": "Aurora",
        "predicate": "occurs_at",
        "object": "Q4",
        "claim_text": "The Aurora ship date moved to Q4.",
        "asserted_at": "2026-06-01T00:00:00Z"
      }
    ]
  }
}
```

Design intent: with REAL embeddings both claim texts sit near the query, so which one the KNN ranks first is not guaranteed; supersedence makes k=1 return the current Q4 either way. That embedding-independence is exactly what makes this a robust live case. (`claim_query_embedding` is present only to route the live subject down its claims branch; the live subject embeds the query text for real.)

- [ ] **Step 2: Seed authored temporal fields in the live subject**

In `test/support/eval/subject/super_brain_live.ex`, in `seed_claims/2`'s `Ash.Changeset.for_create` map (lines 149-164), replace the line

```elixir
          asserted_at: DateTime.utc_now(),
```

with

```elixir
          asserted_at: c.asserted_at || DateTime.utc_now(),
          valid_from: c.valid_from,
          valid_to: c.valid_to,
```

- [ ] **Step 3: Assert the temporal case in the e2e test**

In `test/e2e_live/super_brain_retrieval_eval_test.exs`, after the `claim_case` assertions (line 32) and before the `assert run.aggregate == 1.0` line, add:

```elixir
    temporal_case = Enum.find(run.per_case, &(&1.id == "temporal_ship_quarter_live"))

    assert temporal_case,
           "expected the live temporal case in the run (cases.json subjects must include \"live\")"

    assert temporal_case.recall_at_k == 1.0,
           "temporal graded at #{temporal_case.recall_at_k}: supersedence must return Q4 at k=1"
```

- [ ] **Step 4: Verify the deterministic suites still pass (no live env needed)**

Run: `mix test test/magus/eval test/magus/super_brain`
Expected: PASS; the deterministic count assertion stays 9 (the new case is live-only and filtered out by `subject_kind: :deterministic`).

- [ ] **Step 5: Run the live eval (requires `OPENROUTER_API_KEY` in `.env`)**

Run: `bin/test-e2e-live test/e2e_live/super_brain_retrieval_eval_test.exs`
Expected: PASS, including the new temporal assertion at recall 1.0 and `run.aggregate == 1.0`. If the environment has no key, report this step as blocked instead of skipping silently.

- [ ] **Step 6: Commit**

```bash
git commit -m "test(eval): live temporal case for the e2e retrieval eval

The live subject seeds authored asserted_at / validity windows; a new
live-only occurs_at case proves supersedence returns the current Q4 at
k=1 with real embeddings regardless of which claim text the KNN ranks
first.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- test/support/eval/subject/super_brain_live.ex priv/eval/super_brain_retrieval/cases.json test/e2e_live/super_brain_retrieval_eval_test.exs
```

---

### Task 7: Documentation

**Files:**
- Modify: `docs/system/15-super-brain.md`

**Interfaces:**
- Consumes: the shipped behavior of Tasks 1-6 (documentation only; verify names against the code, do not invent).
- Produces: nothing.

- [ ] **Step 1: Add the temporal section**

In `docs/system/15-super-brain.md`, inside the `## Retrieval Pipeline` section (it ends before `## Per-episode ...` at line 273), append this subsection at the end of the Retrieval Pipeline content:

```markdown
### Temporal ranking (current vs historic)

Claim retrieval is time-aware. `Magus.SuperBrain.Temporal` (pure, `now`
injected, no I/O) resolves the accessor's accessible claims into `current`
and `historic` at query time:

1. **Validity partition**: `valid_to` before `now` marks a claim `:expired`;
   `valid_from` after `now` marks it `:future`. Both go historic.
2. **Supersedence** (in-window claims only):
   - Value-change: same `(subject_key, predicate)`, predicate in
     `Ontology.single_valued_predicates/0` (seeded with `occurs_at`), BOTH
     claims `:affirms`, newest wins. Checked via
     `Ontology.single_valued_predicate?/1` (string-space; `Claim.predicate`
     is a string, ontology lists are atoms).
   - Polarity flip: opposite polarity on the exact same triple, newest wins.
   - "Newer" = `asserted_at` desc, then `valid_from` desc (nil oldest), then
     id desc (UUIDv7, time-ordered).
3. **Recency**: `0.5 + 0.5 * exp(-age_days * ln(2) / 90)` on `asserted_at`,
   floored at 0.5.

`Retrieval.search_claims/2` runs a two-step fetch so the KNN cannot miss a
superseder: pgvector candidates (`Claim.top_hits_by_embedding/4`, now
returning `(id, similarity)` pairs), then one batched group-completion read
of ALL accessible claims in the candidate `(subject_key, predicate)` groups
(`Claim.group_hits_by_embedding/5`; nil-embedding claims included at
similarity 0.0 so an unembedded superseder still resolves). Ranked score:
`vector_similarity x trust_tier_multiplier x recency_factor`. Superseded and
expired claims are excluded from the default result, never merely
down-weighted.

Because resolution runs over only the accessor's allow-listed graphs,
supersedence is accessor-relative: a superseder in a graph the reader cannot
access does not hide the claim they can read.

Options: `:now` (pinned by the deterministic eval), `:include_historic`
(default false; when true the return is
`{:ok, %{current: [...], historic: [%{claim: c, reason: :superseded |
:expired | :future}]}}`).

Surfacing: the `<super_brain>` context block appends a `(was: X)` trailer to
a current line whose group has a superseded prior (expired claims are
omitted); `get_dossier` splits facts (current) from a `history` trail with
per-entry status, resolving subject-side claims only (object-side groups are
supersedence-incomplete by fetch construction).
```

- [ ] **Step 2: Update the Claims section pointer**

In the `## Claims (Layer 0 propositional store)` section of the same file, append one paragraph at the end of that section (before `### Authorization` at line 185):

```markdown
Temporal fields (`asserted_at`, `valid_from`, `valid_to`) drive query-time
temporal ranking; see "Temporal ranking (current vs historic)" under the
Retrieval Pipeline. `asserted_at` is stamped at extraction write time, so
re-extracting old content restamps it: supersedence prefers the
most-recently-extracted statement, the correct default for "what does the
system currently believe".
```

- [ ] **Step 3: Add the Key Files entry**

In the `## Key Files` section at the bottom of the same file, add one line alongside the existing entries, matching their format:

```markdown
- `lib/magus/super_brain/temporal.ex`: pure query-time temporal resolution (validity, supersedence, recency)
```

- [ ] **Step 4: Verify the docs contain no em dashes and the referenced names exist**

Run: `grep -n $'—\|–' docs/system/15-super-brain.md; echo "exit: $?"`
Expected: `exit: 1` (no matches).

Run: `grep -rn "single_valued_predicate?\|top_hits_by_embedding\|group_hits_by_embedding" lib/magus/super_brain/ | head -5`
Expected: matches in `ontology.ex` and `claim.ex` (the documented names exist).

- [ ] **Step 5: Commit**

```bash
git commit -m "docs(super-brain): document temporal ranking

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- docs/system/15-super-brain.md
```

---

## Final verification (after all tasks)

- [ ] Run the full feature suite: `mix test test/magus/super_brain test/magus/eval test/magus/agents/context/super_brain_rag_context_test.exs`
  Expected: 0 failures.
- [ ] Run the compile gate: `MIX_ENV=test mix compile --warnings-as-errors`
  Expected: clean.
- [ ] Run `mix format --check-formatted` on the touched files; run `mix format` if needed and amend.
- [ ] Confirm no migration was generated: `git status priv/repo/migrations` shows no new files.
- [ ] Grep every feature commit for em dashes: `git log main..HEAD -p | grep -c $'—'` prints `0` (when executing directly on main, substitute the first feature commit for `main`).
