# OpenRouter Provider Routing — Design

Date: 2026-07-02
Status: Approved

## Problem

OpenRouter serves each model through many upstream providers whose datacenters
sit in different jurisdictions. Magus already filters providers by user data
region, but the implementation is inaccurate and stale:

- `config :magus, :data_regions` hand-assigns each provider slug exactly one
  region. Real providers run datacenters in several countries; the map goes
  stale as OpenRouter adds providers, and unknown slugs are silently excluded.
- `Model.allowed_providers` (the per-model serving-provider list) is
  hand-curated at catalog import and has no admin UI.
- An empty `allowed_providers` disables region enforcement entirely, while an
  empty intersection sends `"only" => []` to OpenRouter, which fails the
  request instead of producing a clean user-facing error.

This feature applies to OpenRouter models only (`api_provider == :openrouter`).
BYOK and native providers (xai, publicai, aimlapi, fal) are out of scope; the
small `api_provider_regions` config remains for their availability display.

## Verified OpenRouter API facts

- `GET /api/v1/providers` (public): per provider `name`, `slug`,
  `headquarters` (ISO 3166-1 alpha-2), `datacenters` (array of ISO codes),
  privacy/terms/status URLs.
- `GET /api/v1/models/:author/:slug/endpoints` (public): which providers serve
  a model (`provider_name` display name, status, pricing, uptime,
  quantization, variant `tag`). No per-endpoint location.
- Chat-completion `provider` object: `order`, `only`, `ignore`,
  `allow_fallbacks`, `require_parameters`, `data_collection`, `zdr`,
  `quantizations`, `sort`, `max_price`, latency/throughput preferences.
  **No native region filter** (EU in-region routing is enterprise-only), so
  region enforcement stays our job: translate regions into an `only` slug list.

## Decisions

| Decision | Choice |
|---|---|
| Control model | Admin curates per model (deny-list); users keep region preferences |
| Region matching | **Strict**: a provider is eligible only if every datacenter country falls in the user's enabled regions |
| Data maintenance | Auto-sync from OpenRouter + admin deny-list; all serving providers allowed by default |
| Region taxonomy | Coarse buckets `US / EU / CH / CN / SG` + consent-gated `OTHER` |
| `data_collection` | Stays `"deny"` always |
| `zdr` | Future user toggle, out of scope |

Strict matching is the only interpretation that makes "EU only" a residency
guarantee, since requests cannot be pinned to one datacenter of a
multi-region provider. Example consequence: for an EU-only user, the
`deepseek` provider (CN datacenters) is excluded while EU providers serving
the same DeepSeek model stay eligible; a provider with both US and EU
datacenters requires both buckets enabled.

## Data model

### New resource: `Magus.Providers.OpenRouterProvider`

New small Ash domain `Magus.Providers`; the existing `lib/magus/providers/`
modules (`Routing`, `Registry`) join it.

| Attribute | Type | Notes |
|---|---|---|
| `slug` | string | unique identity |
| `name` | string | display name; also used for endpoint name→slug mapping |
| `headquarters` | string, nullable | ISO country code |
| `datacenters` | {array, string}, default [] | ISO country codes |
| `regions` | {array, string} | bucket codes, materialized at sync time |
| `privacy_policy_url` / `terms_of_service_url` / `status_page_url` | string, nullable | |
| `disabled` | boolean, default false | admin global kill-switch |
| `last_synced_at` | utc_datetime | staleness display |

Providers that disappear from the OpenRouter list keep their rows (last-known
data keeps serving) and simply stop being refreshed.

### Model changes (OpenRouter models only)

- `openrouter_providers` ({array, string}, default []): serving-provider
  slugs synced from the endpoints API. Not hand-edited.
- `denied_providers` ({array, string}, default []): admin deny-list.
- `providers_synced_at` (utc_datetime, nullable).
- `allowed_providers` is **deprecated**: a data migration copies its values
  into `openrouter_providers` so routing behaves identically before the first
  sync; catalog import mirrors `allowed_providers` into
  `openrouter_providers` for the same reason. Dropping the column is a cloud
  follow-up (the commercial catalog seeds it).

### Country→bucket mapping: `Magus.Providers.Regions`

Static module (geography is stable, unlike provider lists):

- `US` — United States.
- `EU` — EU/EEA member states + UK (existing user-facing label is "Europe").
- `CH` — Switzerland.
- `CN` — China, including HK.
- `SG` — Singapore.
- `OTHER` — every other country (JP, KR, CA, AE, ...). Consent-gated like
  CN/SG.

A provider with no datacenter data maps to `OTHER`: unknown jurisdiction is
treated as unconsented (strict stance).

Bucket definitions (labels, `requires_consent`, `default_allowed`) stay in
`config :magus, :data_regions`; the hand-maintained `providers:` slug→region
map is deleted. `api_provider_regions` (non-OpenRouter providers) survives.

## Sync

Plain Oban cron workers — the same documented exception as the Super Brain
extraction enqueues: a global API fetch does not map to a per-resource
AshOban trigger.

- **`SyncProviders`**: fetch `GET /api/v1/providers`, upsert
  `OpenRouterProvider` rows, derive `regions` from `datacenters`.
- **`SyncModelEndpoints`**: for each active OpenRouter model, fetch
  `GET /models/:author/:slug/endpoints`; set `openrouter_providers` to the
  serving providers' slugs. The endpoints API returns display names
  ("Google Vertex"), mapped name→slug via the synced provider rows; unmatched
  names are slugified and logged. A 404 (key unknown to OpenRouter) sets an
  empty list; the "unsynced" admin state is derived, not stored:
  `providers_synced_at` present with empty `openrouter_providers`. All serving providers are included
  regardless of transient endpoint status (OpenRouter handles fallback).

Triggers: daily cron; boot-time run when the provider table is empty; inline
enqueue (after_action) when an OpenRouter model is imported or created;
"Sync now" buttons in admin. Volume is one request per model plus one for the
provider list — modest concurrency, no rate-limit concerns at daily cadence.
Both endpoints are public, so OSS self-hosts need no extra credentials.

## Routing & enforcement

`Magus.Providers.Routing.build_provider_routing(model, user)` keeps its seam
(Preflight merges the result into `llm_opts[:openrouter_provider]`), with new
logic:

1. Non-OpenRouter model → `nil` (unchanged).
2. Base set = `openrouter_providers` − `denied_providers` − globally
   `disabled` providers.
3. **Unsynced fallback**: if the base set is empty (sync never ran, or 404),
   or the entire provider table is empty (fresh deploy before first sync),
   return `%{"data_collection" => "deny"}` with no `only`, log loudly, and
   surface an "unsynced" flag in admin. Transient by design (boot- and
   import-time sync); a deploy never bricks chat.
4. **Strict eligibility**: keep providers whose entire `regions` set is a
   subset of the user's enabled buckets. A slug with no provider row counts
   as `OTHER`.
5. Non-empty eligible set → `%{"only" => eligible, "data_collection" =>
   "deny"}`. Empty → `{:error, :no_eligible_providers}`, which Preflight
   turns into the existing `region_unavailable` block. This removes the
   `"only" => []` bug and keeps availability and routing from drifting apart.

Derived API (names stay compatible so the classic workbench selector keeps
working untouched):

- `model_available_for_user?/2` → "is the eligible set non-empty" (with the
  unsynced fallback counting as available).
- `missing_consent_regions/2` → consent-gated buckets present in the model's
  serving providers' region sets that the user has not consented to (UI hint
  semantics unchanged).
- `Magus.Providers.Registry` becomes a DB-backed lookup (one indexed query
  per turn; caching is a later optimization if ever needed).

Sticky sessions (`openrouter_session_id`) are unaffected: the `only` list is
stable per user+model, so OpenRouter's prompt cache stays warm.

## UI surfaces

**Admin (LiveView `/admin`):**

- New "Routing" page (distinct from the existing Providers page, which
  manages credential/BYOK providers): table of synced OpenRouter providers —
  slug, name, HQ, datacenters, buckets, `last_synced_at` — with per-provider
  global disable toggle and "Sync providers now".
- Models admin: per-model section listing synced serving providers as chips
  with deny toggles (writes `denied_providers`), `providers_synced_at`,
  per-model "Resync", and an "unsynced" warning badge.

**User settings (SPA preferences page):** unchanged UX plus a consent-gated
"Other regions" toggle using the existing consent-modal pattern. The static
`DATA_REGIONS` list in the frontend stays (it now mirrors stable bucket
definitions, not a churning provider map).

**SPA model picker:** expose per-model availability (available + missing
consent buckets) as actor-aware calculations on `Model`, loaded by the
existing model-listing RPC and regenerated into `ash_rpc.ts`. The picker
badges/greys excluded models and shows the consent hint. Preflight remains
the enforcement backstop; this is progressive disclosure only.

**Classic workbench:** untouched (SPA-replaces-workbench rule); it keeps
working through the compatible `Routing`/`Registry` function surface.

## Error handling

- Sync failures retry via Oban backoff; last-known data keeps serving.
  Staleness is visible in admin via the synced-at timestamps.
- Endpoint 404 → empty `openrouter_providers`, admin flag, unsynced fallback.
- Region-unavailable error copy names the buckets that would unlock the model
  (model's provider buckets minus the user's enabled ones) instead of the
  current generic message.
- Name→slug mapping misses during endpoint sync are logged with the raw name.

## Testing

- Unit: country→bucket mapping (EU/EEA+UK list, HK→CN, unknown→OTHER);
  strict eligibility (mixed US+EU provider excluded for an EU-only user);
  deny-list and global-disable precedence; unsynced/empty-table fallbacks;
  `build_provider_routing` output shapes including the error tuple;
  consent-hint logic.
- Sync workers: stubbed OpenRouter responses (Req.Test) covering upserts,
  region derivation, name→slug mapping, 404 handling, and the boot-time
  empty-table trigger.
- Preflight integration: `region_unavailable` block on an empty eligible
  set; `llm_opts[:openrouter_provider]` carries the expected map end-to-end.
- Admin LiveView: structural `data-*` hooks and counts, no label/copy
  assertions.
- Migration: `allowed_providers` → `openrouter_providers` copy preserves
  routing behavior pre-first-sync.

## Out of scope / future

- `zdr` (zero data retention) as a user toggle.
- Endpoint-level modeling (pricing/uptime/variant rows) and region-suffixed
  variant targeting (`google-vertex/europe` style) for mixed-region
  providers.
- Cost/latency-aware routing (`sort`, `max_price`,
  `preferred_min_throughput`).
- User-level provider allow/deny (beyond region preferences).
- Dropping `Model.allowed_providers` (cloud catalog follow-up).
