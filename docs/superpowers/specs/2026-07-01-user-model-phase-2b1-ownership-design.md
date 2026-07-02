# Phase 2b-1: User-Owned Providers and Models (Ownership Backend Foundation)

Date: 2026-07-01
Status: Design (revised after design review; approved for planning)
Predecessors: Phase 1 (curation, merged), Phase 2a (resolver keystone, merged)
Successor: Phase 2b-2 (BYOK UX: SPA CRUD, clone affordance, cloud paid-plan gate, hard-stop remediation)

## Context and Goal

Phase 2a consolidated model resolution into `Magus.Models.Resolver` + `%Magus.Models.Resolution{}`, and pre-carved the ownership axes (`access_source`, `credential_owner_user_id`, `cost_source`) as constants. Phase 2b opens model management to regular users. It is split one level further:

- **2b-1 (this spec)**: the ownership backend foundation. Regular users can own providers and models through Ash actions, safely. Resolution, the credential trust boundary, authorization, and lifecycle are complete. No UI, and resolver degradation stays soft (telemetry only).
- **2b-2**: the BYOK UX. SPA provider/model CRUD, the clone/prefill affordance, the cloud paid-plan gate, and flipping degradation into a hard-stop with one-click remediation.

The goal of 2b-1 is a hardened, independently reviewable, mergeable backend keystone. The design review (2026-07-01) established that introducing `owner_user_id` is not safe unless the same change also closes the credential trust boundary and adopts authorization on `Model`; those are therefore in scope here, not deferred.

## Scope

**In scope (2b-1):**
- `owner_user_id` on `Magus.Models.Provider` and `Magus.Chat.Model` (first migration of this effort).
- Server-generated unique slugs for user providers.
- `:create_owned` actions on Provider and Model (owner-scoped, cap-enforced, SSRF-validated, text-only).
- **Credential trust boundary (fail-closed)**: `RequestOptions` becomes actor-aware so owned-provider credentials are returned only to a matching owner. It defaults to no actor, so owned credentials are never handed out on any current path (LLM client or raw-string tool paths). This closes the bearer-key hole immediately; the resolver/LLM-client wiring that makes owned models actually *execute* for their owner is 2b-2.
- **Owned-model read scoping (no global authorizer)**: actor-filter the `list_active` read and owner-scope the selection validation, so owned models never leak through the picker or selection. The codebase-wide `Model` authorizer adoption is deferred to 2b-2 (it breaks ~30 actor-less call sites).
- Atom-safety: user providers never reach `CatalogSync.slug_to_atom`, and owned writes skip catalog reloads.
- **Actor-capable resolution**: the resolver gains an owner-scoped fetch and populates ownership facts when an actor is supplied. Its callers keep passing `nil` in 2b-1 (behavior-neutral); the live per-call-site actor sourcing is 2b-2.
- `api_provider` handling for owned models (a neutral enum value so legacy routing is skipped).
- Selection-write ownership validation (user and conversation selection actions, and the curation `ModelSelectable` validation).
- Per-user caps (config-driven, universal).
- Credential validation machinery (async, Oban-unique-guarded, rate-limited; stamps status; no UI).
- Account-deletion cleanup of owned providers/models and defined FK behavior.
- The two deferred Phase 2a carryover items.

**Explicitly blocked / out of scope (2b-1):**
- **Owned media models** (image/video). The media clients bypass `RequestOptions` (image reads `OPENROUTER_API_KEY` directly; video dispatches by key prefix), so an owned key would not be used. `:create_owned` rejects media models. Media BYOK is Phase 5.

**Out of scope (2b-2):** all SPA UI, the clone/prefill affordance, the cloud paid-plan gate on provider creation, flipping degradation to a hard-stop + remediation, **execution wiring** (threading the acting user through the resolver call sites and the LLM client so owned models actually run end to end), and **full `Model` `Ash.Policy.Authorizer` adoption** with the codebase-wide read-path audit.

**Out of scope (2c):** `MessageUsage` billing attribution and the universal-vs-spend gate split. 2b-1 records `cost_source`/`credential_owner_user_id` as facts but changes no billing behavior.

## Locked Decisions

1. **Extend, do not fork.** Add `owner_user_id` to the existing `Provider` and `Model` resources. One row shape, one resolution path. `owner_user_id == nil` means global/admin (all rows today); a set value means user-owned.
2. **Both BYOK shapes.** A user may (a) bring their own key for a first-class provider (`req_llm_id` in a config allowlist: `anthropic`, `openai`, `openrouter`, `xai`, `google`, plus deployment additions) and create models under it, and (b) register a custom `openai_compatible` endpoint (`base_url` + key + hand-entered model ids). Text-only in 2b-1.
3. **Keep global-unique keys, no id-migration** (carried from 2a). Server-generated unique slugs keep `Model.key = "<slug>:<model_id>"` globally unique; the `unique_key` identity holds untouched.
4. **Atom-safety by exclusion.** User providers never mint atoms (excluded from `CatalogSync.build_custom`) and their writes skip catalog reloads. They resolve through `RequestOptions` (a DB lookup) instead.
5. **The credential trust boundary is `RequestOptions`, not just the Resolver.** Owned-provider credentials are returned only when an actor id is supplied and equals `owner_user_id`. This is the load-bearing security guarantee and holds regardless of which path reaches the LLM client.
6. **No global `Model` authorizer in 2b-1 (revised 2026-07-01).** `Model` has no authorizer today. Adopting `Ash.Policy.Authorizer` breaks roughly 30 internal/test/seed call sites (every `Model` create/read that runs without an actor), a codebase-wide audit that belongs with the 2b-2 UI where it can be validated end to end. For 2b-1 the actual owned-model leak vectors are narrow and closed directly: the `list_active` read is actor-filtered (global plus own), Task 8's selection validation is owner-scoped, and the runtime paths (`Resolver`/`RequestOptions`) are independently fail-closed. Full authorizer adoption is deferred to 2b-2.
7. **Facts, not policy** (carried from 2a). The resolver populates ownership facts; billability derivation stays downstream and is untouched.
8. **Soft degradation stays soft.** The hard-stop is 2b-2.
9. **Caps are universal, the paid-plan gate is not.** Per-user count caps ship here (open-core and cloud). The cloud-only paid-plan gate is 2b-2.
10. **Credential validation machinery in 2b-1**, UI in 2b-2.
11. **Media BYOK is blocked here**, delivered in Phase 5.

## Data Model

### Provider (`lib/magus/models/provider.ex`)

New attributes:
- `owner_user_id` (nullable UUID, FK to `Magus.Accounts.User`, indexed). `nil` = global/admin.
- `validation_status` (atom, `:pending | :valid | :invalid | :error`, default `:pending`).
- `last_validated_at` (utc_datetime, nullable).
- `validation_enqueued_at` (utc_datetime, nullable) as an enqueue guard (see Credential Validation).

New action `:create_owned`:
- Accepts `name`, `req_llm_id`, `base_url` (custom only), `api_key`.
- Sets `owner_user_id = actor.id`; server-generates `slug` (caller never supplies one).
- Restricts `req_llm_id` to the config allowlist (`openai_compatible` always permitted).
- Validates `base_url` via the SSRF validator (user rows only).
- Enforces the provider count cap.
- Enqueues credential validation.

The admin `:create` action is untouched (explicit slug, `IsAdmin`, may point at localhost). `:update` gains owner-scoping; `req_llm_id` and `slug` stay immutable; owned `base_url` updates re-run SSRF validation and re-enqueue validation.

### Model (`lib/magus/chat/model.ex`)

New attribute:
- `owner_user_id` (nullable UUID, indexed), mirrored from its provider on create.

`api_provider` change: add a neutral value `:byok` to the `one_of` constraint (currently `[:openrouter, :xai, :publicai, :aimlapi, :fal]`). Owned models are created with `api_provider: :byok`. This matters because `Magus.Providers.Routing.build_provider_routing/2` (routing.ex:9) applies OpenRouter region routing only when `api_provider == :openrouter`; a neutral value makes owned models skip that legacy routing cleanly (returns `nil`), and no OpenRouter-specific routing params are attached to a request bound for another provider. The plan audits all `api_provider` readers to confirm `:byok` is handled (routing returns `nil`; media/video dispatch keys off the model-key prefix, not `api_provider`, and media models are blocked anyway).

New action `:create_owned`:
- Requires `model_provider_id` referencing a provider owned by the actor.
- Sets `owner_user_id` from that provider and `api_provider: :byok`.
- Mints `key = "<provider.slug>:<model_id>"`.
- Rejects media models (output modalities containing `image`/`video`, or an image/video-only capability). Text-only in 2b-1.
- Enforces the model count cap.

`unique_key [:key]` is unchanged and holds by construction.

## Resolution and the Credential Trust Boundary

### CatalogSync (atom-safety and reload churn)

- `build_custom` (catalog_sync.ex:26) filters to global providers (`owner_user_id == nil`), so `slug_to_atom` (catalog_sync.ex:55) is never reached for a user slug and user models never enter the LLMDB catalog.
- `Magus.Models.Changes.SyncCatalog` (sync_catalog.ex:11) requests an LLMDB reload after every Provider/Model write. It gains a guard: skip `request_reload/0` when the row is owned (`owner_user_id != nil`). Owned rows are absent from the catalog, so reloading for them is pure churn. Global writes behave exactly as today.

### RequestOptions (the security guarantee)

`resolve/1` becomes `resolve/2` with an optional actor id (default `nil` preserves all current global/env behavior). The lookup already loads the model with its provider (request_options.ex:41).
- **Global provider** (`owner_user_id == nil`): unchanged; credentials returned as today, no actor required.
- **Owned provider** (`owner_user_id != nil`): credentials returned only when the supplied actor id equals `owner_user_id`. On mismatch or a missing actor, return the safe env-fallback form (`{model_key, []}`), so no owned credential is ever handed out to a non-owner. A non-owner passing a foreign owned key (`"u_victim:claude"`) gets an unresolvable spec and the request fails cleanly, never billing or using the victim's key. A `[:magus, :models, :request_options, :owner_mismatch]` telemetry event is emitted for observability.

The failure direction is deliberate: a path that does not supply the actor gets the safe fallback (no owned credential), never a leak. `resolve/1` stays as a thin wrapper delegating to `resolve/2` with `nil`, so every current caller (llm.ex:88 and any raw-string tool path such as `spawn_sub_agent.ex:97`) keeps working unchanged and simply never receives owned credentials in 2b-1. This closes the bearer-key hole with no changes to the LLM client or the Jido strategy. Wiring the acting user into `resolve/2` so owned models execute for their owner is 2b-2 (see Execution Wiring).

### Resolver (actor-capable fetch and ownership facts)

`Magus.Models.Resolver.resolve(actor, input)` gains ownership awareness while its callers keep passing `nil`:
- The key lookup (`fetch_by_key`, resolver.ex:142) and the explicit-id lookup (`Magus.Chat.get_model/1`, resolver.ex:37) filter to `owner_user_id == nil OR owner_user_id == <actor id>` when an actor id is present; with a `nil` actor they see global rows only. Behavior-neutral for existing rows and existing callers (all global, all `nil`).
- Owned resolutions (reached in tests by passing a real actor) populate `access_source: :owned`, `credential_owner_user_id`, `cost_source: :byok`.
- Guard `provider_id/1` (resolver.ex:159) with `when is_binary(id)` (2a carryover).
- Degradation stays soft.

The new owner-scoping and fact population are unit-tested by calling `resolve(actor, ...)` with a real actor. The 2b-1 call sites (preflight.ex:78/175/247/286, media_bypass.ex:35) are left passing `nil` and are unchanged.

### Execution Wiring (deferred to 2b-2)

Making owned models run end to end requires supplying the acting user to `resolve/2` at the resolver call sites and, through `opts`, to the LLM client. That is 2b-2 work. The rule it must follow, recorded here so it is not lost: the actor is the **acting user**, obtained via `Magus.Agents.Plugins.Support.Helpers.acting_user_id/2` (helpers.ex:65), which resolves the requesting message's sender and falls back to the agent/conversation owner. It must never be assumed to be the conversation owner in multiplayer.

| Call site (2b-2) | Actor source |
|---|---|
| Preflight main (preflight.ex:78) | `acting_user_id(agent, message_id)` |
| Preflight resume (preflight.ex:175) | `acting_user_id/2` for the resumed message; fall back to agent owner |
| Preflight debug/assembly (preflight.ex:247) | agent owner (`agent.state.user_id`) when no message is in scope |
| Preflight (preflight.ex:286) | `acting_user_id/2` (verify the exact context) |
| MediaBypass (media_bypass.ex:35) | `acting_user_id/2` |
| LLM client -> RequestOptions | the same acting-user id, via `opts` (pop it before the ReqLLM call) |

## Authorization

### Model read scoping (no authorizer in 2b-1)

`Magus.Chat.Model` does NOT adopt `Ash.Policy.Authorizer` in this phase (see Locked Decision 6). Instead, owned-model visibility is scoped at the specific paths that could leak it:
- **`list_active`** (the SPA curation catalog and picker) becomes actor-scoped by FILTER: `active? == true and internal? == false and (is_nil(owner_user_id) or owner_user_id == ^actor(:id))`. Called with an actor it returns global rows plus the actor's owned rows; called with no actor (or `authorize?: false` internal use) it returns global rows only. This holds without an authorizer because it is an action filter, not a policy.
- **Selection validation** (Section below and Task 8) queries with the same owner filter, so a foreign owned id is rejected.
- **Runtime paths** (`Resolver`, `RequestOptions`) are fail-closed independently via explicit owner filters plus `authorize?: false` (Tasks 6 and 7). They do not rely on a Model policy.

`:create_owned` needs no policy: its `BuildOwnedModel` change requires an actor and verifies the target provider is owned by that actor, so a user can only create models under providers they own. The admin `:create` keeps its pre-2b-1 behavior (no authorizer, no new gate). Full policy adoption and the codebase-wide reader audit move to 2b-2.

### Provider read tightening

`Provider` read policy tightens from the blanket `authorize_if always()` (provider.ex:55) to global-or-owned in actor context; internal plumbing keeps `authorize?: false`. `api_key` is already `sensitive?`/non-public.

### Selection-write validation

The selection actions accept ids with no validation today: `User.select_model`/`select_image_model`/`select_video_model` (user.ex:186) and `Conversation.set_model`/`set_image_model`/`set_video_model` (conversation.ex:155). Each gains a validation that the selected id resolves, under the acting actor, to an active, non-internal, usable model; a foreign or unusable id is rejected at write time rather than relying on later soft degradation. The curation `ModelSelectable` validation (model_selectable.ex:16), which currently calls `get_model/1` without an actor, is updated to read with the changeset actor so it cannot green-light another user's private model.

## Slug Generation

- Format: a short prefixed token matching the existing `~r/\A[a-z0-9_]+\z/` constraint and `max: 64` (for example `u_` + lowercase base32 of random bytes).
- Uniqueness: enforced by the `unique_slug` identity; a collision retries with a fresh token, bounded, surfacing an error rather than looping.
- Because the slug is unique by construction, `Model.key` built from it is globally unique.

## Security: SSRF and Caps

### SSRF validation (user base_url only)

A validator (`Magus.Models.BaseUrlValidator`) applied in `Provider.:create_owned` and owned `:update`:
- Require scheme `https`.
- Reject hosts resolving to loopback / private / link-local / ULA / cloud-metadata ranges (`127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` including `169.254.169.254`, `0.0.0.0`, `::1`, `fc00::/7`).
- Reject embedded credentials and non-`https` schemes.
- Admin `:create` stays exempt (self-hosted localhost keeps working; `RequestOptionsTest` relies on it).

Documented limitation: DNS rebinding / TOCTOU is not fully closed by static check + validation-time resolution; a per-request egress guard is a later hardening item.

### Per-user caps

Config-driven, universal:
```elixir
config :magus, :user_model_limits, max_providers: 10, max_models: 50
```
Enforced by a count check in the `:create_owned` actions. The benign TOCTOU race under concurrent creates is acceptable for an abuse cap. Plan-based raising and the paid-plan gate are 2b-2.

## Credential Validation

Async, cached, rate-limited; stamps status on the Provider; no UI in 2b-1.
- Trigger: `:create_owned` enqueues a validation job; owned `:update` changing `api_key`/`base_url` re-enqueues; an explicit `:validate` action re-enqueues.
- **Enqueue guard**: an Oban unique job (`unique: [period: <window>, fields: [:args]]`, a pattern already used in the repo, for example `super_brain/workers/build_super_full.ex`) plus a `validation_enqueued_at` check, so a burst of triggers cannot fan out into many jobs before the first stamps `last_validated_at`.
- Job: an Oban worker performing a minimal probe (for example a models-list request against the resolved endpoint with the stored key), then writing `validation_status` + `last_validated_at`.
- Strategy indirection: a `CredentialValidator` seam keyed by `req_llm_id`, stubbable in tests; the default OpenAI-style probe covers most first-class providers.
- Non-blocking: an invalid key still saves with `validation_status: :invalid`; resolution is unaffected in 2b-1.

## Account Lifecycle

Adding `owner_user_id` FKs must not block user deletion, and `Model` deletion is already FK-restricted (no `ON DELETE`; Postgres restricts, per model_references.ex:3). The account-deletion flow (account_deletion.ex:231) does not touch providers/models today.
- Cleanup: extend the deletion flow to delete the user's owned `Model` rows, then owned `Provider` rows, ordered **after** conversation deletion (which removes the messages and nilifies the `MessageUsage` model references), so owned-model deletes are not restricted by lingering usage rows. In 2b-1 owned models are private, so only the owner's own (now-deleted) messages reference them.
- FK behavior: `owner_user_id` is a restricting reference backed by explicit app-level cleanup, consistent with existing model FK conventions; the cleanup ordering, not a database cascade, guarantees deletability.

## Phase 2a Carryover

- Guard `Resolver.provider_id/1` (resolver.ex:159) with `when is_binary(id)`.
- Add the two deferred metadata-path tests: (a) explicit-id-miss plus `:auto`-image `inherited_requested` propagation; (b) explicit key equal to `Config.default_model()` labeled `:explicit` / `degraded?=false`.

## Open-Core and Cloud

- Everything in 2b-1 is universal (open-core and cloud): ownership, the credential trust boundary, authorization, atom-safety, SSRF, caps, credential validation, lifecycle.
- No billing behavior changes. `cost_source`/`credential_owner_user_id` are recorded as facts; 2c consumes them.
- The cloud paid-plan gate on provider creation is 2b-2, behind the existing billing seam.

## Testing

`Magus.ResourceCase` / `DataCase` tests:
- Provider `:create_owned`: owner set, valid unique server-gen slug, `req_llm_id` allowlist, provider cap.
- Model `:create_owned`: actor-owned provider required, owner mirrored, `api_provider: :byok`, unique slug-prefixed key, media rejected, model cap.
- Slug generation: format, uniqueness, collision retry.
- **Credential trust boundary**: `RequestOptions.resolve/2` returns owned credentials only to the owner; a non-owner (and a nil actor) get the safe env fallback for a foreign owned key; global rows unchanged; `owner_mismatch` telemetry fires.
- Resolver actor-capability: calling `resolve/2` with user B's actor cannot resolve user A's private model by key or id; calling it with the owner's actor resolves it and populates ownership facts; a `nil` actor (the 2b-1 caller default) sees global rows only and preserves global defaults.
- Model read scoping: `list_active_models` returns global plus the actor's owned rows with an actor, and global only with no actor (or `authorize?: false`); it never returns another user's owned rows. (No Model authorizer in 2b-1.)
- Selection-write validation: selecting a foreign/unusable model id is rejected on `User` and `Conversation` selection actions; `ModelSelectable` uses the actor.
- `CatalogSync`: owned rows excluded from `build_custom`; no atom minted for a user slug; owned writes do not request a reload.
- `RequestOptions`: known-provider rewrite (`u_...:model` -> `req_llm_id:model` + key) and `openai_compatible` inline form for owned rows; admin rows unchanged.
- SSRF: rejection of loopback/private/link-local/metadata hosts, embedded credentials, non-https; admin exemption preserved.
- Credential validation: enqueue on create, Oban-unique + `validation_enqueued_at` guard prevents fan-out, status stamping, stubbed probe for valid/invalid/error.
- Account deletion: a user owning providers/models with prior usage deletes cleanly; owned rows are gone; no FK restriction error.
- Carryover: `provider_id/1` guard and the two 2a metadata-path tests.

## Migration Notes

- One AshPostgres migration adds `owner_user_id` (Provider, Model), `validation_status`, `last_validated_at`, `validation_enqueued_at`, the `:byok` enum value, and supporting indexes. Generated via `mix ash.codegen`; never `mix ash.reset`.
- All new columns are nullable/defaulted; existing rows remain valid global rows with no backfill.

## Risks and Limitations

- **DNS rebinding / TOCTOU** on `base_url`: static validation is the first bar; a per-request egress guard is a later item.
- **Cap race**: concurrent `:create_owned` can slightly exceed the cap; acceptable for an abuse cap.
- **Authorizer adoption blast radius**: adding `Ash.Policy.Authorizer` to `Model` touches every read path. Mitigated by the call-site audit and by keeping internal reads explicit `authorize?: false`; the plan enumerates each reader.
- **Actor threading gaps fail closed**: a path that forgets the acting user degrades the owner's own request rather than leaking credentials, which is the correct failure direction but a UX papercut to watch for in 2b-2.
- **ReqLLM metadata for exotic user model ids**: a known-provider id absent from the packaged snapshot still routes but without registry metadata; cost/context come from the `Model` row. Credential validation surfaces obviously wrong ids in 2b-2.

## Review Traceability (design review 2026-07-01)

| Finding | Resolution |
|---|---|
| P1 Private keys as bearer credentials | Fail-closed credential boundary in `RequestOptions.resolve/2` (default `nil` actor -> owned credentials never returned); safe env fallback otherwise. Closed in 2b-1 without touching the LLM client. |
| P1 Model has no authorizer | 2b-1 closes the actual leak vectors without a global authorizer: actor-filtered `list_active` + owner-scoped selection validation + fail-closed Resolver/RequestOptions. Full `Ash.Policy.Authorizer` adoption (breaks ~30 actor-less call sites) deferred to 2b-2. |
| P1 Actor threading underspecified | 2b-1 makes the resolver + `RequestOptions` actor-capable and fail-closed. The live per-call-site sourcing (via `acting_user_id/2`, multiplayer-correct) is specified for 2b-2 in Execution Wiring; 2b-1 callers stay `nil`. |
| P1 Allowlist vs `api_provider` enum | Add neutral `:byok` enum value; owned models set it; legacy OpenRouter routing is skipped; audit `api_provider` readers. |
| P1 Media BYOK unsupported | Block owned media models in `:create_owned`; media BYOK is Phase 5. |
| P2 Selection writes unvalidated | Add ownership/usability validation to `User`/`Conversation` selection actions; fix `ModelSelectable` to use the actor. |
| P2 Account-deletion cleanup missing | Delete owned models then providers after conversation deletion; define restricting FK + app-level cleanup ordering. |
| P2 Owned writes trigger catalog reloads | `SyncCatalog` skips `request_reload/0` for owned rows. |
| P2 Validation enqueue guard | Oban unique job + `validation_enqueued_at`, not only `last_validated_at`. |
