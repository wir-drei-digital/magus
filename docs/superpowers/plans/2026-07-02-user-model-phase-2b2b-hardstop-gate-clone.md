# Phase 2b-2b Implementation Plan: Hard-Stop, Cloud Gate, Clone, Write Guards

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flip broken explicit model selections from silent fallback to a blocking pre-flight error with one-click remediation; gate cloud provider creation behind a paid plan via a seam; add the clone/prefill affordance; land the Model write policy floor and the RPC-surface pin test.

**Architecture:** The Resolver stays total; the hard-stop is caller policy in Preflight/MediaBypass, riding the exact rails the existing region/limit pre-flight blocks use. The gate is a config-resolved seam module (open-core default allows). Clone/prefill and remediation are SPA work following the established mirror-first pattern. The write floor adopts the authorizer with reads explicitly open.

**Tech Stack:** Elixir/Ash 3.x, Jido plugins, AshTypescript RPC, SvelteKit (Svelte 5) + vitest.

**Reference spec:** `docs/superpowers/specs/2026-07-02-user-model-phase-2b2b-hardstop-gate-clone-design.md` (read the Design section for your task before starting).

## Global Constraints

- No em dashes in any code, comment, string, or commit message.
- Tests: `set -a && source .env && set +a && MIX_ENV=test mix test <path>`; NEVER `mix ash.reset`; compile gate before each final commit: `MIX_ENV=test mix compile --warnings-as-errors`; pristine test output.
- Frontend: `cd frontend && npx vitest run <path>` + the package.json check script; structural `data-testid` assertions only (no label/copy/CSS).
- Test factory: `user = generate(user())` via `import Magus.Generators`; `Magus.DataCase.clear_catalog!()` in catalog-touching setups.
- Fail-closed and behavior-neutral for `:auto`/unselected paths: the ONLY new block condition is `Magus.Models.Resolution.degraded?/1` on an explicit selection. No billing check may enter the resolution hot path.
- Ash policy AND-combination: every policy whose condition matches an action must pass; owned actions must match exactly ONE policy each. Use `action(...)` matchers, never `action_type(...)` where it would double-match `:create_owned`/`:destroy_owned`.
- Nil-actor filter branching rule: never `owner_user_id == ^actor_id` with a possibly-nil pin.
- If `mix ash.codegen` proposes a migration or unrelated snapshot drops (platform_pricing/pricing_tiers/seat_grants), stop/exclude per prior phases; NO schema change is expected anywhere in this plan.
- Mirror-first frontend tasks: read the named mirror files fully before coding; contracts here are binding, idioms come from the mirrors.

## File Structure

- `lib/magus/agents/plugins/support/preflight.ex`, `media_bypass.ex` — hard-stop block + payload.
- `lib/magus/models/provider_gate.ex` (new seam) + validation wiring in `lib/magus/models/provider.ex`.
- `lib/magus/chat/model.ex` — write policy floor.
- `test/magus/rpc_surface_test.exs` (new pin test).
- `frontend/src/lib/components/.../chat` error-event remediation; `frontend/src/routes/settings/providers/` prefill + gate CTA; `frontend/src/routes/settings/models/` template action.

---

### Task 1: Hard-stop in Preflight + MediaBypass

**Files:**
- Modify: `lib/magus/agents/plugins/support/preflight.ex` (main path around the `Resolver.resolve` at ~:83 and the resume path ~:185), `lib/magus/agents/plugins/support/media_bypass.ex` (~:38)
- Test: `test/magus/agents/plugins/support/preflight_hardstop_test.exs` (new)

**Interfaces:**
- Consumes: `Magus.Models.Resolution.degraded?/1`, `resolution.requested_selection` (`%{by: :id | :key, value: term}`), `resolution.model` (the fallback), existing block idiom `handle_region_unavailable/2` + `{:ok, {:override, Jido.Actions.Control.Noop}}` (preflight.ex ~:101-104) and the deny branch of `check_usage_limit` in the same function.
- Produces: a broadcast error event whose `tool_call_data`/payload contains `%{kind: "broken_model_selection", requested_by: "id" | "key", requested_value: ..., fallback_key: ..., scope: "conversation" | "user"}`; Task 2 (SPA) consumes exactly these string keys.

- [ ] **Step 1: Read the enclosing code first.** In `preflight.ex`, read the whole function containing the main `Resolver.resolve` call and the private handlers it uses to block (region-unavailable and usage-limit-deny). Identify: (a) how the error event/message is persisted+broadcast (the same helper the limit path uses), (b) what `message_id`/`conversation_id` bindings are available. Note them in your report.

- [ ] **Step 2: Write the failing test.** Model it on `test/magus/agents/plugins/support/preflight_actor_test.exs` and neighboring preflight tests (read them first; if the main path is not isolatable, test through the same seam those tests use). Cases:

```elixir
# test/magus/agents/plugins/support/preflight_hardstop_test.exs (shape; adapt setup to the file you mirror)
# 1. Owner selects their owned model, then the model is destroyed:
#    building the react signal for their next message returns the Noop override
#    (blocked) and persists/broadcasts an error event whose payload includes
#    kind "broken_model_selection", requested_by/requested_value matching the
#    stale selection, fallback_key = the resolved default, and the right scope.
# 2. scope derivation: conversation.selected_model_id stale -> scope "conversation";
#    conversation selection nil but user.selected_model_id stale -> scope "user".
# 3. :auto chat key -> NOT blocked (no requested_selection).
# 4. No explicit selection anywhere -> NOT blocked.
# 5. Multiplayer: sender B on A's owned pinned model -> blocked with scope "conversation".
```

Write real assertions against whatever the mirrored harness exposes (the persisted event message and the returned override). If the harness only allows resolver-level assertions, escalate BLOCKED rather than watering the test down: this task exists to verify the block.

- [ ] **Step 3: RED.** Run the file; expected: failures because no block happens.

- [ ] **Step 4: Implement.** After each `Resolver.resolve` in the MAIN and RESUME paths (not the debug/assembly path at ~:261, which builds context rather than executing a turn): if `Resolution.degraded?(resolution)` then call a new private `handle_broken_selection(conversation_id, message_id, resolution, scope)` that mirrors the limit/region handler (persist + broadcast the error event with the payload above) and return the same Noop override. Derive `scope`: `"conversation"` when the conversation's own selection (`conversation.selected_model_id` or a conversation-set model key for the mode) sourced the requested value, else `"user"`; compute it from the same data `ModelKeyResolver` used (the conversation is in scope at both sites). MediaBypass: same check + a media-appropriate error broadcast mirroring how it reports its existing failures (read its current error path first). Keys in the payload are STRINGS as specified in Interfaces.

- [ ] **Step 5: GREEN + regressions.** Run the new file plus `test/magus/models/resolver_test.exs`, `resolver_ownership_test.exs`, `preflight_actor_test.exs`, and the existing preflight suite(s) you mirrored. All green; `:auto` cases must show no behavior change.

- [ ] **Step 6: Compile gate + commit** with explicit paths: `feat(agents): pre-flight hard-stop on degraded explicit model selections (phase 2b-2b)`.

---

### Task 2: SPA remediation on the error event

**Files:**
- Modify: the SPA chat component that renders error/event messages (locate: grep `frontend/src` for how event messages with error kinds render; read the component fully), plus a small pure module `frontend/src/lib/chat/broken-selection.ts` (+ `.test.ts`)
- Test: colocated vitest

**Interfaces:**
- Consumes: the Task 1 payload (string keys: `kind`, `requested_by`, `requested_value`, `fallback_key`, `scope`); existing RPCs `setConversationModel` (nil clears) and `selectModel` (nil clears) in `ash_rpc.ts`/api wrappers; the SPA's existing message-send path.
- Produces: on a `broken_selection` error event, a "Reset to default and retry" action (`data-testid="broken-selection-reset"`) that clears the scoped selection (conversation vs user per `scope`) and re-sends the blocked message text.

- [ ] **Step 1: Pure module + failing vitest.**

```typescript
// frontend/src/lib/chat/broken-selection.ts
export interface BrokenSelectionPayload {
  kind: string; requested_by: string; requested_value: string;
  fallback_key: string; scope: string;
}
export function isBrokenSelection(p: unknown): p is BrokenSelectionPayload {
  return !!p && typeof p === 'object' && (p as any).kind === 'broken_model_selection';
}
export function resetTarget(p: BrokenSelectionPayload): 'conversation' | 'user' {
  return p.scope === 'user' ? 'user' : 'conversation';
}
```

Vitest: `isBrokenSelection` accepts the payload and rejects other kinds/null; `resetTarget` maps `user` -> user, anything else -> conversation. RED then GREEN.

- [ ] **Step 2: Wire the action.** MIRROR-FIRST: read the chat error-event rendering component and how existing message actions (retry/copy) are wired, plus how the composer sends a message. Add the reset button when `isBrokenSelection(payload)`: click -> `resetTarget` decides `setConversationModel(conversationId, null)` vs `selectModel(null)` (verify the exact wrapper names/shapes in the api layer) -> re-send the blocked message. Re-send: reuse the SPA's existing retry mechanism if one exists for failed messages (search for it and say what you found in your report); otherwise send a fresh message with the original text via the normal send path. Never double-persist: the fresh-send path is acceptable because the blocked turn produced no agent response.

- [ ] **Step 3: Verify.** `cd frontend && npx vitest run src/lib/chat` + full `npx vitest run` + the package.json check script. All green.

- [ ] **Step 4: Commit**: `feat(spa): one-click reset + retry for broken model selections (phase 2b-2b)`.

---

### Task 3: ProviderGate seam + cloud CTA mapping

**Files:**
- Create: `lib/magus/models/provider_gate.ex`, `lib/magus/models/validations/provider_gate_allows.ex`
- Modify: `lib/magus/models/provider.ex` (wire validation), `config/config.exs` (default), providers page SPA error mapping
- Test: `test/magus/models/provider_gate_test.exs` (new)

**Interfaces:**
- Produces: `Magus.Models.ProviderGate.can_create?(user) :: :ok | {:error, atom}` resolved via `Application.get_env(:magus, :provider_gate, Magus.Models.ProviderGate.Open)`; behaviour module + `Open` default impl returning `:ok`.

- [ ] **Step 1: Failing test.**

```elixir
defmodule Magus.Models.ProviderGateTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  defmodule Deny do
    @behaviour Magus.Models.ProviderGate
    def can_create?(_user), do: {:error, :paid_plan_required}
  end

  setup do
    Magus.DataCase.clear_catalog!()
    %{user: generate(user())}
  end

  test "default gate allows create", %{user: user} do
    assert {:ok, _} =
             Magus.Models.create_owned_provider(
               %{name: "P", req_llm_id: "openai", api_key: "sk"}, actor: user)
  end

  test "deny impl blocks create and key update, not name edit", %{user: user} do
    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "P", req_llm_id: "openai", api_key: "sk"}, actor: user)

    Application.put_env(:magus, :provider_gate, __MODULE__.Deny)
    on_exit(fn -> Application.delete_env(:magus, :provider_gate) end)

    assert {:error, _} =
             Magus.Models.create_owned_provider(
               %{name: "Q", req_llm_id: "openai", api_key: "sk2"}, actor: user)

    assert {:error, _} =
             Magus.Models.update_owned_provider(provider, %{api_key: "sk-new"}, actor: user)

    assert {:ok, _} = Magus.Models.update_owned_provider(provider, %{name: "Renamed"}, actor: user)
  end
end
```

- [ ] **Step 2: RED**, then implement:

```elixir
# lib/magus/models/provider_gate.ex
defmodule Magus.Models.ProviderGate do
  @moduledoc """
  Deployment seam gating BYOK provider creation and credential updates.
  Open-core default allows everything; the cloud edition swaps the module
  via `config :magus, :provider_gate` to require a paid or trialing
  subscription. Never consulted on the resolution hot path, and a lapsed
  subscription never disables existing providers.
  """
  @callback can_create?(user :: struct()) :: :ok | {:error, atom()}

  def impl, do: Application.get_env(:magus, :provider_gate, __MODULE__.Open)
  def can_create?(user), do: impl().can_create?(user)

  defmodule Open do
    @behaviour Magus.Models.ProviderGate
    @impl true
    def can_create?(_user), do: :ok
  end
end
```

```elixir
# lib/magus/models/validations/provider_gate_allows.ex
defmodule Magus.Models.Validations.ProviderGateAllows do
  @moduledoc "Applies the ProviderGate seam on create and on credential changes."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, %{actor: %{} = actor}) do
    credential_change? =
      Ash.Changeset.changing_attribute?(changeset, :api_key) or
        Ash.Changeset.changing_attribute?(changeset, :base_url)

    if changeset.action_type == :create or credential_change? do
      case Magus.Models.ProviderGate.can_create?(actor) do
        :ok -> :ok
        {:error, reason} -> {:error, field: :base, message: to_string(reason)}
      end
    else
      :ok
    end
  end

  def validate(_changeset, _opts, _context), do: {:error, field: :base, message: "requires an actor"}
end
```

Wire `validate Magus.Models.Validations.ProviderGateAllows` on `:create_owned` and `:update_owned` in provider.ex. Add `config :magus, :provider_gate, Magus.Models.ProviderGate.Open` near the other :magus config.

- [ ] **Step 3: GREEN + regression** (`provider_owned_test.exs`, `credential_validation_test.exs`).

- [ ] **Step 4: SPA CTA.** In the providers page (read it first), map a create/update failure whose message is `paid_plan_required` to an upgrade state on the form (`data-testid="provider-gate-cta"`, link to the subscription settings route used elsewhere in settings nav). Extend the page's existing `applyErrors`-style routing; a tiny pure helper + vitest if logic warrants.

- [ ] **Step 5: Verify (backend suites + frontend run + check), compile gate, commit**: `feat(models): ProviderGate seam for cloud paid-plan gating (phase 2b-2b)`.

---

### Task 4: Clone/prefill (SPA-only)

**Files:**
- Create: `frontend/src/lib/components/settings/providers/model-template.ts` (+ `.test.ts`)
- Modify: `frontend/src/routes/settings/models/+page.svelte` (template action on catalog rows), `frontend/src/routes/settings/providers/+page.svelte` (accept prefill)

**Interfaces:**
- Produces: `toTemplate(model) :: {name, modelId, contextWindow?, inputCost?, outputCost?}` where `modelId` strips the `<slug>:` prefix from the model key IF the key is exposed; if the curation list's Model type does not expose `key` (it is non-public), derive `modelId` from the model's `name` as fallback and document it. Prefill transport: URL query params on `/settings/providers` (e.g. `?template=<urlencoded json>`), parsed on mount; survives the create-provider-first detour because it stays in the URL.

- [ ] **Step 1: Pure module + failing vitest** for `toTemplate` (maps fields, handles missing costs/context) and `parseTemplateParam(url)` (round-trips the JSON, rejects malformed input safely). RED -> GREEN.

- [ ] **Step 2: Wire.** MIRROR-FIRST: read both pages. Curation page: add a "use as template" action (`data-testid="model-template-button"`) on catalog (non-owned) rows navigating to `/settings/providers?template=...`. Providers page: on mount, if a valid template param exists, open the add-model flow prefilled (reuse Task 6/7 form state from 2b-2a); if the user owns no compatible provider, open the create-provider form first, keeping the param in the URL. Strip the param after consumption (mirror how `?edit=` params are stripped elsewhere in the SPA: grep for the recent "strip ?edit= param" pattern).

- [ ] **Step 3: Full frontend suite + check green; commit**: `feat(spa): clone catalog model into BYOK create form via template prefill (phase 2b-2b)`.

---

### Task 5: Model write policy floor

**Files:**
- Modify: `lib/magus/chat/model.ex`
- Test: `test/magus/chat/model_write_floor_test.exs` (new)

**Interfaces:**
- Produces: `Magus.Chat.Model` with `authorizers: [Ash.Policy.Authorizer]` and policies: reads always allowed; `:create_owned`/`:destroy_owned` always allowed at policy level (changes enforce); named admin actions gated by `Magus.Checks.IsAdmin`.

- [ ] **Step 1: Failing test.**

```elixir
defmodule Magus.Chat.ModelWriteFloorTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  setup do
    Magus.DataCase.clear_catalog!()
    %{user: generate(user())}
  end

  test "non-admin cannot use the admin create/update/destroy", %{user: user} do
    assert {:error, %Ash.Error.Forbidden{}} =
             Magus.Chat.Model
             |> Ash.Changeset.for_create(:create, %{name: "x", key: "openrouter:x/y", context_window: 10},
               actor: user)
             |> Ash.create()
  end

  test "reads and owned actions unchanged", %{user: user} do
    assert {:ok, _} = Magus.Chat.list_active_models(actor: user)

    {:ok, provider} =
      Magus.Models.create_owned_provider(%{name: "P", req_llm_id: "openai", api_key: "sk"}, actor: user)

    assert {:ok, model} =
             Magus.Chat.create_owned_model(
               %{name: "M", model_id: "gpt-x", model_provider_id: provider.id}, actor: user)

    assert :ok = Magus.Chat.destroy_owned_model(model, actor: user)
  end
end
```

- [ ] **Step 2: RED**, then add to model.ex: `authorizers: [Ash.Policy.Authorizer]` on `use Ash.Resource`, and:

```elixir
policies do
  # Reads stay open: owned-row scoping lives in the list_active prepare, the
  # :owned action filter, and the selection validations. Full read policies
  # arrive with workspace sharing (Phase 3).
  policy action_type(:read) do
    authorize_if always()
  end

  # Owned actions: ownership is enforced fail-closed inside their changes
  # (BuildOwnedModel / RequireOwner). Exactly one policy matches each.
  policy action([:create_owned, :destroy_owned]) do
    authorize_if always()
  end

  policy action([:create, :update, :destroy]) do
    authorize_if Magus.Checks.IsAdmin
  end
end
```

- [ ] **Step 3: Writer audit.** Run `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models test/magus/chat` and fix every NEW failure by adding `authorize?: false` to actor-less internal/test Model writes (known from the 2b-1 attempt: catalog_sync_test setups and siblings). Do NOT touch reads. Verify against the documented pre-existing failures (role_assignment, roles_explain, default_flags_backfill, catalog_sync whole-dir pollution: confirm in isolation before attributing). Also grep `lib/` for `for_create(:create` / `for_update(:update` on Model without `authorize?: false` and confirm each runs as admin or system (add the bypass where system).

- [ ] **Step 4: GREEN, compile gate, commit**: `feat(chat): Model write policy floor, reads open (phase 2b-2b)`.

---

### Task 6: RPC-surface pin test

**Files:**
- Create: `test/magus/rpc_surface_test.exs`

**Interfaces:**
- Consumes: the `typescript_rpc` DSL on `Magus.Chat` and `Magus.Models`. Discover the Spark introspection API first: check `deps/ash_typescript` for an `Info` module (e.g. `AshTypescript.Rpc.Info`) exposing the rpc resources/actions; if none exists, parse via `Spark.Dsl.Extension.get_entities(Magus.Chat, [:typescript_rpc])` (verify the exact section path from the DSL source).

- [ ] **Step 1: Failing test** asserting exact allowlists:

```elixir
defmodule Magus.RpcSurfaceTest do
  use ExUnit.Case, async: true

  @model_expected ~w(list_active list_image_generation list_video_generation create_owned owned destroy_owned)a
  @provider_expected ~w(owned create_owned update_owned destroy_owned validate list_remote_models)a

  test "Model RPC surface is pinned" do
    assert exposed_actions(Magus.Chat, Magus.Chat.Model) |> Enum.sort() ==
             Enum.sort(@model_expected),
           "Model's RPC surface changed. Adding write/admin actions over RPC needs a security review (see docs/superpowers/specs/2026-07-02-user-model-phase-2b2b-hardstop-gate-clone-design.md)."
  end

  test "Provider RPC surface is pinned" do
    assert exposed_actions(Magus.Models, Magus.Models.Provider) |> Enum.sort() ==
             Enum.sort(@provider_expected)
  end

  # implement exposed_actions/2 against the introspection API you discovered;
  # it returns the backing ACTION names (not the rpc_action public names).
  defp exposed_actions(domain, resource), do: raise("implement via introspection")
end
```

- [ ] **Step 2: Implement `exposed_actions/2`** via the discovered API; RED (raise) -> GREEN. Verify the expected lists against the ACTUAL current DSL blocks first (open chat.ex and models.ex; if the real surface differs from the lists above, the lists in the test must match reality and your report must call out any surprising exposure).

- [ ] **Step 3: Self-check the pin**: temporarily add a fake `rpc_action :evil_update, :update` locally, confirm the test fails, revert. State this in the report.

- [ ] **Step 4: Compile gate, commit**: `test(rpc): pin Model and Provider RPC surfaces (phase 2b-2b)`.

---

## Final Verification

- [ ] Backend: `MIX_ENV=test mix test test/magus/models test/magus/chat test/magus/agents` with only documented pre-existing failures (verify any other in isolation).
- [ ] `MIX_ENV=test mix compile --warnings-as-errors`.
- [ ] Frontend: full `npx vitest run` + check script.
- [ ] Spec cross-check: hard-stop (T1) + remediation (T2) + gate (T3) + clone (T4) + write floor (T5) + pin test (T6); no schema change anywhere; `:auto` paths behavior-neutral.
