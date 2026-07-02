# Phase 2b-2a: BYOK Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user adds a BYOK provider and model in the SPA and immediately chats with it end to end.

**Architecture:** Thread the acting user (already present in the react signal data as `acting_user_id`) into the five `Resolver.resolve` call sites and, via a `:credential_actor_id` llm-opt, into `RequestOptions.resolve/2`. Replace the credential-probe stub with real per-provider models-list requests, reuse it for a rate-limited `:list_remote_models` action, expose the owned actions over AshTypescript RPC, and build a `/settings/providers` SvelteKit page mirroring the `mcp-servers` page.

**Tech Stack:** Elixir, Ash 3.x, Req (HTTP probe, `plug:` stubbing in tests), Oban, AshTypescript RPC, SvelteKit (Svelte 5) + vitest.

**Reference spec:** `docs/superpowers/specs/2026-07-02-user-model-phase-2b2a-byok-slice-design.md`

## Global Constraints

- **No em dashes** in any code, comment, string, or commit message.
- **No secrets**: `api_key` never in logs, telemetry, Oban args, RPC output, or error messages. It is `sensitive?`/non-public; the SPA only ever writes it.
- **Fail-closed**: a missing/mismatched actor degrades to global resolution; never leaks owned credentials. Preserve this direction in every change.
- **Multiplayer**: the actor is the ACTING user (message sender via `Helpers.acting_user_id/2`, agent-owner fallback), never assumed to be the conversation owner.
- **Behavior-neutral for global rows**: platform-key resolution and existing chats must be unchanged.
- **Background/system LLM ops stay actor-less** (naming, memory extraction, super brain): do not thread actors into role-driven workers.
- **No schema change expected**; if `mix ash.codegen` produces a migration, stop and investigate. If codegen tries to DROP unrelated shared-test-DB tables (platform_pricing/pricing_tiers/seat_grants), exclude those and revert unrelated snapshot edits.
- **Nil-actor filter branching**: never write `owner_user_id == ^actor_id` with a possibly-nil pin; branch on `is_binary` (Task 7/8 lesson from 2b-1).
- Compile clean before each final commit: `MIX_ENV=test mix compile --warnings-as-errors`. Tests: `set -a && source .env && set +a && MIX_ENV=test mix test <path>`. NEVER `mix ash.reset`.
- **Test user factory**: `user = generate(user())` via `import Magus.Generators` (returns `%User{}` directly). `Magus.DataCase.clear_catalog!/0` in setup for catalog-touching tests.
- **Frontend tests**: structural `data-testid` hooks + counts only; no label/copy/CSS assertions. Frontend suite: `cd frontend && npx vitest run` (verify the exact runner in frontend/package.json first).
- **AshTypescript gotcha**: any exposed resource with `?`-suffixed booleans MUST map them via `field_names` (Provider: `enabled?: "enabled"`), else codegen/compile hard-fails.
- **Mirror-first frontend tasks**: Tasks 6 and 7 REQUIRE reading the named mirror files before writing code; the contracts (RPC names, testids, component boundaries) in the task are binding, the idioms come from the mirrors.

---

### Task 1: Actor into the Resolver call sites

**Files:**
- Modify: `lib/magus/models/resolver.ex` (actor_id/1 widening)
- Modify: `lib/magus/agents/plugins/support/preflight.ex:78,175,247,286`
- Modify: `lib/magus/agents/plugins/support/media_bypass.ex:35`
- Test: `test/magus/models/resolver_test.exs` (append), `test/magus/agents/plugins/support/preflight_actor_test.exs` (new)

**Interfaces:**
- Consumes: `Resolver.resolve(actor, input)` (2b-1), `Helpers.acting_user_id(agent, message_id)` (helpers.ex:65).
- Produces: `Resolver.resolve/2` accepting `nil | binary() | %{id: binary()}` as actor. Preflight/MediaBypass pass a binary acting-user id.

- [ ] **Step 1: Failing test for bare-binary actor**

Append to `test/magus/models/resolver_test.exs` (reuse the file's existing setup/model helpers):

```elixir
describe "bare binary actor id" do
  test "a binary actor id scopes exactly like %{id: id}" do
    user = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk"},
        actor: user
      )

    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{name: "C", model_id: "claude-x", model_provider_id: provider.id},
        actor: user
      )

    {:ok, res} = Magus.Models.Resolver.resolve(user.id, %{model_keys: %{chat: model.key}, mode: :chat})
    assert res.model.key == model.key
    assert res.cost_source == :byok
  end
end
```

Add `import Magus.Generators` and `Magus.DataCase.clear_catalog!()` if the file's setup lacks them (check first; the ownership test file has the pattern).

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/resolver_test.exs`
Expected: the new test FAILS (bare binary falls to the nil clause, model degrades).

- [ ] **Step 3: Widen actor_id/1**

In `lib/magus/models/resolver.ex`, the private `actor_id/1` gains a sibling clause:

```elixir
defp actor_id(%{id: id}) when is_binary(id), do: id
defp actor_id(id) when is_binary(id), do: id
defp actor_id(_), do: nil
```

- [ ] **Step 4: Thread the acting user at the call sites**

In `preflight.ex`, each `Resolver.resolve(nil, %{...})` becomes `Resolver.resolve(credential_actor, %{...})` where `credential_actor` is computed just above the call. Sources per site (verify each enclosing function's available bindings and use these rules):
- Line 78 (main path): the function already computes `Helpers.acting_user_id(agent, message_id)` at line 90 for limits; hoist that expression above the resolve call, bind it once (`acting_user_id = Helpers.acting_user_id(agent, message_id)`), and use it for BOTH the resolve actor and the existing line-90 usage (do not call it twice).
- Line 175 (resume): use `data[:acting_user_id] || data["acting_user_id"] || state[:user_id]` (the same expression preflight.ex:369 already uses); bind as `acting_user_id`.
- Line 247 (debug/assembly): `state[:user_id]` (agent owner; no message in scope).
- Line 286: same expression as line 175 if `data` is in scope, else `state[:user_id]`. Inspect the enclosing function and note the choice in the report.

In `media_bypass.ex:35`: `Resolver.resolve(state[:user_id], %{...})` (owned media models are blocked in 2b-1, so this is consistency, not a leak vector).

- [ ] **Step 5: Wiring test for preflight main path**

Create `test/magus/agents/plugins/support/preflight_actor_test.exs`. Before writing it, read `test/magus/models/resolver_ownership_test.exs` and any existing preflight test for setup patterns. If preflight's function at line 78 is not directly invocable in isolation, cover the threading at the resolver level instead: assert that `Resolver.resolve(owner_id, ...)` resolves the owned model while `Resolver.resolve(other_id, ...)` degrades (both with a bare binary id), and state in the report that the preflight-level path is covered by Task 2's end-to-end test. Do not build heavyweight agent scaffolding here.

- [ ] **Step 6: Run, compile, commit**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/resolver_test.exs test/magus/models/resolver_ownership_test.exs test/magus/agents/plugins/support/preflight_actor_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean compile.

```bash
git add lib/magus/models/resolver.ex lib/magus/agents/plugins/support/preflight.ex lib/magus/agents/plugins/support/media_bypass.ex test/magus/models/resolver_test.exs test/magus/agents/plugins/support/preflight_actor_test.exs
git commit -m "feat(agents): thread acting user into resolver call sites (phase 2b-2a)"
```

---

### Task 2: `:credential_actor_id` through Config.llm_opts to RequestOptions

**Files:**
- Modify: `lib/magus/agents/clients/llm.ex:88-93`
- Modify: the react `Config` module (find it: `Config.llm_opts(...)` is called at `lib/magus/agents/strategies/react/runner.ex:297-299`; open that module)
- Modify: wherever the react Config is built from signal data (trace from runner/strategy; the signal data carries `acting_user_id` per preflight.ex:369)
- Test: `test/magus/agents/clients/llm_credential_test.exs` (new)

**Interfaces:**
- Consumes: `RequestOptions.resolve(model_key, actor_id)` (2b-1, fail-closed), signal-data `acting_user_id`.
- Produces: `Magus.Agents.Clients.LLM.provider_options(model, opts) :: {model_or_map, opts}` (public, pops `:credential_actor_id`); react llm_opts include `credential_actor_id: <acting user id>`.

- [ ] **Step 1: Failing test for the public helper**

```elixir
# test/magus/agents/clients/llm_credential_test.exs
defmodule Magus.Agents.Clients.LLMCredentialTest do
  use Magus.DataCase, async: false
  import Magus.Generators
  alias Magus.Agents.Clients.LLM

  setup do
    Magus.DataCase.clear_catalog!()
    user = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk-owner"},
        actor: user
      )

    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{name: "C", model_id: "claude-x", model_provider_id: provider.id},
        actor: user
      )

    %{user: user, model: model}
  end

  test "owner id in credential_actor_id yields rewritten spec + key, opt popped", %{user: user, model: model} do
    {spec, opts} = LLM.provider_options(model.key, credential_actor_id: user.id, temperature: 0.5)
    assert spec == "anthropic:claude-x"
    assert opts[:api_key] == "sk-owner"
    refute Keyword.has_key?(opts, :credential_actor_id)
    assert opts[:temperature] == 0.5
  end

  test "absent or foreign actor id keeps safe fallback", %{model: model} do
    assert {key, opts} = LLM.provider_options(model.key, [])
    assert key == model.key
    refute opts[:api_key]

    other = generate(user())
    assert {key2, opts2} = LLM.provider_options(model.key, credential_actor_id: other.id)
    assert key2 == model.key
    refute opts2[:api_key]
  end

  test "non-binary model passes through" do
    assert {%{some: :map}, [a: 1]} = LLM.provider_options(%{some: :map}, a: 1, credential_actor_id: "x")
  end
end
```

Note: the third test expects the opt popped even on pass-through; implement accordingly.

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/clients/llm_credential_test.exs`
Expected: FAIL (`provider_options/2` undefined).

- [ ] **Step 3: Implement in llm.ex**

Replace the private `with_provider_options/2` with a public `provider_options/2` (keep the private name as a thin delegate so `stream_text/generate_text/generate_object` bodies stay unchanged, or update the three call sites; either is fine, be consistent):

```elixir
@doc """
Resolves DB-configured provider credentials/endpoints for the model key.
Pops :credential_actor_id (the acting user) so owned-provider credentials
are released only to their owner; the opt never reaches ReqLLM. Explicit
opts win over resolved ones; non-binary model inputs pass through.
"""
@spec provider_options(term(), keyword()) :: {term(), keyword()}
def provider_options(model, opts) when is_binary(model) do
  {actor_id, opts} = Keyword.pop(opts, :credential_actor_id)
  {resolved_model, provider_opts} = Magus.Models.RequestOptions.resolve(model, actor_id)
  {resolved_model, Keyword.merge(provider_opts, opts)}
end

def provider_options(model, opts), do: {model, Keyword.delete(opts, :credential_actor_id)}
```

- [ ] **Step 4: Thread into react llm_opts**

Open the module that defines `Config.llm_opts/1` (referenced at runner.ex:299) and the code that builds the Config from the react signal data. Add `credential_actor_id` sourced from the signal's `acting_user_id` (preflight puts it in signal data; see preflight.ex:369 for the read pattern). Requirements:
- The value lands in the keyword list the runner passes as `llm_opts` (runner.ex:571/584), so every turn's stream/generate call carries it.
- When absent, it is simply omitted (safe fallback).
- Do NOT put it anywhere it would serialize into checkpoints/signal payloads beyond where acting_user_id already lives.

- [ ] **Step 5: End-to-end wiring test**

Append to the same test file a test through the mocked-LLM integration path IF a lightweight harness exists (read `test/magus/agents/integration_test.exs` first). Assert: the mock LLM client receives opts containing `credential_actor_id == owner.id` when the owner's message triggers a turn on their owned model. If the harness is too heavy for this, assert instead at the Config level (build a Config from signal data containing `acting_user_id` and assert `Config.llm_opts/1` includes it) and say so in the report.

- [ ] **Step 6: Run, compile, commit**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/clients/llm_credential_test.exs test/magus/models/request_options_owned_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS.

```bash
git add lib/magus/agents/clients/llm.ex lib/magus/agents/strategies/react/ test/magus/agents/clients/llm_credential_test.exs
git commit -m "feat(agents): carry credential_actor_id through llm opts to RequestOptions (phase 2b-2a)"
```

---

### Task 3: Real credential probe

**Files:**
- Modify: `lib/magus/models/credential_validator.ex`
- Test: `test/magus/models/credential_validator_probe_test.exs` (new)

**Interfaces:**
- Consumes: Provider row (`req_llm_id`, `base_url`, `api_key`), existing seam `config :magus, :credential_validator`.
- Produces: `CredentialValidator.validate(provider) :: :valid | :invalid | :error` (unchanged contract, real default) and `CredentialValidator.probe(provider) :: {:valid, [String.t()]} | :invalid | :error` (new, returns upstream model ids). `config :magus, :credential_probe_req_options` (keyword, default `[]`) merged into the Req request for test stubbing via `plug: {Req.Test, ...}`.

- [ ] **Step 1: Failing tests (Req.Test-stubbed)**

```elixir
# test/magus/models/credential_validator_probe_test.exs
defmodule Magus.Models.CredentialValidatorProbeTest do
  use ExUnit.Case, async: false
  alias Magus.Models.CredentialValidator

  defp provider(attrs) do
    Map.merge(
      %{req_llm_id: "openai", base_url: nil, api_key: "sk-test", owner_user_id: "u"},
      attrs
    )
  end

  setup do
    Req.Test.stub(CredentialValidator, fn conn ->
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer sk-good"] ->
          Req.Test.json(conn, %{"data" => [%{"id" => "gpt-4o"}, %{"id" => "gpt-4o-mini"}]})

        _ ->
          conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "unauthorized"})
      end
    end)

    Application.put_env(:magus, :credential_probe_req_options, plug: {Req.Test, CredentialValidator})
    on_exit(fn -> Application.delete_env(:magus, :credential_probe_req_options) end)
    :ok
  end

  test "valid key probes to {:valid, ids} and validate/1 maps to :valid" do
    p = provider(%{api_key: "sk-good"})
    assert {:valid, ids} = CredentialValidator.probe(p)
    assert "gpt-4o" in ids
    assert CredentialValidator.validate(p) == :valid
  end

  test "401 maps to :invalid" do
    p = provider(%{api_key: "sk-bad"})
    assert CredentialValidator.probe(p) == :invalid
    assert CredentialValidator.validate(p) == :invalid
  end

  test "transport failure maps to :error" do
    Application.put_env(:magus, :credential_probe_req_options,
      plug: {Req.Test, CredentialValidator}
    )

    Req.Test.stub(CredentialValidator, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert CredentialValidator.probe(provider(%{})) == :error
  end

  test "configured validator fun still overrides" do
    Application.put_env(:magus, :credential_validator, fn _ -> :invalid end)
    on_exit(fn -> Application.delete_env(:magus, :credential_validator) end)
    assert CredentialValidator.validate(provider(%{api_key: "sk-good"})) == :invalid
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/credential_validator_probe_test.exs`
Expected: FAIL (`probe/1` undefined; validate returns :error).

- [ ] **Step 3: Implement**

Rewrite `lib/magus/models/credential_validator.ex`:

```elixir
defmodule Magus.Models.CredentialValidator do
  @moduledoc """
  Probes a provider's credentials with a minimal models-list request and
  returns a status. `validate/1` keeps the status-atom contract the Oban
  worker stamps; `probe/1` additionally returns the upstream model ids for
  the add-model picker. Tests and deployments can override the whole check
  via `config :magus, :credential_validator` (1-arity fun) and stub HTTP via
  `config :magus, :credential_probe_req_options`. The api_key is sent only
  as a request header, never logged or returned.
  """

  @type status :: :valid | :invalid | :error

  @default_base_urls %{
    "openai" => "https://api.openai.com/v1",
    "openrouter" => "https://openrouter.ai/api/v1",
    "xai" => "https://api.x.ai/v1",
    "anthropic" => "https://api.anthropic.com/v1",
    "google" => "https://generativelanguage.googleapis.com/v1beta"
  }

  @spec validate(map()) :: status()
  def validate(provider) do
    case Application.get_env(:magus, :credential_validator) do
      fun when is_function(fun, 1) ->
        fun.(provider)

      _ ->
        case probe(provider) do
          {:valid, _ids} -> :valid
          other -> other
        end
    end
  end

  @spec probe(map()) :: {:valid, [String.t()]} | :invalid | :error
  def probe(provider) do
    with {:ok, url, headers} <- request_for(provider) do
      opts =
        [url: url, headers: headers, receive_timeout: 5_000, retry: false] ++
          Application.get_env(:magus, :credential_probe_req_options, [])

      case Req.get(opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:valid, model_ids(provider.req_llm_id, body)}

        {:ok, %Req.Response{status: status}} when status in [401, 403] ->
          :invalid

        _ ->
          :error
      end
    end
  end

  defp request_for(%{req_llm_id: "anthropic", api_key: key}) do
    {:ok, "https://api.anthropic.com/v1/models",
     [{"x-api-key", key || ""}, {"anthropic-version", "2023-06-01"}]}
  end

  defp request_for(%{req_llm_id: "google", api_key: key}) do
    {:ok, "#{@default_base_urls["google"]}/models?key=#{key || ""}", []}
  end

  defp request_for(%{req_llm_id: id} = provider) do
    base = provider.base_url || Map.get(@default_base_urls, id)

    if is_binary(base) do
      {:ok, String.trim_trailing(base, "/") <> "/models",
       [{"authorization", "Bearer #{provider.api_key || ""}"}]}
    else
      :error
    end
  end

  # OpenAI-style: %{"data" => [%{"id" => ...}]}. Anthropic uses the same shape.
  # Google: %{"models" => [%{"name" => "models/gemini-..."}]}.
  defp model_ids("google", %{"models" => models}) when is_list(models) do
    models
    |> Enum.map(&(&1["name"] || ""))
    |> Enum.map(&String.replace_prefix(&1, "models/", ""))
    |> Enum.reject(&(&1 == ""))
  end

  defp model_ids(_, %{"data" => data}) when is_list(data) do
    data |> Enum.map(& &1["id"]) |> Enum.filter(&is_binary/1)
  end

  defp model_ids(_, _), do: []
end
```

Note: the google `?key=` query param carries the key in the URL for that provider's convention; never log the URL. If Req's error struct could embed the URL, rescue broadly around `Req.get` and return `:error` without logging the exception message.

- [ ] **Step 4: Run to verify pass, then the existing worker test**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/credential_validator_probe_test.exs test/magus/models/credential_validation_test.exs`
Expected: PASS (the worker test still passes; it uses the config-fun override).

- [ ] **Step 5: Compile + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/models/credential_validator.ex test/magus/models/credential_validator_probe_test.exs
git commit -m "feat(models): real per-provider credential probe with model listing (phase 2b-2a)"
```

---

### Task 4: `:list_remote_models` action (owner-only, rate-windowed)

**Files:**
- Modify: `lib/magus/models/provider.ex` (generic action + policy)
- Create: `lib/magus/models/rate_window.ex`
- Modify: `lib/magus/models.ex` (interface)
- Test: `test/magus/models/list_remote_models_test.exs` (new)

**Interfaces:**
- Consumes: `CredentialValidator.probe/1` (Task 3).
- Produces: `Magus.Models.list_remote_models(provider_id, actor: user) :: {:ok, %{status: :ok | :unauthorized | :unavailable | :rate_limited, model_ids: [String.t()]}}`; `Magus.Models.RateWindow.allow?(key, window_ms) :: boolean()`.

- [ ] **Step 1: Failing test**

```elixir
# test/magus/models/list_remote_models_test.exs
defmodule Magus.Models.ListRemoteModelsTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  setup do
    Magus.DataCase.clear_catalog!()
    user = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    Application.put_env(:magus, :credential_validator, fn _ -> :valid end)
    Application.put_env(:magus, :credential_probe, fn _ -> {:valid, ["gpt-4o"]} end)
    on_exit(fn ->
      Application.delete_env(:magus, :credential_validator)
      Application.delete_env(:magus, :credential_probe)
    end)

    %{user: user, provider: provider}
  end

  test "owner lists remote models", %{user: user, provider: provider} do
    assert {:ok, %{status: :ok, model_ids: ["gpt-4o"]}} =
             Magus.Models.list_remote_models(provider.id, actor: user)
  end

  test "non-owner is refused", %{provider: provider} do
    other = generate(user())
    assert {:error, _} = Magus.Models.list_remote_models(provider.id, actor: other)
  end

  test "second call inside the window is rate_limited", %{user: user, provider: provider} do
    assert {:ok, %{status: :ok}} = Magus.Models.list_remote_models(provider.id, actor: user)

    assert {:ok, %{status: :rate_limited, model_ids: []}} =
             Magus.Models.list_remote_models(provider.id, actor: user)
  end
end
```

This requires a `config :magus, :credential_probe` test seam on `probe/1` symmetric to the `validate/1` one: add to `CredentialValidator.probe/1` a first clause checking `Application.get_env(:magus, :credential_probe)` for a 1-arity fun.

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/list_remote_models_test.exs`
Expected: FAIL (`list_remote_models/2` undefined).

- [ ] **Step 3: Implement RateWindow**

```elixir
# lib/magus/models/rate_window.ex
defmodule Magus.Models.RateWindow do
  @moduledoc """
  Tiny per-key rate window backed by a public ETS table. Returns true when
  the key has not fired inside the window and records the hit. Best-effort
  (per-node, resets on restart), which is sufficient for bounding live
  credential probes triggered from the UI.
  """

  @table __MODULE__

  @spec allow?(term(), pos_integer()) :: boolean()
  def allow?(key, window_ms) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, last}] when now - last < window_ms ->
        false

      _ ->
        :ets.insert(@table, {key, now})
        true
    end
  end

  defp ensure_table do
    :ets.whereis(@table) != :undefined ||
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  rescue
    ArgumentError -> :ok
  end
end
```

- [ ] **Step 4: Implement the generic action**

In `lib/magus/models/provider.ex`, add to `actions do` (Ash generic actions carry arguments, not a record, so the action takes a `provider_id` and the run module loads + owner-checks it):

```elixir
action :list_remote_models, :map do
  description "Live models-list from the provider endpoint (owner-only, rate-windowed, never persisted)."
  argument :provider_id, :uuid, allow_nil?: false

  run Magus.Models.Provider.Actions.ListRemoteModels
end
```

with the run module:

```elixir
# lib/magus/models/provider/actions/list_remote_models.ex
defmodule Magus.Models.Provider.Actions.ListRemoteModels do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  @window_ms 10_000

  @impl true
  def run(input, _opts, %{actor: %{id: actor_id}}) when is_binary(actor_id) do
    provider_id = input.arguments.provider_id

    with {:ok, %{} = provider} <-
           Magus.Models.Provider
           |> Ash.Query.filter(id == ^provider_id and owner_user_id == ^actor_id)
           |> Ash.read_one(authorize?: false),
         true <- Magus.Models.RateWindow.allow?({:remote_models, provider_id}, @window_ms) do
      case Magus.Models.CredentialValidator.probe(provider) do
        {:valid, ids} -> {:ok, %{status: :ok, model_ids: ids}}
        :invalid -> {:ok, %{status: :unauthorized, model_ids: []}}
        :error -> {:ok, %{status: :unavailable, model_ids: []}}
      end
    else
      false -> {:ok, %{status: :rate_limited, model_ids: []}}
      _ -> {:error, "provider not found"}
    end
  end

  def run(_input, _opts, _context), do: {:error, "requires an actor"}
end
```

Add the policy in provider.ex's `policies do`:

```elixir
policy action(:list_remote_models) do
  authorize_if actor_present()
end
```

(Ownership is enforced inside the run module's filter; the policy gates authentication. Note the nil-actor branch never reaches the filter, so no nil-pin warning.)

Add the `probe/1` config seam in `credential_validator.ex` (first line of `probe/1`):

```elixir
def probe(provider) do
  case Application.get_env(:magus, :credential_probe) do
    fun when is_function(fun, 1) -> fun.(provider)
    _ -> do_probe(provider)
  end
end
```

(rename the existing body to `defp do_probe/1`).

In `lib/magus/models.ex` Provider block: `define :list_remote_models, action: :list_remote_models, args: [:provider_id]`.

- [ ] **Step 5: Run, compile, commit**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/list_remote_models_test.exs test/magus/models/credential_validator_probe_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS.

```bash
git add lib/magus/models/provider.ex lib/magus/models/provider/actions/ lib/magus/models/rate_window.ex lib/magus/models/credential_validator.ex lib/magus/models.ex test/magus/models/list_remote_models_test.exs
git commit -m "feat(models): owner-only rate-windowed list_remote_models action (phase 2b-2a)"
```

---

### Task 5: Cascade destroy + owned-model destroy + RPC exposure + codegen

**Files:**
- Modify: `lib/magus/models/provider.ex` (`:destroy_owned` + policy + AshTypescript extension + typescript block)
- Create: `lib/magus/models/provider/changes/destroy_owned_models.ex`
- Modify: `lib/magus/chat/model.ex` (`:destroy_owned` action)
- Modify: `lib/magus/models.ex`, `lib/magus/chat/chat.ex` (interfaces + `typescript_rpc` blocks)
- Regenerate: `frontend/src/lib/ash/ash_rpc.ts` (via `mix ash.codegen`)
- Test: `test/magus/models/provider_destroy_owned_test.exs` (new)

**Interfaces:**
- Produces: `Magus.Models.destroy_owned_provider(provider, actor:)` (cascades owned models); `Magus.Chat.destroy_owned_model(model, actor:)`; RPC actions `list_owned_providers`, `create_owned_provider`, `update_owned_provider`, `destroy_owned_provider`, `validate_provider_credential`, `list_remote_models`, `create_owned_model`, `list_owned_models`, `destroy_owned_model` in `ash_rpc.ts`. Provider TS type `ModelProvider` with `enabled` (field_names-mapped), `validationStatus`, `lastValidatedAt`.

- [ ] **Step 1: Failing test**

```elixir
# test/magus/models/provider_destroy_owned_test.exs
defmodule Magus.Models.ProviderDestroyOwnedTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  setup do
    Magus.DataCase.clear_catalog!()
    user = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{name: "M", model_id: "gpt-x", model_provider_id: provider.id},
        actor: user
      )

    %{user: user, provider: provider, model: model}
  end

  test "owner destroys provider, models cascade", %{user: user, provider: provider, model: model} do
    assert :ok = Magus.Models.destroy_owned_provider(provider, actor: user)
    assert {:error, _} = Ash.get(Magus.Chat.Model, model.id, authorize?: false)
    assert {:error, _} = Ash.get(Magus.Models.Provider, provider.id, authorize?: false)
  end

  test "non-owner refused", %{provider: provider} do
    other = generate(user())
    assert {:error, _} = Magus.Models.destroy_owned_provider(provider, actor: other)
  end

  test "owner destroys a single owned model", %{user: user, model: model} do
    assert :ok = Magus.Chat.destroy_owned_model(model, actor: user)
    assert {:error, _} = Ash.get(Magus.Chat.Model, model.id, authorize?: false)
  end

  test "non-owner cannot destroy the model", %{model: model} do
    other = generate(user())
    assert {:error, _} = Magus.Chat.destroy_owned_model(model, actor: other)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/provider_destroy_owned_test.exs`
Expected: FAIL (actions undefined).

- [ ] **Step 3: Implement destroys**

Provider (`lib/magus/models/provider.ex`):

```elixir
destroy :destroy_owned do
  description "Owner deletes a user-owned provider; its owned models are deleted first."
  require_atomic? false
  change Magus.Models.Provider.Changes.DestroyOwnedModels
end
```

```elixir
# lib/magus/models/provider/changes/destroy_owned_models.ex
defmodule Magus.Models.Provider.Changes.DestroyOwnedModels do
  @moduledoc """
  Before destroying an owned provider, deletes its owned models (the models
  FK restricts otherwise). Runs in the same transaction; scoped to rows that
  are both owned and linked to this provider.
  """
  use Ash.Resource.Change
  import Ecto.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      provider = cs.data

      if is_binary(provider.owner_user_id) do
        from(m in "models",
          where: m.model_provider_id == type(^provider.id, :binary_id) and not is_nil(m.owner_user_id)
        )
        |> Magus.Repo.delete_all()

        cs
      else
        Ash.Changeset.add_error(cs, field: :base, message: "only user-owned providers")
      end
    end)
  end
end
```

Provider policy (in `policies do`):

```elixir
policy action(:destroy_owned) do
  authorize_if expr(owner_user_id == ^actor(:id))
end
```

Model (`lib/magus/chat/model.ex`, in `actions do`; Model has NO authorizer, so enforce in-change):

```elixir
destroy :destroy_owned do
  description "Owner deletes a user-owned model."
  require_atomic? false

  change fn changeset, context ->
    actor_id =
      case context.actor do
        %{id: id} when is_binary(id) -> id
        _ -> nil
      end

    if is_binary(actor_id) and changeset.data.owner_user_id == actor_id do
      changeset
    else
      Ash.Changeset.add_error(changeset, field: :base, message: "must be a model you own")
    end
  end
end
```

(Per the 2b-1 convention, an inline change is acceptable only if the codebase pattern allows; prefer a change module `lib/magus/chat/model/changes/require_owner.ex` with the same body if `mix credo`/conventions object. The repo convention is change modules; create `RequireOwner` as a module.)

Interfaces: `lib/magus/models.ex` Provider block adds `define :destroy_owned_provider, action: :destroy_owned`; `lib/magus/chat/chat.ex` Model block adds `define :destroy_owned_model, action: :destroy_owned`.

- [ ] **Step 4: RPC exposure**

`lib/magus/models.ex`: add the domain-level RPC block (mirror the exact syntax from `lib/magus/chat/chat.ex:12`, `typescript_rpc do resource ... rpc_action :public_name, :action end`; the domain also needs the AshTypescript.Rpc extension in `use Ash.Domain` — copy how Magus.Chat declares it):

```elixir
typescript_rpc do
  resource Magus.Models.Provider do
    rpc_action :list_owned_providers, :owned
    rpc_action :create_owned_provider, :create_owned
    rpc_action :update_owned_provider, :update_owned
    rpc_action :destroy_owned_provider, :destroy_owned
    rpc_action :validate_provider_credential, :validate
    rpc_action :list_remote_models, :list_remote_models
  end
end
```

`lib/magus/chat/chat.ex` (inside the existing `typescript_rpc` block's Model resource section, next to `list_active_models`):

```elixir
rpc_action :create_owned_model, :create_owned
rpc_action :list_owned_models, :owned
rpc_action :destroy_owned_model, :destroy_owned
```

`lib/magus/models/provider.ex`: add `extensions: [AshTypescript.Resource]` to `use Ash.Resource` and:

```elixir
typescript do
  type_name "ModelProvider"
  field_names enabled?: "enabled"
end
```

Check which attributes are `public?` on Provider: `name`, `slug`, `req_llm_id`, `base_url`, `enabled?`, `validation_status`, `last_validated_at` are public; `api_key` (sensitive, non-public) and `owner_user_id` (non-public) stay hidden. `create_owned`/`update_owned` accept `api_key` as input, which AshTypescript allows for accepted non-public attributes; verify codegen output includes it in the input type and does NOT include it in the ModelProvider output type.

- [ ] **Step 5: Codegen + verify**

```bash
set -a && source .env && set +a
MIX_ENV=test mix ash.codegen phase_2b2a_rpc
```

Expected: `frontend/src/lib/ash/ash_rpc.ts` regenerated with the 9 new functions; NO migration generated (if one appears, stop and investigate per Global Constraints). Grep the generated file for `listOwnedProviders`, `createOwnedModel`, `listRemoteModels` and confirm the ModelProvider type has `enabled` (not `enabled?`) and no `apiKey` output field.

- [ ] **Step 6: Run, compile, commit**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/provider_destroy_owned_test.exs test/magus/models && MIX_ENV=test mix compile --warnings-as-errors`
Expected: new tests PASS; pre-existing models/ failures only (role_assignment, roles_explain, default_flags_backfill, catalog_sync-in-suite pollution).

```bash
git add lib/magus/models/provider.ex lib/magus/models/provider/changes/destroy_owned_models.ex lib/magus/chat/model.ex lib/magus/chat/model/changes/require_owner.ex lib/magus/models.ex lib/magus/chat/chat.ex frontend/src/lib/ash/ash_rpc.ts test/magus/models/provider_destroy_owned_test.exs
git commit -m "feat(models): cascade destroy + RPC exposure for owned providers/models (phase 2b-2a)"
```

---

### Task 6: SPA providers page (provider CRUD + validation badge)

**Files:**
- Create: `frontend/src/routes/settings/providers/+page.svelte` (+ colocated components under `frontend/src/lib/components/settings/providers/` if the mirror uses that layout)
- Modify: the SPA api wrapper module (find where `listActiveModels` is wrapped, e.g. `frontend/src/lib/ash/api.ts` or similar; mirror it)
- Modify: the settings navigation (where `/settings/mcp-servers` is registered)
- Test: `frontend/src/lib/components/settings/providers/*.test.ts` (vitest, colocated per repo convention)

**Interfaces:**
- Consumes (from ash_rpc.ts, Task 5): `listOwnedProviders()`, `createOwnedProvider(input)`, `updateOwnedProvider(id, input)`, `destroyOwnedProvider(id)`, `validateProviderCredential(id)`.
- Produces: route `/settings/providers`; components emitting `data-testid` hooks: `provider-card`, `provider-add-button`, `provider-form`, `provider-validation-badge`, `provider-delete-button`.

**MIRROR-FIRST (binding):** before writing any code, read `frontend/src/routes/settings/mcp-servers/+page.svelte` end to end (page shape, form wiring, error surfacing, api-wrapper usage) and `frontend/src/routes/settings/models/+page.svelte` (list sections). Follow their idioms exactly (Svelte 5 runes, form state, RpcResult handling). The contracts below are binding; the idioms come from the mirrors.

- [ ] **Step 1: Failing vitest for pure logic**

Extract form/display logic into a pure module and test it first:

```typescript
// frontend/src/lib/components/settings/providers/provider-form.ts
export const PROVIDER_TYPES = [
  'anthropic', 'openai', 'openrouter', 'xai', 'google', 'openai_compatible',
] as const;
export type ProviderType = (typeof PROVIDER_TYPES)[number];

export function requiresBaseUrl(type: ProviderType): boolean {
  return type === 'openai_compatible';
}

export type ValidationStatus = 'pending' | 'valid' | 'invalid' | 'error';

export function badgeKind(status: ValidationStatus): 'neutral' | 'success' | 'danger' | 'warning' {
  switch (status) {
    case 'valid': return 'success';
    case 'invalid': return 'danger';
    case 'error': return 'warning';
    default: return 'neutral';
  }
}
```

```typescript
// frontend/src/lib/components/settings/providers/provider-form.test.ts
import { describe, expect, it } from 'vitest';
import { PROVIDER_TYPES, badgeKind, requiresBaseUrl } from './provider-form';

describe('provider form logic', () => {
  it('only openai_compatible requires base url', () => {
    expect(requiresBaseUrl('openai_compatible')).toBe(true);
    for (const t of PROVIDER_TYPES.filter((t) => t !== 'openai_compatible')) {
      expect(requiresBaseUrl(t)).toBe(false);
    }
  });

  it('maps validation status to badge kind', () => {
    expect(badgeKind('valid')).toBe('success');
    expect(badgeKind('invalid')).toBe('danger');
    expect(badgeKind('error')).toBe('warning');
    expect(badgeKind('pending')).toBe('neutral');
  });
});
```

Run: `cd frontend && npx vitest run src/lib/components/settings/providers` -> FAIL (module missing), then create the module -> PASS. (Verify the exact vitest invocation from frontend/package.json scripts first.)

- [ ] **Step 2: API wrappers**

Mirror the existing wrapper pattern (same file where `listActiveModels` is wrapped) for the five provider functions. Follow the RpcResult error-shape convention exactly as the mirror does; no new abstractions.

- [ ] **Step 3: Page + components**

Build `/settings/providers` mirroring mcp-servers' structure:
- Provider list: one card per provider (`data-testid="provider-card"`), showing name, `req_llm_id` type label, "key set" static indicator (the API never returns the key; presence is implied by the row existing), validation badge (`data-testid="provider-validation-badge"`, class/kind from `badgeKind`), re-validate button calling `validateProviderCredential` then refetching, enabled toggle calling `updateOwnedProvider`.
- Add/edit form (`data-testid="provider-form"`): type select over `PROVIDER_TYPES` (disabled on edit; `req_llm_id` is immutable), name, api_key password input (placeholder indicates unchanged-on-edit; empty value on edit means "do not send the field"), base_url shown only when `requiresBaseUrl(type)`. Server-side field errors surface per the mirror's pattern (SSRF/cap/allowlist errors arrive as Ash field errors on `base_url`/`base`/`req_llm_id`).
- Delete button (`data-testid="provider-delete-button"`) opens a confirm dialog; Task 7 extends it to list the models that cascade.
- Empty state with a short BYOK explanation.
- Register the page in the settings navigation exactly the way `mcp-servers` is registered.

- [ ] **Step 4: Structural render test**

Following the repo's existing component-test idiom (if the mirror pages have render tests, copy that harness; if they do not, keep coverage at the pure-logic level and say so in the report): assert count of `[data-testid="provider-card"]` for a mocked list of 2 providers, and that the form toggles the base_url field on type change. No label/copy/CSS assertions.

- [ ] **Step 5: Verify + commit**

```bash
cd frontend && npx vitest run src/lib/components/settings/providers
```
Expected: PASS. Also run the frontend type check the way CI does (check package.json for `check`/`typecheck` script) and ensure it passes.

```bash
git add frontend/src/routes/settings/providers frontend/src/lib/components/settings/providers <api-wrapper-file> <settings-nav-file>
git commit -m "feat(spa): /settings/providers page with provider CRUD + validation badges (phase 2b-2a)"
```

---

### Task 7: SPA models-per-provider section + probe-powered picker

**Files:**
- Modify: `frontend/src/routes/settings/providers/+page.svelte` + components dir from Task 6
- Create: `frontend/src/lib/components/settings/providers/model-picker.ts` (+ `.test.ts`)
- Test: colocated vitest

**Interfaces:**
- Consumes (ash_rpc.ts): `listRemoteModels(providerId)` returning `{status: 'ok'|'unauthorized'|'unavailable'|'rate_limited', modelIds: string[]}`, `createOwnedModel(input)`, `listOwnedModels()`, `destroyOwnedModel(id)`.
- Produces: testids `provider-models-section`, `model-row`, `model-add-button`, `model-id-picker`, `model-id-freetext`, `model-delete-button`.

- [ ] **Step 1: Failing vitest for picker logic**

```typescript
// frontend/src/lib/components/settings/providers/model-picker.test.ts
import { describe, expect, it } from 'vitest';
import { filterModelIds, pickerMode } from './model-picker';

describe('model picker', () => {
  it('filters ids by case-insensitive substring', () => {
    const ids = ['gpt-4o', 'gpt-4o-mini', 'o3-mini'];
    expect(filterModelIds(ids, 'MINI')).toEqual(['gpt-4o-mini', 'o3-mini']);
    expect(filterModelIds(ids, '')).toEqual(ids);
  });

  it('falls back to freetext when listing is not ok', () => {
    expect(pickerMode('ok', ['a'])).toBe('picker');
    expect(pickerMode('ok', [])).toBe('freetext');
    expect(pickerMode('unauthorized', [])).toBe('freetext');
    expect(pickerMode('unavailable', [])).toBe('freetext');
    expect(pickerMode('rate_limited', [])).toBe('freetext');
  });
});
```

```typescript
// frontend/src/lib/components/settings/providers/model-picker.ts
export type RemoteListStatus = 'ok' | 'unauthorized' | 'unavailable' | 'rate_limited';

export function filterModelIds(ids: string[], query: string): string[] {
  const q = query.trim().toLowerCase();
  if (q === '') return ids;
  return ids.filter((id) => id.toLowerCase().includes(q));
}

export function pickerMode(status: RemoteListStatus, ids: string[]): 'picker' | 'freetext' {
  return status === 'ok' && ids.length > 0 ? 'picker' : 'freetext';
}
```

Run RED (missing module) then GREEN.

- [ ] **Step 2: Wire the models section**

Per provider card, an expandable `provider-models-section`: rows of that provider's owned models (filter `listOwnedModels()` by `modelProviderId` client-side, or add a load on expand; mirror how the repo fetches per-parent collections), each with `model-delete-button` -> `destroyOwnedModel` + refetch. Add-model form: on open, call `listRemoteModels(providerId)`; `pickerMode` decides searchable-select (filtered by `filterModelIds`) vs free-text input (`model-id-freetext`, always reachable via a "type it manually" toggle); fields: display name (required), optional context window, input/output cost values. Submit -> `createOwnedModel({modelId, name, modelProviderId, contextWindow?, ...})` -> refetch. Surface Ash field errors per the mirror pattern (media-block and cap errors arrive on `output_modalities`/`base`).

Extend Task 6's provider delete confirm to list the models from this section that will cascade.

- [ ] **Step 3: Structural test + full frontend verify**

Same harness decision as Task 6 Step 4: `model-row` count for a mocked list, picker/freetext mode switch on mocked `listRemoteModels` statuses. Then run the whole frontend suite + typecheck:

```bash
cd frontend && npx vitest run && <typecheck script from package.json>
```
Expected: PASS (entire existing suite stays green).

- [ ] **Step 4: Commit**

```bash
git add frontend/src/routes/settings/providers frontend/src/lib/components/settings/providers
git commit -m "feat(spa): per-provider model management with probe-powered picker (phase 2b-2a)"
```

---

## Final Verification (after all tasks)

- [ ] Backend: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models test/magus/chat test/magus/agents/clients` (only the documented pre-existing failures: role_assignment, roles_explain, default_flags_backfill, catalog_sync whole-dir pollution; verify any other failure in isolation before attributing).
- [ ] `MIX_ENV=test mix compile --warnings-as-errors`.
- [ ] Frontend: `cd frontend && npx vitest run` + typecheck script, all green.
- [ ] No migration files added; no unrelated snapshot changes; no em dashes (`grep -rn "—" lib/magus/models lib/magus/agents frontend/src/routes/settings/providers` over changed files).
- [ ] Spec cross-check: execution wiring (Tasks 1-2), probe (3), remote listing (4), cascade + RPC (5), SPA page (6-7); background-ops boundary untouched (no actor threading into workers); degradation still soft everywhere.
