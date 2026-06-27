# Phase 2a: Model Resolver Keystone

- Date: 2026-06-27
- Status: Design (revised after review)
- Parent: [2026-06-27-user-model-management-design.md](2026-06-27-user-model-management-design.md) (north-star)

## Context

Phase 2 of opening model management to regular users is decomposed into three sub-phases:

- **2a (this doc): resolver keystone.** Consolidate the scattered model resolution into one authoritative module returning a typed result. Establishes the seam that 2b and 2c extend. No user-facing capability, no user-visible behavior change.
- **2b: BYOK providers + models.** `owner_user_id` becomes user-writable, provider/model CRUD, server-generated slugs, credential validation, SSRF/atom/caps, the paid-plan gate, and the broken-selection hard-stop + remediation.
- **2c: billing attribution + gate split.** `MessageUsage` attribution fields, the universal-vs-spend gate split, key-owner usage visibility.

2a ships no new capability on purpose. Its value is a single tested resolution path plus a stable contract, landed behavior-neutral so it is fully testable against today's flows before ownership and billing pile on.

## Current state (what 2a consolidates)

Resolution today spans six modules. Relevant `file:line`:

- **Selection** (`lib/magus/agents/routing/model_key_resolver.ex`): `ModelKeyResolver.resolve/1` applies precedence conversation -> custom agent -> user -> `:auto`, yielding `%{chat, image, video}` of key strings.
- **Auto-routing** (`lib/magus/agents/routing/{auto_route_resolver,auto_router,model_matcher}.ex`): the message-classifying router that replaces `:auto` with a concrete key chosen from global `RoutingSlot`s (one model per `{specialty, tier}`).
- **Resolution** (`lib/magus/agents/plugins/support/model_resolver.ex:13-108`): `ModelResolver.resolve_model/3,4` turns keys/id into a `%Magus.Chat.Model{}`, with **two silent fallbacks**: an explicit `selected_model_id` that is not found falls through to the keys map (lines 15-21), and a key that is not found returns a synthetic `fallback_model()` (lines 99-108). The fetch is `authorize?: false` (lines 80-86). Image/video modes fall back to the chat key when the mode key is absent (lines 63-65). Chat `:auto` reaching this module resolves to the role default; media `:auto` resolves via `ModelMatcher.find_media_model` (lines 37-48).
- **Roles** (`lib/magus/models/roles.ex`): `Roles.resolve/1` maps a role (`:chat_default`, `:image_default`, ...) to a default key, admin-assignable via `RoleAssignment`.
- **Credentials** (`lib/magus/models/request_options.ex`): `RequestOptions.resolve/1` turns a key into `{reqllm_model, [api_key:, base_url:]}`, called at the last moment inside `LLMClient`. Already handles per-provider credentials and the `openai_compatible` bypass.
- **Orchestration** (`lib/magus/agents/plugins/support/preflight.ex`): `build_react_signal/3` runs auto-route (55-62) -> `ModelResolver.resolve_model` (65) -> usage gate (77) -> region gate (80) -> provider routing (84) -> emits `ai.react.query` with `:model` = `model.key` (100).

### The full `resolve_model` call graph (corrected after review)

`ModelResolver.resolve_model` has **five** call sites across **two** modules, not one:

| Site | Purpose | Pre-resolves chat `:auto`? | Modes |
|---|---|---|---|
| `preflight.ex:65` | `build_react_signal/3` (main turn) | **Yes** (dispatcher; Preflight `maybe_auto_route` at 749 is a fallback) | chat |
| `preflight.ex:159` | `build_resume_signal` (agent.resume) | No (raw `state[:model_keys]`) | chat |
| `preflight.ex:229` | `assemble_context/2` (read-only debug, `mix agent.preflight`) | No (`ModelKeyResolver.resolve`) | chat |
| `preflight.ex:265` | `validate_and_resolve_model/4` (helper) | No (raw arg) | chat |
| `media_bypass.ex:33` | media generation bypass | No (raw `data/state[:model_keys]`) | image, video |

For the main turn, the **dispatcher** auto-routes chat `:auto` (`Dispatcher.auto_route` -> `AutoRouteResolver`) and threads both the resolved keys and a `routing_reason` into the `message.user` signal (`Dispatcher.build_signal_data`); `Preflight.maybe_auto_route` (749) is a secondary fallback that only fires if a still-`:auto` chat key reaches Preflight. So at `preflight.ex:65` the chat key is already concrete, and a present `routing_reason` (or a raw chat key still `:auto`) is the provenance signal that it was auto-routed. The four other sites pass raw keys, so `:auto` can still be present and is resolved *inside* `ModelResolver` (chat -> role default; media -> `ModelMatcher`). The existing Preflight gate order in `build_react_signal` is **resolve -> usage -> region -> routing**, which 2a preserves.

## Design decisions (locked)

1. **Keep globally-unique keys; no id-migration.** A model `key` is `"<slug>:<model_id>"`, provider `slug` is globally unique (`unique_slug`), model `key` is globally unique (`unique_key`), and `key` is non-public (users see the model `name`). The runtime keeps referencing models by key. User providers (2b) get server-generated unique slugs, so user keys are unique by construction and the existing identity holds untouched. This dissolves the north-star's per-owner key-collision concern rather than paying a runtime migration to manage it. Persistence and usage attribution stay model-id-based, as they already are.

2. **Fact vs policy naming.** The resolver reports facts, never billing policy. The result carries `credential_owner_user_id` (nil = the platform/admin-configured key; a user id = BYOK) and `cost_source: :platform_key | :byok`. There is **no** `billable_by_*` field anywhere. Billability is derived later in `PolicyEnforcer` (2c) as `cost_source == :platform_key and billing_enabled?(deployment)`, where `billing_enabled?` is the existing open-core/cloud seam. (Naming reconciliation with the existing `billable` concept is in Forward compatibility.)

3. **Behavior-neutral 2a; hard-stop deferred to 2b.** The resolver reports `selection_source` truthfully and records whether a broken *explicit* selection was honored. In 2a a broken explicit selection degrades to the same inherited model used today, recorded via telemetry: the silent fallback becomes *visible*, not blocking. In 2b that flips to a hard-stop with one-click remediation, shipped alongside the UX that can remediate it. Region-unavailable stays a hard-stop exactly as today.

4. **Tight scope.** The resolver owns resolution only: a chosen key/id becomes a model + provider reference + `selection_source` + ownership/billing axes. Selection (`ModelKeyResolver`) and the message-classifying auto-router (`AutoRouter`) stay as upstream feeders; their output flows through the resolver, so auto-routed models get identical treatment to explicit picks. Region-availability, provider-routing, and the usage gate stay in Preflight in their current order: folding them in would reorder gates and is not needed here.

5. **Resolver is total; degradation is data, not an error.** `resolve/2` always returns `{:ok, %Resolution{}}`, producing the same model today's `ModelResolver` returns for the same input, including the synthetic fallback on a miss. Whether an explicit selection was requested-but-not-honored is carried as data on the struct (`requested_selection` + `selection_source`). Strictness (hard-stop on a broken explicit selection) is a Preflight *policy* applied to that data: off in 2a, on in 2b. This keeps `resolve/2` golden-master-comparable for every input and means 2b changes Preflight, not the resolver's signature.

6. **Provenance in, not just resolved keys.** Because the main path resolves chat `:auto` upstream before resolution, a bare resolved key cannot distinguish an explicit pick from an auto-routed one. The resolver input carries auto-routing provenance (the caller's routing outcome / an `auto_routed?` signal per mode) alongside the explicit selection, so `selection_source` is computable. Callers that do not auto-route (resume, assemble, validate, media) pass raw keys and no provenance; the resolver resolves any remaining `:auto` the way `ModelResolver` does today.

7. **No secrets in the result.** The struct carries `provider_id` (the model's `model_provider_id` FK), never a `%Magus.Models.Provider{}` (whose `api_key` is `sensitive?`). 2a does not preload `model_provider`. Credential resolution stays in `RequestOptions`/`LLMClient` at call time.

8. **Media resolution is subsumed, BYOK is not.** Deleting `ModelResolver` requires migrating its media caller (`media_bypass.ex:33`) too. 2a moves media's *existing* resolution (image/video -> chat fallback, media `:auto` matching) into the resolver, behavior-neutral. This is resolution consolidation only; media BYOK stays Phase 5.

9. **No schema change.** Because keys stay key-based, 2a needs no migration. The `owner_user_id` columns move to 2b, where the writes that need them live. 2a is a pure code refactor.

## The contract: `Magus.Models.Resolution`

A plain struct (not an Ash resource, not exposed over RPC) in the `Magus.Models` namespace. The full contract is defined now; ownership/billing axes carry admin-only constants in 2a, so 2b/2c change only how they are populated:

```elixir
%Magus.Models.Resolution{
  model:                    %Magus.Chat.Model{},   # carries id + key
  selection_source:         :explicit | :auto | :role_default | :product_default,
  requested_selection:      nil | %{by: :id | :key, value: term},  # the explicit ask, if any
  provider_id:              Ecto.UUID | nil,        # = model.model_provider_id; NO provider struct, NO secret
  access_source:            :global,                # 2b adds :owned | :workspace_shared
  credential_owner_user_id: nil,                    # 2b sets for BYOK
  cost_source:              :platform_key           # 2b adds :byok
}
```

**Degradation predicate:** `requested_selection != nil and selection_source in [:role_default, :product_default]` means an explicit selection was requested and not honored. 2a telemeters it; 2b hard-stops on it.

**No secrets** enter this struct or the `ai.react.query` signal. `provider_id` is a bare FK; API-key resolution stays in `RequestOptions`/`LLMClient`. `req_routing`/region opts are deliberately not in this struct: they stay in Preflight to preserve gate order.

## The module: `Magus.Models.Resolver`

A plain module, not an Ash resource. **Total**: always `{:ok, ...}`.

```
Resolver.resolve(actor, %{
  selected_model_id: id | nil,
  model_keys:        %{chat, image, video},   # may still contain :auto (resume/assemble/validate/media)
  auto_routed:       %{chat: bool, image: bool, video: bool} | nil,  # provenance from the caller
  mode:              atom,
  preloaded:         [%Magus.Chat.Model{}]
}) :: {:ok, %Magus.Models.Resolution{}}
```

Handles all modes (chat/image/video), preserving today's behavior exactly:

- image/video -> chat key fallback when the mode key is absent,
- chat `:auto` (when not pre-resolved) -> role default,
- media `:auto` -> `ModelMatcher.find_media_model`,
- explicit `selected_model_id` miss -> falls through to keys, explicit key miss -> synthetic product default.

It does **not** run the message-classifying `AutoRouter`; that stays in `Preflight.maybe_auto_route` as an upstream feeder for the main path, and its outcome arrives via `auto_routed`.

`selection_source` mapping (behavior-preserving): explicit id/key honored -> `:explicit`; a key flagged `auto_routed` -> `:auto`; chat `:auto` fallen to the role default, or any role-default key -> `:role_default`; the synthetic `Config.default_model()` -> `:product_default`.

`actor` is accepted for forward-compatibility. In 2a the fetch stays effectively unrestricted (admin-global models are readable by everyone), preserving current behavior; 2b uses `actor` for authorization.

## Call-site migration (blast radius)

All five `resolve_model` sites move to `Resolver.resolve`, then `ModelResolver` is deleted:

- **`preflight.ex:65`** (`build_react_signal`): pass `auto_routed` provenance from `maybe_auto_route`; bind `model = resolution.model`; emit telemetry on `selection_source` and the degradation predicate. Usage gate (77), region gate (80), routing (84), and signal build (95-118) are unchanged and consume `resolution.model`. Gate order preserved.
- **`preflight.ex:159`** (`build_resume_signal`): raw keys, no provenance.
- **`preflight.ex:229`** (`assemble_context`): raw keys, no provenance.
- **`preflight.ex:265`** (`validate_and_resolve_model`): raw keys, no provenance.
- **`media_bypass.ex:33`**: raw keys, image/video modes (subsumed per decision 8).

- **New:** `lib/magus/models/resolution.ex`, `lib/magus/models/resolver.ex`.
- **Modified:** `lib/magus/agents/plugins/support/preflight.ex` (4 sites + telemetry), `lib/magus/agents/plugins/support/media_bypass.ex` (1 site).
- **Removed:** `lib/magus/agents/plugins/support/model_resolver.ex`.
- **Unchanged:** `ModelKeyResolver`, `AutoRouter`/`AutoRouteResolver`/`ModelMatcher`, `Roles`, `RequestOptions`, `LLMClient`, the ReAct runner, the `ai.react.query` signal shape, and all selection storage (User/Conversation/CustomAgent). No migration.

## Testing

- **Golden-master behavior-neutrality (the core proof).** Because the resolver is total, `resolution.model` is directly comparable to `ModelResolver.resolve_model`'s output for every input. Cover, across the call-site shapes: explicit-by-id hit and miss, explicit-by-key hit and miss, main-path auto-routed, chat `:auto` -> role default, media `:auto`, image/video -> chat fallback, and no-selection -> product default. For the chat signal path, also assert Preflight emits the same `:model` key and the same final request options.
- **Provenance.** Given `auto_routed` provenance, assert `selection_source` distinguishes `:explicit` from `:auto`; without it, assert the resume/assemble/validate/media paths resolve as today.
- **Degradation.** Assert `requested_selection` is set and `selection_source` is a fallback when an explicit selection misses; assert a telemetry event fires for that case.
- **Secret-free.** Assert the `Resolution` struct carries `provider_id` (not a `%Provider{}`) and that neither the struct nor the `ai.react.query` signal contains an `api_key`.
- **Axes.** Assert `access_source: :global`, `credential_owner_user_id: nil`, `cost_source: :platform_key`, and `provider_id == model.model_provider_id`.
- **Media bypass.** A `media_bypass` test through the resolver for both image and video, including the image/video -> chat key fallback.
- **Regression.** Existing Preflight, agent, and media tests stay green with no expectation changes; that they pass unmodified is the behavior-neutrality proof.

## Acceptance criteria

- `Magus.Models.Resolution` and `Magus.Models.Resolver` exist; all five sites resolve through `Resolver.resolve`; `ModelResolver` is deleted with no remaining callers (`grep` clean).
- `resolve/2` is total (`{:ok, _}` for every input) and behavior-neutral against `ModelResolver` for the full input matrix.
- No migration is introduced in this phase.
- The result carries `provider_id`, `cost_source: :platform_key`, and `credential_owner_user_id`; no `%Provider{}`, no `api_key`, and no `billable_by_*` anywhere.
- Telemetry records explicit-selection degradation.
- The full suite is green with no changes to existing resolution/agent/media test expectations; new resolver tests are added.
- Compiles with `--warnings-as-errors`.

## Forward compatibility

### Billing-naming reconciliation (resolves review finding 7)

`billable` already exists in the codebase with **two distinct meanings**, and the new axes must not collide with either:

- `Magus.Usage.MessageUsage.billable` (boolean, `message_usage.ex:242`): does this usage count against user limits. System operations (title generation, memory extraction, intent classification) record `billable: false`; `UsageRecorder` defaults it true (`usage_recorder.ex:86`). This is the *user-request vs system-operation* axis.
- `Magus.Usage.Calculator.billable?/1` (`calculator.ex:303`): is the subscription Stripe-backed (paid vs free trial). This is the *subscription tier* axis.

The 2a/2c BYOK axes are **orthogonal** to both. A user-driven BYOK request is still `MessageUsage.billable: true` (a real user request) but must **not** meter against the spend cap, because BYOK is not platform-billed. The new resolver facts are `cost_source` and `credential_owner_user_id`; the 2c spend-metering flag will get a name that does not collide with `billable` (the earlier draft's `metered?` is **not** committed here; 2c's spec fixes it). Billability is derived in `PolicyEnforcer` from `cost_source` + `billing_enabled?`.

### How 2b/2c extend this

- **2b** adds `owner_user_id` to `Magus.Models.Provider` and `Magus.Chat.Model` (the first migration), makes `actor`-scoped reads real, populates `access_source`/`credential_owner_user_id`/`cost_source` from ownership, flips the degradation predicate into a hard-stop plus remediation, mints server-generated unique slugs for user providers, and adds SSRF base-URL validation, atom-safety, per-user caps, and the cloud paid-plan gate on provider creation. When 2b needs provider facts beyond the FK, it specifies a redacted load that excludes `api_key`.
- **2c** adds `MessageUsage` attribution (the reconciled spend-metering flag, `requesting_user_id`, `credential_owner_user_id`, `cost_source`, external cost), derives billability in `PolicyEnforcer`, and adds key-owner usage visibility (message_usage only, never the messages).
