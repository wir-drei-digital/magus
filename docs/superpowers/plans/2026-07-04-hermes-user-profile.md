# Hermes-Style User Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single, size-capped, rewritten-in-place user profile document per (user, workspace) bucket as the distilled memory layer, injected into every conversation, behind a feature flag, with its own eval benchmark plus a LongMemEval A/B run.

**Architecture:** The episodic Memory store stays as-is (provenance, semantic recall, Super Brain feed). A new `UserProfile` resource holds one living document per bucket. A `DistillUserProfile` LLM action rewrites the ENTIRE document from (current document + active user-scope memories + pending agent notes), enforcing a ~800-token cap. It runs inside the existing daily `ConsolidateMemories` pass. When the flag is on and a profile exists, `BuildMemoryContext` injects the document and drops the top-3-recency global key-memory layer it replaces. Agents queue mid-session signals via an `update_profile` tool (notes fold in at the next distillation; the tool never edits the document directly).

**Tech Stack:** Ash 3.x resources + policies, Jido actions, Mox (LLMMock), Magus.Eval (new `profile_distill` benchmark + subject).

## Global Constraints

- **Depends on the memory-hardening plan** (`2026-07-04-memory-hardening.md`) being merged first: it establishes the eval baseline and the `turns` extraction interface.
- NEVER run `mix ash.reset`. Schema changes via `mix ash.codegen <name>` + `mix ash.migrate`.
- Before push: `MIX_ENV=test mix compile --warnings-as-errors`.
- Feature flag: profile behavior is OFF unless `MAGUS_MEMORY_PROFILE=1` (env) or `config :magus, memory_profile_enabled: true`. Nothing user-visible changes with the flag off.
- Profile document hard cap: 800 tokens estimated as `div(String.length(doc), 4)`, i.e. 3200 chars distiller target, 4000 chars resource-level hard validation.
- Nullable Jido schema fields MUST use `{:or, [<type>, nil]}`.
- Eval runs need `.env` (`set -a && source .env && set +a`); LongMemEval runs always use `--limit 60`.
- No em dashes in prose. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: UserProfile + UserProfileVersion resources

**Files:**
- Create: `lib/magus/memory/user_profile.ex`
- Create: `lib/magus/memory/user_profile_version.ex`
- Create: `lib/magus/memory/user_profile/validations/document_size.ex`
- Create: `lib/magus/memory/user_profile/changes/create_version.ex`
- Modify: `lib/magus/memory/memory.ex` (domain resource block + code interfaces)
- Test: `test/magus/memory/user_profile_test.exs`

**Interfaces:**
- Produces (code interfaces on `Magus.Memory`):
  - `create_user_profile(user_id, workspace_id, %{document: doc}, opts)` (workspace_id may be nil)
  - `get_user_profile(user_id, workspace_id, opts)` returns `{:ok, profile}` or a NotFound error
  - `set_profile_document(profile, %{document: doc}, opts)` (recomputes `token_estimate`, sets `last_distilled_at`, clears `pending_notes`, snapshots a version)
  - `add_profile_note(profile, note, opts)` (appends to `pending_notes`, kept to last 20)
- Profile fields consumed by later tasks: `document`, `pending_notes`, `token_estimate`, `last_distilled_at`, `user_id`, `workspace_id`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/memory/user_profile_test.exs`:

```elixir
defmodule Magus.Memory.UserProfileTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Support.AiAgent

  @ai %AiAgent{}

  test "one profile per (user, nil-workspace) bucket, set_document rewrites in place" do
    user = generate(user())

    {:ok, profile} =
      Magus.Memory.create_user_profile(user.id, nil, %{document: "## Current Focus\nInitial"}, actor: @ai)

    {:ok, fetched} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
    assert fetched.id == profile.id

    {:ok, updated} =
      Magus.Memory.set_profile_document(profile, %{document: "## Current Focus\nRewritten"}, actor: @ai)

    assert updated.document =~ "Rewritten"
    assert updated.token_estimate == div(String.length(updated.document), 4)
    refute is_nil(updated.last_distilled_at)
    assert updated.pending_notes == []

    # A second create in the same bucket violates the identity
    assert {:error, _} =
             Magus.Memory.create_user_profile(user.id, nil, %{document: "dup"}, actor: @ai)
  end

  test "set_document snapshots a version" do
    user = generate(user())
    {:ok, profile} = Magus.Memory.create_user_profile(user.id, nil, %{document: "v0"}, actor: @ai)
    {:ok, _} = Magus.Memory.set_profile_document(profile, %{document: "v1"}, actor: @ai)

    {:ok, versions} = Magus.Memory.list_profile_versions(profile.id, actor: @ai)
    assert Enum.any?(versions, &(&1.document == "v1"))
  end

  test "add_note appends and set_document drains notes" do
    user = generate(user())
    {:ok, profile} = Magus.Memory.create_user_profile(user.id, nil, %{document: ""}, actor: @ai)

    {:ok, with_note} = Magus.Memory.add_profile_note(profile, "prefers concise answers", actor: @ai)
    assert with_note.pending_notes == ["prefers concise answers"]

    {:ok, drained} = Magus.Memory.set_profile_document(with_note, %{document: "## Preferences\nConcise"}, actor: @ai)
    assert drained.pending_notes == []
  end

  test "documents over 4000 chars are rejected" do
    user = generate(user())
    {:ok, profile} = Magus.Memory.create_user_profile(user.id, nil, %{document: ""}, actor: @ai)

    assert {:error, _} =
             Magus.Memory.set_profile_document(profile, %{document: String.duplicate("x", 4001)}, actor: @ai)
  end

  test "another user cannot read the profile" do
    owner = generate(user())
    other = generate(user())
    {:ok, _} = Magus.Memory.create_user_profile(owner.id, nil, %{document: "secret"}, actor: @ai)

    assert {:error, _} = Magus.Memory.get_user_profile(owner.id, nil, actor: other)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/memory/user_profile_test.exs`
Expected: FAIL with `function Magus.Memory.create_user_profile/4 is undefined`.

- [ ] **Step 3: Create the validation module**

Create `lib/magus/memory/user_profile/validations/document_size.ex`:

```elixir
defmodule Magus.Memory.UserProfile.Validations.DocumentSize do
  @moduledoc """
  Hard cap on the profile document. The distiller targets 3200 chars
  (~800 tokens); this is the resource-level backstop at 4000 chars.
  """
  use Ash.Resource.Validation

  @max_chars 4000

  @impl true
  def validate(changeset, _opts, _context) do
    document = Ash.Changeset.get_attribute(changeset, :document) || ""

    if String.length(document) <= @max_chars do
      :ok
    else
      {:error, field: :document, message: "must be at most #{@max_chars} characters"}
    end
  end
end
```

- [ ] **Step 4: Create the version resource**

Create `lib/magus/memory/user_profile_version.ex`:

```elixir
defmodule Magus.Memory.UserProfileVersion do
  @moduledoc """
  Immutable snapshot of a UserProfile document, captured on every
  set_document. Mirrors MemoryVersion.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Memory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "user_profile_versions"
    repo Magus.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:document, :token_estimate, :changed_by]
      argument :user_profile_id, :uuid, allow_nil?: false
      change manage_relationship(:user_profile_id, :user_profile, type: :append)
    end

    read :for_profile do
      argument :user_profile_id, :uuid, allow_nil?: false
      filter expr(user_profile_id == ^arg(:user_profile_id))
      prepare build(sort: [inserted_at: :desc])
    end
  end

  policies do
    bypass action_type(:create) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
      authorize_if relates_to_actor_via([:user_profile, :user])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :document, :string, allow_nil?: false, default: ""
    attribute :token_estimate, :integer, allow_nil?: false, default: 0

    attribute :changed_by, :atom do
      constraints one_of: [:distiller, :system]
      default :system
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user_profile, Magus.Memory.UserProfile, allow_nil?: false
  end
end
```

- [ ] **Step 5: Create the version-snapshot change**

Create `lib/magus/memory/user_profile/changes/create_version.ex`:

```elixir
defmodule Magus.Memory.UserProfile.Changes.CreateVersion do
  @moduledoc "Snapshots the profile document after every set_document."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, profile ->
      changed_by = if match?(%Magus.Agents.Support.AiAgent{}, context.actor), do: :distiller, else: :system

      {:ok, _version} =
        Magus.Memory.create_profile_version(
          %{
            user_profile_id: profile.id,
            document: profile.document,
            token_estimate: profile.token_estimate,
            changed_by: changed_by
          },
          authorize?: false
        )

      {:ok, profile}
    end)
  end
end
```

- [ ] **Step 6: Create the profile resource**

Create `lib/magus/memory/user_profile.ex`:

```elixir
defmodule Magus.Memory.UserProfile do
  @moduledoc """
  Singleton distilled profile document per (user, workspace bucket).

  Hermes-style working memory: ONE living document per bucket, rewritten in
  place by DistillUserProfile, never appended to. The episodic Memory rows
  remain the source layer; this is the distilled layer injected into every
  conversation. workspace_id nil is the personal bucket (nils_distinct?: false
  on the identity makes it a real singleton).
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Memory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "user_profiles"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      argument :user_id, :uuid, allow_nil?: false
      argument :workspace_id, :uuid, allow_nil?: true
      accept [:document]

      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:workspace_id, arg(:workspace_id))
      validate Magus.Memory.UserProfile.Validations.DocumentSize
    end

    read :for_bucket do
      get? true
      argument :user_id, :uuid, allow_nil?: false
      argument :workspace_id, :uuid, allow_nil?: true

      prepare fn query, _context ->
        require Ash.Query

        user_id = Ash.Query.get_argument(query, :user_id)
        workspace_id = Ash.Query.get_argument(query, :workspace_id)

        query = Ash.Query.filter(query, user_id == ^user_id)

        if is_nil(workspace_id) do
          Ash.Query.filter(query, is_nil(workspace_id))
        else
          Ash.Query.filter(query, workspace_id == ^workspace_id)
        end
      end
    end

    update :set_document do
      accept [:document]
      require_atomic? false

      validate Magus.Memory.UserProfile.Validations.DocumentSize

      change fn changeset, _context ->
        document = Ash.Changeset.get_attribute(changeset, :document) || ""

        changeset
        |> Ash.Changeset.force_change_attribute(:token_estimate, div(String.length(document), 4))
        |> Ash.Changeset.force_change_attribute(:last_distilled_at, DateTime.utc_now())
        |> Ash.Changeset.force_change_attribute(:pending_notes, [])
      end

      change Magus.Memory.UserProfile.Changes.CreateVersion
    end

    update :add_note do
      argument :note, :string, allow_nil?: false
      require_atomic? false

      change fn changeset, _context ->
        note = Ash.Changeset.get_argument(changeset, :note)
        notes = (changeset.data.pending_notes ++ [note]) |> Enum.take(-20)
        Ash.Changeset.force_change_attribute(changeset, :pending_notes, notes)
      end
    end
  end

  policies do
    bypass action_type([:read, :create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:create) do
      authorize_if Magus.Memory.Memory.Checks.UserIdMatchesActor
    end

    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type([:update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :document, :string, allow_nil?: false, default: ""
    attribute :pending_notes, {:array, :string}, allow_nil?: false, default: []
    attribute :token_estimate, :integer, allow_nil?: false, default: 0
    attribute :last_distilled_at, :utc_datetime_usec

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User, allow_nil?: false
    belongs_to :workspace, Magus.Workspaces.Workspace, allow_nil?: true

    has_many :versions, Magus.Memory.UserProfileVersion do
      destination_attribute :user_profile_id
    end
  end

  identities do
    identity :unique_bucket, [:user_id, :workspace_id], nils_distinct?: false
  end
end
```

Note: `Magus.Memory.Memory.Checks.UserIdMatchesActor` is the existing argument-based check at `lib/magus/memory/memory/checks/user_id_matches_actor.ex`. If it reads the `:user_id` argument (it does for Memory's create), it works here unchanged because our create also takes `user_id` as an argument.

- [ ] **Step 7: Register in the domain**

In `lib/magus/memory/memory.ex`, inside the `resources do ... end` block, add:

```elixir
    resource Magus.Memory.UserProfile do
      define :create_user_profile, action: :create, args: [:user_id, :workspace_id]
      define :get_user_profile, action: :for_bucket, args: [:user_id, :workspace_id]
      define :set_profile_document, action: :set_document
      define :add_profile_note, action: :add_note, args: [:note]
    end

    resource Magus.Memory.UserProfileVersion do
      define :create_profile_version, action: :create
      define :list_profile_versions, action: :for_profile, args: [:user_profile_id]
    end
```

- [ ] **Step 8: Generate and run the migration**

Run:
```bash
mix ash.codegen add_user_profiles
mix ash.migrate
```
Expected: migrations creating `user_profiles` (with a unique index on `(user_id, workspace_id)` where nils compare equal, i.e. `NULLS NOT DISTINCT`) and `user_profile_versions`. Inspect for unrelated drift; stop if any appears.

- [ ] **Step 9: Run tests**

Run: `mix test test/magus/memory/user_profile_test.exs`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/magus/memory priv/repo/migrations priv/resource_snapshots test/magus/memory/user_profile_test.exs
git commit -m "feat(memory): UserProfile singleton resource with versioning and pending notes" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: DistillUserProfile action

**Files:**
- Create: `lib/magus/agents/actions/distill_user_profile.ex`
- Test: `test/magus/agents/actions/distill_user_profile_test.exs`

**Interfaces:**
- Consumes: `Magus.Memory.get_user_profile/3`, `create_user_profile/4`, `set_profile_document/3`, `Magus.Memory.list_user_memories(workspace_id, actor:)` (returns active user-scope memories, most recent first), `Magus.Agents.Clients.LLM.llm_client().generate_object/4`, `Magus.Agents.Config.extraction_model/0`, `Magus.Agents.Persistence.UsageRecorder.record!/1`.
- Produces: `DistillUserProfile.run(%{user_id: String.t(), workspace_id: String.t() | nil, model: String.t() | nil}, %{})` returning `{:ok, %{document: String.t(), token_estimate: integer()}}` or `{:error, term()}`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/agents/actions/distill_user_profile_test.exs`:

```elixir
defmodule Magus.Agents.Actions.DistillUserProfileTest do
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.DistillUserProfile
  alias Magus.Agents.Support.AiAgent
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  @ai %AiAgent{}

  test "rewrites the profile from memories and pending notes, draining notes" do
    user = generate(user())

    {:ok, _} =
      Magus.Memory.create_user_memory(
        user.id,
        nil,
        "Preferred Stack",
        %{content: %{}, summary: "Prefers Elixir and Phoenix for all projects"},
        actor: @ai
      )

    {:ok, profile} = Magus.Memory.create_user_profile(user.id, nil, %{document: "## Preferences\nOld"}, actor: @ai)
    {:ok, _} = Magus.Memory.add_profile_note(profile, "responds well to short answers", actor: @ai)

    expect(LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
      assert prompt =~ "Prefers Elixir and Phoenix"
      assert prompt =~ "responds well to short answers"
      assert prompt =~ "## Preferences\nOld"

      MockResponses.generate_object_response(%{
        "document" => "## Preferences\nElixir/Phoenix. Short answers."
      })
    end)

    assert {:ok, %{document: doc}} =
             DistillUserProfile.run(%{user_id: to_string(user.id), workspace_id: nil}, %{})

    assert doc =~ "Elixir/Phoenix"

    {:ok, reloaded} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
    assert reloaded.document == doc
    assert reloaded.pending_notes == []
  end

  test "creates the profile row on first distillation" do
    user = generate(user())

    expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
      MockResponses.generate_object_response(%{"document" => "## Current Focus\nNothing yet"})
    end)

    assert {:ok, _} = DistillUserProfile.run(%{user_id: to_string(user.id), workspace_id: nil}, %{})
    assert {:ok, _profile} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
  end

  test "retries once when the document exceeds the cap, then errors" do
    user = generate(user())
    too_long = String.duplicate("y", 3500)

    expect(LLMMock, :generate_object, 2, fn _model, _prompt, _schema, _opts ->
      MockResponses.generate_object_response(%{"document" => too_long})
    end)

    assert {:error, :document_too_long} =
             DistillUserProfile.run(%{user_id: to_string(user.id), workspace_id: nil}, %{})
  end
end
```

Note: if `Magus.Memory.create_user_memory/5` does not accept a bare map with `content`/`summary` in that shape, check `test/magus/agents/actions/extract_turn_memories_test.exs` for the exact call convention used elsewhere and mirror it.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/agents/actions/distill_user_profile_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 3: Implement the action**

Create `lib/magus/agents/actions/distill_user_profile.ex`:

```elixir
defmodule Magus.Agents.Actions.DistillUserProfile do
  @moduledoc """
  Rewrites the distilled user profile document (Hermes-style working memory).

  Reads the current document, the bucket's active user-scope memories, and
  pending agent notes, then asks the LLM to REWRITE the whole document under
  a hard token cap. Rewriting (not merging) is the mechanism that resolves
  contradictions and drops completed or one-off information. Runs from the
  daily ConsolidateMemories pass; safe to call ad hoc.
  """

  use Jido.Action,
    name: "distill_user_profile",
    description: "Rewrites the distilled user profile document from user-scope memories",
    schema: [
      user_id: [type: :string, required: true, doc: "User ID"],
      workspace_id: [type: {:or, [:string, nil]}, default: nil, doc: "Workspace bucket (nil = personal)"],
      model: [type: {:or, [:string, nil]}, default: nil, doc: "Model key override"]
    ]

  require Logger

  alias Magus.Agents.Clients.LLM, as: LLMClient
  alias Magus.Agents.Config
  alias Magus.Agents.Persistence.UsageRecorder
  alias Magus.Agents.Support.AiAgent
  alias Magus.Memory

  @actor %AiAgent{}
  @max_chars 3200
  @max_memories 50

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "document" => %{
        "type" => "string",
        "description" => "The complete rewritten profile document (markdown)"
      }
    },
    "required" => ["document"]
  }

  @impl true
  def run(params, _context) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)
    user_id = params["user_id"]
    workspace_id = params["workspace_id"]
    model = params["model"] || Config.extraction_model()

    with {:ok, profile} <- get_or_create_profile(user_id, workspace_id),
         memories = load_memories(user_id, workspace_id),
         {:ok, document, usage} <- generate_document(model, profile, memories),
         {:ok, updated} <- Memory.set_profile_document(profile, %{document: document}, actor: @actor) do
      record_usage(user_id, model, usage)
      {:ok, %{document: updated.document, token_estimate: updated.token_estimate}}
    end
  end

  defp get_or_create_profile(user_id, workspace_id) do
    case Memory.get_user_profile(user_id, workspace_id, actor: @actor) do
      {:ok, profile} when not is_nil(profile) -> {:ok, profile}
      _ -> Memory.create_user_profile(user_id, workspace_id, %{document: ""}, actor: @actor)
    end
  end

  defp load_memories(user_id, workspace_id) do
    actor = %Magus.Accounts.User{id: user_id}

    case Memory.list_user_memories(workspace_id, actor: actor) do
      {:ok, memories} -> Enum.take(memories, @max_memories)
      _ -> []
    end
  end

  defp generate_document(model, profile, memories) do
    prompt = build_prompt(profile, memories)

    with {:ok, document, usage} <- call_llm(model, prompt) do
      if String.length(document) <= @max_chars do
        {:ok, document, usage}
      else
        retry_prompt =
          prompt <>
            "\n\nYour previous draft was #{String.length(document)} characters, over the " <>
            "#{@max_chars} character limit. Rewrite it under the limit by dropping the " <>
            "least durable information."

        case call_llm(model, retry_prompt) do
          {:ok, retried, retry_usage} when byte_size(retried) > 0 ->
            if String.length(retried) <= @max_chars do
              {:ok, retried, retry_usage}
            else
              {:error, :document_too_long}
            end

          _ ->
            {:error, :document_too_long}
        end
      end
    end
  end

  defp call_llm(model, prompt) do
    case LLMClient.llm_client().generate_object(model, prompt, @output_schema,
           system_prompt: system_prompt()
         ) do
      {:ok, response} -> {:ok, to_string(response.object["document"] || ""), response.usage}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_prompt(profile, memories) do
    """
    ## Current Profile Document

    #{if profile.document == "", do: "(empty)", else: profile.document}

    ## Stored User Memories (most recent first)

    #{format_memories(memories)}

    ## Pending Notes From Recent Sessions

    #{format_notes(profile.pending_notes)}

    ## Instructions

    Rewrite the COMPLETE profile document now, following the system rules.
    """
  end

  defp format_memories([]), do: "None"

  defp format_memories(memories) do
    Enum.map_join(memories, "\n", fn m ->
      kind = if m.kind && m.kind != :general, do: " [#{m.kind}]", else: ""
      "- **#{m.name}**#{kind} (updated #{Date.to_iso8601(DateTime.to_date(m.updated_at))}): #{m.summary || "(no summary)"}"
    end)
  end

  defp format_notes([]), do: "None"
  defp format_notes(notes), do: Enum.map_join(notes, "\n", &("- " <> &1))

  defp system_prompt do
    """
    You maintain a single distilled profile document for a user. You rewrite
    the ENTIRE document from scratch each time, based on the current document,
    the user's stored memories, and pending notes.

    Structure (markdown, only these sections, omit ones that would be empty):
    ## Current Focus
    ## Active Projects
    ## Behavioral Patterns
    ## Preferences
    ## Open Threads

    Rules:
    - Hard limit: #{@max_chars} characters (~800 tokens). Compression is the
      point: keep only signal that has repeated or proven durable.
    - Update, do not append: replace outdated statements instead of adding
      qualifiers to them.
    - Resolve contradictions in favor of the most recently updated source.
    - Drop completed work and one-off facts with no behavioral relevance.
    - At most 4 active projects.
    - Plain declarative statements. No preamble, no meta-commentary.
    """
  end

  defp record_usage(user_id, model_key, usage) do
    UsageRecorder.record!(
      user_id: user_id,
      conversation_id: nil,
      model_key: model_key,
      usage: usage,
      usage_type: :response,
      billable: false,
      action_name: "distill_user_profile"
    )
  rescue
    e -> Logger.warning("DistillUserProfile: usage recording failed: #{Exception.message(e)}")
  end
end
```

Note: if `UsageRecorder.record!/1` rejects `conversation_id: nil`, check how `Magus.Agents.Actions.ConsolidateMemories` records usage without a conversation and mirror that call exactly.

- [ ] **Step 4: Run tests**

Run: `mix test test/magus/agents/actions/distill_user_profile_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/magus/agents/actions/distill_user_profile.ex test/magus/agents/actions/distill_user_profile_test.exs
git commit -m "feat(memory): DistillUserProfile action rewrites the profile document under a token cap" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Feature flag + daily consolidation wiring

**Files:**
- Modify: `lib/magus/agents/config.ex` (add `profile_enabled?/0`)
- Modify: `lib/magus/agents/actions/consolidate_memories.ex` (distill step per bucket)
- Test: `test/magus/agents/actions/consolidate_memories_profile_test.exs` (new)

**Interfaces:**
- Produces: `Magus.Agents.Config.profile_enabled?() :: boolean` (env `MAGUS_MEMORY_PROFILE=1` or app config `:memory_profile_enabled`, default false).
- Consumes: `DistillUserProfile.run/2` from Task 2 and the existing workspace-bucket list inside ConsolidateMemories (the `SELECT DISTINCT workspace_id` helper around `consolidate_memories.ex:169-181`).

- [ ] **Step 1: Add the flag**

In `lib/magus/agents/config.ex` add:

```elixir
  @doc """
  Feature flag for the distilled user profile layer (Hermes-style working
  memory). Env var wins so eval A/B runs can toggle it per process.
  """
  def profile_enabled? do
    System.get_env("MAGUS_MEMORY_PROFILE") == "1" or
      Application.get_env(:magus, :memory_profile_enabled, false)
  end
```

- [ ] **Step 2: Write the failing test**

Create `test/magus/agents/actions/consolidate_memories_profile_test.exs`:

```elixir
defmodule Magus.Agents.Actions.ConsolidateMemoriesProfileTest do
  # async: false because it mutates global app config for the flag.
  use Magus.ResourceCase, async: false

  import Mox

  alias Magus.Agents.Actions.ConsolidateMemories
  alias Magus.Agents.Support.AiAgent
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!
  setup :set_mox_from_context

  @ai %AiAgent{}

  setup do
    Application.put_env(:magus, :memory_profile_enabled, true)
    on_exit(fn -> Application.delete_env(:magus, :memory_profile_enabled) end)
    :ok
  end

  test "daily consolidation distills the profile for each bucket" do
    user = generate(user())

    {:ok, _} =
      Magus.Memory.create_user_memory(
        user.id,
        nil,
        "Durable Preference",
        %{content: %{}, summary: "Prefers concise, direct answers"},
        actor: @ai
      )

    # ConsolidateMemories makes LLM calls for merge/promote steps too; stub
    # everything generically and return a profile document when the distiller
    # schema is requested (it is the only schema requiring just "document").
    stub(LLMMock, :generate_object, fn _model, _prompt, schema, _opts ->
      if schema["required"] == ["document"] do
        MockResponses.generate_object_response(%{"document" => "## Preferences\nConcise answers."})
      else
        MockResponses.generate_object_response(%{"candidates" => [], "merge_groups" => [], "extractions" => [], "reasoning" => ""})
      end
    end)

    assert {:ok, _result} = ConsolidateMemories.run(%{user_id: to_string(user.id)}, %{})

    {:ok, profile} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
    assert profile.document =~ "Concise answers"
  end
end
```

Note: read `consolidate_memories.ex` first and mirror its actual `run/2` params (it may take `user_id` plus threshold options) and adjust the generic stub payload to whatever object keys its merge/promote schemas require. The distiller branch keys off `schema["required"] == ["document"]`, which is unique to the distiller schema.

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/magus/agents/actions/consolidate_memories_profile_test.exs`
Expected: FAIL on `get_user_profile` (no profile row: consolidation does not distill yet).

- [ ] **Step 4: Wire the distill step**

In `lib/magus/agents/actions/consolidate_memories.ex`, after the merge step in the main flow (the merge step is around lines 138-156; it iterates the same bucket list as promotion), add a fourth step:

```elixir
    profiles_distilled =
      if Magus.Agents.Config.profile_enabled?() do
        distill_profiles(user_id, buckets)
      else
        0
      end
```

(where `buckets` is the same list of workspace ids the merge step iterates; if the local variable is named differently, use that name) and include `profiles_distilled: profiles_distilled` in the result map the action returns. Add the helper:

```elixir
  defp distill_profiles(user_id, buckets) do
    Enum.count(buckets, fn workspace_id ->
      case Magus.Agents.Actions.DistillUserProfile.run(
             %{
               user_id: to_string(user_id),
               workspace_id: workspace_id && to_string(workspace_id)
             },
             %{}
           ) do
        {:ok, _} ->
          true

        {:error, reason} ->
          Logger.warning(
            "ConsolidateMemories: profile distillation failed for bucket #{inspect(workspace_id)}: #{inspect(reason)}"
          )

          false
      end
    end)
  end
```

A distillation failure logs and continues (decay/promote/merge results are already committed; the profile just stays on its previous version).

- [ ] **Step 5: Run tests**

Run: `mix test test/magus/agents/actions/consolidate_memories_profile_test.exs test/magus/agents/actions/`
Expected: PASS, including the pre-existing consolidation tests (the flag defaults off, so they are unaffected).

- [ ] **Step 6: Commit**

```bash
git add lib/magus/agents/config.ex lib/magus/agents/actions/consolidate_memories.ex test/magus/agents/actions/consolidate_memories_profile_test.exs
git commit -m "feat(memory): distill user profiles in daily consolidation behind a feature flag" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: update_profile agent tool

**Files:**
- Create: `lib/magus/agents/tools/memory/update_profile.ex`
- Modify: `lib/magus/agents/tools/tool_builder.ex:27` (alias), `:150-152` (tool map), `:213-215` (category map)
- Test: `test/magus/agents/tools/memory/update_profile_test.exs`

**Interfaces:**
- Consumes: `Magus.Memory.add_profile_note/3`, `get_user_profile/3`, `create_user_profile/4`, `Magus.Memory.workspace_id_for_conversation/1`, `Magus.Agents.Tools.Helpers.validate_context/2`.
- Produces: tool `update_profile` with param `note :: String.t()`, returning `{:ok, %{status: "queued", pending_notes: integer()}}`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/agents/tools/memory/update_profile_test.exs`:

```elixir
defmodule Magus.Agents.Tools.Memory.UpdateProfileTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Support.AiAgent
  alias Magus.Agents.Tools.Memory.UpdateProfile

  @ai %AiAgent{}

  test "queues a note on the bucket profile, creating the profile if needed" do
    user = generate(user())
    conv = generate(conversation(actor: user))

    context = %{user_id: user.id, conversation_id: conv.id}

    assert {:ok, %{status: "queued", pending_notes: 1}} =
             UpdateProfile.run(%{note: "prefers step-by-step plans"}, context)

    {:ok, profile} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
    assert profile.pending_notes == ["prefers step-by-step plans"]
  end

  test "errors without required context" do
    assert {:error, _} = UpdateProfile.run(%{note: "x"}, %{})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/agents/tools/memory/update_profile_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 3: Implement the tool**

Create `lib/magus/agents/tools/memory/update_profile.ex`:

```elixir
defmodule Magus.Agents.Tools.Memory.UpdateProfile do
  @moduledoc """
  Queues a durable behavioral note for the user's distilled profile.

  The note is folded into the profile document at the next distillation
  pass; the tool never edits the document directly, which keeps the
  document a single-writer artifact of DistillUserProfile.
  """

  use Jido.Action,
    name: "update_profile",
    description:
      "Queue a durable note about the user (preference, behavioral pattern, goal) " <>
        "for their distilled profile. Use only for signal that should persist across " <>
        "all conversations, not conversation-local facts.",
    schema: [
      note: [
        type: :string,
        required: true,
        doc: "One-sentence durable observation about the user"
      ]
    ]

  require Logger

  alias Magus.Agents.Support.AiAgent
  alias Magus.Agents.Tools.Helpers
  alias Magus.Memory

  @actor %AiAgent{}

  def display_name, do: "Update Profile"

  def summarize_output(%{status: status}), do: "Profile note #{status}"
  def summarize_output(_), do: "Profile note queued"

  @impl true
  def run(params, context) do
    with :ok <- Helpers.validate_context(context, [:user_id, :conversation_id]) do
      user_id = to_string(context.user_id)
      workspace_id = Memory.workspace_id_for_conversation(context.conversation_id)

      with {:ok, profile} <- get_or_create(user_id, workspace_id),
           {:ok, updated} <- Memory.add_profile_note(profile, params.note, actor: @actor) do
        {:ok, %{status: "queued", pending_notes: length(updated.pending_notes)}}
      else
        {:error, reason} -> {:error, "Failed to queue profile note: #{inspect(reason)}"}
      end
    end
  end

  defp get_or_create(user_id, workspace_id) do
    case Memory.get_user_profile(user_id, workspace_id, actor: @actor) do
      {:ok, profile} when not is_nil(profile) -> {:ok, profile}
      _ -> Memory.create_user_profile(user_id, workspace_id, %{document: ""}, actor: @actor)
    end
  end
end
```

Check `Helpers.validate_context/2`'s exact return contract at `lib/magus/agents/tools/helpers.ex:260` (it returns `:ok` or an error tuple); if it returns `{:error, msg}` in a different shape, match it accordingly.

- [ ] **Step 4: Register the tool**

In `lib/magus/agents/tools/tool_builder.ex`:

1. Line 27: extend the alias to `alias Magus.Agents.Tools.Memory.{SearchMemories, SetMemory, ForgetMemory, UpdateProfile}`
2. In the tool name map (lines 150-152), add: `"update_profile" => UpdateProfile,`
3. In the category map (lines 213-215), add: `UpdateProfile => :memory,`

The tool is registered unconditionally: with the flag off, notes queue harmlessly and are simply never distilled.

- [ ] **Step 5: Run tests**

Run: `mix test test/magus/agents/tools/memory/update_profile_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/magus/agents/tools/memory/update_profile.ex lib/magus/agents/tools/tool_builder.ex test/magus/agents/tools/memory/update_profile_test.exs
git commit -m "feat(memory): update_profile tool queues distillation notes from mid-session signal" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Inject the profile into conversation context

When the flag is on and a non-empty profile exists for the bucket, the document is injected as the top section of the memory block and the top-3-recency GLOBAL key-memory layer is dropped (that is the layer the profile replaces). Local and agent key memories, semantic search, and associations are unchanged.

**Files:**
- Modify: `lib/magus/agents/actions/build_memory_context.ex`
- Test: `test/magus/agents/actions/build_memory_context_test.exs` (extend)

**Interfaces:**
- Consumes: `Magus.Memory.get_user_profile/3`, `Magus.Agents.Config.profile_enabled?/0`, the public `format_context/4` introduced by the hardening plan (Task 7 there).
- Produces: `format_context/4` gains `opts[:profile_document]`; the context map returned by `build/1` gains `:profile_document` (string or nil).

- [ ] **Step 1: Write the failing test**

Append to `test/magus/agents/actions/build_memory_context_test.exs` (this file exists after the hardening plan; change the top of the module to `async: false` since these tests toggle global config):

```elixir
  describe "profile injection" do
    setup do
      Application.put_env(:magus, :memory_profile_enabled, true)
      on_exit(fn -> Application.delete_env(:magus, :memory_profile_enabled) end)
      :ok
    end

    test "injects the profile document and drops the global key-memory layer" do
      user = generate(user())
      conv = generate(conversation(actor: user))
      ai = %Magus.Agents.Support.AiAgent{}

      {:ok, _} =
        Magus.Memory.create_user_memory(
          user.id,
          nil,
          "Global Key Memory",
          %{content: %{}, summary: "Would be injected by recency"},
          actor: ai
        )

      {:ok, _} =
        Magus.Memory.create_user_profile(
          user.id,
          nil,
          %{document: "## Preferences\nConcise answers, Elixir stack."},
          actor: ai
        )

      {:ok, context} =
        Magus.Agents.Actions.BuildMemoryContext.build(%{
          user_id: to_string(user.id),
          conversation_id: to_string(conv.id),
          query_text: "",
          global_enabled: true
        })

      assert context.profile_document =~ "Concise answers"
      assert context.formatted =~ "### User Profile"
      assert context.formatted =~ "Concise answers"
      refute Enum.any?(context.important, &(&1.display_scope == :user))
    end

    test "falls back to global key memories when no profile exists" do
      user = generate(user())
      conv = generate(conversation(actor: user))
      ai = %Magus.Agents.Support.AiAgent{}

      {:ok, _} =
        Magus.Memory.create_user_memory(
          user.id,
          nil,
          "Global Key Memory",
          %{content: %{}, summary: "Injected by recency"},
          actor: ai
        )

      {:ok, context} =
        Magus.Agents.Actions.BuildMemoryContext.build(%{
          user_id: to_string(user.id),
          conversation_id: to_string(conv.id),
          query_text: "",
          global_enabled: true
        })

      assert is_nil(context.profile_document)
      assert Enum.any?(context.important, &(&1.display_scope == :user))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/agents/actions/build_memory_context_test.exs`
Expected: FAIL (`context.profile_document` key missing).

- [ ] **Step 3: Implement**

In `lib/magus/agents/actions/build_memory_context.ex`:

1. In `build_context/6`, before the Layer 1 loads:

```elixir
    profile_document =
      if global_enabled and Magus.Agents.Config.profile_enabled?() do
        load_profile_document(user_id, workspace_id)
      end
```

2. Replace the `important_global` load with:

```elixir
    important_global =
      if global_enabled and is_nil(profile_document) do
        load_important_global(workspace_id, actor)
      else
        []
      end
```

3. Pass the document into formatting. Both `format_context` calls (full and `previews: false` budget fallback) gain `profile_document: profile_document` in opts:

```elixir
    formatted =
      format_context(important, semantic ++ associated, global_enabled,
        profile_document: profile_document
      )
```

4. Extend the returned map with `profile_document: profile_document`.

5. Add the loader:

```elixir
  defp load_profile_document(user_id, workspace_id) do
    case Magus.Memory.get_user_profile(user_id, workspace_id, authorize?: false) do
      {:ok, %{document: doc}} when is_binary(doc) and doc != "" -> doc
      _ -> nil
    end
  rescue
    e ->
      Logger.warning("Failed to load user profile: #{Exception.message(e)}")
      nil
  end
```

6. In `format_context/4`, read `profile_document = Keyword.get(opts, :profile_document)` and prepend a section to the `sections` list:

```elixir
    sections = [
      format_profile_section(profile_document),
      format_important_section(important, previews?),
      format_semantic_section(semantic),
      format_global_note(global_enabled, important ++ semantic)
    ]
```

with:

```elixir
  defp format_profile_section(nil), do: ""

  defp format_profile_section(document) do
    """
    ### User Profile
    #{document}
    """
  end
```

7. Adjust the empty clause so a profile alone still renders: change `def format_context([], [], _global_enabled, _opts), do: ""` to:

```elixir
  def format_context([], [], _global_enabled, opts) do
    case Keyword.get(opts, :profile_document) do
      nil -> ""
      _doc -> format_context([], [], true, opts, :force)
    end
  end
```

Simplest correct implementation: delete the empty-clause shortcut entirely and instead return `""` from the main body when ALL of profile/important/semantic sections are empty (the existing `if content == ""` check already does this).

- [ ] **Step 4: Run tests**

Run: `mix test test/magus/agents/actions/build_memory_context_test.exs test/magus/agents/actions/build_memory_context_format_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/magus/agents/actions/build_memory_context.ex test/magus/agents/actions/build_memory_context_test.exs
git commit -m "feat(memory): inject the distilled profile as the top context layer behind the flag" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: profile_distill eval benchmark, subject, and dataset

**Files:**
- Create: `priv/eval/profile_distill/cases.json`
- Create: `lib/magus/eval/benchmarks/profile_distill.ex`
- Create: `test/support/eval/subject/profile_live.ex`
- Modify: `test/support/mix/tasks/magus.eval.ex` (register benchmark + per-benchmark subject)
- Test: `test/magus/eval/benchmarks/profile_distill_test.exs`

**Interfaces:**
- Consumes: `Magus.Eval.Benchmark` behaviour (`name/0`, `load_dataset/1`, `cases/2`, `score/2`, `emit_hypotheses/2`), `Magus.Eval.Subject` behaviour (`reset/1`, `ingest/2`, `query/2`), `DistillUserProfile.run/2`.
- Produces: benchmark `profile_distill` runnable via `MIX_ENV=test mix magus.eval profile_distill`. Case scoring: `(covered gold facts + absent forbidden facts) / (gold + forbidden)`, halved if `token_estimate > 800`. Aggregate = mean case score.

- [ ] **Step 1: Author the dataset**

Create `priv/eval/profile_distill/cases.json`:

```json
[
  {
    "id": "contradiction_preference",
    "seed_memories": [
      {"name": "Theme Preference Old", "summary": "User prefers dark mode in all editors", "content": {}, "updated_at_days_ago": 30},
      {"name": "Theme Preference New", "summary": "User switched to light mode and prefers it now", "content": {}, "updated_at_days_ago": 2},
      {"name": "Editor", "summary": "User uses VS Code as their primary editor", "content": {}, "updated_at_days_ago": 10}
    ],
    "gold_facts": ["The user prefers light mode", "The user uses VS Code"],
    "forbidden_facts": ["The user prefers dark mode"]
  },
  {
    "id": "completed_work_dropped",
    "seed_memories": [
      {"name": "Payments Launch", "summary": "Shipped and launched the payments feature, work is complete", "content": {}, "updated_at_days_ago": 40},
      {"name": "Notifications Project", "summary": "Currently building a notifications system with websocket delivery", "content": {}, "updated_at_days_ago": 3}
    ],
    "gold_facts": ["The user is currently working on a notifications system"],
    "forbidden_facts": ["The payments feature is described as current or active work"]
  },
  {
    "id": "one_off_fact_dropped",
    "seed_memories": [
      {"name": "Answer Style", "summary": "User repeatedly asks for concise, direct answers without preamble", "content": {}, "updated_at_days_ago": 5},
      {"name": "Berlin Weather Question", "summary": "User once asked about the weather in Berlin", "content": {}, "updated_at_days_ago": 20}
    ],
    "gold_facts": ["The user prefers concise, direct answers"],
    "forbidden_facts": ["The profile mentions Berlin weather"]
  },
  {
    "id": "open_thread_kept",
    "seed_memories": [
      {"name": "Database Decision", "summary": "User is undecided between Postgres and SQLite for their side project", "content": {}, "updated_at_days_ago": 5},
      {"name": "Side Project", "summary": "User is building a recipe manager side project in Elixir", "content": {}, "updated_at_days_ago": 5}
    ],
    "gold_facts": ["There is an open decision between Postgres and SQLite", "The user is building a recipe manager side project"],
    "forbidden_facts": []
  },
  {
    "id": "behavioral_patterns",
    "seed_memories": [
      {"name": "Testing Habit", "summary": "User tends to test changes manually in the browser before writing unit tests", "content": {}, "updated_at_days_ago": 12},
      {"name": "Planning Habit", "summary": "User asks for step-by-step implementation plans before coding starts", "content": {}, "updated_at_days_ago": 8}
    ],
    "gold_facts": ["The user tests manually before writing unit tests", "The user wants step-by-step plans before implementation"],
    "forbidden_facts": []
  },
  {
    "id": "multi_project",
    "seed_memories": [
      {"name": "Project Alpha", "summary": "Active project: a Phoenix chat application with agent tooling", "content": {}, "updated_at_days_ago": 2},
      {"name": "Project Beta", "summary": "Active project: an open-source CLI for knowledge management", "content": {}, "updated_at_days_ago": 4},
      {"name": "Project Gamma", "summary": "Active project: a landing page redesign with a new design system", "content": {}, "updated_at_days_ago": 6}
    ],
    "gold_facts": ["A chat application project is active", "A CLI project is active", "A landing page redesign is active"],
    "forbidden_facts": []
  }
]
```

- [ ] **Step 2: Write the failing benchmark unit test**

Create `test/magus/eval/benchmarks/profile_distill_test.exs`:

```elixir
defmodule Magus.Eval.Benchmarks.ProfileDistillTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Benchmarks.ProfileDistill

  test "loads the dataset and builds cases with encoded seeds" do
    {:ok, dataset} = ProfileDistill.load_dataset([])
    cases = ProfileDistill.cases(dataset, [])

    assert length(cases) >= 6

    case_one = Enum.find(cases, &(&1.id == "contradiction_preference"))
    assert case_one.gold["gold_facts"] == ["The user prefers light mode", "The user uses VS Code"]

    [first_item | _] = case_one.ingest_items
    assert %{role: :user, text: json} = first_item
    assert %{"name" => _, "summary" => _} = Jason.decode!(json)
  end

  test "case_score is deterministic arithmetic" do
    assert ProfileDistill.case_score([true, true], [false], true) == 1.0
    assert ProfileDistill.case_score([true, false], [false], true) == 2 / 3
    assert ProfileDistill.case_score([true, true], [true], true) == 2 / 3
    assert ProfileDistill.case_score([true, true], [false], false) == 0.5
    assert ProfileDistill.case_score([], [], true) == 0.0
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/magus/eval/benchmarks/profile_distill_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 4: Implement the benchmark**

Create `lib/magus/eval/benchmarks/profile_distill.ex`:

```elixir
defmodule Magus.Eval.Benchmarks.ProfileDistill do
  @moduledoc """
  Profile distillation quality benchmark. Each case seeds user-scope
  memories (including contradictions, completed work, and one-off noise),
  runs the distiller, and grades the resulting document: are the gold facts
  stated, are the forbidden (stale/noise) facts absent, and is the document
  within the 800-token cap.
  """
  @behaviour Magus.Eval.Benchmark

  alias Magus.Agents.Clients.LLM, as: LLMClient

  @impl true
  def name, do: "profile_distill"

  @impl true
  def load_dataset(opts) do
    path =
      opts[:dataset_path] ||
        Path.join(:code.priv_dir(:magus), "eval/profile_distill/cases.json")

    with {:ok, body} <- File.read(path) do
      Jason.decode(body)
    end
  end

  @impl true
  def cases(dataset, _opts) do
    Enum.map(dataset, fn c ->
      %{
        id: c["id"],
        question: "distill",
        gold: %{
          "gold_facts" => c["gold_facts"] || [],
          "forbidden_facts" => c["forbidden_facts"] || []
        },
        meta: %{},
        ingest_items:
          Enum.map(c["seed_memories"], fn m -> %{role: :user, text: Jason.encode!(m)} end)
      }
    end)
  end

  @impl true
  def emit_hypotheses(results, path) do
    body =
      Enum.map_join(results, "\n", fn r ->
        Jason.encode!(%{id: r.id, document: r.answer || ""})
      end)

    File.write!(path, body <> "\n")
    :ok
  end

  @impl true
  def score(results, opts) do
    judge_model = opts[:judge] || Magus.Agents.Config.extraction_model()

    per_case =
      Enum.map(results, fn r ->
        gold = r.gold["gold_facts"]
        forbidden = r.gold["forbidden_facts"]
        verdict = judge_case(judge_model, r.answer || "", gold, forbidden)
        cap_ok = (get_in(r, [:meta, :token_estimate]) || 0) <= 800

        %{
          id: r.id,
          score: case_score(verdict.covered, verdict.forbidden_present, cap_ok),
          cap_ok: cap_ok,
          covered: verdict.covered,
          forbidden_present: verdict.forbidden_present
        }
      end)

    aggregate =
      case per_case do
        [] -> 0.0
        list -> Enum.sum(Enum.map(list, & &1.score)) / length(list)
      end

    %{aggregate: aggregate, per_case: per_case}
  end

  @doc """
  Deterministic case score: fraction of checks passed, where checks are
  each gold fact covered plus each forbidden fact absent. Halved when the
  document exceeds the token cap. Empty check set scores 0.0 (misconfigured
  case, should never happen with the shipped dataset).
  """
  def case_score(covered, forbidden_present, cap_ok) do
    checks = length(covered) + length(forbidden_present)

    if checks == 0 do
      0.0
    else
      passed = Enum.count(covered, & &1) + Enum.count(forbidden_present, &(not &1))
      raw = passed / checks
      if cap_ok, do: raw, else: raw * 0.5
    end
  end

  @judge_schema %{
    "type" => "object",
    "properties" => %{
      "covered" => %{"type" => "array", "items" => %{"type" => "boolean"}},
      "forbidden_present" => %{"type" => "array", "items" => %{"type" => "boolean"}}
    },
    "required" => ["covered", "forbidden_present"]
  }

  defp judge_case(_model, _document, [], []), do: %{covered: [], forbidden_present: []}

  defp judge_case(model, document, gold, forbidden) do
    prompt = """
    Profile document:
    <document>
    #{document}
    </document>

    Expected facts (is each one stated in the document, possibly reworded?):
    #{numbered(gold)}

    Forbidden facts (is each one present in the document?):
    #{numbered(forbidden)}

    Return "covered" as an array of exactly #{length(gold)} booleans and
    "forbidden_present" as an array of exactly #{length(forbidden)} booleans,
    both in the order listed above.
    """

    case LLMClient.llm_client().generate_object(model, prompt, @judge_schema,
           system_prompt: "You are a strict grader. Judge only from the document text."
         ) do
      {:ok, %{object: obj}} ->
        %{
          covered: pad_bools(obj["covered"], length(gold), false),
          forbidden_present: pad_bools(obj["forbidden_present"], length(forbidden), true)
        }

      {:error, _} ->
        # Judge failure grades worst-case so it cannot inflate the score.
        %{
          covered: List.duplicate(false, length(gold)),
          forbidden_present: List.duplicate(true, length(forbidden))
        }
    end
  end

  defp numbered([]), do: "(none)"

  defp numbered(items) do
    items |> Enum.with_index(1) |> Enum.map_join("\n", fn {item, i} -> "#{i}. #{item}" end)
  end

  defp pad_bools(list, expected, fill) when is_list(list) do
    list
    |> Enum.map(&(&1 == true))
    |> Enum.take(expected)
    |> then(fn l -> l ++ List.duplicate(fill, expected - length(l)) end)
  end

  defp pad_bools(_other, expected, fill), do: List.duplicate(fill, expected)
end
```

- [ ] **Step 5: Implement the subject**

Create `test/support/eval/subject/profile_live.ex`:

```elixir
defmodule Magus.Eval.Subject.ProfileLive do
  @moduledoc """
  Subject for the profile_distill benchmark. Creates a fresh user per case,
  seeds the encoded user-scope memories (backdating updated_at so recency
  ordering is meaningful), runs the real DistillUserProfile action, and
  returns the document. Lives in test support because it depends on
  Magus.Generators.
  """
  @behaviour Magus.Eval.Subject

  alias Magus.Agents.Support.AiAgent

  @actor %AiAgent{}

  @impl true
  def reset(ctx) do
    user = Magus.Generators.generate(Magus.Generators.user())
    {:ok, Map.put(ctx, :profile_user, user)}
  end

  @impl true
  def ingest(ctx, items) do
    Enum.each(items, fn %{text: json} ->
      seed = Jason.decode!(json)

      {:ok, memory} =
        Magus.Memory.create_user_memory(
          ctx.profile_user.id,
          nil,
          seed["name"],
          %{content: seed["content"] || %{}, summary: seed["summary"]},
          actor: @actor
        )

      backdate(memory, seed["updated_at_days_ago"])
    end)

    {:ok, ctx}
  end

  @impl true
  def query(ctx, _question) do
    case Magus.Agents.Actions.DistillUserProfile.run(
           %{user_id: to_string(ctx.profile_user.id), workspace_id: nil},
           %{}
         ) do
      {:ok, %{document: document, token_estimate: token_estimate}} ->
        {:ok, %{answer: document, meta: %{token_estimate: token_estimate}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Raw SQL: updated_at is not writable through actions, and the distiller
  # prompt orders memories by it.
  defp backdate(_memory, nil), do: :ok

  defp backdate(memory, days_ago) do
    ts = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)
    {:ok, uuid} = Ecto.UUID.dump(to_string(memory.id))

    Magus.Repo.query!("UPDATE memories SET updated_at = $1 WHERE id = $2", [ts, uuid])
    :ok
  end
end
```

- [ ] **Step 6: Register in the mix task**

In `test/support/mix/tasks/magus.eval.ex`, change `@benchmarks` to carry a per-benchmark subject and use it:

```elixir
  @benchmarks %{
    "coverage_smoke" => {Magus.Eval.Benchmarks.CoverageSmoke, Magus.Eval.Subject.Live},
    "longmemeval" => {Magus.Eval.Benchmarks.LongMemEval, Magus.Eval.Subject.Live},
    "gaia" => {Magus.Eval.Benchmarks.GAIA, Magus.Eval.Subject.Live},
    "profile_distill" => {Magus.Eval.Benchmarks.ProfileDistill, Magus.Eval.Subject.ProfileLive}
  }
```

and in `run/1` destructure:

```elixir
    {benchmark, subject} =
      case args do
        [name] -> Map.get(@benchmarks, name) || {nil, nil}
        _ -> {nil, nil}
      end
```

then `subject: subject` in `run_opts` (replacing the hardcoded `Magus.Eval.Subject.Live`). Update the usage string and `@moduledoc` benchmark list to include `profile_distill`.

- [ ] **Step 7: Run tests and compile checks**

Run:
```bash
mix test test/magus/eval/benchmarks/profile_distill_test.exs
MIX_ENV=test mix compile --warnings-as-errors
```
Expected: PASS, no warnings.

- [ ] **Step 8: Commit**

```bash
git add priv/eval/profile_distill lib/magus/eval/benchmarks/profile_distill.ex test/support/eval/subject/profile_live.ex test/support/mix/tasks/magus.eval.ex test/magus/eval/benchmarks/profile_distill_test.exs
git commit -m "feat(eval): profile_distill benchmark with seeded-memory fixtures and LLM fact grading" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Eval runs (profile_distill + LongMemEval A/B)

**Files:**
- Modify: `docs/superpowers/plans/2026-07-04-memory-eval-baselines.md`

**Interfaces:**
- Consumes: the post-hardening LongMemEval row from the hardening plan (same `--limit 60`); `MAGUS_MEMORY_PROFILE=1` toggles the profile layer for the A/B run.

- [ ] **Step 1: Run profile_distill (flag not required; the subject calls the distiller directly)**

```bash
set -a && source .env && set +a
MIX_ENV=test mix magus.eval profile_distill
```
Expected: `profile_distill aggregate: 0.XXXX` and a scoreboard line. Target: aggregate >= 0.8. If below, inspect per-case output in `eval/results/profile_distill.jsonl` (which facts failed) and iterate on the distiller system prompt (Task 2) before proceeding; each iteration is one commit + one re-run.

- [ ] **Step 2: LongMemEval A/B**

The flag-off run is the post-hardening row already recorded. Run flag-on:

```bash
set -a && source .env && set +a
MAGUS_MEMORY_PROFILE=1 MIX_ENV=test mix magus.eval longmemeval --limit 60
```

Note: the Live subject seeds memories via extraction and queries via the real agent pipeline, so with the flag on, `BuildMemoryContext` injects the distilled profile (distillation runs lazily only if a profile row exists; the LongMemEval flow does not run consolidation, so add a distill step to make the A/B meaningful). Before running, check whether `Magus.Eval.Subject.Live.ingest/2` should distill after settling extraction, and if so add to its `ingest/2` (guarded by the flag):

```elixir
    if Magus.Agents.Config.profile_enabled?() do
      Magus.Agents.Actions.DistillUserProfile.run(
        %{user_id: to_string(ctx.user.id), workspace_id: nil},
        %{}
      )
    end
```

placed after `settle_extraction()`. Commit that change with this task.

- [ ] **Step 3: Record the A/B comparison**

Append to `docs/superpowers/plans/2026-07-04-memory-eval-baselines.md`:

```markdown
## Profile layer A/B (LongMemEval-S, limit 60)

| run | aggregate | knowledge-update | multi-session | temporal | notes |
|---|---|---|---|---|---|
| flag off (post-hardening) | <val> | <val> | <val> | <val> | |
| flag on (profile injected) | <val> | <val> | <val> | <val> | |

## profile_distill

- Date, SHA, aggregate: <fill>
- Per-case failures and prompt iterations: <fill or "none">

### Ship decision
<Profile ships (flag default on) only if: profile_distill >= 0.8 AND
LongMemEval flag-on aggregate >= flag-off aggregate - 0.02. Record the
decision and reasoning here.>
```

All `<...>` filled from real runs.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-07-04-memory-eval-baselines.md eval/results test/support/eval/subject/live.ex
git commit -m "docs(eval): profile_distill results and LongMemEval profile A/B" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Not in scope (deliberately)

- Flipping the flag on by default: that is the ship decision at the end of Task 7, made on eval evidence.
- A profile management UI (view/edit the document): valuable follow-up once the layer proves itself.
- Feeding the profile into Super Brain L1 extraction: the underlying memories are already extracted; extracting the profile would double-count.
- Per-conversation (local) or per-agent profiles: the user bucket is the Hermes case; revisit only with evidence.
