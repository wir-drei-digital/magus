# Phase 2b-2b: Hard-Stop, Cloud Gate, Clone/Prefill + Write Guards

Date: 2026-07-02
Status: Design (approved in discussion; pending spec review)
Predecessors: Phase 2b-1 (ownership backend) and 2b-2a (BYOK vertical slice, PR #9), both merged to main.
Related: full Model authorizer adoption + reader audit deliberately deferred to Phase 3 (workspace sharing), where resource-level policies become structurally required.

## Context and Goal

BYOK text chat is live: users create providers/models in the SPA and chat on their own keys, fail-closed everywhere. Three product gaps remain from the 2b deferrals, plus two cheap hardening guards that replace the previously planned (and rejected as premature) global Model authorizer audit.

## Scope

**In scope:**
1. **Degradation hard-stop + one-click remediation** (flips the 2a/2b-1 soft-degradation policy at the callers).
2. **Cloud paid-plan gate** on provider creation/key-update (seam module; open-core unaffected).
3. **Clone/prefill affordance** (SPA-only "use as template" from catalog models).
4. **Model write policy floor** (authorizer with reads-open, writes-gated).
5. **RPC-surface pin test** (CI-fails if Model/Provider RPC exposure drifts).

**Out of scope:** full Model authorizer + reader audit (Phase 3), media BYOK (Phase 5), billing attribution (2c), workspace sharing (Phase 3), background-ops BYOK (Phase 4 preference + 2c cost policy).

## Design

### 1. Hard-stop + remediation

`Magus.Models.Resolver` stays total and unchanged. The policy flips at its two caller modules:
- After resolution, if `Magus.Models.Resolution.degraded?/1` is true (an explicit selection, by id or key, resolved to something else), `Preflight` (and `MediaBypass`) BLOCK the turn before any LLM call, exactly like the existing usage-limit pre-flight errors (same error/event rails, same PubSub surface).
- The error event carries a machine-readable payload: `%{kind: :broken_model_selection, requested: %{by: :id | :key, value: ...}, resolved_fallback_key: ..., scope: :conversation | :user}`. Scope reflects which selection sourced the broken value (conversation `selected_model_id` vs user default), derived from the same precedence `ModelKeyResolver` used.
- SPA remediation: the chat error event renders a **"Reset to default and retry"** action. One click clears the broken selection via the EXISTING RPC (`set_conversation_model` / `select_model` with nil, whose nil-clear path is already validated) and re-sends the blocked message. No new backend action.
- Multiplayer stays sender-scoped: user B blocked on A's pinned model gets the error; B may reset the conversation selection (member permission rules unchanged) or pick another model.
- `:auto` and unselected paths never "degrade" (no `requested_selection`), so routing and defaults are untouched. The 2a telemetry event stays as-is.

### 2. Cloud paid-plan gate

- New seam: `Magus.Models.ProviderGate` with `can_create?(user) :: :ok | {:error, reason}` resolved via config (`config :magus, :provider_gate, Module`), default open-core impl returns `:ok` always. Mirrors the `BillingStatusProvider` seam pattern.
- Wired as a validation on `Provider.:create_owned` and on `:update_owned` WHEN `api_key` or `base_url` changes (metadata edits stay free).
- Cloud impl (in the cloud repo): `:ok` iff subscription is billable AND status in `[:active, :trialing]`. Free users get `{:error, :paid_plan_required}`.
- Lapse never disables existing providers/models: BYOK runs on the user's key; no billing check enters the resolution hot path.
- SPA: the providers page maps `paid_plan_required` to an upgrade CTA state on the create form.

### 3. Clone/prefill ("use as template")

SPA-only, snapshot semantics, no backend change:
- Catalog (non-owned) models in the curation/catalog list get a "use as template" action.
- It opens `/settings/providers` with the create-model form prefilled: display name, model id (the key suffix after the provider slug), context window, input/output cost values.
- The user picks a compatible owned provider as the target; with none, the UI prompts provider creation first (prefill preserved across that step via the page store/query params).
- No linkage or auto-tracking; edits after prefill are free.

### 4. Model write policy floor

`Magus.Chat.Model` adopts `Ash.Policy.Authorizer` with reads explicitly OPEN and writes gated:
- `policy action_type(:read) do authorize_if always() end` (owned-row scoping stays where it lives today: the `list_active` prepare, the `:owned` action filter, selection validations, fail-closed runtime).
- `policy action([:create_owned, :destroy_owned]) do authorize_if always() end` (their changes `BuildOwnedModel`/`RequireOwner` already enforce actor + ownership; policy AND-combination rule: exactly one policy matches each).
- `policy action_type([:create, :update, :destroy]) do authorize_if Magus.Checks.IsAdmin end` gates the admin actions. NOTE the AND-combination hazard: `action_type(:create)` also matches `:create_owned`, and `action_type(:destroy)` matches `:destroy_owned`; the plan must use `action(:create)` / `action(:update)` / `action(:destroy)` (or exclusion) so owned actions match exactly one policy.
- Audit scope: WRITERS only (~seeds, admin surfaces, tests that create/update models without an admin actor or `authorize?: false`). Known from the 2b-1 attempt: `catalog_sync_test` and sibling test setups create models actor-lessly and will need `authorize?: false` added; production seeding paths already use it or run as admin. Readers are untouched by construction.

### 5. RPC-surface pin test

A test that introspects the `typescript_rpc` DSL (Spark info on the Magus.Chat and Magus.Models domains) and asserts the exposed action sets for `Magus.Chat.Model` and `Magus.Models.Provider` equal the exact expected allowlists (Model: list_active, image/video lists, create_owned, owned, destroy_owned; Provider: owned, create_owned, update_owned, destroy_owned, validate, list_remote_models). A future PR exposing e.g. Model `:update` over RPC fails CI with a message pointing at this spec.

## Testing

- Hard-stop: owner with a deleted/invisible explicit model is blocked pre-flight with the correct payload (scope conversation vs user); remediation nil-clear + re-send works; `:auto` and unselected paths unaffected; multiplayer sender-B case blocked with B-scoped remediation; no LLM call and no usage row on block.
- Gate: open-core default allows; a deny-stub (config swap) blocks create and key-update but not name edits; SPA maps the error.
- Write floor: non-admin direct `:create`/`:update`/`:destroy` refused; `create_owned`/`destroy_owned` unchanged; full models/chat suites green after the writer audit.
- Pin test: fails when a disallowed rpc_action is added (self-test by construction), passes on current surface.
- Frontend: pure-logic vitest for prefill mapping + remediation payload handling; structural testids.

## Risks

- The hard-stop touches the highest-traffic path (every turn). Mitigation: the block condition is exactly `degraded?/1` (already telemetered since 2a; production telemetry shows the base rate), and `:auto`/unselected paths cannot trigger it.
- Write floor breaks actor-less test writers found in the 2b-1 attempt; bounded, test-only churn.
- Re-send after remediation must not double-persist the user message; reuse the SPA's existing retry path if one exists, else send a fresh message with the same content (plan verifies which).
