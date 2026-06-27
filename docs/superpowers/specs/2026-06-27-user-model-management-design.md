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
- Limits/billing: `Magus.Usage.PolicyEnforcer` (`check_usage/3`, `check_mode_access`,
  `check_workspace_model`) plus `Magus.Usage.Calculator` gate generation against a CHF-cent
  monthly spend cap (`period_usage_cents` vs `effective_cap_cents`, `monthly_spend_cap_cents`),
  mode access, and a workspace model allowlist. There is no runtime credit system;
  subscriptions carry a Stripe-backed `billable?` flag. CLAUDE.md's `daily_credits` /
  `cost_multiplier` wording is stale, and no `Magus.Subscriptions.LimitEnforcer` module
  exists.

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

**Identity / uniqueness.** The runtime identity of any model is its `id` (UUID); `key` is a
catalog/provider-facing identifier, not a runtime lookup key (see the Model reference
contract in pillar B). Uniqueness:

- Admin/global models keep a globally-unique `key` (partial unique index on `key` where
  `owner_user_id IS NULL`). The catalog and ReqLLM model strings rely on this.
- User models keep `(owner_user_id, key)` unique (partial index where
  `owner_user_id IS NOT NULL`) only to dedup a user's own list. Their `key` is NOT required
  to be globally unique and may collide with an admin `key`; that is safe only because
  runtime never resolves a user model by bare `key`.
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

**Access model.** The generic `workspace_scoped_policies` macro defaults ownership to
`user_id == actor(:id)`, but our ownership field is `owner_user_id` and admin/global rows
have a nil owner. Models therefore need explicit policy wiring and an actor-scoped read, not
the bare macro:

- Wire `workspace_scoped_policies(resource_type: :model, owner_expr: expr(owner_user_id == ^actor(:id)))`,
  plus an `extra_read` branch granting any authenticated user read of global rows
  (`owner_user_id` is nil and `active?` and not `internal?`).
- Add an actor-scoped read (for example `list_for_actor`) returning the union of global +
  owned + workspace-shared models. The existing key-only `list_active` stays for catalog and
  admin use; the user-facing picker uses the actor-scoped read.

Model access matrix (read / use / edit):

| Category | Condition | Read | Use | Edit |
| --- | --- | --- | --- | --- |
| admin/global | owner nil, active, not internal | all users | all users | admin |
| admin internal | `internal?` true | system only | system only | admin |
| user private | owner == actor | owner | owner | owner |
| workspace-shared | ResourceAccess grant | grantees | grantees (owner's key) | per role |
| disabled/deleted | `active?` false or removed | n/a | no (explicit selection hard-stops) | owner/admin |
| hidden | `UserModelPreference.hidden?` for actor | yes (so unhideable) | yes | owner |

**Provider read policy.** `Provider` currently authorizes all reads (`authorize_if always()`)
and exposes `slug` / `req_llm_id` / `base_url` / `enabled?` as public. Once providers are
user-owned, that endpoint metadata is private user data. Before Phase 2 exposes providers
over RPC: restrict reads to admin/global providers (owner nil) and the owner for user
providers, expose only non-sensitive fields, and keep `api_key` sensitive and never
serialized. Grantees of a shared model never read the owner's provider directly; the
server-side resolver loads it.

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
   selection_source:         :explicit | :conversation | :agent | :user_default | :router_slot | :product_default,
   access_source:            :owned | :workspace_shared | :admin_global | :product_default,
   provider:                 %Magus.Models.Provider{} | nil,
   credential_owner_user_id: uuid | nil,   # nil = admin/env key (Magus pays the provider)
   cost_source:              :provider_reported | :admin_pricing | :user_pricing | :zero | :unknown,
   billable_by_magus:        boolean,       # derived: credential_owner_user_id == nil
   req_opts:                 keyword         # api_key, base_url, routing
 }}
| {:error, %Magus.Models.Resolution.Error{reason: atom, model_ref: term, message: String.t}}
```

The four axes are orthogonal: `selection_source` records which layer supplied the model
(for remediation messaging and the explicit-vs-inherited decision), `access_source` records
by what right the actor may use it, `credential_owner_user_id` records whose key pays the
provider, and `billable_by_magus` is derived from it. A user can explicitly select an admin
model (`selection :conversation`, `access :admin_global`, credential owner nil, billable
true) or run a shared model on another user's key (`access :workspace_shared`, credential
owner the sharer, billable false). A single `source` field could not express both.

**Model reference contract.** Runtime selection and signals reference a model by `id` (UUID)
or an opaque `ModelRef`, never by bare `key`. This is a prerequisite for ownership: today
`ModelResolver.fetch_model_by_key` does `filter(key == ^key) |> Ash.read_one(authorize?: false)`
and `RequestOptions.resolve/1` does `get_model_by_key_with_provider(key)`, both of which
break once a user `key` can collide with an admin `key` (`read_one` errors on duplicates,
and the `authorize?: false` lookup ignores ownership). Phase 2 migrates these explicit-
selection paths and the `ai.react.query` `:model` field to carry `model_id`. The resolver
then dispatches on the loaded model: admin/global models build the ReqLLM model from `key`
(catalog path); user-owned models build it from the owned provider (protocol `req_llm_id` +
`base_url` + the model's provider-local id). `key` stays the provider-facing identifier and
the catalog/ReqLLM string for admin rows; it is never a cross-owner lookup key. The
conversation/message/user/agent FKs are already `id`-based, so the migration is the two
key-based lookups above plus any signal that passes a bare key string.

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

Two separate layers, deliberately decoupled. The split must be concrete in code, because
today `Magus.Usage.PolicyEnforcer` runs them behind one preflight call: `check_mode_access`
(feature gate), `check_workspace_model` (allowlist), and `check_usage/3` (CHF-cent spend
cap).

**Universal gates (cloud and self-hosted, always apply).** Mode access, the workspace model
allowlist, and abuse/run quotas (rate limits, agent run caps, parallel-run caps) apply to
every request regardless of who pays, including BYOK and shared-key. BYOK waives money, not
guardrails, otherwise a user could proxy unlimited agent runs through the platform on their
own key. A self-hosted admin configures these caps with no billing involved.

**Spend gate (cloud only, billable requests only).** `check_usage/3` compares
`period_usage_cents + estimate <= effective_cap_cents` against the subscription's monthly
CHF-cent spend cap. There is no credit system. This gate, and the addition to
`period_usage_cents`, apply only when the request is `billable_by_magus`. BYOK and
shared-key requests (`billable_by_magus: false`) skip the spend gate and do not accrue
`period_usage_cents`: the user pays only the base fee and their provider bills them
directly.

Two distinct `billable` axes, do not conflate: the subscription-level `billable?`
(Stripe-backed vs free-trial, already in `Magus.Usage.Calculator`) is unchanged; the new
request-level `billable_by_magus` (on the resolution and the usage row) decides whether a
single request meters.

**Cloud gating.** Adding providers (BYOK or custom models) requires a paid base-fee plan.
Free users cannot add providers in cloud. The gate is a check on the provider/model create
actions, plan-gated in cloud and a no-op in self-hosted (where self-hosters bring keys
natively).

**Attribution.** Extend `Magus.Usage.MessageUsage` with: `billable_by_magus` (bool),
`requesting_user_id` (uuid), `credential_owner_user_id` (uuid, nil for admin/env keys),
`cost_source` (`:provider_reported | :admin_pricing | :user_pricing | :zero | :unknown`),
and `external_cost_chf` (nullable decimal). The resolver computes `billable_by_magus`,
`credential_owner_user_id`, and `cost_source`; the usage plugin writes the row. The SPA
shows BYOK and shared-key usage as external provider cost ("External CHF 0.04, your key"),
never folded into Magus spend.

**Key-owner usage visibility.** Because external cost lands on the credential owner, a key
owner can see usage and estimated external cost attributed to their key, including requests
made by workspace grantees. This is a usage read scoped by `credential_owner_user_id`
(aggregate cost, not the grantee's message content). Grantees see their own usage as
external, not billed.

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
  are designed into the filter model now but only populated as those phases land. A
  favorited model appears in the Favorites group only, not duplicated in its provider group.
  Keep the picker compact: put filters behind a small control (popover or segmented), not
  always-on chrome.
- Favorite/hide toggles (star icon in rows) on the picker and the settings list, calling the
  new RPC actions. On any preference mutation, explicitly invalidate the `catalog.ts` model
  cache (reset the cached entry and refetch) rather than waiting out the 5-minute TTL, so the
  picker reflects the change immediately.
- New settings route `frontend/src/routes/settings/models/+page.svelte` plus a nav entry in
  `settings-nav.svelte` ("Models"). Phase 1 content: list all models as a dense management
  list (rows, not a card grid) with favorite/hide/reorder controls. This route is where later
  phases add "My models",
  "API keys", "Workspace sharing", and "Auto router" subsections.

**Acceptance criteria.**

- `position` is a single global manual ordering of the user's visible models (fractional or
  integer rank; null sorts last, then by name). No per-filter ordering (YAGNI). The Favorites
  group renders favorited models in that same order.
- `favorite?` and `hidden?` are independent. In the picker, hidden wins: a hidden model is
  excluded even if favorited. The settings Models list shows every model with both toggles,
  so a hidden+favorite model can be unhidden.
- `set_favorite` / `set_hidden` / `set_position` validate that the target model is readable
  by the actor (active, non-internal, or owned/shared) and reject otherwise; they upsert on
  `(user_id, model_id)` and never create a row for an unreadable or internal model.
- Empty states: no favorites yet means the Favorites group is omitted, not an empty header;
  all models hidden shows an explicit "all models hidden" affordance linking to settings.
- Tests cover: favoriting moves a model into the Favorites group and removes it from its
  provider group; hiding excludes it from the picker but keeps it in settings; a
  hidden+favorite model resolves to hidden in the picker; the actions reject an unreadable or
  internal model; a mutation invalidates the cache and refetches.

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

- **Billing meter (resolved).** Verified in code: there is no runtime credit system.
  `Magus.Usage.PolicyEnforcer` enforces a CHF-cent monthly spend cap (`period_usage_cents`
  vs `effective_cap_cents`) via `Magus.Usage.Calculator`. The spec is written in those terms;
  CLAUDE.md's `daily_credits` / `cost_multiplier` wording is stale.
- **Modes as features (grounded).** `check_mode_access` is a plan feature gate that always
  applies, so BYOK does not bypass mode access; image/video stay gated by plan. Confirm a
  paid base-fee plan is intended to unlock all modes.
- **Clone affordance** ("clone a catalog model into mine"): confirm it is wanted in Phase 2
  and that clones are explicit snapshots that do not auto-track admin catalog updates.
- **Key-owner usage visibility** (Phase 3): confirm key owners should see aggregate external
  usage that workspace grantees generate on their key.

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
- `lib/magus/usage/message_usage.ex` (attribution), `lib/magus/usage/policy_enforcer.ex`,
  `lib/magus/usage/calculator.ex` (universal gates + CHF-cent spend cap)
- `lib/magus/chat/chat.ex`, `lib/magus/accounts/user.ex` (rpc_action declarations, user defaults)
- `lib/magus_web/core_router.ex`, `lib/magus_web/rpc/rpc_controller.ex` (RPC + actor)

Frontend (SPA):

- `frontend/src/lib/components/chat/model-picker.svelte`, `frontend/src/lib/chat/catalog.ts`,
  `frontend/src/lib/components/chat/composer.svelte`
- `frontend/src/routes/settings/` (+ `preferences/+page.svelte`),
  `frontend/src/lib/components/shell/settings-nav.svelte`
- `frontend/src/lib/ash/{api,ash_rpc,ash_types}.ts`
