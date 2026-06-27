# Open Model Management for Users: North-Star Design

Date: 2026-06-27
Status: Approved north-star architecture. Phase 1 (curation) detailed for first implementation.

## Goal

Today only admins manage the model catalog and providers. This effort opens model
management to regular users while keeping admin-provided models as the shared default
baseline. Users can curate the catalog for themselves, bring their own providers and API
keys (BYOK), share their models into workspaces, and configure their own defaults and
auto-router slots. Resolution becomes explicit and predictable, with no silent runtime
fallback.

The full vision is a multi-phase effort. This document is the durable end-state
architecture (the north-star) across three pillars (data model, resolution contract,
billing and limits) plus a phase roadmap. Phase 1 is detailed here and will be the first
implementation plan. Later phases are captured at architecture level and will each get
their own spec when we reach them.

## Core principles (refined from the brief)

- Admin models remain the shared default baseline.
- Users can add private providers, models, and API keys. Ownership is all-or-nothing:
  a user-owned model is fully theirs (config + key + billing), not an override of an
  admin row.
- Users can curate (favorite, hide, order) and configure their own defaults and router
  slots.
- Workspace sharing is explicit, never automatic. Sharing a user model lets grantees run
  it on the owner's key.
- BYOK, private, and shared-key requests are not metered for Magus pay-as-you-go billing.
- Cost telemetry stays useful: show provider-reported or estimated external cost in CHF,
  labeled as external provider cost, never folded into Magus billing.
- No silent runtime fallback: a broken explicit selection stops with a clear error.
- Open-core split: usage caps and abuse limits are universal (cloud and self-hosted);
  billing is cloud only.

## Current architecture (ground truth)

Backend:

- `Magus.Chat.Model` (`lib/magus/chat/model.ex`): global catalog, identity
  `unique_key [:key]`, no owner. `belongs_to :model_provider`. Legacy `api_provider` enum
  (`:openrouter | :xai | :publicai | :aimlapi | :fal`) is the routing/region key. Flags
  `active?` / `internal?`, modalities, per-token cost fields. Exposed to the SPA via
  `rpc_action` (`list_active_models`, `list_image_generation_models`,
  `list_video_generation_models`) in `lib/magus/chat/chat.ex`.
- `Magus.Models.Provider` (`lib/magus/models/provider.ex`): `name`, `slug`, `req_llm_id`,
  `base_url`, encrypted `api_key`, `enabled?`, identity `unique_slug [:slug]`. Policies:
  reads open, create/update/destroy gated by `Magus.Checks.IsAdmin`. This is the
  credentials + endpoint source.
- Encryption: `Magus.Agents.AgentSecret.EncryptedString` over `Magus.Integrations.Vault`
  (Cloak AES-256-GCM, `INTEGRATION_ENCRYPTION_KEY`).
- `Magus.Models.CatalogSync` (`lib/magus/models/catalog_sync.ex`): builds the LLMDB custom
  catalog from enabled providers + provider-linked active models. `slug_to_atom/1` tries
  `String.to_existing_atom` then mints atoms for unknown slugs. Safe for admin rows, not
  safe for user-controlled slugs.
- Resolution is split across four modules:
  - `Magus.Agents.Routing.ModelKeyResolver`: builds `model_keys: %{chat, image, video}`,
    precedence conversation selection > custom agent model > user default > `:auto`.
  - `Magus.Agents.Plugins.Support.ModelResolver`: `selected_model_id` > model_keys for
    mode > `:auto` (auto-router) > fallback default. **Silently falls back to a default.**
  - `Magus.Agents.Plugins.Support.Preflight`: usage/spend gate, mode access, workspace
    model gate, region availability, provider routing.
  - `Magus.Models.RequestOptions` (`lib/magus/models/request_options.ex`): loads model +
    provider, injects `api_key` / `base_url` into ReqLLM opts via
    `Magus.Agents.Clients.LLM`. **Silently falls back to env-var keys** when no provider is
    linked or it is disabled.
- Auto-router: `Magus.Chat.RoutingSlot` (`{specialty, tier}` unique, `belongs_to :model`),
  driven by `AutoRouteResolver` + `ModelMatcher`, capped by subscription `max_tier`.
- Media generation bypasses all of the above: `generate_image` / `generate_video` actions
  call provider clients (`openrouter_image`, `openrouter_video`, `aimlapi_client`,
  `fal_client`) that each read `System.get_env` directly.
- Usage: `Magus.Usage.MessageUsage` records per-message tokens and cost.
- Sharing infra: `Magus.Workspaces.ResourceAccess` grants + `workspace_scoped_policies`
  macro, reused by Folder/Prompt/CustomAgent/Brain/KnowledgeCollection. `:model` is not in
  the resource-types list yet.
- Limits/billing: `Magus.Subscriptions.LimitEnforcer` and `Magus.Usage.PolicyEnforcer`
  gate generation against subscription credits, mode access, and model tier.

Frontend (the SPA, where all new user-facing UI lands):

- SvelteKit 2 / Svelte 5 (TypeScript) under `frontend/`.
- API layer is AshTypescript RPC: `POST /rpc/run`, generated client in
  `frontend/src/lib/ash/{ash_rpc,ash_types}.ts`, app wrappers in
  `frontend/src/lib/ash/api.ts`. Actor flows from the session cookie via the `:rpc`
  pipeline (`set_actor, :user`) in `lib/magus_web/core_router.ex`. New backend actions
  reach the SPA by adding `rpc_action` declarations to the relevant domain.
- Picker: `frontend/src/lib/components/chat/model-picker.svelte` (groups by `provider`,
  filters by modality). Models loaded via `cachedActiveModels()`
  (`frontend/src/lib/chat/catalog.ts`, 5-minute TTL).
- Settings: SvelteKit routes under `frontend/src/routes/settings/`, nav in
  `frontend/src/lib/components/shell/settings-nav.svelte`. Default models live in
  `settings/preferences/+page.svelte`.
- The classic LiveView workbench (`lib/magus_web/workbench/...`,
  `lib/magus_web/legacy/...`) is being retired. Do not build new user UI there. The admin
  model UI (`lib/magus_web/admin/models_live.ex`) stays as is.

## North-star architecture

### A. Data model and ownership

**Ownership fields.** Add `owner_user_id` (nullable, FK to users) to both
`Magus.Models.Provider` and `Magus.Chat.Model`. Nil means admin/global; a set value means
user-owned. A user's API key is encrypted on their own `Provider` row, exactly as admin
keys are today. There is no per-user override of an admin row: BYOK is achieved by owning a
provider and the models under it.

**Identity / uniqueness.**

- Admin models keep a globally-unique `key` (partial unique index on `key` where
  `owner_user_id IS NULL`).
- User models are unique per owner (partial unique index on `(owner_user_id, key)` where
  `owner_user_id IS NOT NULL`).
- Same split for `Provider.slug`: globally unique for admin, unique per owner for user
  providers.

**User models bypass the global atom catalog.** User-owned models are not fed into
`CatalogSync` (which is atom-keyed by provider slug). They resolve directly through their
owned provider:

- Routing uses the provider row's UUID FK, explicit `base_url`, and `api_key`.
- `req_llm_id` is chosen from a fixed, admin-curated protocol enum (for example
  `openai_compatible`, `openrouter`, `anthropic`, `openai`), so the protocol token is
  always a known atom.
- The user's free-text `slug` is display and dedup only and never reaches
  `String.to_atom`.

**Sharing.** Add `:model` to `Magus.Workspaces.ResourceAccess` resource types and wire
`Magus.Chat.Model` with `workspace_scoped_policies(resource_type: :model)`. A grant
(workspace or specific user) lets grantees select and run the model. Because the model is
bound to the owner's provider and key, running a shared model uses the owner's key, and the
external provider cost lands on the owner. Role semantics: `viewer` can use, `editor` can
edit, `owner` can reshare. Revoking a grant removes access without deleting the model. The
existing classic share button (`lib/magus_web/workbench/workspace_share_button.ex`) is a
reference only; the SPA needs its own share affordance backed by the same
`Magus.Workspaces` grant actions exposed over RPC.

**Curation (Phase 1).** One resource `Magus.Chat.UserModelPreference`:
`(user_id, model_id, favorite?, hidden?, position)`, unique `(user_id, model_id)`. A row
exists only when the user has expressed a preference; absence means default (not favorite,
not hidden, unpinned). This single row carries favorite, hidden, and ordering rather than
three tables.

**User defaults and router (Phase 4).** User defaults already exist on `Magus.Accounts.User`
(`selected_model_id`, `selected_image_model_id`, `selected_video_model_id`); they will be
allowed to reference owned and shared models, not just admin models. User-scoped router
slots: add a nullable `user_id` to `Magus.Chat.RoutingSlot` with identity
`(user_id, specialty, tier)`. Nil `user_id` is an admin/global slot.

### B. Resolution contract

**One resolver.** Introduce a single module (working name `Magus.Models.Resolver`) that
owns the selection-plus-credential-plus-billing decision and replaces the scattered
`ModelKeyResolver` / `ModelResolver` / `Preflight` / `RequestOptions` logic for that
decision. It serves text and media uniformly, so media generation stops reading env vars
directly in the end-state.

It returns a resolution struct or a typed error:

```
{:ok, %Magus.Models.Resolution{
   model:                    %Magus.Chat.Model{},
   source:                   :user | :workspace_shared | :admin | :product_default,
   provider:                 %Magus.Models.Provider{} | nil,
   credential_owner_user_id: uuid | nil,   # nil = admin/env key
   cost_source:              :provider_reported | :admin_pricing | :user_pricing | :zero | :unknown,
   billable_by_magus:        boolean,
   req_opts:                 keyword       # api_key, base_url, routing
 }}
| {:error, %Magus.Models.Resolution.Error{reason: atom, model_ref: term, message: String.t}}
```

**Precedence.**

- Model: user-owned/selected -> workspace-shared -> admin/global -> built-in product
  default -> error.
- Router slot: user slot -> admin slot -> product default -> error.

**Missing config inherits.** A layer with no selection falls through to the next, silently
and correctly. No user default set means use admin/product.

**Broken explicit selection hard-stops.** A model that was explicitly selected, or a slot
explicitly configured, that is disabled, deleted, missing a key, or whose key last failed
validation does not get silently swapped. Resolution returns `{:error, ...}`. The decision
applies at every explicit layer: current pick, conversation pin, agent pin, user default,
configured router slot.

- Interactive turns: block the turn and surface a clear error naming the model and the
  reason, paired with one-click remediation (switch to your default, switch to auto, or fix
  the key). This is the SPA's job, fed by the typed error.
- Autonomous runs (heartbeat, sub-agents): fail visibly in the `AgentRun` status; no silent
  substitution.

**Credential validation.** Validate a key when it is saved and on demand. Store a cached
validation status plus timestamp on the provider, and rate-limit validation calls. Per turn
we trust the cached status and surface a live 401 or credential failure honestly as the
turn's error. No per-turn health probes.

### C. Billing, limits, and the open-core split

Two separate layers, deliberately decoupled:

**Usage caps and abuse limits: universal.** Rate limits, agent run caps, parallel-run caps,
and quotas apply in both cloud and self-hosted, independent of billing. A self-hosted admin
can cap users with no billing involved at all. These always apply, including to BYOK and
shared-key requests: BYOK waives money, not guardrails, otherwise a user could proxy
unlimited agent runs through the platform on their own key.

**Billing: cloud only.** Cloud is a base fee plus pay-as-you-go on metered usage. The
`billable_by_magus` flag gates whether a request meters for PAYG. BYOK and shared-key
requests are `billable_by_magus: false`: the user pays only the base fee, and their provider
bills them directly. (Open item: confirm whether the existing credit/`cost_multiplier`
mechanism is the PAYG meter or is being superseded; see Open Items. The attribution fields
and the BYOK-is-not-metered rule hold either way.)

**Cloud gating.** Adding providers (BYOK or custom models) requires a paid base-fee plan.
Free users cannot add providers in cloud. This gate is a check on the provider/model create
actions that is a no-op in self-hosted deployments (where self-hosters bring keys natively)
and plan-gated in cloud.

**Attribution.** Extend `Magus.Usage.MessageUsage` with: `billable_by_magus` (bool),
`requesting_user_id` (uuid), `credential_owner_user_id` (uuid, nil for admin/env keys),
`cost_source` (the enum above), and `external_cost_chf` (nullable decimal). The resolver
computes `billable_by_magus`, `credential_owner_user_id`, and `cost_source`; the usage
plugin writes the row. The SPA shows BYOK and shared-key usage as external provider cost
("External CHF 0.04, your key"), never folded into Magus spend.

## Phase roadmap

The original brief listed six phases. Old Phase 2 (BYOK on admin models) and Phase 3
(custom models/providers) merge into a single "user-owned providers + models" capability,
because ownership is all-or-nothing (no key-override on admin rows).

1. **Curation.** Favorites, hidden models, and picker filters/grouping. Fully additive, no
   credential/resolution/billing changes. Detailed below.
2. **User-owned providers + models (text), with the resolver and billing keystone.** The
   `owner_user_id` data model, the central `Magus.Models.Resolver` with the no-silent-
   fallback contract, BYOK provider + model CRUD (text-first), credential validation, and
   the `MessageUsage` attribution fields. Optional "clone a catalog model into mine"
   affordance lives here. Cloud paid-plan gate on provider creation.
3. **Workspace sharing.** `:model` added to `ResourceAccess`; SPA share affordance; shared
   models run on the owner's key with correct attribution.
4. **User defaults and router slots.** User-scoped defaults honoring owned/shared models;
   per-user `RoutingSlot` rows; router precedence and no-silent-fallback for configured
   slots.
5. **Media BYOK.** Route image/video generation through the resolver and plumb resolved
   keys into the media provider clients, replacing their direct `System.get_env` reads.

## Phase 1 (first implementation): user curation

Scope: let a user favorite, hide, and filter/group models in the SPA picker and a new
settings area. No credentials, no resolution change, no billing change. This validates the
picker grouping and filtering surface that every later phase plugs into.

**Backend.**

- New resource `Magus.Chat.UserModelPreference` with attributes `favorite?`, `hidden?`,
  `position`, relationships `belongs_to :user` and `belongs_to :model`, identity
  `(user_id, model_id)`. Policies: a user reads and writes only their own preference rows
  (`relates_to_actor_via :user`).
- Actions: `set_favorite`, `set_hidden`, `set_position` (upsert on `(user_id, model_id)`),
  and a read for the current actor's preferences. Expose via `rpc_action` in the Chat
  domain.
- Add a read action returning the current actor's `UserModelPreference` rows. The SPA
  fetches these alongside `list_active_models` and joins them to models client-side, which
  keeps `list_active_models` unchanged and cacheable. Hidden models stay in the returned
  model list so the user can unhide them in settings; the SPA filters them out of the
  picker.

**Frontend (SPA).**

- `model-picker.svelte`: add grouping and filters. Groups in priority order: Favorites,
  then the existing provider groups. Filters available now: favorites only, hide/show
  hidden, capability (search, reasoning, tools), modality (text/image/video). Filters that
  depend on later phases (My models, Workspace models, Has my key, cost-known/free/unknown)
  are designed into the filter model now but only populated as those phases land.
- Favorite toggle (star) on each picker row and in the settings list, calling the new RPC
  actions; update the `catalog.ts` cache or refetch.
- New settings route `frontend/src/routes/settings/models/+page.svelte` plus a nav entry in
  `settings-nav.svelte` ("Models"). Phase 1 content: list all models with
  favorite/hide/reorder controls. This route is where later phases add "My models",
  "API keys", "Workspace sharing", and "Auto router" subsections.

**Out of scope for Phase 1:** any provider/key/custom-model work, the resolver refactor,
billing attribution, sharing, and router slots. Those are Phases 2 to 5.

## Cross-cutting constraints and risks

- **Atom safety.** Never feed user-controlled provider slugs into `String.to_atom` or the
  atom-keyed `CatalogSync`. User providers route by UUID + explicit base_url + a protocol
  `req_llm_id` drawn from a fixed admin-curated enum.
- **SSRF.** Validate and constrain custom `base_url`: require https, block internal,
  loopback, and link-local targets, and disallow private IP ranges. Apply at provider
  create/update and before any validation request.
- **Secret exposure.** Never expose decrypted API keys to the SPA. Provider read actions
  must omit `api_key`; the SPA only ever sees presence/validation status, never the value.
- **Caps.** Cap the number of providers and models a user can create; cap and rate-limit
  test-connection and validation calls.
- **No-silent-fallback regressions.** Removing the env-var and default fallbacks in
  `RequestOptions` and `ModelResolver` is a behavior change. Existing flows that relied on
  silent fallback need tests proving they now either inherit (missing config) or error
  (broken explicit), never silently swap.
- **SPA-only UI.** All new user UI is SvelteKit under `frontend/`. The classic LiveView
  workbench is not touched. The admin model UI stays.

## Open items to confirm

- **PAYG vs credits.** Confirm whether the existing credit/`cost_multiplier` system is the
  cloud PAYG meter or is being replaced by direct CHF metering. Resolve when Phase 2 touches
  billing. Does not affect the attribution-field design.
- **Modes as features vs cost** for paid plans: confirm that a paid base-fee plan unlocks
  all modes (image/video/reasoning) so BYOK does not need to bypass mode gates. Assumed yes.
- **Clone affordance** ("clone a catalog model into mine"): confirm it is wanted in Phase 2
  and that clones are explicit snapshots that do not auto-track admin catalog updates.

## Appendix: key file references

Backend:

- `lib/magus/chat/model.ex`, `lib/magus/models/provider.ex` (ownership targets)
- `lib/magus/models/catalog_sync.ex` (atom risk), `lib/magus/models/request_options.ex`,
  `lib/magus/agents/clients/llm.ex` (credential injection, text)
- `lib/magus/agents/routing/model_key_resolver.ex`,
  `lib/magus/agents/plugins/support/model_resolver.ex`,
  `lib/magus/agents/plugins/support/preflight.ex` (resolution to consolidate)
- `lib/magus/chat/routing_slot.ex`, `lib/magus/agents/routing/auto_route_resolver.ex`,
  `lib/magus/agents/routing/model_matcher.ex` (auto-router)
- `lib/magus/agents/providers/{openrouter_image,openrouter_video,aimlapi_client,fal_client}.ex`,
  `lib/magus/agents/actions/{generate_image,generate_video}.ex` (media env reads)
- `lib/magus/agents/agent_secret/encrypted_string.ex`, `lib/magus/integrations/vault.ex`
  (encryption)
- `lib/magus/workspaces/{resource_access,policies}.ex` (sharing)
- `lib/magus/usage/message_usage.ex` (attribution), `lib/magus/subscriptions/limit_enforcer.ex`,
  `lib/magus/usage/policy_enforcer.ex` (limits/billing)
- `lib/magus/chat/chat.ex`, `lib/magus/accounts/user.ex` (rpc_action declarations, user defaults)
- `lib/magus_web/core_router.ex`, `lib/magus_web/rpc/rpc_controller.ex` (RPC + actor)

Frontend (SPA):

- `frontend/src/lib/components/chat/model-picker.svelte`, `frontend/src/lib/chat/catalog.ts`,
  `frontend/src/lib/components/chat/composer.svelte`
- `frontend/src/routes/settings/` (+ `preferences/+page.svelte`),
  `frontend/src/lib/components/shell/settings-nav.svelte`
- `frontend/src/lib/ash/{api,ash_rpc,ash_types}.ts`
