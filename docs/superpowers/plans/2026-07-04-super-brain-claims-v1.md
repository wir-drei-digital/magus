# Super Brain Claims v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make claims (subject-predicate-object statements carrying the supporting sentence, provenance, polarity, and time) the first-class knowledge unit of the Super Brain: stored in Postgres, recalled by embedding, and consumed through a rewritten context block and a `get_dossier` tool.

**Architecture:** A new `Magus.SuperBrain.Claim` Ash resource (Postgres + pgvector) is populated by the existing extraction pipeline, whose prompt now emits claims instead of bare edges. L1 `RELATES_TO` edges are derived from claims, so the FalkorDB builders are untouched. Retrieval gains a pgvector claim search beside the existing entity KNN; the `<super_brain>` context block and a new dossier tool render claims with citations.

**Tech Stack:** Elixir, Ash 3.x + AshPostgres, pgvector (via `Magus.Files.Types.Vector` + raw Ecto for KNN), FalkorDB (unchanged), Jido tools, Oban, ExUnit + Mox.

## Global Constraints

- **No em dashes** in any code, comment, doc, or commit message. Use colons, periods, or commas.
- **Never run `mix ash.reset`.** Use `mix ash.codegen` + `mix ash.migrate`, or direct SQL.
- **Scope every commit** with `git commit -- <paths>` (shared checkout with concurrent agents). Never `git add -A` / `git add .`.
- **End commit messages** with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Verify `MIX_ENV=test mix compile --warnings-as-errors`** before every commit (CI compiles warnings-as-errors; per-edit hooks do not).
- **Nullable NimbleOptions/Ash tool schema fields** must use `{:or, [<type>, nil]}`, never a bare type with `default: nil`.
- **Test-DB hygiene:** the shared test DB carries committed leaked rows (super graphs, users, models). Scope every assertion to rows the test seeds (unique names / email prefixes / ids). Never assert global table counts.
- **Super Brain internal writes** use `authorize?: false` (documented pattern; the auth boundary is `Magus.SuperBrain.AccessibleGraphs`, not Ash policy).
- **German localization** (not used in this plan) stays informal (du), if any copy is added.
- **Concurrency:** a concurrent session may hold `lib/magus/application.ex` and other files uncommitted in the working tree. Only stage the exact paths each task lists.
- **One shared name-key helper.** Name-key normalization (downcase, collapse whitespace, trim) lives in exactly one place: `Magus.SuperBrain.Naming.key/1` (created in Task 1). Every task below that shows a local `entity_key/1`, `key/1`, or `claim_key/1` helper is a placeholder for a call to `Magus.SuperBrain.Naming.key/1`: use the shared function, do not redefine the logic per file. A subject_key / object_key is always `Naming.key(name)`.

## Test setup conventions

Several test files below use `user_fixture()`, a `:user`-scoped `Memory`, brains, and a local `seed_claim/3`. Concrete rules for the implementer (a fresh agent per task):

- **Users / memories / brains / drafts** are created via `Magus.Generators` (the project's test factory). For any test that needs one, open the nearest sibling test in the same directory (for extraction workers: the existing `test/magus/super_brain/workers/extract_*_test.exs`; for retrieval: `test/magus/super_brain/retrieval_test.exs`) and mirror its setup verbatim. Do not invent generator function names; copy the ones the sibling test uses.
- **`seed_claim/3`** is shown in full in Task 5. Copy that helper locally into each test file that needs to seed claims (Tasks 5, 8). Do not rely on it being shared across files: subagent-driven execution gives each task a fresh context.
- **DB case:** claim tests are pure Postgres, so `use Magus.DataCase, async: false` (match the sibling files; some are `async: false` because of the shared FalkorDB/DB state).
- **Scope every assertion to seeded rows** (unique names / ids), never global counts (see Global Constraints).
- **Every `Claim` needs a real `Episode`.** `Claim.episode_id` is a hard DB foreign key (`belongs_to :episode`, `allow_nil? false`), so a fabricated `Ash.UUID.generate()` episode id violates the constraint on insert. Before seeding any claim (in tests and in the eval subjects), create an Episode and use its id. Shared helper to copy locally where needed:

```elixir
defp seed_episode(graph_name, user_id) do
  {:ok, ep} =
    Magus.SuperBrain.Episode
    |> Ash.Changeset.for_create(:create, %{
      resource_type: :memory,
      resource_id: Ash.UUID.generate(),
      graph_name: graph_name,
      raw_text: "seed",
      source_user_id: user_id,
      extractor_version: "test"
    })
    |> Ash.create(authorize?: false)

  ep
end
```

The claim's `graph_name` / `source_user_id` should match the episode's for coherence. In the eval subjects (Tasks 12, 13), create ONE episode per case (in `ingest`) and reuse its id for every claim seeded that case.

---

## File Structure

**New files:**
- `lib/magus/super_brain/claim.ex`: the `Claim` Ash resource + `top_ids_by_embedding/4` raw-SQL KNN helper.
- `lib/magus/super_brain/dossier.ex`: pure grouping/conflict/ordering over claim maps.
- `lib/magus/super_brain/tools/get_dossier.ex`: Jido tool wrapping `Dossier`.
- `lib/mix/tasks/super_brain.backfill_claims.ex`: on-demand re-extraction of pre-claims content.
- Test files mirroring each (paths given per task).

**Modified files:**
- `lib/magus/super_brain.ex`: register the `Claim` resource.
- `lib/magus/super_brain/extraction/prompt.ex`: claims section, remove edge-density quota.
- `lib/magus/super_brain/extraction/sanitizer.ex`: `sanitize_claim/1`.
- `lib/magus/super_brain/extraction.ex`: parse `claims`, derive `edges`, drop sparse-edge telemetry.
- `lib/magus/super_brain/workers/extract_base.ex`: persist claims, supersede-delete claims, `force` gate, claim-embedding helper, telemetry counts.
- `lib/magus/super_brain/workers/{extract_brain_page,extract_memory,extract_file_chunk,extract_draft,ingest_brain_connection}.ex`: bump `extractor_version/0`.
- `lib/magus/super_brain/retrieval.ex`: `search_claims/2` + `:accessible_graphs` sharing.
- `lib/magus/agents/context/super_brain_rag_context.ex`: claim-centered render.
- `lib/magus/super_brain/tools/search.ex`: top claims in output + description.
- `lib/magus/agents/tools/rag.ex`, `lib/magus/agents/tools/memory/search_memories.ex`: description disambiguation.
- `lib/magus/agents/tools/tool_builder.ex`: register `GetDossier`.
- `lib/magus/eval/super_brain/metrics.ex`, `fixture.ex`: claim scoring + claim fixtures.
- `test/support/eval/subject/super_brain_deterministic.ex`, `super_brain_live.ex`: seed claims.
- `priv/eval/super_brain_retrieval/cases.json`: `claim_recall` + `temporal` cases.
- `docs/system/15-super-brain.md`: document the claims layer.

---

## Task 1: Claim resource + migration

**Files:**
- Create: `lib/magus/super_brain/claim.ex`
- Create: `lib/magus/super_brain/naming.ex`
- Modify: `lib/magus/super_brain.ex` (register resource)
- Create: `priv/repo/migrations/<generated>_add_super_brain_claims.exs` (via codegen + hand-edit)
- Create: `test/magus/super_brain/claim_test.exs`

**Interfaces:**
- Produces: `Magus.SuperBrain.Claim` resource with actions `:create`, `:bulk_create`, `:read`, `:for_graphs` (arg `graph_names: {:array, :string}`), `:for_entity_keys` (args `keys: {:array, :string}`, `graph_names: {:array, :string}`). Attributes listed below.
- Produces: `Magus.SuperBrain.Claim.top_ids_by_embedding(embedding :: [float], graph_names :: [String.t()], tiers :: [String.t()], limit :: integer) :: [binary]` (ids in cosine-distance order).

- [ ] **Step 1: Write the failing test**

`test/magus/super_brain/claim_test.exs`:

```elixir
defmodule Magus.SuperBrain.ClaimTest do
  use Magus.DataCase, async: false

  alias Magus.SuperBrain.Claim

  defp episode_id, do: Ash.UUID.generate()

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        graph_name: "brain:#{Ash.UUID.generate()}",
        episode_id: episode_id(),
        source_user_id: Ash.UUID.generate(),
        subject_name: "Project Aurora",
        subject_type: "project",
        subject_key: "project aurora",
        object_name: "Q3",
        object_type: "date",
        object_key: "q3",
        predicate: "occurs_at",
        polarity: :affirms,
        claim_text: "Aurora targets Q3.",
        confidence: 0.8,
        trust_tier: :evidence,
        asserted_at: DateTime.utc_now()
      },
      overrides
    )
  end

  test "creates a claim with all fields" do
    assert {:ok, claim} =
             Claim
             |> Ash.Changeset.for_create(:create, valid_attrs())
             |> Ash.create(authorize?: false)

    assert claim.polarity == :affirms
    assert claim.claim_text == "Aurora targets Q3."
  end

  test "claim_text longer than 500 chars is rejected" do
    attrs = valid_attrs(%{claim_text: String.duplicate("x", 501)})

    assert {:error, _} =
             Claim
             |> Ash.Changeset.for_create(:create, attrs)
             |> Ash.create(authorize?: false)
  end

  test "for_graphs returns only claims whose graph_name is in the allow-list" do
    g1 = "brain:#{Ash.UUID.generate()}"
    g2 = "brain:#{Ash.UUID.generate()}"

    {:ok, _} = Claim |> Ash.Changeset.for_create(:create, valid_attrs(%{graph_name: g1})) |> Ash.create(authorize?: false)
    {:ok, _} = Claim |> Ash.Changeset.for_create(:create, valid_attrs(%{graph_name: g2})) |> Ash.create(authorize?: false)

    {:ok, rows} =
      Claim
      |> Ash.Query.for_read(:for_graphs, %{graph_names: [g1]})
      |> Ash.read(authorize?: false)

    assert Enum.all?(rows, &(&1.graph_name == g1))
    assert length(rows) >= 1
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/super_brain/claim_test.exs`
Expected: FAIL, `Magus.SuperBrain.Claim` is undefined.

- [ ] **Step 3: Create the resource**

`lib/magus/super_brain/claim.ex`:

```elixir
defmodule Magus.SuperBrain.Claim do
  @moduledoc """
  A Claim is one extracted subject-predicate-object statement plus the sentence
  that supports it, its provenance (episode), polarity, confidence, trust tier,
  and optional validity window. Claims are the propositional layer over the
  entity graph: retrieval embeds and recalls `claim_text`, and the dossier tool
  aggregates them per entity.

  Authorization boundary is `Magus.SuperBrain.AccessibleGraphs`: every read path
  filters by `graph_name in <accessible graphs>`. The resource is internal; the
  extraction pipeline and retrieval call it with `authorize?: false`.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.SuperBrain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  @max_claim_text 500

  postgres do
    table "super_brain_claims"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :graph_name,
        :episode_id,
        :source_user_id,
        :subject_name,
        :subject_type,
        :subject_key,
        :object_name,
        :object_type,
        :object_key,
        :predicate,
        :polarity,
        :claim_text,
        :confidence,
        :trust_tier,
        :asserted_at,
        :valid_from,
        :valid_to,
        :embedding
      ]
    end

    create :bulk_create do
      accept [
        :graph_name,
        :episode_id,
        :source_user_id,
        :subject_name,
        :subject_type,
        :subject_key,
        :object_name,
        :object_type,
        :object_key,
        :predicate,
        :polarity,
        :claim_text,
        :confidence,
        :trust_tier,
        :asserted_at,
        :valid_from,
        :valid_to,
        :embedding
      ]
    end

    read :for_graphs do
      argument :graph_names, {:array, :string}, allow_nil?: false
      filter expr(graph_name in ^arg(:graph_names))
    end

    read :for_entity_keys do
      argument :keys, {:array, :string}, allow_nil?: false
      argument :graph_names, {:array, :string}, allow_nil?: false

      filter expr(
               graph_name in ^arg(:graph_names) and
                 (subject_key in ^arg(:keys) or object_key in ^arg(:keys))
             )
    end
  end

  policies do
    bypass action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if expr(source_user_id == ^actor(:id))
    end

    # Claims are written only by the extraction pipeline (authorize?: false).
    # Deny user-facing writes so a stray actor: caller fails loud.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :graph_name, :string, allow_nil?: false, public?: true
    attribute :episode_id, :uuid, allow_nil?: false, public?: true
    attribute :source_user_id, :uuid, allow_nil?: false, public?: true

    attribute :subject_name, :string, allow_nil?: false, public?: true
    attribute :subject_type, :string, allow_nil?: true, public?: true
    attribute :subject_key, :string, allow_nil?: false, public?: true

    attribute :object_name, :string, allow_nil?: false, public?: true
    attribute :object_type, :string, allow_nil?: true, public?: true
    attribute :object_key, :string, allow_nil?: false, public?: true

    attribute :predicate, :string, allow_nil?: false, public?: true

    attribute :polarity, :atom do
      allow_nil? false
      default :affirms
      public? true
      constraints one_of: [:affirms, :negates]
    end

    attribute :claim_text, :string do
      allow_nil? false
      public? true
      constraints max_length: @max_claim_text
    end

    attribute :confidence, :float, allow_nil?: true, public?: true

    attribute :trust_tier, :atom do
      allow_nil? false
      default :evidence
      public? true
      constraints one_of: [:instruction, :evidence, :noise]
    end

    attribute :asserted_at, :utc_datetime, allow_nil?: true, public?: true
    attribute :valid_from, :utc_datetime, allow_nil?: true, public?: true
    attribute :valid_to, :utc_datetime, allow_nil?: true, public?: true

    attribute :embedding, Magus.Files.Types.Vector, allow_nil?: true, public?: true

    timestamps()
  end

  relationships do
    belongs_to :episode, Magus.SuperBrain.Episode do
      source_attribute :episode_id
      define_attribute? false
      attribute_writable? false
    end
  end

  @doc """
  Top-N claim ids by cosine distance to `embedding`, filtered to the given
  `graph_names` allow-list and `tiers` (string trust tiers). Mirrors
  `Magus.Files.Chunk.top_chunk_ids/3`: the vector is passed as a single Pgvector
  binary parameter so the HNSW index is usable and the SQL string stays small.
  """
  @spec top_ids_by_embedding([float()], [String.t()], [String.t()], integer()) :: [binary()]
  def top_ids_by_embedding([], _graph_names, _tiers, _limit), do: []
  def top_ids_by_embedding(_embedding, [], _tiers, _limit), do: []
  def top_ids_by_embedding(_embedding, _graph_names, [], _limit), do: []

  def top_ids_by_embedding(embedding, graph_names, tiers, limit) do
    import Ecto.Query

    vector = Pgvector.new(embedding)

    from(c in "super_brain_claims",
      where: not is_nil(c.embedding),
      where: c.graph_name in ^graph_names,
      where: c.trust_tier in ^tiers,
      select: c.id,
      order_by: [asc: fragment("? <=> ?", c.embedding, ^vector)],
      limit: ^limit
    )
    |> Magus.Repo.all()
    |> Enum.map(&Ecto.UUID.load!/1)
  end
end
```

- [ ] **Step 3a: Create the shared name-key helper**

`lib/magus/super_brain/naming.ex`:

```elixir
defmodule Magus.SuperBrain.Naming do
  @moduledoc """
  Shared name-key normalization for claims. A key is the downcased,
  whitespace-collapsed, trimmed form of an entity name, used as `subject_key` /
  `object_key` and for grouping claims by entity. Defined once so every call
  site (extraction, retrieval, dossier, context, eval subjects) agrees.
  """

  @spec key(term()) :: String.t()
  def key(name) when is_binary(name) do
    name |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  def key(_), do: ""
end
```

- [ ] **Step 4: Register the resource in the domain**

In `lib/magus/super_brain.ex`, inside the `resources do ... end` block, after the `resource Magus.SuperBrain.SuperGraph do ... end` block, add:

```elixir
    resource Magus.SuperBrain.Claim
```

- [ ] **Step 5: Generate the migration**

Run: `MIX_ENV=test mix ash.codegen add_super_brain_claims`
This creates `priv/repo/migrations/<ts>_add_super_brain_claims.exs` and a resource snapshot.

- [ ] **Step 6: Hand-edit the migration for the vector column + HNSW index**

Ash's codegen writes the `embedding` column as bare `:vector` and does NOT create a pgvector index (custom index, same as `file_chunks`). Open the generated migration. Ensure the embedding column is created as `vector(1536)` (replace the generated `add :embedding, :vector` line inside `create table` with the raw execute below if codegen did not size it), and append the HNSW cosine index at the end of `up` (and a matching drop in `down`):

```elixir
    # pgvector: size the embedding column and add an HNSW cosine index,
    # mirroring file_chunks (Ash cannot express either through the snapshot).
    execute "ALTER TABLE super_brain_claims ALTER COLUMN embedding TYPE vector(1536)"

    execute """
    CREATE INDEX super_brain_claims_embedding_idx ON super_brain_claims
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """
```

In `down`, before the table drop, add:

```elixir
    execute "DROP INDEX IF EXISTS super_brain_claims_embedding_idx"
```

Also confirm the generated migration indexes `graph_name`, `subject_key`, `object_key`, `episode_id`, and `source_user_id` (add `create index(:super_brain_claims, [:col])` lines if codegen omitted any; these back the `for_graphs` / `for_entity_keys` / cleanup queries).

- [ ] **Step 7: Run the migration**

Run: `MIX_ENV=test mix ash.migrate`
Expected: migration applies, no error.

- [ ] **Step 8: Run the test to verify it passes**

Run: `MIX_ENV=test mix test test/magus/super_brain/claim_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 9: Compile check + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git commit -- lib/magus/super_brain/claim.ex lib/magus/super_brain/naming.ex lib/magus/super_brain.ex test/magus/super_brain/claim_test.exs priv/repo/migrations priv/resource_snapshots -m "feat(super-brain): Claim resource + pgvector table

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Claim sanitizer (pure)

**Files:**
- Modify: `lib/magus/super_brain/extraction/sanitizer.ex`
- Modify: `test/magus/super_brain/extraction/sanitizer_test.exs` (create if absent)

**Interfaces:**
- Consumes: `Magus.SuperBrain.Ontology.classify_predicate/1` (existing).
- Produces: `Sanitizer.sanitize_claim(map) :: map | :skip`. Input keys (string or atom): `subject_name`, `object_name`, `predicate`, `polarity`, `claim_text`, `confidence`, optional `valid_from`, `valid_to`. Returns `:skip` when subject/object/claim_text empty after trim. Output map keys: `:subject_name`, `:object_name`, `:predicate` (snake_case string), `:polarity` (`:affirms | :negates`), `:claim_text` (<=500), `:confidence` (clamped), `:valid_from`/`:valid_to` (`DateTime` or nil).

- [ ] **Step 1: Write the failing test**

Add to `test/magus/super_brain/extraction/sanitizer_test.exs`:

```elixir
defmodule Magus.SuperBrain.Extraction.SanitizerClaimTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.Extraction.Sanitizer

  test "sanitizes a well-formed claim" do
    out =
      Sanitizer.sanitize_claim(%{
        subject_name: "  Aurora ",
        object_name: "Q3",
        predicate: "Occurs At",
        polarity: "affirms",
        claim_text: "Aurora targets Q3.",
        confidence: 1.4
      })

    assert out.subject_name == "Aurora"
    assert out.predicate == "occurs_at"
    assert out.polarity == :affirms
    assert out.confidence == 1.0
  end

  test "defaults polarity to :affirms and coerces unknown polarity" do
    assert %{polarity: :affirms} =
             Sanitizer.sanitize_claim(base(%{polarity: "banana"}))

    assert %{polarity: :negates} =
             Sanitizer.sanitize_claim(base(%{polarity: "negates"}))
  end

  test "clips claim_text to 500 chars" do
    out = Sanitizer.sanitize_claim(base(%{claim_text: String.duplicate("x", 600)}))
    assert String.length(out.claim_text) == 500
  end

  test "skips when subject, object, or claim_text is empty" do
    assert :skip == Sanitizer.sanitize_claim(base(%{subject_name: "   "}))
    assert :skip == Sanitizer.sanitize_claim(base(%{claim_text: ""}))
  end

  test "parses ISO dates and tolerates junk" do
    out = Sanitizer.sanitize_claim(base(%{valid_from: "2026-01-02T00:00:00Z", valid_to: "nope"}))
    assert %DateTime{} = out.valid_from
    assert out.valid_to == nil
  end

  defp base(overrides) do
    Map.merge(
      %{
        subject_name: "Aurora",
        object_name: "Q3",
        predicate: "occurs_at",
        polarity: "affirms",
        claim_text: "Aurora targets Q3.",
        confidence: 0.8
      },
      overrides
    )
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/super_brain/extraction/sanitizer_test.exs`
Expected: FAIL, `sanitize_claim/1` undefined.

- [ ] **Step 3: Implement `sanitize_claim/1`**

Add to `lib/magus/super_brain/extraction/sanitizer.ex` (reuse the existing private helpers `strip_control/1`, `clip/2`, `clamp/3`, `normalize_predicate/1`):

```elixir
  @max_claim_text 500

  @doc """
  Sanitises an extracted claim map. Returns `:skip` when subject, object, or
  claim text is empty after trimming. Predicate is normalised like edges;
  polarity is whitelisted (default `:affirms`); dates are parsed as ISO 8601
  with graceful nil.
  """
  def sanitize_claim(claim) do
    sub = claim |> fetch(:subject_name) |> strip_control() |> String.trim()
    obj = claim |> fetch(:object_name) |> strip_control() |> String.trim()
    text = claim |> fetch(:claim_text) |> strip_control() |> String.trim()

    if sub == "" or obj == "" or text == "" do
      :skip
    else
      %{
        subject_name: clip(sub, @max_name_length),
        object_name: clip(obj, @max_name_length),
        predicate: predicate_string(fetch(claim, :predicate)),
        polarity: polarity(fetch(claim, :polarity)),
        claim_text: clip(text, @max_claim_text),
        confidence: clamp(fetch(claim, :confidence) || 0.0, 0.0, 1.0),
        valid_from: parse_date(fetch(claim, :valid_from)),
        valid_to: parse_date(fetch(claim, :valid_to))
      }
    end
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  # Reuse edge predicate normalization, but keep the result a STRING (claims
  # store predicate as text) instead of an atom.
  defp predicate_string(p) do
    case normalize_predicate(p) do
      atom when is_atom(atom) -> Atom.to_string(atom)
      other -> to_string(other)
    end
  end

  defp polarity(p) when p in [:negates, "negates"], do: :negates
  defp polarity(_), do: :affirms

  defp parse_date(nil), do: nil

  defp parse_date(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_date(_), do: nil
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `MIX_ENV=test mix test test/magus/super_brain/extraction/sanitizer_test.exs`
Expected: PASS.

- [ ] **Step 5: Compile check + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git commit -- lib/magus/super_brain/extraction/sanitizer.ex test/magus/super_brain/extraction/sanitizer_test.exs -m "feat(super-brain): claim sanitizer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Extraction speaks claims

**Files:**
- Modify: `lib/magus/super_brain/extraction/prompt.ex`
- Modify: `lib/magus/super_brain/extraction.ex`
- Modify: `lib/magus/super_brain/telemetry.ex` (claims_emitted/claims_dropped helpers, Step 4a)
- Modify: `test/magus/super_brain/extraction_test.exs` (create if absent)
- Modify (fixture migration, Step 6a): every `test/magus/super_brain/` test that mocks the extraction LLM with an old `{"entities", "edges"}` payload, plus `test/magus/super_brain/extraction/prompt_test.exs`. The current set (discover the live list with `grep -rl '"edges"' test/magus/super_brain/`): `extraction_test.exs`, `extract_base_test.exs`, `extract_memory_test.exs`, `extract_brain_page_test.exs`, `extract_brain_source_test.exs`, `extract_draft_test.exs`, `extract_file_chunk_test.exs`, `inline_canonicalize_test.exs`, `build_super_full_test.exs`, `build_super_incremental_test.exs`, `retrieval_test.exs`, `authorization_test.exs`, `prompt_test.exs`.

**SCOPE NOTE (why this task is large):** switching the extraction output contract from `edges` to `claims` breaks EVERY test whose mocked LLM `content:` returns `{"entities":..., "edges":...}`, because the parser now requires `"claims"`. Most are `"edges":[]` (rename the key to `"claims":[]`). The few carrying real edges (e.g. `{"subject_name":"Daniel","object_name":"Project X","predicate":"supports","confidence":0.8}`) become a claim by adding `"polarity":"affirms"` and a `"claim_text"` sentence (e.g. `"Daniel supports Project X."`). `prompt_test.exs` asserts the old prompt schema and must be updated to the claims schema. Any test asserting the removed sparse-edges telemetry (`[:super_brain, :extraction, :sparse_edges]`) must be deleted or repurposed. This is discovery-driven: after the code changes, run the full `test/magus/super_brain/` suite and fix every failure that stems from the shape change. Do NOT touch `"edges"` references that are FalkorDB RELATES_TO graph fixtures/assertions rather than LLM-mock output (those do not flow through the parser and must keep working; the derived edges preserve them).

**Interfaces:**
- Consumes: `Sanitizer.sanitize_claim/1` (Task 2).
- Produces: `Extraction.extract/2` returns `{:ok, %{entities: [...], edges: [...], claims: [...], usage: ..., user_id: ...}}` where `claims` are sanitized claim maps and `edges` are DERIVED from claims (one per claim: `%{subject_name, object_name, predicate: atom, confidence}`).
- Produces: `Extraction.claims_to_edges(claims :: [map]) :: [map]` (public, pure).

- [ ] **Step 1: Write the failing test**

`test/magus/super_brain/extraction_test.exs`:

```elixir
defmodule Magus.SuperBrain.ExtractionClaimsTest do
  use ExUnit.Case, async: true

  import Mox
  setup :verify_on_exit!

  alias Magus.SuperBrain.Extraction

  test "extract returns sanitized claims and derives edges from them" do
    payload =
      Jason.encode!(%{
        "entities" => [
          %{"name" => "Aurora", "type" => "project", "confidence" => 0.9},
          %{"name" => "Q3", "type" => "date", "confidence" => 0.9}
        ],
        "claims" => [
          %{
            "subject_name" => "Aurora",
            "object_name" => "Q3",
            "predicate" => "occurs_at",
            "polarity" => "affirms",
            "claim_text" => "Aurora targets Q3.",
            "confidence" => 0.8
          }
        ]
      })

    expect(Magus.SuperBrain.LLMMock, :complete, fn _messages, _opts ->
      {:ok, %{content: payload, usage: %Magus.SuperBrain.Usage{}}}
    end)

    assert {:ok, %{entities: entities, claims: claims, edges: edges}} =
             Extraction.extract("some text")

    assert length(entities) == 2
    assert [%{claim_text: "Aurora targets Q3.", polarity: :affirms}] = claims
    assert [%{subject_name: "Aurora", object_name: "Q3", predicate: :occurs_at}] = edges
  end

  test "claims whose endpoints are not extracted entities are dropped" do
    payload =
      Jason.encode!(%{
        "entities" => [%{"name" => "Aurora", "type" => "project", "confidence" => 0.9}],
        "claims" => [
          %{
            "subject_name" => "Aurora",
            "object_name" => "Ghost",
            "predicate" => "relates_to",
            "polarity" => "affirms",
            "claim_text" => "Aurora relates to Ghost.",
            "confidence" => 0.7
          }
        ]
      })

    expect(Magus.SuperBrain.LLMMock, :complete, fn _m, _o ->
      {:ok, %{content: payload, usage: %Magus.SuperBrain.Usage{}}}
    end)

    assert {:ok, %{claims: [], edges: []}} = Extraction.extract("t")
  end
end
```

Note: confirm the configured mock module name via `grep super_brain_llm_client config/test.exs`; use that module in `expect/3`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/super_brain/extraction_test.exs`
Expected: FAIL (extract still expects `"edges"` and returns no `claims`).

- [ ] **Step 3: Rewrite the extraction prompt**

In `lib/magus/super_brain/extraction/prompt.ex`, replace the `edges` block of the output schema with a `claims` block, and DELETE the entire "Edge density" section (the quota). The claims schema:

```
    "claims": [
      {
        "subject_name": "must match an entity name in entities",
        "predicate": "one of: #{preds}, or a free-form snake_case verb",
        "object_name": "must match an entity name in entities",
        "polarity": "affirms | negates",
        "claim_text": "the sentence from the content that states this fact (max 500 chars)",
        "confidence": 0.0-1.0,
        "valid_from": "ISO 8601 date, or null unless the text states it",
        "valid_to": "ISO 8601 date, or null unless the text states it"
      }
    ]
```

Replace the density rules with grounding rules:

```
    Claim rules:
    - Every claim MUST be supported by a sentence in the content. Put that
      sentence (quoted or minimally normalised) in claim_text.
    - Prefer fewer, well-grounded claims. Never invent a relation to connect
      entities. When unsure, lower confidence rather than omit.
    - Use polarity "negates" for explicit denials ("Aurora does NOT ship in Q3").
    - subject_name and object_name MUST match an entity in the entities list.
```

Keep the entity-type guidance and the temporal/identity/spatial/causal predicate-family guidance unchanged (they now describe claim predicates).

- [ ] **Step 4: Rewrite the extraction parser**

In `lib/magus/super_brain/extraction.ex`:

Replace `parse_and_sanitize/1` so it reads `"claims"`, sanitizes them, filters to claims whose endpoints are extracted entities, and derives `edges`:

```elixir
  defp parse_and_sanitize(raw) do
    with {:ok, payload} <- decode_json(raw),
         %{"entities" => raw_entities, "claims" => raw_claims} <- payload do
      entities =
        raw_entities
        |> Enum.map(&sanitize_entity_input/1)
        |> Enum.reject(&(&1 == :skip))

      entity_names = MapSet.new(entities, & &1.name)

      sanitized =
        raw_claims
        |> Enum.map(&Sanitizer.sanitize_claim/1)
        |> Enum.reject(&(&1 == :skip))

      claims =
        Enum.filter(sanitized, fn c ->
          MapSet.member?(entity_names, c.subject_name) and
            MapSet.member?(entity_names, c.object_name)
        end)

      # Observability: claims dropped because an endpoint was not an extracted
      # entity. Emitted from day one so sanitizer strictness is measurable.
      Magus.SuperBrain.Telemetry.claims_dropped(length(sanitized) - length(claims))

      {:ok, %{entities: entities, claims: claims, edges: claims_to_edges(claims)}}
    else
      {:error, :invalid_json} = err -> err
      _ -> {:error, :unexpected_schema}
    end
  end

  @doc """
  Derives L1 `RELATES_TO` edge observations from claims: one per claim, using
  the claim's predicate as an atom (via the atom-safe classifier). The FalkorDB
  builders consume these unchanged; polarity stays on the claim, not the edge.
  """
  def claims_to_edges(claims) do
    Enum.map(claims, fn c ->
      %{
        subject_name: c.subject_name,
        object_name: c.object_name,
        predicate: predicate_atom(c.predicate),
        confidence: c.confidence
      }
    end)
  end

  defp predicate_atom(p) when is_binary(p) do
    case Magus.SuperBrain.Ontology.classify_predicate(p) do
      {:canonical, atom} -> atom
      {:freeform, atom} when is_atom(atom) -> atom
      _ -> :relates_to
    end
  end
```

Delete `maybe_emit_sparse_edges/2` and its call in `extract/2` (the quota it measured is gone). Also delete the now-unused private `sanitize_edge_input/1` clauses and the old `edges` mapping that referenced them (an unused private function fails `--warnings-as-errors`). Leave the public `Sanitizer.sanitize_edge/1` in place (no warning for unused public functions; its unit tests still pass).

- [ ] **Step 4a: Add the telemetry counter helpers**

In `lib/magus/super_brain/telemetry.ex`, add next to the existing counter helpers (so `claims_dropped/1`, called by the parser above, and `claims_emitted/1`, called by `write_claims` in Task 4, both exist):

```elixir
  def claims_emitted(count) when is_integer(count) and count > 0 do
    :telemetry.execute([:super_brain, :extract, :claims_emitted], %{count: count}, %{})
  end

  def claims_emitted(_), do: :ok

  def claims_dropped(count) when is_integer(count) and count > 0 do
    :telemetry.execute([:super_brain, :extract, :claims_dropped], %{count: count}, %{})
  end

  def claims_dropped(_), do: :ok
```

- [ ] **Step 5: Update the `extract/2` body**

Remove the `maybe_emit_sparse_edges(payload, user_id)` line so `extract/2` reads:

```elixir
        with {:ok, payload} <- parse_and_sanitize(raw) do
          {:ok, payload |> Map.put(:usage, usage) |> Map.put(:user_id, user_id)}
        end
```

- [ ] **Step 6: Run the new extraction test**

Run: `MIX_ENV=test MIX_TEST_PARTITION=_wtclaims mix test test/magus/super_brain/extraction_test.exs`
Expected: PASS.

- [ ] **Step 6a: Migrate the broken LLM-mock fixtures + prompt test (the large part)**

Run the FULL super_brain suite to surface every test broken by the shape change:
`set -a && source .env && set +a && MIX_ENV=test MIX_TEST_PARTITION=_wtclaims mix test test/magus/super_brain/`

For each failure, fix the cause:
- **LLM-mock `content:` with `"edges"`**: rename `"edges"` to `"claims"`. If the array is `[]`, done. If it has entries, convert each `{"subject_name","object_name","predicate","confidence"}` to a claim by adding `"polarity":"affirms"` and a `"claim_text"` sentence built from the endpoints (e.g. `"<subject> <predicate> <object>."`). Endpoint names must still match entities in the same mock (the parser drops non-matching claims), so preserve them exactly.
- **`prompt_test.exs`**: update assertions from the old edges schema to the new claims schema (the prompt now describes a `claims` array and no edge-density quota).
- **sparse-edges telemetry test** (if any asserts `[:super_brain, :extraction, :sparse_edges]`): delete it; that telemetry was removed with the quota.
- **Do not** alter `"edges"` that are FalkorDB graph fixtures/assertions (RELATES_TO), not LLM-mock output. Derived edges keep those green; if such a test fails, the cause is elsewhere, investigate before editing.

Re-run the full super_brain suite until it is green with pristine output. This is the bulk of the task.

- [ ] **Step 7: Compile check + commit**

Stage the code files, the new/updated extraction test, telemetry.ex, and every fixture file you touched. List them explicitly (use `git status` to enumerate, then `git commit -- <each path>`; never `git add -A`).

```bash
MIX_ENV=test mix compile --warnings-as-errors
# git commit -- lib/magus/super_brain/extraction/prompt.ex lib/magus/super_brain/extraction.ex \
#   lib/magus/super_brain/telemetry.ex test/magus/super_brain/extraction_test.exs \
#   <every migrated test fixture file> \
#   -m "feat(super-brain): extraction emits claims, derives edges"
```
Commit message body: "Replace the extraction edge output with claims (subject/predicate/object, polarity, claim_text); derive L1 edges from claims so the builders are unchanged; remove the edge-density quota and its sparse-edges telemetry; migrate all extraction-LLM-mock fixtures to the claims shape." End with the Co-Authored-By line.

---

## Task 4: Persist claims in ExtractBase

**Files:**
- Modify: `lib/magus/super_brain/workers/extract_base.ex`
- Modify: `lib/magus/super_brain/workers/{extract_brain_page,extract_memory,extract_file_chunk,extract_draft,ingest_brain_connection}.ex` (version bumps)
- Modify: `lib/magus/super_brain/telemetry.ex` (claim counters)
- Create: `test/magus/super_brain/workers/extract_base_claims_test.exs`

**Interfaces:**
- Consumes: `Extraction.extract/2` returning `claims` (Task 3), `Magus.SuperBrain.Claim.bulk_create` (Task 1), `Ontology.compute_trust_tier/2`, `extraction_embedder().embed_many/1`.
- Produces: after a successful extraction, one `Claim` row per claim tied to the new episode; prior episodes' claim rows deleted on supersede.

- [ ] **Step 1: Write the failing test**

`test/magus/super_brain/workers/extract_base_claims_test.exs` (model it on the existing `extract_base` integration tests; discover them with `ls test/magus/super_brain/workers/`). The test drives one worker (e.g. `ExtractMemory`) with the LLM mock emitting claims, then asserts `Claim` rows:

```elixir
defmodule Magus.SuperBrain.Workers.ExtractBaseClaimsTest do
  use Magus.DataCase, async: false

  import Mox
  setup :verify_on_exit!

  alias Magus.SuperBrain.Claim
  require Ash.Query

  test "a successful extraction writes Claim rows tied to the episode" do
    # ... set up a user + a :user-scoped Memory via Magus.Generators so
    # ExtractMemory.load/1 resolves it (follow the existing extract_memory
    # test setup in this directory) ...

    payload =
      Jason.encode!(%{
        "entities" => [
          %{"name" => "Aurora", "type" => "project", "confidence" => 0.9},
          %{"name" => "Q3", "type" => "date", "confidence" => 0.9}
        ],
        "claims" => [
          %{"subject_name" => "Aurora", "object_name" => "Q3",
            "predicate" => "occurs_at", "polarity" => "affirms",
            "claim_text" => "Aurora targets Q3.", "confidence" => 0.8}
        ]
      })

    expect(Magus.SuperBrain.LLMMock, :complete, fn _m, _o ->
      {:ok, %{content: payload, usage: %Magus.SuperBrain.Usage{}}}
    end)

    assert :ok =
             Magus.SuperBrain.Workers.ExtractMemory.perform(%Oban.Job{
               args: %{"resource_id" => memory_id}
             })

    {:ok, claims} =
      Claim
      |> Ash.Query.filter(source_user_id == ^user_id)
      |> Ash.read(authorize?: false)

    assert [%{claim_text: "Aurora targets Q3.", subject_key: "aurora", predicate: "occurs_at"}] =
             claims
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/super_brain/workers/extract_base_claims_test.exs`
Expected: FAIL (no claim rows written).

- [ ] **Step 3: Add the claim-persistence step to the transaction**

In `lib/magus/super_brain/workers/extract_base.ex`, add `write_claims/3` to the `persist_extraction/5` `with` chain, right after `write_to_graph`:

```elixir
           :ok <- write_to_graph(input, episode, extraction, worker_module),
           :ok <- write_claims(input, episode, extraction),
           {:ok, _} <- mark_extracted(episode, extraction) do
```

Implement the helpers (place near `write_to_graph`):

```elixir
  # Persist claims to Postgres. Trust tier mirrors the entity pathway
  # (`compute_trust_tier` with the worker's ontology source). Claim texts are
  # embedded via the batch extraction embedder; embedding failure logs and
  # leaves `embedding` nil (backfillable) rather than failing the extraction.
  defp write_claims(_input, _episode, %{claims: []}), do: :ok

  defp write_claims(input, %Episode{id: episode_id}, %{claims: claims}) do
    ontology_source = Map.get(input, :ontology_source, :llm_extract)
    embeddings = embed_claim_texts(claims)
    now = DateTime.utc_now()

    rows =
      claims
      |> Enum.zip(embeddings)
      |> Enum.map(fn {c, embedding} ->
        %{
          graph_name: input.graph_name,
          episode_id: episode_id,
          source_user_id: input.user_id,
          subject_name: c.subject_name,
          subject_key: entity_key(c.subject_name),
          object_name: c.object_name,
          object_key: entity_key(c.object_name),
          predicate: c.predicate,
          polarity: c.polarity,
          claim_text: c.claim_text,
          confidence: c.confidence,
          trust_tier: Ontology.compute_trust_tier(c.confidence, source: ontology_source),
          asserted_at: now,
          valid_from: c.valid_from,
          valid_to: c.valid_to,
          embedding: embedding
        }
      end)

    SBTelemetry.claims_emitted(length(rows))

    case Ash.bulk_create(rows, Magus.SuperBrain.Claim, :bulk_create,
           authorize?: false,
           return_errors?: true,
           stop_on_error?: true
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, {:claim_write_failed, errors}}
    end
  end

  defp write_claims(_input, _episode, _extraction), do: :ok

  # Downcased, whitespace-collapsed name key, matching the canonical bucket
  # normalization the entity graph uses.
  defp entity_key(name) when is_binary(name) do
    name |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  # Batch-embed claim texts. On any failure, return a list of nils the same
  # length as `claims` so persistence proceeds with null embeddings.
  defp embed_claim_texts(claims) do
    texts = Enum.map(claims, & &1.claim_text)

    case extraction_embedder().embed_many(texts) do
      {:ok, embeddings} when length(embeddings) == length(texts) -> embeddings
      _ -> List.duplicate(nil, length(texts))
    end
  end
```

- [ ] **Step 4: Delete prior claim rows on supersede**

In `supersede_prior/4`, inside the `Enum.each(priors, fn prior -> ... end)` loop (where the graph footprint is already removed), add a claim-row delete for the prior episode. Use a bulk destroy scoped to `episode_id`:

```elixir
          # Claims mirror the current extraction per source: drop the prior
          # episode's claim rows so the fresh episode's claims replace them.
          Magus.SuperBrain.Claim
          |> Ash.Query.filter(episode_id == ^prior.id)
          |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: false)
```

(Add `require Ash.Query` at the top of the module if not already present; it is.)

- [ ] **Step 5: Confirm the telemetry counter helper exists**

`SBTelemetry.claims_emitted/1` and `claims_dropped/1` were added to `lib/magus/super_brain/telemetry.ex` in Task 3 Step 4a. Confirm they are present (grep `claims_emitted lib/magus/super_brain/telemetry.ex`); `write_claims/3` calls `SBTelemetry.claims_emitted(length(rows))` as shown in Step 3. No new telemetry code in this task.

- [ ] **Step 6: Bump `extractor_version/0` on every worker**

In each of `extract_brain_page.ex`, `extract_memory.ex`, `extract_file_chunk.ex`, `extract_draft.ex`, `ingest_brain_connection.ex`, change the `@extractor_version` string to a new `...@2026-07-04-claims` suffix (e.g. `"memory_extract_worker@2026-07-04-claims"`). This distinguishes pre-claims episodes for the backfill task.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `MIX_ENV=test mix test test/magus/super_brain/workers/extract_base_claims_test.exs test/magus/super_brain/workers/`
Expected: PASS, including the pre-existing extract_base tests (behavior preserved: entities + derived edges still write).

- [ ] **Step 8: Compile check + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git commit -- lib/magus/super_brain/workers/extract_base.ex lib/magus/super_brain/workers/extract_brain_page.ex lib/magus/super_brain/workers/extract_memory.ex lib/magus/super_brain/workers/extract_file_chunk.ex lib/magus/super_brain/workers/extract_draft.ex lib/magus/super_brain/workers/ingest_brain_connection.ex lib/magus/super_brain/telemetry.ex test/magus/super_brain/workers/extract_base_claims_test.exs -m "feat(super-brain): persist claims on extraction; supersede-delete; version bump

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Retrieval.search_claims

**Files:**
- Modify: `lib/magus/super_brain/retrieval.ex`
- Create: `test/magus/super_brain/retrieval_claims_test.exs`

**Interfaces:**
- Consumes: `Claim.top_ids_by_embedding/4` (Task 1), `AccessibleGraphs.for_actor/2`.
- Produces: `Retrieval.search_claims(actor, opts) :: {:ok, [Claim.t()]}` where opts are `:query_embedding` (required), `:workspace_context`, `:trust_tiers` (default `[:instruction, :evidence]`), `:limit` (default 10), `:accessible_graphs` (optional precomputed list). Returned claims are loaded with `:episode` and ordered by cosine distance.
- Produces: `Retrieval.search/2` additionally honors an `:accessible_graphs` option (shared allow-list); default behavior unchanged when absent.

- [ ] **Step 1: Write the failing test**

`test/magus/super_brain/retrieval_claims_test.exs`:

```elixir
defmodule Magus.SuperBrain.RetrievalClaimsTest do
  use Magus.DataCase, async: false

  alias Magus.SuperBrain.{Claim, Retrieval}

  test "search_claims recalls a claim in an accessible graph and isolates others" do
    user = user_fixture()            # follow existing test helpers
    graph = "memories:user:#{user.id}"

    seed_claim(graph, user.id, "Aurora ships without the npm wrapper.", one_hot(0))
    seed_claim("memories:user:#{Ash.UUID.generate()}", Ash.UUID.generate(), "Someone else fact.", one_hot(0))

    assert {:ok, [claim]} =
             Retrieval.search_claims(user,
               query_embedding: one_hot(0),
               accessible_graphs: [graph],
               limit: 5
             )

    assert claim.claim_text == "Aurora ships without the npm wrapper."
  end

  defp one_hot(i), do: List.duplicate(0.0, 1536) |> List.replace_at(i, 1.0)

  defp seed_claim(graph, uid, text, embedding) do
    ep = seed_episode(graph, uid)   # see "Test setup conventions"; Claim.episode_id is a hard FK

    Claim
    |> Ash.Changeset.for_create(:create, %{
      graph_name: graph,
      episode_id: ep.id,
      source_user_id: uid,
      subject_name: "Aurora",
      subject_key: "aurora",
      object_name: "wrapper",
      object_key: "wrapper",
      predicate: "relates_to",
      polarity: :affirms,
      claim_text: text,
      confidence: 0.8,
      trust_tier: :evidence,
      asserted_at: DateTime.utc_now(),
      embedding: embedding
    })
    |> Ash.create(authorize?: false)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/super_brain/retrieval_claims_test.exs`
Expected: FAIL, `search_claims/2` undefined.

- [ ] **Step 3: Implement `search_claims/2` + shared allow-list**

In `lib/magus/super_brain/retrieval.ex`, add:

```elixir
  @doc """
  Semantic search over the actor's claims (pgvector). Independent of super-graph
  state: works during cold start and drift. Returns claims ordered by cosine
  distance, loaded with `:episode` for provenance.
  """
  def search_claims(actor, opts) do
    if Magus.SuperBrain.enabled?() do
      embedding = Keyword.fetch!(opts, :query_embedding)
      limit = Keyword.get(opts, :limit, 10)
      tiers = opts |> Keyword.get(:trust_tiers, @default_trust_tiers) |> Enum.map(&Atom.to_string/1)
      graphs = accessible_graphs(actor, opts)

      ids = Magus.SuperBrain.Claim.top_ids_by_embedding(embedding, graphs, tiers, limit)
      {:ok, load_claims_in_order(ids)}
    else
      {:ok, []}
    end
  end

  defp load_claims_in_order([]), do: []

  defp load_claims_in_order(ids) do
    {:ok, claims} =
      Magus.SuperBrain.Claim
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.load(:episode)
      |> Ash.read(authorize?: false)

    by_id = Map.new(claims, &{&1.id, &1})
    Enum.flat_map(ids, fn id -> List.wrap(Map.get(by_id, id)) end)
  end

  # Shared accessible-graph list: callers (per-turn context) may precompute it
  # once and pass it to both search/2 and search_claims/2.
  defp accessible_graphs(actor, opts) do
    case Keyword.get(opts, :accessible_graphs) do
      nil ->
        actor
        |> AccessibleGraphs.for_actor(workspace_context: Keyword.get(opts, :workspace_context))
        |> Enum.reject(&String.starts_with?(&1, "super:"))

      list ->
        list
    end
  end
```

In `read_set_drifted?/3` and `legacy_fan_out_search/2`, no change is required for Task 5, but to enable sharing, thread `:accessible_graphs` into `do_search/2` where `AccessibleGraphs.for_actor` is called for the drift check: prefer `Keyword.get(opts, :accessible_graphs)` when present. (Minimal: leave `search/2` as-is if threading is noisy; the context builder in Task 6 can still pass the list to `search_claims/2` and let `search/2` compute its own. Document whichever you choose.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `MIX_ENV=test mix test test/magus/super_brain/retrieval_claims_test.exs`
Expected: PASS.

- [ ] **Step 5: Compile check + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git commit -- lib/magus/super_brain/retrieval.ex test/magus/super_brain/retrieval_claims_test.exs -m "feat(super-brain): pgvector claim recall (search_claims)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Context block rewrite

**Files:**
- Modify: `lib/magus/agents/context/super_brain_rag_context.ex`
- Modify: `test/magus/agents/context/super_brain_rag_context_test.exs`

**Interfaces:**
- Consumes: `Retrieval.search/2` (entities), `Retrieval.search_claims/2` (Task 5).
- Produces: an updated `<super_brain>` block rendering claims grouped by subject entity, a CONFLICT line for opposite-polarity claims on the same triple, per-entity (3) and total (10) caps, and the existing name+refs line for claim-less entities.

- [ ] **Step 1: Write the failing test**

Extend `test/magus/agents/context/super_brain_rag_context_test.exs` with a claim-render test that calls a new pure formatter `format_with_claims/2` (entities, claims) and asserts the claim line, citation, and CONFLICT line render, plus the claim-less fallback. Use structural assertions (substring presence), not exact whitespace:

```elixir
  test "renders claims grouped under subjects with citations and conflicts" do
    entities = [%{name: "Aurora", primary_type: "project", sources: []}]

    claims = [
      %{subject_name: "Aurora", subject_key: "aurora", predicate: "occurs_at",
        object_name: "Q3", object_key: "q3", polarity: :affirms,
        claim_text: "Aurora targets Q3.", confidence: 0.9,
        episode: %{resource_type: :brain_page, resource_id: Ash.UUID.generate()}},
      %{subject_name: "Aurora", subject_key: "aurora", predicate: "occurs_at",
        object_name: "Q4", object_key: "q4", polarity: :affirms,
        claim_text: "Aurora moved to Q4.", confidence: 0.9,
        episode: %{resource_type: :draft, resource_id: Ash.UUID.generate()}}
    ]

    block = Magus.Agents.Context.SuperBrainRagContext.format_with_claims(entities, claims)

    assert block =~ "<super_brain>"
    assert block =~ "Aurora targets Q3."
    assert block =~ "Aurora"
  end

  test "an entity with no claims renders the name + type line" do
    block = Magus.Agents.Context.SuperBrainRagContext.format_with_claims(
      [%{name: "Daniel", primary_type: "person", sources: []}], [])

    assert block =~ "Daniel"
    assert block =~ "person"
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/agents/context/super_brain_rag_context_test.exs`
Expected: FAIL, `format_with_claims/2` undefined.

- [ ] **Step 3: Implement claim rendering**

In `lib/magus/agents/context/super_brain_rag_context.ex`:

Change `do_build/3` to fetch claims alongside entities and call the new formatter:

```elixir
  defp do_build(query, user, opts) do
    workspace_context = Map.get(opts, :workspace_id)

    case EmbeddingModel.embed(query) do
      {:ok, embedding} ->
        entities =
          case Retrieval.search(user,
                 query: query,
                 query_embedding: embedding,
                 workspace_context: workspace_context,
                 limit: @max_results
               ) do
            {:ok, %{entities: es}} -> es
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        {:ok, claims} =
          Retrieval.search_claims(user,
            query_embedding: embedding,
            workspace_context: workspace_context,
            limit: @max_claims
          )

        if entities == [] and claims == [] do
          nil
        else
          format_with_claims(entities, claims)
        end

      _ ->
        nil
    end
  rescue
    e ->
      Logger.warning("SuperBrain RAG context failed: #{Exception.message(e)}")
      nil
  end
```

Add module attributes `@max_claims 10` and `@max_claims_per_entity 3`, and the formatter (keep the existing `format/1`, `format_legacy/1`, title resolution, and `format_super_entity/2` as the claim-less fallback path):

```elixir
  @doc false
  def format_with_claims(entities, claims) do
    titles = resolve_titles_for_claims(claims)
    by_subject = Enum.group_by(claims, & &1.subject_key)

    sections =
      Enum.map_join(entities, "\n\n", fn e ->
        key = e |> Map.get(:name) |> entity_key()
        entity_claims = Map.get(by_subject, key, []) |> Enum.take(@max_claims_per_entity)
        render_entity_section(e, entity_claims, titles)
      end)

    """
    <super_brain>
    Distilled knowledge from your sources relevant to this query (each line cites its source).

    #{sections}
    </super_brain>\
    """
  end

  defp render_entity_section(e, [], _titles), do: format_super_entity(e, %{})

  defp render_entity_section(e, entity_claims, titles) do
    name = Map.get(e, :name) || "?"
    type = Map.get(e, :primary_type) || Map.get(e, :type) || "?"
    header = "## #{name} [#{type}]"
    lines = entity_claims |> group_conflicts() |> Enum.map(&claim_line(&1, titles))
    header <> "\n" <> Enum.join(lines, "\n")
  end

  # Group claims on the same (subject_key, predicate, object_key) that carry
  # opposite polarities into a single :conflict tuple; others stay :single.
  defp group_conflicts(claims) do
    claims
    |> Enum.group_by(fn c -> {c.subject_key, c.predicate, c.object_key} end)
    |> Enum.flat_map(fn {_triple, group} ->
      polarities = group |> Enum.map(& &1.polarity) |> Enum.uniq()

      if length(polarities) > 1 do
        [{:conflict, group}]
      else
        Enum.map(group, &{:single, &1})
      end
    end)
  end

  defp claim_line({:single, c}, titles) do
    "- \"#{c.claim_text}\" (#{cite(c, titles)})"
  end

  defp claim_line({:conflict, [a, b | _]}, titles) do
    "- CONFLICT: \"#{a.claim_text}\" (#{cite(a, titles)}) vs \"#{b.claim_text}\" (#{cite(b, titles)})"
  end

  defp cite(%{episode: %{resource_type: rt, resource_id: id}}, titles) do
    case Map.get(titles, id) do
      nil -> "#{rt}"
      title -> "#{rt} \"#{title}\""
    end
  end

  defp cite(_, _), do: "source"

  defp entity_key(nil), do: nil
  defp entity_key(name), do: name |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()

  # Batch-resolve brain-page / draft titles from the claims' episodes.
  defp resolve_titles_for_claims(claims) do
    refs =
      claims
      |> Enum.map(fn c -> Map.get(c, :episode) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn ep -> {ep.resource_type, ep.resource_id} end)

    page_ids = for {:brain_page, id} <- refs, do: id
    draft_ids = for {:draft, id} <- refs, do: id

    Map.merge(page_titles(page_ids), draft_titles(draft_ids))
  end

  defp page_titles([]), do: %{}

  defp page_titles(ids) do
    case Magus.Brain.Page |> Ash.Query.filter(id in ^ids) |> Ash.read(authorize?: false) do
      {:ok, pages} -> Map.new(pages, &{&1.id, &1.title})
      _ -> %{}
    end
  end

  defp draft_titles([]), do: %{}

  defp draft_titles(ids) do
    case Magus.Drafts.Draft |> Ash.Query.filter(id in ^ids) |> Ash.read(authorize?: false) do
      {:ok, drafts} -> Map.new(drafts, &{&1.id, &1.title})
      _ -> %{}
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `MIX_ENV=test mix test test/magus/agents/context/super_brain_rag_context_test.exs`
Expected: PASS (new + existing tests).

- [ ] **Step 5: Compile check + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git commit -- lib/magus/agents/context/super_brain_rag_context.ex test/magus/agents/context/super_brain_rag_context_test.exs -m "feat(super-brain): claim-centered <super_brain> context block

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Dossier pure module

**Files:**
- Create: `lib/magus/super_brain/dossier.ex`
- Create: `test/magus/super_brain/dossier_test.exs`

**Interfaces:**
- Produces: `Magus.SuperBrain.Dossier.build(entity_key :: String.t(), claims :: [map]) :: %{facts: [group], referenced_by: [group], conflicts: [map]}` where each `group` is `%{predicate, other_name, other_key, polarity, texts: [String.t()], evidence_count, trust_tier, latest_asserted_at}` and `conflicts` lists opposite-polarity groups on the same triple. Groups are ordered by `latest_asserted_at` descending. Pure: input claim maps have keys `:subject_key, :subject_name, :object_key, :object_name, :predicate, :polarity, :claim_text, :trust_tier, :asserted_at`.

- [ ] **Step 1: Write the failing test**

`test/magus/super_brain/dossier_test.exs`:

```elixir
defmodule Magus.SuperBrain.DossierTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.Dossier

  defp claim(overrides) do
    Map.merge(
      %{subject_key: "aurora", subject_name: "Aurora", object_key: "q3", object_name: "Q3",
        predicate: "occurs_at", polarity: :affirms, claim_text: "Aurora targets Q3.",
        trust_tier: :evidence, asserted_at: ~U[2026-06-01 00:00:00Z]},
      overrides
    )
  end

  test "splits facts (subject) from referenced_by (object) and dedups texts per group" do
    d = Dossier.build("aurora", [claim(%{}), claim(%{claim_text: "Aurora targets Q3."})])
    assert [%{predicate: "occurs_at", texts: ["Aurora targets Q3."], evidence_count: 2}] = d.facts
    assert d.referenced_by == []
  end

  test "flags opposite-polarity claims on the same triple as a conflict" do
    d =
      Dossier.build("aurora", [
        claim(%{polarity: :affirms, claim_text: "Aurora ships in Q3."}),
        claim(%{polarity: :negates, claim_text: "Aurora does not ship in Q3."})
      ])

    assert length(d.conflicts) == 1
  end

  test "orders groups by latest asserted_at descending" do
    d =
      Dossier.build("aurora", [
        claim(%{object_key: "q3", object_name: "Q3", asserted_at: ~U[2026-05-01 00:00:00Z]}),
        claim(%{object_key: "q4", object_name: "Q4", asserted_at: ~U[2026-06-01 00:00:00Z]})
      ])

    assert [%{other_key: "q4"}, %{other_key: "q3"}] = d.facts
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/super_brain/dossier_test.exs`
Expected: FAIL, `Dossier` undefined.

- [ ] **Step 3: Implement the pure module**

`lib/magus/super_brain/dossier.ex`:

```elixir
defmodule Magus.SuperBrain.Dossier do
  @moduledoc """
  Pure aggregation of an entity's claims into a dossier: facts where the entity
  is the subject, claims where it is the object, and conflicts (opposite-polarity
  claims on the same triple). Groups are ordered newest-first by `asserted_at`.
  No I/O: callers fetch the accessible claims and pass them in.
  """

  @tier_order %{instruction: 3, evidence: 2, noise: 1}

  @spec build(String.t(), [map()]) :: %{facts: [map()], referenced_by: [map()], conflicts: [map()]}
  def build(entity_key, claims) do
    {as_subject, as_object} = Enum.split_with(claims, &(&1.subject_key == entity_key))

    %{
      facts: group(as_subject, :object),
      referenced_by: group(as_object, :subject),
      conflicts: conflicts(as_subject ++ as_object)
    }
  end

  defp group(claims, other_side) do
    claims
    |> Enum.group_by(fn c -> {c.predicate, other_key(c, other_side), c.polarity} end)
    |> Enum.map(fn {{predicate, other_key, polarity}, group} ->
      %{
        predicate: predicate,
        other_key: other_key,
        other_name: other_name(hd(group), other_side),
        polarity: polarity,
        texts: group |> Enum.map(& &1.claim_text) |> Enum.uniq(),
        evidence_count: length(group),
        trust_tier: max_tier(group),
        latest_asserted_at: group |> Enum.map(& &1.asserted_at) |> Enum.max(DateTime)
      }
    end)
    |> Enum.sort_by(& &1.latest_asserted_at, {:desc, DateTime})
  end

  defp conflicts(claims) do
    claims
    |> Enum.group_by(fn c -> {c.subject_key, c.predicate, c.object_key} end)
    |> Enum.filter(fn {_triple, group} ->
      group |> Enum.map(& &1.polarity) |> Enum.uniq() |> length() > 1
    end)
    |> Enum.map(fn {{s, p, o}, group} ->
      %{subject_key: s, predicate: p, object_key: o,
        texts: group |> Enum.map(& &1.claim_text) |> Enum.uniq()}
    end)
  end

  defp other_key(c, :object), do: c.object_key
  defp other_key(c, :subject), do: c.subject_key
  defp other_name(c, :object), do: c.object_name
  defp other_name(c, :subject), do: c.subject_name

  defp max_tier(group) do
    group
    |> Enum.map(& &1.trust_tier)
    |> Enum.max_by(fn t -> Map.get(@tier_order, t, 0) end, fn -> :evidence end)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `MIX_ENV=test mix test test/magus/super_brain/dossier_test.exs`
Expected: PASS.

- [ ] **Step 5: Compile check + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git commit -- lib/magus/super_brain/dossier.ex test/magus/super_brain/dossier_test.exs -m "feat(super-brain): pure Dossier aggregation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: get_dossier tool + registration

**Files:**
- Create: `lib/magus/super_brain/tools/get_dossier.ex`
- Modify: `lib/magus/agents/tools/tool_builder.ex`
- Create: `test/magus/super_brain/tools/get_dossier_test.exs`

**Interfaces:**
- Consumes: `Dossier.build/2` (Task 7), `Claim.for_entity_keys` read (Task 1), `AccessibleGraphs.for_actor/2`, `Retrieval.search/2` (zero-claims fallback).
- Produces: Jido tool `get_dossier` with schema `entity_name` (required string), `entity_type` (`{:or, [:string, nil]}`, default nil), `limit` (integer, default 20). Returns `%{entity, facts, referenced_by, conflicts}` or `%{fallback: entity_view}` when no claims.

- [ ] **Step 1: Write the failing test**

`test/magus/super_brain/tools/get_dossier_test.exs`: seed a couple of claims for a user's accessible graph, call `GetDossier.run(%{entity_name: "Aurora"}, %{user_id: user.id})`, assert grouped facts; and a zero-claims case asserting the fallback shape. Follow the `search.ex` context convention (`user_id` in context).

```elixir
defmodule Magus.SuperBrain.Tools.GetDossierTest do
  use Magus.DataCase, async: false

  alias Magus.SuperBrain.Tools.GetDossier

  test "returns grouped facts for an entity across accessible claims" do
    user = user_fixture()
    seed_claim("memories:user:#{user.id}", user.id, "Aurora targets Q3.")

    assert {:ok, %{facts: facts}} =
             GetDossier.run(%{entity_name: "Aurora"}, %{user_id: user.id})

    assert Enum.any?(facts, &("Aurora targets Q3." in &1.texts))
  end

  test "falls back to the entity view when the entity has no claims" do
    user = user_fixture()
    assert {:ok, result} = GetDossier.run(%{entity_name: "Nonexistent"}, %{user_id: user.id})
    assert Map.has_key?(result, :fallback)
  end

  # seed_claim/3 as in Task 5's test
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/super_brain/tools/get_dossier_test.exs`
Expected: FAIL, `GetDossier` undefined.

- [ ] **Step 3: Implement the tool**

`lib/magus/super_brain/tools/get_dossier.ex` (model structure on `Magus.SuperBrain.Tools.Search`):

```elixir
defmodule Magus.SuperBrain.Tools.GetDossier do
  @moduledoc """
  Jido tool: everything known about one entity across all accessible sources.
  Groups the entity's claims (as subject and as object) into facts, referenced-by,
  and conflicts, each with citations and newest-first ordering. Falls back to the
  entity graph view when the entity has no claims yet.
  """

  use Jido.Action,
    name: "get_dossier",
    description: """
    Everything known about ONE entity across all your sources: grouped facts with
    citations, conflicts flagged, newest first. Use when the user asks "what do we
    know about X" or you need a consolidated view of a person, project, or concept.
    """,
    schema: [
      entity_name: [type: :string, required: true, doc: "The entity to build a dossier for"],
      entity_type: [type: {:or, [:string, nil]}, default: nil, doc: "Optional type disambiguator"],
      limit: [type: :integer, default: 20, doc: "Max claim groups"]
    ]

  require Ash.Query
  require Logger

  alias Magus.SuperBrain.{AccessibleGraphs, Claim, Dossier, Retrieval}

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_param: 3]

  def display_name, do: "Building dossier..."

  def summarize_output(%{facts: facts, conflicts: conflicts}) do
    "#{length(facts)} facts, #{length(conflicts)} conflicts"
  end

  def summarize_output(%{fallback: _}), do: "No claims yet; showing entity view"
  def summarize_output(_), do: "No results"

  @impl true
  def run(params, context) do
    name = get_param(params, :entity_name)
    user_id = Map.get(context, :user_id)

    cond do
      is_nil(user_id) -> {:ok, %{error: "Missing user_id in context"}}
      is_nil(name) or name == "" -> {:ok, %{error: "Missing entity_name"}}
      true -> build_dossier(name, user_id, context)
    end
  end

  defp build_dossier(name, user_id, context) do
    with {:ok, user} <- Magus.Accounts.get_user(user_id, authorize?: false) do
      key = entity_key(name)
      graphs = accessible_graphs(user, context)

      {:ok, claims} =
        Claim
        |> Ash.Query.for_read(:for_entity_keys, %{keys: [key], graph_names: graphs})
        |> Ash.Query.load(:episode)
        |> Ash.read(authorize?: false)

      if claims == [] do
        fallback(name, user, context)
      else
        d = Dossier.build(key, Enum.map(claims, &to_dossier_claim/1))
        {:ok, Map.put(d, :entity, name)}
      end
    else
      _ -> {:ok, %{error: "Dossier unavailable"}}
    end
  end

  defp fallback(name, user, context) do
    case Retrieval.search(user,
           query: name,
           query_embedding: fallback_embedding(name),
           workspace_context: Map.get(context, :workspace_id),
           limit: 5
         ) do
      {:ok, %{entities: entities}} -> {:ok, %{fallback: entities, entity: name}}
      _ -> {:ok, %{fallback: [], entity: name}}
    end
  end

  defp fallback_embedding(name) do
    case Magus.SuperBrain.EmbeddingConfig.embedder().embed(name, []) do
      {:ok, %{embedding: e}} -> e
      {:ok, e} when is_list(e) -> e
      _ -> []
    end
  end

  defp to_dossier_claim(c) do
    %{
      subject_key: c.subject_key, subject_name: c.subject_name,
      object_key: c.object_key, object_name: c.object_name,
      predicate: c.predicate, polarity: c.polarity, claim_text: c.claim_text,
      trust_tier: c.trust_tier, asserted_at: c.asserted_at
    }
  end

  defp accessible_graphs(user, context) do
    user
    |> AccessibleGraphs.for_actor(workspace_context: Map.get(context, :workspace_id))
    |> Enum.reject(&String.starts_with?(&1, "super:"))
  end

  defp entity_key(name), do: name |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
end
```

Confirm the embedder return shape by checking `Magus.SuperBrain.EmbeddingConfig.embedder()` and `Magus.SuperBrain.Tools.Search.embed/1`; match `fallback_embedding/1` to it.

- [ ] **Step 4: Register the tool**

In `lib/magus/agents/tools/tool_builder.ex`:
- Add alias near line 129: `alias Magus.SuperBrain.Tools.GetDossier`.
- Add `GetDossier,` to the `main_tools` list (after `SuperBrainSearch,` at ~line 313) and to `sub_agent_tools` (after `SuperBrainSearch,` at ~line 346).
- In the kill-switch line (~466), include GetDossier: change `tools -- [SuperBrainSearch, PinFact]` to `tools -- [SuperBrainSearch, PinFact, GetDossier]`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `MIX_ENV=test mix test test/magus/super_brain/tools/get_dossier_test.exs`
Expected: PASS.

- [ ] **Step 6: Compile check + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git commit -- lib/magus/super_brain/tools/get_dossier.ex lib/magus/agents/tools/tool_builder.ex test/magus/super_brain/tools/get_dossier_test.exs -m "feat(super-brain): get_dossier tool

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: super_brain_search claim output + tool description pass

**Files:**
- Modify: `lib/magus/super_brain/tools/search.ex`
- Modify: `lib/magus/agents/tools/rag.ex`
- Modify: `lib/magus/agents/tools/memory/search_memories.ex`
- Modify: `test/` (the search tool's existing test; discover with `ls test/magus/super_brain/tools/`)

**Interfaces:**
- Consumes: `Retrieval.search_claims/2`.
- Produces: `super_brain_search` output entities each carry a `claims: [%{text, predicate}]` list (top 2 by recall). Descriptions of the three search tools disambiguated.

- [ ] **Step 1: Write the failing test**

Extend the search tool test: with a seeded entity + a claim whose subject is that entity, `Search.run(%{query: "..."}, %{user_id: ...})` returns entities where at least one carries a non-empty `claims` list. (If seeding an entity graph is heavy, assert instead on a smaller unit: a new private `attach_claims/3` is exposed as `@doc false` and unit-tested with hand-built entities + claims.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/super_brain/tools/search_test.exs`
Expected: FAIL.

- [ ] **Step 3: Attach claims to search output**

In `lib/magus/super_brain/tools/search.ex`, after the super-graph happy path returns `project_super_graph_entities(entities)`, also fetch claims for the query and attach the top claim texts per entity by matching `subject_key`. Add to `do_search/4` (happy path branch):

```elixir
        {:ok, %{entities: entities}} when is_list(entities) ->
          projected = project_super_graph_entities(entities)
          {:ok, %{entities: attach_claims(projected, actor, embedding)}}
```

```elixir
  @doc false
  def attach_claims(entities, actor, embedding) do
    {:ok, claims} = Retrieval.search_claims(actor, query_embedding: embedding, limit: 10)
    by_subject = Enum.group_by(claims, &claim_key(&1.subject_name))

    Enum.map(entities, fn e ->
      key = claim_key(Map.get(e, :name))

      tops =
        by_subject
        |> Map.get(key, [])
        |> Enum.take(2)
        |> Enum.map(&%{text: &1.claim_text, predicate: &1.predicate})

      Map.put(e, :claims, tops)
    end)
  end

  defp claim_key(nil), do: nil
  defp claim_key(name), do: name |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
```

- [ ] **Step 4: Rewrite the three tool descriptions**

- `search.ex` description: change to emphasize claims: `"Search your accumulated knowledge for distilled cross-source facts (claims) and entities, with citations. Prefer get_dossier for one specific entity."`
- `rag.ex` (`search_files`) description: append/clarify `"Searches raw document excerpts (verbatim file text), not distilled facts."`
- `search_memories.ex` description: append/clarify `"Searches your curated conversation and user memories, not cross-source claims."`

Keep changes to the `description:` strings only.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `MIX_ENV=test mix test test/magus/super_brain/tools/`
Expected: PASS.

- [ ] **Step 6: Compile check + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git commit -- lib/magus/super_brain/tools/search.ex lib/magus/agents/tools/rag.ex lib/magus/agents/tools/memory/search_memories.ex test/magus/super_brain/tools -m "feat(super-brain): claims in super_brain_search + tool description disambiguation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: backfill_claims task + force gate

**Files:**
- Modify: `lib/magus/super_brain/workers/extract_base.ex` (force arg through the gate)
- Create: `lib/mix/tasks/super_brain.backfill_claims.ex`
- Create: `test/magus/super_brain/workers/extract_base_force_test.exs`

**Interfaces:**
- Consumes: the worker `perform/1` args map, `gate_extract_persist/4`, `gate_on_fingerprint/3`.
- Produces: a `"force" => true` job arg that bypasses BOTH fingerprint gates so unchanged content re-extracts once through the normal supersede path.

- [ ] **Step 1: Write the failing test**

`test/magus/super_brain/workers/extract_base_force_test.exs`: extract a resource once (mock LLM), then re-run `perform` with the SAME content and `"force" => true` and assert it re-extracts (a fresh `:extracted` episode, prior superseded) rather than `:skip_unchanged`. Without `force`, assert it skips.

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/super_brain/workers/extract_base_force_test.exs`
Expected: FAIL (force not honored; second run skips).

- [ ] **Step 3: Thread `force` through the gate**

In `extract_base.ex`, `run_pipeline_enabled/2` already has `args`. Pass a `force?` flag into `gate_extract_persist`. Change `traced_pipeline` / `gate_extract_persist` to read `Map.get(args, "force", false)` and skip the fingerprint gate when true:

```elixir
  defp gate_extract_persist(worker_module, input, started_at, args) do
    new_fingerprint = :crypto.hash(:sha256, input.raw_text || "")
    force? = Map.get(args, "force", false)

    with :ok <- check_budget(input.user_id),
         :continue <- gate_or_force(force?, input.resource_type, input.resource_id, new_fingerprint),
         {:ok, extraction} <- run_extraction(input, started_at) do
      persist_extraction(worker_module, input, extraction, new_fingerprint, args, force?)
    else
      :skip_unchanged -> :ok
      {:error, :budget_exceeded} -> {:cancel, :budget_exceeded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp gate_or_force(true, _rt, _rid, _fp), do: :continue
  defp gate_or_force(false, rt, rid, fp), do: gate_on_fingerprint(rt, rid, fp)
```

Update `persist_extraction/5` to `persist_extraction/6` accepting `force?`, and inside its transaction replace the re-check `gate_on_fingerprint(...)` with `gate_or_force(force?, ...)`. Update the single caller.

- [ ] **Step 4: Run the test to verify it passes**

Run: `MIX_ENV=test mix test test/magus/super_brain/workers/extract_base_force_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the backfill task**

`lib/mix/tasks/super_brain.backfill_claims.ex` (model on `super_brain.backfill.ex`). Detection: the latest `:extracted` episode per resource whose `extractor_version` differs from the worker's current `extractor_version/0`. For each, enqueue the worker with `%{"resource_id" => id, "force" => true}`:

```elixir
defmodule Mix.Tasks.SuperBrain.BackfillClaims do
  @shortdoc "Re-extract a user's pre-claims content so it gains claims."

  @moduledoc """
      mix super_brain.backfill_claims --user <user_id|email> [--dry-run]

  Finds each resource whose latest :extracted episode predates the claims-aware
  extractor version and force-re-extracts it (budget-gated, superseding the old
  episode). Forward-only: only stale-version resources are touched.
  """
  use Mix.Task
  require Ash.Query

  @workers %{
    brain_page: Magus.SuperBrain.Workers.ExtractBrainPage,
    brain_source: Magus.SuperBrain.Workers.ExtractBrainSource,
    memory: Magus.SuperBrain.Workers.ExtractMemory,
    file_chunk: Magus.SuperBrain.Workers.ExtractFileChunk,
    draft: Magus.SuperBrain.Workers.ExtractDraft
  }

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [user: :string, dry_run: :boolean])
    user_arg = Keyword.fetch!(opts, :user)
    dry? = Keyword.get(opts, :dry_run, false)

    Mix.Task.run("app.start")
    user_id = resolve_user_id(user_arg)

    Enum.each(@workers, fn {resource_type, worker} ->
      current = worker.extractor_version()
      stale = stale_episodes(user_id, resource_type, current)
      Mix.shell().info("#{resource_type}: #{length(stale)} stale (target #{current})")

      unless dry? do
        Enum.each(stale, fn ep ->
          %{"resource_id" => ep.resource_id, "force" => true}
          |> worker.new()
          |> Oban.insert!()
        end)
      end
    end)

    Mix.shell().info(if dry?, do: "Dry run: nothing enqueued.", else: "Enqueued.")
  end

  defp stale_episodes(user_id, resource_type, current_version) do
    Magus.SuperBrain.Episode
    |> Ash.Query.filter(
      source_user_id == ^user_id and resource_type == ^resource_type and
        status == :extracted and extractor_version != ^current_version
    )
    |> Ash.read!(authorize?: false)
  end

  defp resolve_user_id(arg) do
    case Ecto.UUID.cast(arg) do
      {:ok, uuid} -> uuid
      :error ->
        case Magus.Accounts.get_by_email(arg, authorize?: false) do
          {:ok, %{id: id}} -> id
          _ -> Mix.raise("No user for #{inspect(arg)}")
        end
    end
  end
end
```

- [ ] **Step 6: Run the full worker suite**

Run: `MIX_ENV=test mix test test/magus/super_brain/workers/`
Expected: PASS.

- [ ] **Step 7: Compile check + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git commit -- lib/magus/super_brain/workers/extract_base.ex lib/mix/tasks/super_brain.backfill_claims.ex test/magus/super_brain/workers/extract_base_force_test.exs -m "feat(super-brain): force re-extract gate + backfill_claims task

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 11: Eval scoring + fixture for claims

**Files:**
- Modify: `lib/magus/eval/super_brain/metrics.ex`
- Modify: `lib/magus/eval/super_brain/fixture.ex`
- Modify: `test/magus/eval/super_brain/metrics_test.exs`, `fixture_test.exs`

**Interfaces:**
- Produces: `Metrics.score/2` grades cases with `meta.target == "claims"` by matching normalized `(subject, predicate, object)` triples (default `"entities"` preserves current behavior).
- Produces: `Fixture` parses a `claims` list and exposes `Fixture.expand_basis(%{"hot" => i}, dim \\ 1536) :: [float]`.

- [ ] **Step 1: Write the failing tests**

Add to `metrics_test.exs`:

```elixir
  test "grades claim-target cases by (subject, predicate, object) triples" do
    results = [
      %{id: "c1", meta: %{
        target: "claims", supported: true, category: "claim_recall", k: 5,
        expected: [%{"subject" => "Aurora", "predicate" => "occurs_at", "object" => "Q3"}],
        retrieved: [%{"subject" => "aurora", "predicate" => "occurs_at", "object" => "q3"}]
      }}
    ]

    assert %{aggregate: 1.0} = Magus.Eval.SuperBrain.Metrics.score(results, [])
  end
```

Add to `fixture_test.exs`:

```elixir
  test "parses claims and expands basis vectors" do
    f = Magus.Eval.SuperBrain.Fixture.parse(%{"claims" => [%{"subject" => "Aurora", "predicate" => "occurs_at", "object" => "Q3", "claim_text" => "Aurora targets Q3.", "embedding" => %{"hot" => 2}}]})
    assert [%{subject: "Aurora"}] = f.claims
    vec = Magus.Eval.SuperBrain.Fixture.expand_basis(%{"hot" => 2})
    assert length(vec) == 1536
    assert Enum.at(vec, 2) == 1.0
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `MIX_ENV=test mix test test/magus/eval/super_brain/metrics_test.exs test/magus/eval/super_brain/fixture_test.exs`
Expected: FAIL.

- [ ] **Step 3: Extend Metrics for claim triples**

In `metrics.ex`, change `grade/1` to branch on target:

```elixir
  defp grade(%{id: id, meta: meta}) do
    target = get(meta, :target) || "entities"
    expected = normalize_expected(target, get(meta, :expected) || [])
    retrieved = normalize_retrieved(target, get(meta, :retrieved) || [])
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

  defp normalize_expected("claims", list), do: Enum.map(list, &triple/1)
  defp normalize_expected(_entities, list), do: Enum.map(list, &normalize_one/1)
  defp normalize_retrieved("claims", list), do: Enum.map(list, &triple/1)
  defp normalize_retrieved(_entities, list), do: Enum.map(list, &normalize_one/1)

  defp triple(%{} = m), do: {down(get(m, :subject)), down(get(m, :predicate)), down(get(m, :object))}
```

- [ ] **Step 4: Extend Fixture for claims + basis vectors**

In `fixture.ex`, add `claims: []` to the struct and type, parse them in `parse/1`, and add:

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
      confidence: Map.get(c, "confidence", 0.8)
    }
  end

  @doc "Expands a basis spec `%{\"hot\" => i}` to a `dim`-length one-hot vector."
  def expand_basis(%{"hot" => i}, dim \\ 1536) do
    List.duplicate(0.0, dim) |> List.replace_at(i, 1.0)
  end
```

Parse: `claims: Enum.map(Map.get(raw, "claims", []), &claim/1)`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `MIX_ENV=test mix test test/magus/eval/super_brain/metrics_test.exs test/magus/eval/super_brain/fixture_test.exs`
Expected: PASS.

- [ ] **Step 6: Compile check + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git commit -- lib/magus/eval/super_brain/metrics.ex lib/magus/eval/super_brain/fixture.ex test/magus/eval/super_brain/metrics_test.exs test/magus/eval/super_brain/fixture_test.exs -m "feat(eval): claim-triple scoring + claim fixtures + basis vectors

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 12: Deterministic subject claims + cases + regression test

**Files:**
- Modify: `test/support/eval/subject/super_brain_deterministic.ex`
- Modify: `priv/eval/super_brain_retrieval/cases.json`
- Modify: `test/magus/super_brain/eval/super_brain_retrieval_test.exs`

**Interfaces:**
- Consumes: `Fixture` claims + `expand_basis/2` (Task 11), `Claim.create` (Task 1), `Retrieval.search_claims/2` (Task 5).
- Produces: the deterministic subject seeds `Claim` rows and, for claim-target cases, returns retrieved triples in `meta.retrieved`.

- [ ] **Step 1: Add the failing cases to cases.json**

Append two cases to `priv/eval/super_brain_retrieval/cases.json`. A `claim_recall` supported case (deterministic + live) whose `claim_query_embedding` sits at a basis index matching one claim, and a `temporal` xfail (deterministic) with two claims on one triple where the stale one is embedding-closer:

```json
{
  "id": "claim_recall_aurora_wrapper",
  "category": "claim_recall",
  "supported": true,
  "target": "claims",
  "subjects": ["deterministic", "live"],
  "query": "does Aurora ship with the npm wrapper",
  "query_embedding": [0,0,0,0,0,0,0,0],
  "claim_query_embedding": {"hot": 5},
  "k": 5,
  "expected": [{"subject": "Aurora", "predicate": "excludes", "object": "npm wrapper"}],
  "fixture": {
    "entities": [
      {"key": "aurora", "name": "Aurora", "type": "project", "embedding": [1,0,0,0,0,0,0,0]},
      {"key": "wrapper", "name": "npm wrapper", "type": "concept", "embedding": [0,1,0,0,0,0,0,0]}
    ],
    "edges": [],
    "sources": [],
    "claims": [
      {"subject": "Aurora", "predicate": "excludes", "object": "npm wrapper",
       "claim_text": "Aurora ships without the npm wrapper.", "embedding": {"hot": 5}}
    ]
  }
},
{
  "id": "temporal_ship_quarter",
  "category": "temporal",
  "supported": false,
  "target": "claims",
  "subjects": ["deterministic"],
  "query": "when does Aurora ship",
  "query_embedding": [0,0,0,0,0,0,0,0],
  "claim_query_embedding": {"hot": 7},
  "k": 1,
  "expected": [{"subject": "Aurora", "predicate": "occurs_at", "object": "Q4"}],
  "fixture": {
    "entities": [{"key": "aurora", "name": "Aurora", "type": "project", "embedding": [1,0,0,0,0,0,0,0]}],
    "edges": [],
    "sources": [],
    "claims": [
      {"subject": "Aurora", "predicate": "occurs_at", "object": "Q4",
       "claim_text": "Aurora now ships in Q4.", "embedding": {"hot": 9}, "asserted_at": "2026-06-01T00:00:00Z"},
      {"subject": "Aurora", "predicate": "occurs_at", "object": "Q3",
       "claim_text": "Aurora ships in Q3.", "embedding": {"hot": 7}, "asserted_at": "2026-05-01T00:00:00Z"}
    ]
  }
}
```

Note: the `temporal` xfail expects Q4 (latest) but the query vector (`hot: 7`) is nearest the stale Q3 claim, so similarity-only ranking returns Q3 at `k: 1`: recall stays 0 until temporal ranking lands. The benchmark's `to_case/1` must forward `target` and `claim_query_embedding`; see Step 3.

- [ ] **Step 2: Forward the new case fields in the benchmark**

In `lib/magus/eval/benchmarks/super_brain_retrieval.ex`, `to_case/1`: add `target: c["target"] || "entities"` to `meta`, and include `claim_query_embedding` in the `fixture_payload` map so the subject receives it:

```elixir
    fixture_payload = %{
      "fixture" => c["fixture"],
      "query_embedding" => c["query_embedding"],
      "claim_query_embedding" => c["claim_query_embedding"]
    }
```

and in `meta`: `target: c["target"] || "entities",`.

- [ ] **Step 3: Seed claims in the deterministic subject**

In `test/support/eval/subject/super_brain_deterministic.ex`:

`ingest/2`: after seeding the super graph, also insert `Claim` rows from `fixture.claims` (basis-expanded embeddings tied to a seeded episode-less row: `episode_id` may be a generated UUID since the deterministic subject does not exercise provenance joins), and stash `claim_query_embedding` on ctx:

```elixir
    seed_claims(ctx.user, fixture)

    {:ok,
     ctx
     |> Map.put(:query_embedding, query_embedding)
     |> Map.put(:claim_query_embedding, expand(Map.get(decoded, "claim_query_embedding")))}
```

where `decoded` is the full `Jason.decode!(text)` map. Add:

```elixir
  alias Magus.Eval.SuperBrain.Fixture
  alias Magus.SuperBrain.Claim

  defp expand(nil), do: nil
  defp expand(%{"hot" => _} = basis), do: Fixture.expand_basis(basis)

  defp seed_claims(user, fixture) do
    graph = "memories:user:#{user.id}"
    ep = seed_episode(graph, user.id)   # one episode per case; Claim.episode_id is a hard FK

    Enum.each(fixture.claims, fn c ->
      Claim
      |> Ash.Changeset.for_create(:create, %{
        graph_name: graph,
        episode_id: ep.id,
        source_user_id: user.id,
        subject_name: c.subject, subject_key: key(c.subject),
        object_name: c.object, object_key: key(c.object),
        predicate: c.predicate, polarity: String.to_existing_atom(c.polarity),
        claim_text: c.claim_text, confidence: c.confidence, trust_tier: :evidence,
        asserted_at: DateTime.utc_now(),
        embedding: c.embedding && Fixture.expand_basis(c.embedding)
      })
      |> Ash.create(authorize?: false)
    end)
  end

  defp key(s), do: s |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
```

For the graph to be accessible, the deterministic subject's `seed_super_row` snapshot already lists `memories:user:<id>` only if the user has memories. Since claims filter by `graph_name in accessible_graphs`, ensure the eval user's accessible set includes `memories:user:<id>`: seed a throwaway memory in `reset/1` OR (simpler) have `query/2` pass `accessible_graphs: ["memories:user:#{ctx.user.id}"]` directly to `search_claims/2`. Use the explicit `accessible_graphs` option to keep the subject self-contained.

`query/2`: for claim-target cases (detect via `ctx.claim_query_embedding != nil`), call `search_claims` and return triples:

```elixir
  def query(ctx, question) do
    if ctx[:claim_query_embedding] do
      {:ok, claims} =
        Retrieval.search_claims(ctx.user,
          query_embedding: ctx.claim_query_embedding,
          accessible_graphs: ["memories:user:#{ctx.user.id}"],
          limit: 10
        )

      {:ok, %{answer: "", meta: %{retrieved: Enum.map(claims, &claim_triple/1)}}}
    else
      # ... existing entity-search branch unchanged ...
    end
  end

  defp claim_triple(c), do: %{subject: c.subject_name, predicate: c.predicate, object: c.object_name}
```

- [ ] **Step 4: Update the regression test**

In `test/magus/super_brain/eval/super_brain_retrieval_test.exs`, the supported aggregate must remain 1.0 (now including `claim_recall`), and the `temporal` xfail must fail. The existing xfail loop should already assert every `supported: false` case fails; confirm `temporal` is covered. Run with `subject_kind: :deterministic, dry_run: true`.

- [ ] **Step 5: Run the tests**

Run: `MIX_ENV=test mix test test/magus/super_brain/eval/super_brain_retrieval_test.exs`
Expected: PASS (supported aggregate 1.0; temporal xfail fails-as-required).

- [ ] **Step 6: Compile check + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git commit -- test/support/eval/subject/super_brain_deterministic.ex lib/magus/eval/benchmarks/super_brain_retrieval.ex priv/eval/super_brain_retrieval/cases.json test/magus/super_brain/eval/super_brain_retrieval_test.exs -m "feat(eval): deterministic claim recall + temporal xfail

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 13: Live subject claims + :e2e_live test

**Files:**
- Modify: `test/support/eval/subject/super_brain_live.ex`
- Modify: `test/e2e_live/super_brain_retrieval_eval_test.exs`

**Interfaces:**
- Consumes: `Magus.Files.EmbeddingModel.embed/1` (real), `Claim.create`, `Retrieval.search_claims/2`.
- Produces: the live subject seeds `Claim` rows with real embeddings for claim-target cases and queries via a real embedding.

- [ ] **Step 1: Seed claims with real embeddings in the live subject**

In `test/support/eval/subject/super_brain_live.ex`, `ingest/2`: for `fixture.claims`, embed each `claim_text` via `Magus.Files.EmbeddingModel.embed/1` and insert a `Claim` row tied to the brain graph the subject already creates. `query/2`: when the case is claim-target (carry the flag through ctx as in the deterministic subject), embed the question via `EmbeddingModel.embed/1` and call `search_claims/2` with the brain graph in `accessible_graphs`.

```elixir
  defp seed_claims(ctx, fixture) do
    graph = ctx.brain_graph   # the "brain:<id>" the live subject already builds
    ep = seed_episode(graph, ctx.user.id)   # one episode per case; Claim.episode_id is a hard FK

    Enum.each(fixture.claims, fn c ->
      {:ok, embedding} = Magus.Files.EmbeddingModel.embed(c.claim_text)

      Magus.SuperBrain.Claim
      |> Ash.Changeset.for_create(:create, %{
        graph_name: graph, episode_id: ep.id, source_user_id: ctx.user.id,
        subject_name: c.subject, subject_key: key(c.subject),
        object_name: c.object, object_key: key(c.object),
        predicate: c.predicate, polarity: :affirms, claim_text: c.claim_text,
        confidence: c.confidence, trust_tier: :evidence, asserted_at: DateTime.utc_now(),
        embedding: embedding
      })
      |> Ash.create(authorize?: false)
    end)
  end
```

(Match `ctx.brain_graph` to whatever key the live subject already stores for its Layer 1 brain graph; if it stores it under a different name, reuse that.)

- [ ] **Step 2: Extend the :e2e_live test**

In `test/e2e_live/super_brain_retrieval_eval_test.exs`, ensure the live run includes `claim_recall` (it is `subjects: ["deterministic","live"]`). Assert the run aggregate includes the claim case at recall 1.0. Keep it `:e2e_live` tagged.

- [ ] **Step 3: Run the live eval (requires OPENROUTER_API_KEY)**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/e2e_live/super_brain_retrieval_eval_test.exs --include e2e_live`
Expected: PASS with real embeddings.

- [ ] **Step 4: Commit**

```bash
git commit -- test/support/eval/subject/super_brain_live.ex test/e2e_live/super_brain_retrieval_eval_test.exs -m "feat(eval): live claim recall with real embeddings

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 14: Documentation

**Files:**
- Modify: `docs/system/15-super-brain.md`

- [ ] **Step 1: Document the claims layer**

Add a "Claims (Layer 0 propositional store)" section describing: the `super_brain_claims` table and its columns; that claims are extracted in the same LLM call (prompt v2, no edge-density quota); that L1 `RELATES_TO` edges are derived from claims; the supersede-delete lifecycle; `Retrieval.search_claims/2`; the claim-centered `<super_brain>` block; the `get_dossier` tool; and `mix super_brain.backfill_claims`. Update the "Extraction Pipeline" and "Agent integration" sections to mention claims. Add `Claim` to the Ash Resources table and `get_dossier` to the tools table.

- [ ] **Step 2: Commit**

```bash
git commit -- docs/system/15-super-brain.md -m "docs(super-brain): document the claims layer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] Run the full super_brain + eval suite: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/super_brain/ test/magus/eval/ test/magus/agents/context/super_brain_rag_context_test.exs`. Expected: 0 failures (scope any count checks to seeded rows; a leaked `super_brain_super_graphs` row is environmental, clear with `DELETE FROM super_brain_super_graphs` if `MigrationSweeperTest` / retrieval cold-start flake).
- [ ] `MIX_ENV=test mix compile --warnings-as-errors` clean.
- [ ] `mix precommit` if time permits (compile + format + non-e2e tests).
