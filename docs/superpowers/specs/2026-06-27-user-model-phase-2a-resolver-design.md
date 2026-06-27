# Phase 2a: Model Resolver Keystone

- Date: 2026-06-27
- Status: Design (approved for planning)
- Parent: [2026-06-27-user-model-management-design.md](2026-06-27-user-model-management-design.md) (north-star)

## Context

Phase 2 of opening model management to regular users is decomposed into three sub-phases:

- **2a (this doc): resolver keystone.** Consolidate the scattered chat-model resolution into one authoritative module returning a typed result. Establishes the seam that 2b and 2c extend. No user-facing capability, no user-visible behavior change.
- **2b: BYOK providers + models.** `owner_user_id` becomes user-writable, provider/model CRUD, server-generated slugs, credential validation, SSRF/atom/caps, the paid-plan gate, and the broken-selection hard-stop + remediation.
- **2c: billing attribution + gate split.** `MessageUsage` attribution fields, the universal-vs-spend gate split, key-owner usage visibility.

2a ships no new capability on purpose. Its value is a single tested resolution path plus a stable contract, landed behavior-neutral so it is fully testable against today's flows before ownership and billing pile on.

## Current state (what 2a consolidates)

Resolution today spans six modules. Relevant `file:line`:

- **Selection** (`lib/magus/agents/routing/model_key_resolver.ex`): `ModelKeyResolver.resolve/1` applies precedence conversation -> custom agent -> user -> `:auto`, yielding `%{chat, image, video}` of key strings.
- **Auto-routing** (`lib/magus/agents/routing/{auto_route_resolver,auto_router,model_matcher}.ex`): replaces `:auto` with a concrete key chosen from global `RoutingSlot`s (one model per `{specialty, tier}`).
- **Resolution** (`lib/magus/agents/plugins/support/model_resolver.ex:13-108`): `ModelResolver.resolve_model/4` turns keys/id into a `%Magus.Chat.Model{}`, with **two silent fallbacks**: an explicit `selected_model_id` that is not found falls through to the keys map (lines 15-21), and a key that is not found returns a synthetic `fallback_model()` (lines 99-108). The fetch is `authorize?: false` (lines 80-86).
- **Roles** (`lib/magus/models/roles.ex`): `Roles.resolve/1` maps a role (`:chat_default`, `:image_default`, ...) to a default key, admin-assignable via `RoleAssignment`.
- **Credentials** (`lib/magus/models/request_options.ex`): `RequestOptions.resolve/1` turns a key into `{reqllm_model, [api_key:, base_url:]}`, called at the last moment inside `LLMClient`. Already handles per-provider credentials and the `openai_compatible` bypass.
- **Orchestration** (`lib/magus/agents/plugins/support/preflight.ex:22-125`): `build_react_signal/3` runs auto-route (55-62) -> `ModelResolver.resolve_model` (64-70) -> usage gate (77) -> region gate (80) -> provider routing (84) -> emits `ai.react.query` with `:model` = `model.key` (100).

The existing Preflight gate order is **resolve -> usage -> region -> routing**. 2a preserves it exactly.

## Design decisions (locked)

1. **Keep globally-unique keys; no id-migration.** A model `key` is `"<slug>:<model_id>"`, provider `slug` is globally unique (`unique_slug`), model `key` is globally unique (`unique_key`), and `key` is non-public (users see the model `name`). The runtime keeps referencing models by key. User providers (2b) get server-generated unique slugs, so user keys are unique by construction and the existing identity holds untouched. This dissolves the north-star's per-owner key-collision concern rather than paying a runtime migration to manage it. Persistence and usage attribution stay model-id-based, as they already are.

2. **Fact vs policy naming.** The resolver reports facts, never billing policy. The result carries `credential_owner_user_id` (nil = the platform/admin-configured key; a user id = BYOK) and `cost_source: :platform_key | :byok`. There is **no** `billable_by_*` field anywhere. Billability is derived later in `PolicyEnforcer` (2c) as `cost_source == :platform_key and billing_enabled?(deployment)`, where `billing_enabled?` is the existing open-core/cloud seam. `MessageUsage` (2c) persists the historical outcome as a deployment-neutral `metered?` boolean. This keeps the cloud-operator identity out of the runtime data model entirely.

3. **Behavior-neutral 2a; hard-stop deferred to 2b.** The resolver reports `selection_source` truthfully and distinguishes a broken *explicit* selection (`:selection_unavailable`) from normal inherited resolution. In 2a, a broken explicit selection degrades to the same inherited model used today, recorded via telemetry: the silent fallback becomes *visible*, not blocking. In 2b this flips to a hard-stop with one-click remediation, shipped alongside the UX that can actually remediate it. Region-unavailable stays a hard-stop exactly as today (no change).

4. **Tight scope.** The resolver owns resolution only: a chosen key/id becomes a model + provider + `selection_source` + ownership/billing axes. Selection (`ModelKeyResolver`) and auto-routing (`AutoRouter`) stay as upstream feeders; their output, including auto-routed keys, flows through the resolver, so auto-routed models get identical treatment to explicit picks. Region-availability, provider-routing, and the usage gate stay in Preflight in their current order: folding them in would reorder gates and is not needed here. Media (image/video) resolution stays on its current path for 2a.

5. **No schema change.** Because keys stay key-based, 2a needs no migration. The `owner_user_id` columns move to 2b, where the writes that need them live. 2a is a pure code refactor.

## The contract: `Magus.Models.Resolution`

A struct in the `Magus.Models` namespace. The full contract is defined now; the ownership/billing axes carry admin-only constants in 2a, so 2b/2c change only how they are populated, not the shape:

```elixir
%Magus.Models.Resolution{
  model:                    %Magus.Chat.Model{},             # carries id + key
  selection_source:         :explicit | :auto | :role_default | :product_default,
  provider:                 %Magus.Models.Provider{} | nil,  # loaded from model.model_provider
  access_source:            :global,                          # 2b adds :owned | :workspace_shared
  credential_owner_user_id: nil,                              # 2b sets for BYOK
  cost_source:              :platform_key                     # 2b adds :byok
}
```

Secrets never enter this struct or the `ai.react.query` signal. API-key resolution stays in `RequestOptions`/`LLMClient` at call time. `req_routing`/region opts are deliberately **not** in this struct in 2a; they stay in Preflight to preserve gate order, and may be folded in later once ordering is reconciled.

## The module: `Magus.Models.Resolver`

A plain module, not an Ash resource.

```
Resolver.resolve(actor, %{
  selected_model_id: id | nil,
  model_keys:        %{chat, image, video},
  mode:              atom,
  preloaded:         [%Magus.Chat.Model{}]
}) :: {:ok, %Magus.Models.Resolution{}} | {:error, :selection_unavailable, %{requested: term}}
```

Resolution precedence (preserving today's outcomes):

1. **Explicit by id** (`selected_model_id` present): fetch by id. Found -> `selection_source: :explicit`.
2. **Explicit by key** (concrete, non-`:auto` `model_keys[mode]`): preloaded match or fetch by key. Found -> `:explicit`.
3. **Auto** (`model_keys[mode] == :auto`): media-specialty match or the already-upstream-routed key. Found -> `:auto`.
4. **Role default**: `ModelKeyResolver.default_model_key(type)` -> fetch -> `:role_default`.
5. **Product default**: synthetic `Magus.Agents.Config.default_model()` -> `:product_default`.

A broken **explicit** selection (1 or 2 not found) surfaces as `{:error, :selection_unavailable, ...}`. In 2a, Preflight catches it and falls through to inherited resolution exactly as today (same model used), emitting telemetry.

The two current miss paths have **different** fall-through targets, and behavior-neutral 2a must reproduce both: a missing explicit **id** falls through to the `model_keys` map (which may then resolve to a concrete key, the role default, or the product default), whereas a missing explicit **key** falls straight to the product default. The golden-master test matrix covers these as distinct cases. The precise implementation shape (re-resolve without the explicit selection, or an internal degrade marker) is left to the plan; the contract above is what 2b builds on, so 2b changes only Preflight's handling, not the resolver's signature.

`actor` is accepted for forward-compatibility. In 2a the fetch stays effectively unrestricted (admin-global models are readable by everyone), preserving current behavior; 2b uses `actor` for authorization.

## Preflight integration

In `build_react_signal/3`, lines 64-70 change from:

```elixir
model = ModelResolver.resolve_model(model_keys, mode, selected_model_id, preloaded)
```

to resolving through `Magus.Models.Resolver`, binding `model = resolution.model`, and emitting telemetry on `resolution.selection_source` and any degradation. The usage gate (77), region gate (80), provider routing (84), and signal build (95-118) are unchanged and consume `resolution.model`. Gate order is preserved.

`ModelResolver` is removed; recon shows Preflight is its only caller. The plan verifies no other call sites before deletion.

## Blast radius

- **New:** `lib/magus/models/resolution.ex`, `lib/magus/models/resolver.ex`.
- **Modified:** `lib/magus/agents/plugins/support/preflight.ex` (resolution call + telemetry).
- **Removed:** `lib/magus/agents/plugins/support/model_resolver.ex` (after verifying no other callers).
- **Unchanged:** `ModelKeyResolver`, `AutoRouter`/`AutoRouteResolver`/`ModelMatcher`, `Roles`, `RequestOptions`, `LLMClient`, the ReAct runner, the `ai.react.query` signal shape, the media tools, and all selection storage (User/Conversation/CustomAgent). No migration.

## Testing

- **Golden-master behavior-neutrality (the core proof).** For representative inputs (explicit-by-id hit and miss, explicit-by-key hit and miss, auto-routed, role-default, no-selection), assert the resolver yields the same `model` that `ModelResolver` produces today, and that Preflight emits the same `:model` key and the same final request options. The miss cases must still produce today's fallback model.
- **Resolver unit tests.** Assert the `selection_source` value for each path; assert `{:error, :selection_unavailable, _}` for a broken explicit selection; assert the ownership/billing axes carry their 2a constants (`access_source: :global`, `credential_owner_user_id: nil`, `cost_source: :platform_key`).
- **Telemetry.** Assert a degradation event is recorded when a broken explicit selection degrades.
- **Regression.** Existing Preflight and agent tests stay green with no expectation changes; that they pass unmodified is the behavior-neutrality proof.

## Acceptance criteria

- `Magus.Models.Resolution` and `Magus.Models.Resolver` exist; Preflight resolves through the resolver; `ModelResolver` is deleted with no remaining callers.
- No migration is introduced in this phase.
- The full suite is green with no changes to existing resolution/agent test expectations; new resolver tests are added.
- The result carries `cost_source: :platform_key` and `credential_owner_user_id`; no `billable_by_*` field exists anywhere.
- Telemetry records explicit-selection degradation.
- No secrets appear in the resolution struct or the signal.
- Compiles with `--warnings-as-errors`.

## Forward compatibility (how 2b/2c extend this)

- **2b** adds `owner_user_id` to `Magus.Models.Provider` and `Magus.Chat.Model` (the first migration), makes `actor`-scoped reads real, populates `access_source`/`credential_owner_user_id`/`cost_source` from ownership, flips `:selection_unavailable` into a hard-stop plus remediation, mints server-generated unique slugs for user providers, and adds SSRF base-URL validation, atom-safety, per-user caps, and the cloud paid-plan gate on provider creation.
- **2c** adds `MessageUsage` attribution (`metered?`, `requesting_user_id`, `credential_owner_user_id`, `cost_source`, external cost), derives billability in `PolicyEnforcer`, and adds key-owner usage visibility (message_usage only, never the messages).
