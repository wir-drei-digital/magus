# Phase 2b-1: User-Owned Providers and Models (Ownership Backend Foundation)

Date: 2026-07-01
Status: Design (approved for planning)
Predecessors: Phase 1 (curation, merged), Phase 2a (resolver keystone, merged)
Successor: Phase 2b-2 (BYOK UX: SPA CRUD, clone affordance, cloud paid-plan gate, hard-stop remediation)

## Context and Goal

Phase 2a consolidated model resolution into `Magus.Models.Resolver` + `%Magus.Models.Resolution{}`, and pre-carved the ownership axes (`access_source`, `credential_owner_user_id`, `cost_source`) as constants. Phase 2b opens model management to regular users. It is split one level further:

- **2b-1 (this spec)**: the ownership backend foundation. Regular users can own providers and models through Ash actions. Resolution, security, and correctness are complete. No UI, and resolver degradation stays soft (telemetry only).
- **2b-2**: the BYOK UX. SPA provider/model CRUD, the clone/prefill affordance, the cloud paid-plan gate, and flipping degradation into a hard-stop with one-click remediation.

The goal of 2b-1 is a hardened, independently reviewable, mergeable backend keystone: after it lands, a user *could* create and resolve their own providers and models via the API, safely, but nothing surfaces in the product yet.

## Scope

**In scope (2b-1):**
- `owner_user_id` on `Magus.Models.Provider` and `Magus.Chat.Model` (the first migration of this effort).
- Server-generated unique slugs for user providers.
- `:create_owned` actions on Provider and Model (owner-scoped, cap-enforced, SSRF-validated).
- Atom-safety: user providers never reach `CatalogSync.slug_to_atom`.
- `RequestOptions` rewrite so user providers resolve through their built-in `req_llm_id` (known providers) or the fixed `:openai_compatible` atom (custom endpoints).
- Actor-scoped resolution: a user resolves only global rows plus their own; ownership facts populate the 2a axes.
- Per-user caps (config-driven, universal).
- Credential validation machinery (async, rate-limited, per-provider-type; stamps status; no UI).
- Tightened Provider/Model policies.
- The two deferred Phase 2a carryover items.

**Out of scope (2b-2):** all SPA UI, the clone/prefill affordance, the cloud paid-plan gate on provider creation, flipping degradation to a hard-stop + remediation.

**Out of scope (2c):** `MessageUsage` billing attribution and the universal-vs-spend gate split. 2b-1 populates `cost_source`/`credential_owner_user_id` as facts but changes no billing behavior.

## Locked Decisions

1. **Extend, do not fork.** Add `owner_user_id` to the existing `Provider` and `Model` resources rather than introducing a parallel `UserProvider`. One row shape, one resolution path, one `RequestOptions`/`CatalogSync`/`Resolver`. `owner_user_id == nil` means global/admin (all rows today); a set value means user-owned.
2. **Both BYOK shapes.** A user may (a) bring their own key for a first-class provider (`req_llm_id` in a config allowlist: `anthropic`, `openai`, `openrouter`, `xai`, `google`, plus any deployment additions) and create models under it, and (b) register a fully custom `openai_compatible` endpoint (`base_url` + key + hand-entered model ids).
3. **Keep global-unique keys, no id-migration** (carried from 2a). User providers get server-generated unique slugs, so `Model.key = "<slug>:<model_id>"` stays globally unique and the `unique_key` identity holds untouched.
4. **Atom-safety by exclusion.** User providers never mint atoms. They are excluded from `CatalogSync.build_custom`, so `slug_to_atom` (catalog_sync.ex:55) is never called on user input. User models are simply absent from the LLMDB custom catalog and resolve through `RequestOptions` (a DB lookup) instead.
5. **Facts, not policy** (carried from 2a). The resolver populates `access_source: :owned`, `credential_owner_user_id`, `cost_source: :byok`. Billability derivation remains downstream and is untouched here.
6. **Soft degradation stays soft.** The hard-stop is 2b-2. 2b-1 keeps the telemetry-only behavior.
7. **Caps are universal, the paid-plan gate is not.** Per-user count caps ship in 2b-1 (open-core and cloud). The cloud-only paid-plan gate on provider creation is 2b-2.
8. **Credential validation machinery in 2b-1**, UI in 2b-2.

## Data Model

### Provider (`lib/magus/models/provider.ex`)

New attributes:
- `owner_user_id` (nullable UUID, FK to `Magus.Accounts.User`, indexed). `nil` = global/admin.
- `validation_status` (atom, one of `:pending | :valid | :invalid | :error`, default `:pending`).
- `last_validated_at` (utc_datetime, nullable).

New action `:create_owned`:
- Accepts `name`, `req_llm_id`, `base_url` (custom only), `api_key`.
- Sets `owner_user_id = actor.id`.
- Server-generates `slug` (see Slug Generation). The caller never supplies a slug.
- Restricts `req_llm_id` to the config allowlist (`openai_compatible` is always permitted).
- Validates `base_url` via the SSRF validator (user rows only).
- Enforces the provider count cap.
- Enqueues credential validation (see Credential Validation).

The admin `:create` action is untouched (still accepts an explicit slug, still `IsAdmin`, still allowed to point `base_url` at localhost).

`:update` gains owner-scoping (see Policies). `req_llm_id` and `slug` remain immutable after create. Owned-provider `base_url` updates re-run the SSRF validator and re-enqueue validation.

### Model (`lib/magus/chat/model.ex`)

New attribute:
- `owner_user_id` (nullable UUID, indexed). Mirrored from the provider on create so the hot resolution path can filter without a join.

New action `:create_owned`:
- Requires `model_provider_id` referencing a provider owned by the actor.
- Sets `owner_user_id` from that provider.
- Mints `key = "<provider.slug>:<model_id>"` where `model_id` is the upstream model identifier (for known providers) or the hand-entered id (custom endpoints).
- Enforces the model count cap.

The existing `unique_key [:key]` identity is unchanged and holds by construction, because the server-generated slug prefix is globally unique.

## Resolution Mechanism

### CatalogSync (atom-safety)

`build_custom` (catalog_sync.ex:26) filters to global providers only (`owner_user_id == nil`). Add a corresponding filter to the model side (`list_provider_linked_active_models` is already provider-filtered; user models are dropped because their provider is absent from the `providers` map, but we filter explicitly for clarity and to avoid relying on that side effect). Result: `slug_to_atom` is never reached for a user slug, and no atom is minted from user input.

### RequestOptions (resolution without atoms)

`resolve/1` (request_options.ex:21) gains handling for owned providers:
- `openai_compatible`: already handled. `strip_slug(model.key, provider.slug)` yields the inline `%{provider: :openai_compatible, id: ...}` form. Works unchanged for user rows.
- Known built-in provider: rewrite the spec prefix from the user slug to `req_llm_id`. `"u_ab12:claude-3-5-sonnet"` becomes `"anthropic:claude-3-5-sonnet"` plus `[api_key: <user key>, base_url: <optional>]`. ReqLLM routes through the native, already-registered provider module using the user's credential. No atom, no LLMDB registration.

The distinction is driven by `provider.req_llm_id`, not by `owner_user_id`, so admin and user rows of the same `req_llm_id` follow the same code path. The only owner-specific effect is that the user slug differs from `req_llm_id` and must be rewritten; for admin built-in providers `slug == req_llm_id`, so the rewrite is a no-op.

### Resolver (actor-scoping and ownership facts)

`Magus.Models.Resolver.resolve(actor, input)` becomes actor-aware:
- The key lookup (`fetch_by_key`, resolver.ex:142) and the explicit-id lookup (`Magus.Chat.get_model/1`, resolver.ex:37) filter to `owner_user_id == nil OR owner_user_id == <actor id>`. A user can never resolve another user's private model. This is behavior-neutral for every existing row because all existing rows are global.
- Actor without an id (system/AI contexts with no user) resolves global rows only.
- When the resolved model is owned, `resolution/3` populates `access_source: :owned`, `credential_owner_user_id: model.owner_user_id`, `cost_source: :byok`. Global rows keep `:global` / `nil` / `:platform_key`.
- Degradation stays soft (telemetry only).

**Caller requirement:** `Preflight` (preflight.ex:77) and `MediaBypass` (media_bypass.ex:34) must pass the requesting user as the resolver actor. The plan verifies this and fixes any site that passes `nil`, otherwise BYOK models would be invisible to their own owner.

## Slug Generation

User provider slugs are generated server-side, never accepted from the caller:
- Format: a short prefixed token matching the existing `~r/\A[a-z0-9_]+\z/` constraint and `max: 64`, for example `u_` followed by lowercase base32 of random bytes.
- Uniqueness: enforced by the existing `unique_slug` identity. On the (astronomically unlikely) collision, the create retries with a fresh token; a bounded retry count surfaces an error rather than looping.
- Because the slug is unique by construction, `Model.key` built from it is globally unique, dissolving the collision risk that motivated the "keep global-unique keys" decision.

## Security

### SSRF validation (user base_url only)

A validator (`Magus.Models.BaseUrlValidator` or similar) applied in `Provider.:create_owned` and owned `:update`:
- Require scheme `https`.
- Reject hosts that resolve to loopback, private, link-local, ULA, or cloud-metadata ranges: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` (including `169.254.169.254`), `0.0.0.0`, `::1`, `fc00::/7`.
- Reject embedded credentials (`user:pass@`) and non-`https` schemes.
- Admin `:create` is exempt (self-hosted localhost endpoints keep working; the existing `RequestOptionsTest` relies on this).

Documented limitation: DNS rebinding / TOCTOU is not fully closed by a static check plus validation-time resolution. A per-request egress guard (re-validation or an outbound proxy allowlist) is a later hardening item, out of scope for 2b-1.

### Per-user caps

Config-driven, universal:
```elixir
config :magus, :user_model_limits, max_providers: 10, max_models: 50
```
Enforced by a count check in the `:create_owned` actions (a validation or change that counts existing owned rows for the actor). The count check has a benign TOCTOU race under concurrent creates, acceptable for an abuse-prevention cap. Cloud plan-based raising and the paid-plan gate are 2b-2.

### Policies

Owner-scoped throughout:
- **Read (Provider, Model):** in an actor context, global rows (`owner_user_id == nil`) plus rows owned by the actor. Internal plumbing (`CatalogSync`, `RequestOptions`) reads with `authorize?: false` and is unaffected, so global resolution keeps working without an actor.
- **`:create_owned`:** any authenticated user (subject to caps and, in 2b-2, the cloud gate).
- **Update / destroy:** owner (`owner_user_id == actor(:id)`) for owned rows; `IsAdmin` retains full control of global rows. The admin `:create`/`:update`/`:destroy` actions are untouched.

The Provider read policy tightens from the current blanket `authorize_if always()` (provider.ex:55) to the global-or-owned expression for actor context. Because `api_key` is already `sensitive?`/non-public and internal reads bypass policy, this is the actor-facing tightening the north-star called for, not a change to internal plumbing.

## Credential Validation

Async, cached, rate-limited; stamps status on the Provider row; no UI in 2b-1.
- Trigger: `Provider.:create_owned` enqueues a validation job; owned `:update` that changes `api_key`/`base_url` re-enqueues; an explicit `:validate` action re-enqueues (rate-limited).
- Job: an Oban worker (or AshOban trigger) that performs a minimal, cheap probe appropriate to the provider (for example a models-list request against the resolved endpoint with the stored key), then writes `validation_status` and `last_validated_at`.
- Rate limit: at most one validation per provider per configured window (for example 60s), enforced by checking `last_validated_at`/status before enqueue.
- Strategy indirection: a small `CredentialValidator` seam keyed by `req_llm_id` so provider-specific probes are isolated and stubbable in tests. The default `openai_compatible`/OpenAI-style probe covers most first-class providers.
- Failure is non-blocking: a provider whose key is invalid still saves with `validation_status: :invalid`. Resolution is unaffected in 2b-1; surfacing and remediation are 2b-2.

## Phase 2a Carryover

Folded into 2b-1 because provider facts become load-bearing here:
- Guard `Resolver.provider_id/1` (resolver.ex:159) with `when is_binary(id)`.
- Add the two deferred metadata-path tests: (a) explicit-id-miss plus `:auto`-image `inherited_requested` propagation; (b) explicit key equal to `Config.default_model()` labeled `:explicit` / `degraded?=false`.

## Open-Core and Cloud

- Everything in 2b-1 is universal (open-core and cloud): ownership, resolution, atom-safety, SSRF, caps, credential validation.
- No billing behavior changes. `cost_source`/`credential_owner_user_id` are recorded as facts; 2c consumes them.
- The cloud paid-plan gate on provider creation is deferred to 2b-2 and lives behind the existing billing seam, not in this foundation.

## Testing

`Magus.ResourceCase` / `DataCase` tests:
- Provider `:create_owned`: sets owner, server-generates a valid unique slug, restricts `req_llm_id` to the allowlist, enforces the provider cap.
- Model `:create_owned`: requires an actor-owned provider, mirrors owner, mints a unique slug-prefixed key, enforces the model cap.
- Slug generation: format, uniqueness, collision retry.
- Actor-scoping: user B cannot resolve or read user A's private model by key or id; the owner can.
- Ownership facts: resolving an owned model yields `access_source: :owned`, `credential_owner_user_id`, `cost_source: :byok`; global models keep the defaults.
- `CatalogSync`: user providers/models excluded from `build_custom`; no atom minted for a user slug.
- `RequestOptions`: known-provider rewrite (`u_...:model` -> `req_llm_id:model` + key) and `openai_compatible` inline form for owned rows; admin rows unchanged.
- SSRF: rejection of loopback/private/link-local/metadata hosts, embedded credentials, non-https; admin exemption preserved.
- Credential validation: enqueue on create, rate-limit window, status stamping, stubbed probe for valid/invalid/error.
- Policies: owner-scoped read/update/destroy; admin retains global control; internal `authorize?: false` reads still see everything.
- Carryover: `provider_id/1` guard and the two 2a metadata-path tests.

## Migration Notes

- One AshPostgres migration adds `owner_user_id` (Provider, Model), `validation_status`, `last_validated_at`, and supporting indexes. Generated via `mix ash.codegen`; never `mix ash.reset`.
- All new columns are nullable/defaulted, so existing rows remain valid global rows with no data backfill.

## Risks and Limitations

- **DNS rebinding / TOCTOU** on `base_url`: static validation is the first bar; a per-request egress guard is a later item.
- **Cap race**: concurrent `:create_owned` can slightly exceed the cap; acceptable for an abuse cap.
- **Caller actor threading**: BYOK resolution depends on `Preflight`/`MediaBypass` passing the user as actor; the plan verifies and fixes this.
- **ReqLLM metadata for exotic user model ids**: a known-provider model id absent from the packaged LLMDB snapshot still routes, but without registry metadata; cost/context come from the `Model` row, so this is acceptable. Credential validation surfaces obviously wrong ids in 2b-2.
