# Phase 2a: Model Resolver Keystone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate the scattered model resolution into one authoritative `Magus.Models.Resolver` returning a typed `Magus.Models.Resolution`, behavior-neutral against today's `ModelResolver`, then delete `ModelResolver`.

**Architecture:** A new plain module `Magus.Models.Resolver` reimplements the resolution logic of `Magus.Agents.Plugins.Support.ModelResolver`, returning a `Magus.Models.Resolution` struct that carries the resolved model plus orthogonal facts (selection source, the explicit ask, provider FK, and admin-only ownership/billing constants). All five legacy call sites (4 in Preflight, 1 in MediaBypass) migrate to it; then `ModelResolver` is deleted. No schema change, no migration, no behavior change.

**Tech Stack:** Elixir, Ash 3 (AshPostgres), ExUnit (`Magus.DataCase`), `:telemetry`.

## Global Constraints

Every task's requirements implicitly include this section. Exact values:

- **No em dashes** anywhere (code, comments, docs). Use colons, periods, commas.
- **No schema change and no migration in this phase.** Do not run `mix ash.codegen`. Never run `mix ash.reset`. No new DB columns.
- **Behavior-neutral.** For every input, `Magus.Models.Resolver.resolve(actor, input).model` must equal the model the legacy `Magus.Agents.Plugins.Support.ModelResolver.resolve_model/3,4` returns. Existing Preflight, agent, and media tests must stay green with no changes to their expectations.
- **`resolve/2` is total:** it always returns `{:ok, %Magus.Models.Resolution{}}`. It never returns an error tuple.
- **No secrets in the result.** The struct carries `provider_id` (a UUID) only. Never put a `%Magus.Models.Provider{}` (its `api_key` is `sensitive?`) or any `api_key` in the struct or the `ai.react.query` signal.
- **No `billable_by_*` field, and do not introduce `metered?`** in this phase.
- **Keep the `ai.react.query` signal shape unchanged:** its `:model` field stays a model-key string.
- **Ash conventions:** fetch via the code interface `Magus.Chat.get_model/1`; use `Ash.read_one(authorize?: false)` only to mirror the legacy by-key fetch verbatim.
- **Before every commit:** run `MIX_ENV=test mix compile --warnings-as-errors` and confirm it is clean (CI compiles this way; per-edit hooks do not).
- **Test setup pattern:** `use Magus.DataCase`, `import Magus.Generators`, `generate(model(...))`, `routing_slot(...)`, and `Magus.Models.create_provider(%{...}, authorize?: false)`.

---

## File Structure

- **Create** `lib/magus/models/resolution.ex` — the result struct + `degraded?/1`. One responsibility: represent a resolution as facts.
- **Create** `lib/magus/models/resolver.ex` — the resolution logic. One responsibility: selection -> `%Resolution{}`, total, with degradation telemetry.
- **Create** `test/magus/models/resolution_test.exs`, `test/magus/models/resolver_test.exs`.
- **Modify** `lib/magus/agents/plugins/support/preflight.ex` — migrate 4 call sites (`:65`, `:159`, `:229`, `:265`) to the resolver; pass auto-routing provenance at `:65`.
- **Modify** `lib/magus/agents/plugins/support/media_bypass.ex` — migrate the call site (`:33`).
- **Delete** `lib/magus/agents/plugins/support/model_resolver.ex` and `test/magus/agents/plugins/support/model_resolver_test.exs` (its coverage moves into `resolver_test.exs`).

---

## Task 1: `Magus.Models.Resolution` + `Magus.Models.Resolver`

Build the struct and the complete, behavior-neutral resolver with degradation telemetry. Not yet wired to any caller (Preflight/MediaBypass still use `ModelResolver`), so this task is self-contained and independently testable.

**Files:**
- Create: `lib/magus/models/resolution.ex`
- Create: `lib/magus/models/resolver.ex`
- Test: `test/magus/models/resolution_test.exs`, `test/magus/models/resolver_test.exs`

**Interfaces:**
- Produces:
  - `Magus.Models.Resolution` struct with fields `model`, `selection_source` (`:explicit | :auto | :role_default | :product_default`), `requested_selection` (`nil | %{by: :id | :key, value: term}`), `provider_id` (`binary | nil`), `access_source` (`:global`), `credential_owner_user_id` (`nil`), `cost_source` (`:platform_key`).
  - `Magus.Models.Resolution.degraded?/1 :: boolean`
  - `Magus.Models.Resolver.resolve(actor :: term, input :: map) :: {:ok, Magus.Models.Resolution.t()}` where `input` keys are `:model_keys` (required `%{chat:, image:, video:}`, values are key strings or `:auto`), `:mode` (required atom), `:selected_model_id` (optional `binary | nil`), `:preloaded` (optional list of `%Magus.Chat.Model{}`), `:auto_routed` (optional `%{chat: bool, image: bool, video: bool} | nil`).

- [ ] **Step 1: Write the failing test for the `Resolution` struct**

Create `test/magus/models/resolution_test.exs`:

```elixir
defmodule Magus.Models.ResolutionTest do
  use ExUnit.Case, async: true

  alias Magus.Models.Resolution

  defp model(attrs), do: struct(Magus.Chat.Model, attrs)

  test "defaults carry the admin-only ownership/billing constants" do
    res = %Resolution{model: model(id: "m1", key: "k"), selection_source: :explicit}

    assert res.access_source == :global
    assert res.credential_owner_user_id == nil
    assert res.cost_source == :platform_key
    assert res.requested_selection == nil
    assert res.provider_id == nil
  end

  test "degraded?/1 is false when nothing explicit was requested" do
    res = %Resolution{model: model(id: "m1", key: "k"), selection_source: :role_default}
    refute Resolution.degraded?(res)
  end

  test "degraded?/1 is false when the requested id matches the model" do
    res = %Resolution{
      model: model(id: "m1", key: "k"),
      selection_source: :explicit,
      requested_selection: %{by: :id, value: "m1"}
    }

    refute Resolution.degraded?(res)
  end

  test "degraded?/1 is true when the requested id does not match the model" do
    res = %Resolution{
      model: model(id: "other", key: "k"),
      selection_source: :explicit,
      requested_selection: %{by: :id, value: "m1"}
    }

    assert Resolution.degraded?(res)
  end

  test "degraded?/1 is true when the requested key does not match the model" do
    res = %Resolution{
      model: model(id: "m1", key: "fallback"),
      selection_source: :product_default,
      requested_selection: %{by: :key, value: "wanted"}
    }

    assert Resolution.degraded?(res)
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `MIX_ENV=test mix test test/magus/models/resolution_test.exs`
Expected: FAIL with `Magus.Models.Resolution.__struct__/1 is undefined` (module does not exist).

- [ ] **Step 3: Implement `Magus.Models.Resolution`**

Create `lib/magus/models/resolution.ex`:

```elixir
defmodule Magus.Models.Resolution do
  @moduledoc """
  The result of resolving a model selection: the resolved model plus
  orthogonal facts about how it was selected and whose credential pays.

  Facts only, never billing policy (billability is derived downstream in
  `Magus.Usage.PolicyEnforcer`). No secrets: carries `provider_id`, never a
  `Magus.Models.Provider` struct.
  """

  @type selection_source :: :explicit | :auto | :role_default | :product_default

  @type t :: %__MODULE__{
          model: struct() | nil,
          selection_source: selection_source(),
          requested_selection: nil | %{by: :id | :key, value: term()},
          provider_id: binary() | nil,
          access_source: :global | :owned | :workspace_shared,
          credential_owner_user_id: binary() | nil,
          cost_source: :platform_key | :byok
        }

  @enforce_keys [:model, :selection_source]
  defstruct model: nil,
            selection_source: :product_default,
            requested_selection: nil,
            provider_id: nil,
            access_source: :global,
            credential_owner_user_id: nil,
            cost_source: :platform_key

  @doc """
  True when an explicit selection was requested but the resolved model is not
  it (the request degraded to an inherited fallback).
  """
  @spec degraded?(t()) :: boolean()
  def degraded?(%__MODULE__{requested_selection: nil}), do: false

  def degraded?(%__MODULE__{requested_selection: %{by: :id, value: id}, model: model}),
    do: model_field(model, :id) != id

  def degraded?(%__MODULE__{requested_selection: %{by: :key, value: key}, model: model}),
    do: model_field(model, :key) != key

  defp model_field(%{} = model, field), do: Map.get(model, field)
  defp model_field(_, _), do: nil
end
```

- [ ] **Step 4: Run it to confirm it passes**

Run: `MIX_ENV=test mix test test/magus/models/resolution_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Write the failing test for `Magus.Models.Resolver`**

Create `test/magus/models/resolver_test.exs`. These mirror the legacy `model_resolver_test.exs` cases (behavior parity) plus the new struct facts:

```elixir
defmodule Magus.Models.ResolverTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Models.{Resolution, Resolver}

  describe "explicit selection" do
    test "explicit selected_model_id resolves to that model as :explicit" do
      m = generate(model())

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: :auto, image: nil, video: nil},
          mode: :chat,
          selected_model_id: m.id
        })

      assert res.model.id == m.id
      assert res.selection_source == :explicit
      assert res.requested_selection == %{by: :id, value: m.id}
      refute Resolution.degraded?(res)
      assert res.access_source == :global
      assert res.credential_owner_user_id == nil
      assert res.cost_source == :platform_key
      assert res.provider_id == m.model_provider_id
    end

    test "a broken selected_model_id degrades to the keys map and is flagged" do
      chat = generate(model())
      bad_id = Ash.UUID.generate()

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: chat.key, image: nil, video: nil},
          mode: :chat,
          selected_model_id: bad_id
        })

      assert res.model.key == chat.key
      assert res.requested_selection == %{by: :id, value: bad_id}
      assert Resolution.degraded?(res)
    end

    test "an explicit chat key (no provenance) is :explicit and records the ask" do
      m = generate(model())

      {:ok, res} =
        Resolver.resolve(nil, %{model_keys: %{chat: m.key, image: nil, video: nil}, mode: :chat})

      assert res.model.key == m.key
      assert res.selection_source == :explicit
      assert res.requested_selection == %{by: :key, value: m.key}
      refute Resolution.degraded?(res)
    end
  end

  describe "auto-routing provenance" do
    test "a pre-resolved auto-routed chat key is :auto, not :explicit" do
      m = generate(model())

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: m.key, image: nil, video: nil},
          mode: :chat,
          auto_routed: %{chat: true, image: false, video: false}
        })

      assert res.model.key == m.key
      assert res.selection_source == :auto
      assert res.requested_selection == nil
      refute Resolution.degraded?(res)
    end
  end

  describe ":auto and media (parity with legacy ModelResolver)" do
    test "resolves :auto image to the image model via routing slot, as :auto" do
      image_model = generate(model(output_modalities: ["image"]))
      routing_slot(model_id: image_model.id, specialty: :image, tier: :standard)

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: "some-chat", image: :auto, video: "some-video"},
          mode: :image_generation
        })

      assert res.model.key == image_model.key
      assert res.selection_source == :auto
    end

    test "resolves :auto image to the image_default role when no slot, as :role_default" do
      image_model = generate(model(output_modalities: ["image"]))

      {:ok, _} =
        Magus.Models.assign_role(%{role: "image_default", model_id: image_model.id},
          authorize?: false
        )

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: "some-chat", image: :auto, video: "some-video"},
          mode: :image_generation
        })

      assert res.model.key == image_model.key
      assert res.selection_source == :role_default
    end

    test "image mode with no image key falls back to the chat key" do
      chat_model = generate(model())

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: chat_model.key, image: nil, video: nil},
          mode: :image_generation
        })

      assert res.model.key == chat_model.key
    end

    test "chat :auto with no route falls back to a model struct (product/role default)" do
      {:ok, res} =
        Resolver.resolve(nil, %{model_keys: %{chat: :auto, image: "i", video: "v"}, mode: :chat})

      assert %Magus.Chat.Model{} = res.model
      assert res.selection_source in [:role_default, :product_default]
    end
  end

  describe "degradation telemetry" do
    test "emits [:magus, :models, :resolution, :degraded] when an explicit key misses" do
      ref = make_ref()

      :telemetry.attach(
        {:resolver_degraded, ref},
        [:magus, :models, :resolution, :degraded],
        fn _event, measurements, metadata, pid ->
          send(pid, {:degraded, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach({:resolver_degraded, ref}) end)

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: "missing:does-not-exist", image: nil, video: nil},
          mode: :chat
        })

      assert res.selection_source == :product_default
      assert Resolution.degraded?(res)
      assert_received {:degraded, %{count: 1}, %{selection_source: :product_default}}
    end
  end

  describe "no secrets" do
    test "carries provider_id (a UUID), never a provider struct or api_key" do
      {:ok, provider} =
        Magus.Models.create_provider(
          %{name: "P", slug: "pv_secret", req_llm_id: "openrouter", api_key: "sk-secret"},
          authorize?: false
        )

      model =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "M",
          key: "pv_secret:m",
          provider: "T",
          context_window: 1_000,
          model_provider_id: provider.id
        })
        |> Ash.create!()

      {:ok, res} =
        Resolver.resolve(nil, %{model_keys: %{chat: model.key, image: nil, video: nil}, mode: :chat})

      assert res.provider_id == provider.id
      assert is_binary(res.provider_id)
      refute Map.has_key?(Map.from_struct(res), :provider)
      refute Map.has_key?(Map.from_struct(res), :api_key)
    end
  end
end
```

- [ ] **Step 6: Run it to confirm it fails**

Run: `MIX_ENV=test mix test test/magus/models/resolver_test.exs`
Expected: FAIL with `Magus.Models.Resolver.resolve/2 is undefined`.

- [ ] **Step 7: Implement `Magus.Models.Resolver`**

Create `lib/magus/models/resolver.ex`. This ports `ModelResolver`'s logic exactly (including its preloaded-vs-not distinction) and adds the struct + provenance + telemetry:

```elixir
defmodule Magus.Models.Resolver do
  @moduledoc """
  Central model resolution: turns a selection (explicit id/key, an auto-routed
  key, or an inherited default) into a `Magus.Models.Resolution`.

  Total: always returns `{:ok, %Resolution{}}`, producing the same model the
  legacy `Magus.Agents.Plugins.Support.ModelResolver` did. A broken explicit
  selection degrades to the inherited model (unchanged behavior) and is
  reported via `requested_selection` plus a
  `[:magus, :models, :resolution, :degraded]` telemetry event. Whether to
  hard-stop on a degradation is a caller policy, off in this phase.
  """

  require Ash.Query

  alias Magus.Agents.Routing.{ModelKeyResolver, ModelMatcher}
  alias Magus.Models.Resolution

  @spec resolve(term(), map()) :: {:ok, Resolution.t()}
  def resolve(_actor, %{model_keys: model_keys, mode: mode} = input) do
    selected_model_id = Map.get(input, :selected_model_id)
    preloaded = Map.get(input, :preloaded, [])
    auto_routed = Map.get(input, :auto_routed)

    resolution =
      model_keys
      |> build(mode, selected_model_id, preloaded, auto_routed)
      |> emit_degraded_telemetry(mode)

    {:ok, resolution}
  end

  # Explicit by id: found -> :explicit. Miss -> fall through to the keys map,
  # carrying the original ask so the degradation is visible.
  defp build(model_keys, mode, selected_model_id, preloaded, auto_routed)
       when is_binary(selected_model_id) do
    case Magus.Chat.get_model(selected_model_id) do
      {:ok, model} ->
        resolution(model, :explicit, %{by: :id, value: selected_model_id})

      _ ->
        from_keys(model_keys, mode, preloaded, auto_routed, %{by: :id, value: selected_model_id})
    end
  end

  defp build(model_keys, mode, _selected_model_id, preloaded, auto_routed) do
    from_keys(model_keys, mode, preloaded, auto_routed, nil)
  end

  defp from_keys(model_keys, mode, preloaded, auto_routed, inherited_requested) do
    case model_key_for_mode(model_keys, mode) do
      :auto ->
        {model, source} = resolve_auto(mode, preloaded)
        resolution(model, source, inherited_requested)

      key when is_binary(key) ->
        {model, source, key_requested} = from_key(key, preloaded, mode, auto_routed)
        resolution(model, source, inherited_requested || key_requested)

      _ ->
        resolution(fallback_model(), :product_default, inherited_requested)
    end
  end

  # A concrete key. Auto-routed (per caller provenance) -> :auto, no ask
  # recorded. Otherwise an explicit ask: :explicit on hit, :product_default on
  # miss (synthetic fallback), with the ask recorded either way.
  defp from_key(key, preloaded, mode, auto_routed) do
    if auto_routed?(auto_routed, mode) do
      {find_or_fetch(key, preloaded), :auto, nil}
    else
      model = find_or_fetch(key, preloaded)
      source = if model.key == key, do: :explicit, else: :product_default
      {model, source, %{by: :key, value: key}}
    end
  end

  # Mirrors ModelResolver.resolve_auto_media: media specialty match (no
  # preloaded lookup) -> :auto; otherwise the role default for the mode's key
  # type (with preloaded lookup) -> :role_default.
  defp resolve_auto(mode, preloaded) do
    with specialty when not is_nil(specialty) <- media_specialty_for_mode(mode),
         {:ok, key} <- ModelMatcher.find_media_model(specialty) do
      {fetch_or_fallback(key), :auto}
    else
      _ ->
        key = ModelKeyResolver.default_model_key(mode_to_key_type(mode))
        {find_or_fetch(key, preloaded), :role_default}
    end
  end

  defp resolution(model, selection_source, requested) do
    %Resolution{
      model: model,
      selection_source: selection_source,
      requested_selection: requested,
      provider_id: provider_id(model),
      access_source: :global,
      credential_owner_user_id: nil,
      cost_source: :platform_key
    }
  end

  defp emit_degraded_telemetry(%Resolution{} = resolution, mode) do
    if Resolution.degraded?(resolution) do
      :telemetry.execute(
        [:magus, :models, :resolution, :degraded],
        %{count: 1},
        %{
          requested: resolution.requested_selection,
          selection_source: resolution.selection_source,
          mode: mode
        }
      )
    end

    resolution
  end

  # --- key/mode helpers (ported verbatim from ModelResolver) ---

  defp model_key_for_mode(%{} = keys, :image_generation), do: keys[:image] || keys[:chat]
  defp model_key_for_mode(%{} = keys, :video_generation), do: keys[:video] || keys[:chat]
  defp model_key_for_mode(%{} = keys, _mode), do: keys[:chat]
  defp model_key_for_mode(_, _), do: nil

  defp media_specialty_for_mode(:image_generation), do: :image
  defp media_specialty_for_mode(:video_generation), do: :text_to_video
  defp media_specialty_for_mode(_), do: nil

  defp mode_to_key_type(:image_generation), do: :image
  defp mode_to_key_type(:video_generation), do: :video
  defp mode_to_key_type(_), do: :chat

  defp auto_routed?(nil, _mode), do: false
  defp auto_routed?(%{} = map, mode), do: Map.get(map, mode_to_key_type(mode), false) == true

  defp find_or_fetch(key, preloaded), do: find_preloaded(preloaded, key) || fetch_or_fallback(key)

  defp fetch_or_fallback(key), do: fetch_by_key(key) || fallback_model()

  defp fetch_by_key(key) when is_binary(key) do
    case Magus.Chat.Model |> Ash.Query.filter(key == ^key) |> Ash.read_one(authorize?: false) do
      {:ok, %{} = model} -> model
      _ -> nil
    end
  end

  defp find_preloaded(preloaded, key) when is_list(preloaded) and is_binary(key) do
    Enum.find(preloaded, fn
      %{key: ^key} -> true
      %{"key" => ^key} -> true
      _ -> false
    end)
  end

  defp find_preloaded(_, _), do: nil

  defp provider_id(%{model_provider_id: id}), do: id
  defp provider_id(_), do: nil

  defp fallback_model do
    %Magus.Chat.Model{
      key: Magus.Agents.Config.default_model(),
      name: "Default",
      context_window: 128_000,
      input_cost: "0",
      output_cost: "0",
      supports_tools?: true
    }
  end
end
```

- [ ] **Step 8: Run it to confirm it passes**

Run: `MIX_ENV=test mix test test/magus/models/resolver_test.exs`
Expected: PASS (all tests).

- [ ] **Step 9: Compile with warnings as errors**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean compile, no warnings.

- [ ] **Step 10: Commit**

```bash
git add lib/magus/models/resolution.ex lib/magus/models/resolver.ex \
        test/magus/models/resolution_test.exs test/magus/models/resolver_test.exs
git commit -m "feat(models): add Magus.Models.Resolver + Resolution (phase 2a)"
```

---

## Task 2: Migrate Preflight's four call sites

Swap all four `ModelResolver.resolve_model` calls in `preflight.ex` for `Resolver.resolve`, passing auto-routing provenance at the main path. Behavior-neutral; existing Preflight tests are the regression gate.

**Files:**
- Modify: `lib/magus/agents/plugins/support/preflight.ex` (alias at `:12`; call sites at `:65`, `:159`, `:229`, `:265`)
- Test: `test/magus/agents/plugins/support/preflight_test.exs`, `test/magus/agents/plugins/support/preflight_llm_opts_test.exs` (must stay green unchanged)

**Interfaces:**
- Consumes: `Magus.Models.Resolver.resolve/2` (Task 1).

- [ ] **Step 1: Confirm the regression baseline passes**

Run: `MIX_ENV=test mix test test/magus/agents/plugins/support/preflight_test.exs test/magus/agents/plugins/support/preflight_llm_opts_test.exs`
Expected: PASS. (Establishes the green baseline these edits must preserve.)

- [ ] **Step 2: Swap the alias**

In `lib/magus/agents/plugins/support/preflight.ex:12`, replace:

```elixir
  alias Magus.Agents.Plugins.Support.ModelResolver
```

with:

```elixir
  alias Magus.Models.Resolver
```

- [ ] **Step 3: Migrate the main path (`build_react_signal`, around line 64)**

Replace:

```elixir
    model =
      ModelResolver.resolve_model(
        model_keys,
        mode,
        selected_model_id,
        preloaded_model_candidates(conversation)
      )
```

with (note `data` is bound at line 23 and `raw_model_keys` at line 27 of this function):

```elixir
    # The dispatcher resolves chat :auto upstream and threads the routing
    # reason into the signal (see Magus.Agents.Dispatcher.build_signal_data:
    # routing_reason). A present routing_reason, or a raw chat key still :auto
    # (Preflight's own secondary maybe_auto_route path), means the chat key was
    # auto-routed rather than explicitly picked.
    routing_reason = data[:routing_reason] || data["routing_reason"]

    auto_routed = %{
      chat: routing_reason not in [nil, ""] or raw_model_keys[:chat] == :auto,
      image: raw_model_keys[:image] == :auto,
      video: raw_model_keys[:video] == :auto
    }

    {:ok, resolution} =
      Resolver.resolve(nil, %{
        model_keys: model_keys,
        mode: mode,
        selected_model_id: selected_model_id,
        preloaded: preloaded_model_candidates(conversation),
        auto_routed: auto_routed
      })

    model = resolution.model
```

- [ ] **Step 4: Migrate the resume path (`build_resume_signal`, around line 158)**

Replace:

```elixir
    model =
      ModelResolver.resolve_model(
        raw_model_keys,
        mode,
        nil,
        preloaded_model_candidates(conversation)
      )
```

with:

```elixir
    {:ok, resolution} =
      Resolver.resolve(nil, %{
        model_keys: raw_model_keys,
        mode: mode,
        selected_model_id: nil,
        preloaded: preloaded_model_candidates(conversation)
      })

    model = resolution.model
```

- [ ] **Step 5: Migrate the debug-assembly path (`assemble_context`, around line 228)**

Replace:

```elixir
      model =
        ModelResolver.resolve_model(
          model_keys,
          mode,
          nil,
          preloaded_model_candidates(conversation)
        )
```

with:

```elixir
      {:ok, resolution} =
        Resolver.resolve(nil, %{
          model_keys: model_keys,
          mode: mode,
          selected_model_id: nil,
          preloaded: preloaded_model_candidates(conversation)
        })

      model = resolution.model
```

- [ ] **Step 6: Migrate the validation helper (`validate_and_resolve_model`, line 265)**

Replace:

```elixir
    model = ModelResolver.resolve_model(model_keys, mode, selected_model_id)
```

with:

```elixir
    {:ok, resolution} =
      Resolver.resolve(nil, %{
        model_keys: model_keys,
        mode: mode,
        selected_model_id: selected_model_id
      })

    model = resolution.model
```

- [ ] **Step 7: Compile with warnings as errors**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean (no unused-alias warning, since `Resolver` is now used and `ModelResolver` is no longer referenced in this file).

- [ ] **Step 8: Run the Preflight regression suite**

Run: `MIX_ENV=test mix test test/magus/agents/plugins/support/preflight_test.exs test/magus/agents/plugins/support/preflight_llm_opts_test.exs`
Expected: PASS, with no edits to those test files.

- [ ] **Step 9: Commit**

```bash
git add lib/magus/agents/plugins/support/preflight.ex
git commit -m "refactor(agents): resolve models via Magus.Models.Resolver in Preflight"
```

---

## Task 3: Migrate MediaBypass

Swap the media call site so `ModelResolver` has no remaining callers. Media resolution behavior (image/video -> chat fallback, media `:auto`) is already covered at the resolver level in Task 1.

**Files:**
- Modify: `lib/magus/agents/plugins/support/media_bypass.ex` (alias at `:10`; call site at `:33`)

**Interfaces:**
- Consumes: `Magus.Models.Resolver.resolve/2` (Task 1).

- [ ] **Step 1: Swap the alias**

In `lib/magus/agents/plugins/support/media_bypass.ex:10`, replace:

```elixir
  alias Magus.Agents.Plugins.Support.{Helpers, ModelResolver, Preflight}
```

with:

```elixir
  alias Magus.Agents.Plugins.Support.{Helpers, Preflight}
  alias Magus.Models.Resolver
```

- [ ] **Step 2: Migrate the call site (line 33)**

Replace:

```elixir
    model = ModelResolver.resolve_model(model_keys, mode, selected_model_id)
```

with:

```elixir
    {:ok, resolution} =
      Resolver.resolve(nil, %{
        model_keys: model_keys,
        mode: mode,
        selected_model_id: selected_model_id
      })

    model = resolution.model
```

- [ ] **Step 3: Compile with warnings as errors**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 4: Run resolver + any media-touching tests as a sanity check**

Run: `MIX_ENV=test mix test test/magus/models/resolver_test.exs test/magus/agents/`
Expected: PASS. (The resolver's media-mode coverage from Task 1 is the behavior gate; this confirms nothing in the agents tree regressed.)

- [ ] **Step 5: Commit**

```bash
git add lib/magus/agents/plugins/support/media_bypass.ex
git commit -m "refactor(agents): resolve media models via Magus.Models.Resolver"
```

---

## Task 4: Delete `ModelResolver` and verify the consolidation

With all five callers migrated, delete the legacy module and its test, prove no references remain, and run the full gate.

**Files:**
- Delete: `lib/magus/agents/plugins/support/model_resolver.ex`
- Delete: `test/magus/agents/plugins/support/model_resolver_test.exs`

- [ ] **Step 1: Confirm there are no remaining references**

Run: `grep -rn "ModelResolver" lib test`
Expected: no output. (If anything prints, migrate that reference before deleting.)

- [ ] **Step 2: Delete the legacy module and its test**

```bash
git rm lib/magus/agents/plugins/support/model_resolver.ex \
       test/magus/agents/plugins/support/model_resolver_test.exs
```

- [ ] **Step 3: Compile with warnings as errors**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean (no references to the deleted module).

- [ ] **Step 4: Run the full relevant suite**

Run: `MIX_ENV=test mix test test/magus/models/ test/magus/agents/`
Expected: PASS. No existing test expectations changed; new resolver tests pass.

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor(agents): delete legacy ModelResolver, fully replaced by Magus.Models.Resolver"
```

---

## Self-Review

Checked the plan against the spec ([2026-06-27-user-model-phase-2a-resolver-design.md](../specs/2026-06-27-user-model-phase-2a-resolver-design.md)):

- **Spec coverage:** Resolution struct + total resolver (Task 1); all 5 call sites migrated (Tasks 2-3); `ModelResolver` deleted (Task 4); provenance / `selection_source` (Task 1 provenance test + Preflight `auto_routed` wiring in Task 2); `provider_id` not `%Provider{}` and secret-free (Task 1 "no secrets" test); degradation telemetry (Task 1 telemetry test); behavior-neutral media incl. image/video -> chat fallback (Task 1 media tests); no migration / no `billable_by_*` / no `metered?` (Global Constraints). Billing-naming reconciliation is documentation-only in the spec and has no 2a task, by design.
- **Placeholder scan:** no TBD/TODO; every code and test block is complete; every command has expected output.
- **Type consistency:** `Resolver.resolve/2` input keys (`:model_keys`, `:mode`, `:selected_model_id`, `:preloaded`, `:auto_routed`) and `Resolution` field names are identical across Task 1's definition and the Task 2/3 call sites and tests. `degraded?/1`, `selection_source`, `requested_selection`, `provider_id`, `cost_source` match everywhere.
