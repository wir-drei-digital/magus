# OpenRouter Provider Routing — Design (simplified)

Date: 2026-07-02, rewritten 2026-07-04
Status: Approved

History: the first version of this spec designed per-user region
preferences with strict datacenter matching, consent flows, and synced
per-model endpoint data. It was superseded during review: live OpenRouter
data showed per-user region choice delivers little real value (every major
provider is US-jurisdiction, so "EU only" cripples model access) while
generating most of the design's complexity — consent UX, fail-open/closed
rules, per-user availability, multiplayer edge cases. This version replaces
the per-user knob with an admin-global provider policy. See git history for
the superseded design.

## Problem

OpenRouter serves each model through many upstream providers in different
jurisdictions. Magus's current control has three problems:

- A hand-maintained config map (`config :magus, :data_regions`) assigns each
  provider slug one region; it is stale and factually wrong in places (live
  data: `minimax` and `siliconflow` run US datacenters, config says SG).
- Per-user region preferences add complexity everywhere (consent flow,
  availability checks, settings UI, preflight gating) for a knob few users
  understand and which cannot deliver what it promises — requests cannot be
  pinned to a datacenter, and most major providers are US companies anyway.
- `Model.allowed_providers` is hand-curated with no admin UI, and an empty
  intersection sends `"only" => []` to OpenRouter, failing the request.

Scope: OpenRouter models only (`api_provider == :openrouter`). BYOK and
native providers (xai, publicai, aimlapi, fal) are unaffected.

## Concept

One admin-global allow-list of OpenRouter providers, informed by synced
provider metadata, enforced on every OpenRouter request via the `provider`
routing object. No user-facing region settings. The privacy stance becomes a
product guarantee — "requests are only routed to vetted providers, data
collection denied" — instead of an opt-in maze.

| Decision | Choice |
|---|---|
| Policy level | Admin-global provider allow-list + per-model deny-list |
| User region preferences | Removed entirely (attributes, actions, consent flow, UI) |
| Provider metadata | Synced on demand via an admin button — no cron |
| Location data | Advisory display for the admin decision, never enforcement input |
| New providers | Default `allowed: false` until an admin reviews them (fail-closed) |
| `data_collection` | Stays `"deny"` always |
| Request mechanism | `%{"only" => allowed − model denies, "data_collection" => "deny"}` |

Forward-compatible: if tenant-level residency demand materializes
(enterprise EU workspaces), the allow-list gains a per-workspace override —
a better home for residency than per-user preferences. Not built now.

## Verified OpenRouter API facts

- `GET /api/v1/providers` (public, no auth): per provider `name`, `slug`,
  `headquarters` (ISO 3166-1 alpha-2), `datacenters` (array of ISO codes),
  privacy/terms/status URLs. Live payload 2026-07-04: 90 providers; 25
  populate `datacenters`, 65 `headquarters`, 25 neither. All major hosts
  are headquarters-only (US).
- Chat-completion `provider` object supports `only`, `ignore`, `order`,
  `data_collection`, `zdr`, etc. `only` is intersected with whichever
  providers actually serve the requested model, so a global allow-list works
  without knowing per-model serving providers — no endpoints API needed.

## Data model

### New resource: `Magus.Models.OpenRouterProvider` (Models domain)

| Attribute | Type | Notes |
|---|---|---|
| `slug` | string | unique identity |
| `name` | string | display name |
| `headquarters` | string, nullable | ISO country code, advisory |
| `datacenters` | {array, string}, default [] | ISO country codes, advisory |
| `privacy_policy_url` / `terms_of_service_url` / `status_page_url` | string, nullable | advisory |
| `allowed` | boolean, default false | the admin decision |
| `last_synced_at` | utc_datetime | staleness display; rows absent from the latest payload keep their old timestamp |

No region buckets, no country→region mapping module, no `regions_override`:
the admin reads the location data and flips `allowed`. Jurisdiction
judgment calls (UK, HK, mixed-region providers) are the admin's, made in
the UI, not encoded in code.

### Model changes

- `denied_providers` ({array, string}, default []): per-model admin
  deny-list, subtracted from the global allow-list at request time. Covers
  "this host serves this model badly" cases. The editor suggests slugs from
  synced providers; arbitrary slugs are accepted (a deny for a not-yet-synced
  slug is harmless).
- `allowed_providers` is **no longer read** and is dropped from the resource
  (column drop is a cloud follow-up since the commercial catalog seeds it).
  The migration logs models with non-empty `allowed_providers` so an admin
  can re-express deliberate exclusions as `denied_providers`. (The old
  allow-list intent cannot be converted automatically without per-model
  endpoint data, which this design deliberately does not sync.)

## Sync

No cron, no Oban. A "Sync from OpenRouter" button in admin runs one
synchronous fetch (`GET /api/v1/providers`, ~90 rows) with UI loading/error
feedback, implemented as a plain module (e.g.
`Magus.Models.OpenRouterProviderSync`) called from the LiveView:

- Upsert by `slug`; update metadata fields and `last_synced_at`.
- **`allowed` is never touched on resync** — new rows get the default
  `false`, existing rows keep the admin's decision.
- Providers missing from the payload keep their rows and stale
  `last_synced_at` (visible in admin; OpenRouter won't route to them
  anyway).

### Seeding

A data migration seeds initial rows with `allowed: true` for the providers
the current config map assigns to US/EU/CH — as a snapshot list embedded in
the migration, since the config itself is deleted in the same change. This
preserves today's effective default behavior for cloud users. Everything else (including the
config's CN/SG providers) starts `allowed: false`. Fresh OSS installs start
with an empty table and rely on the fallback below until an admin syncs and
reviews.

## Request building

`Magus.Providers.Routing.build_provider_routing(model)` — signature loses
the `user` argument; Preflight's merge into `llm_opts[:openrouter_provider]`
is unchanged:

1. Non-OpenRouter model → `nil`.
2. Load allowed slugs (one small indexed query per turn; ETS caching is a
   later optimization if ever needed).
3. **No providers allowed at all** (fresh install, or synced but nothing
   reviewed yet) → fail open: `%{"data_collection" => "deny"}` with no
   `only`, plus a log and an admin banner ("no providers allowed — routing
   unrestricted"). Enforcement is opt-in for self-hosters and never bricks
   chat mid-rollout.
4. `only = allowed − model.denied_providers`. If the subtraction empties
   the list (admin denied every allowed provider for this model), that is
   admin misconfiguration: return `{:error, :no_allowed_providers}`, which
   Preflight surfaces as an error event on the conversation. `"only" => []`
   is never sent.
5. Otherwise → `%{"only" => only, "data_collection" => "deny"}`.

Sticky sessions (`openrouter_session_id`) are unaffected; the `only` list
is stable across turns, so OpenRouter's prompt cache stays warm.

`zdr` remains a possible future admin toggle; out of scope.

## Region code removal

The entire user-facing region system is deleted:

- **User resource**: drop `data_region_preference` and
  `data_region_consents` attributes (columns dropped — this is preference
  data for a removed feature), the `update_data_region_preference` and
  `grant_data_region_consent` actions, and their policies. Remove the
  matching code interfaces in `Magus.Accounts`.
- **Preflight**: remove the `model_available_for_user?` gate and
  `handle_region_unavailable`; remove region fields from the
  `load_user_for_limits` fallback map. `build_provider_routing(model)` is
  called with the new signature.
- **`Magus.Providers.Registry`**: deleted. `config :magus, :data_regions`
  (regions, providers map, `api_provider_regions`, `default_allowed`):
  deleted.
- **`Magus.Providers.Routing`**: keeps `build_provider_routing/1` plus two
  trivial shims so the classic workbench selector compiles untouched:
  `model_available_for_user?/2` → `true`, `missing_consent_regions/2` →
  `[]` (its consent modal simply never triggers). The shims die with the
  classic UI.
- **Legacy settings UI** (`settings_live.ex`): the data-region section is
  removed (mechanical deletion; the actions it calls no longer exist).
- **SPA**: remove the region block from the preferences page and the
  `updateDataRegionPreference` / `grantDataRegionConsent` bindings from
  `ash_rpc.ts`; regenerate types.

Users who had consented to CN/SG lose access to those origin providers;
their models remain available via allowed hosts. Acceptable and intended.

## Admin UI

- **New "OpenRouter Routing" admin LiveView** (distinct from the existing
  Providers page, which manages credential/BYOK providers): table of synced
  providers — name, slug, HQ, datacenters, `last_synced_at` — with an
  `allowed` toggle per row and the "Sync from OpenRouter" button. A banner
  states the current mode ("N providers allowed" / "no providers allowed —
  routing unrestricted").
- **Models admin** (`models_live`): a `denied_providers` editor per
  OpenRouter model (chip/tag input of slugs).

## Error handling

- Sync failure → flash error in admin, existing rows untouched.
- Misconfigured model (empty `only` after denies) → error event on the
  conversation naming the cause; fixable only by an admin, so the message
  says so.
- Unrestricted mode (nothing allowed) is logged at warning on each request
  build and shown in the admin banner — never silent.

## Testing

- Routing unit: `only` construction (global allowed − model denies);
  fail-open when nothing is allowed; `{:error, :no_allowed_providers}` on
  empty subtraction; `nil` for non-OpenRouter models; `"only" => []` never
  produced.
- Sync: stubbed providers payload (Req.Test) → upserts, metadata refresh,
  `allowed` preserved on resync, new providers default false, stale
  `last_synced_at` for missing rows.
- Seed migration: config-map US/EU/CH providers become `allowed: true`
  rows; models with legacy non-empty `allowed_providers` are logged.
- Preflight integration: `llm_opts[:openrouter_provider]` carries the map;
  no region gate remains; misconfiguration error event path.
- Removal regression: user actions compile/run without region attributes;
  classic selector renders via shims; SPA preferences page renders without
  the region block.
- Admin LiveView: structural `data-*` hooks and counts (table rows, toggle,
  sync button), no label/copy assertions.

## Out of scope / future

- Per-workspace allow-list override (build when tenant residency demand is
  real).
- `zdr` admin toggle.
- Per-model serving-provider sync (endpoints API), cost/latency routing
  (`sort`, `max_price`), region-variant slug targeting.
- Dropping `Model.allowed_providers` and the classic-UI shims (cloud /
  classic-removal follow-ups).
