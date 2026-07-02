# Phase 2b-2a: BYOK Vertical Slice (SPA UI + Execution Wiring)

Date: 2026-07-02
Status: Design (approved in discussion; pending spec review)
Predecessors: Phase 1 (curation, merged), Phase 2a (resolver keystone, merged), Phase 2b-1 (ownership backend foundation, merged to main at 2906236)
Successor: Phase 2b-2b (hard-stop + remediation, cloud paid-plan gate, clone/prefill, Model authorizer adoption, 2b-1 deferred-Minors cleanup)

## Context and Goal

Phase 2b-1 shipped the security-complete ownership backend: users can own providers (encrypted keys, server-generated slugs, SSRF-validated URLs, caps) and text models, the credential trust boundary in `RequestOptions.resolve/2` is fail-closed, owned rows never mint atoms, and resolution is actor-capable. Deliberately deferred: owned models cannot yet EXECUTE (all resolver/LLM-client call sites pass a nil actor), the credential probe is a stub returning `:error`, and there is no UI.

2b-2a is the vertical slice that makes BYOK real: a user adds a provider and a model in the SPA and can immediately chat with it end to end.

## Scope

**In scope:**
- **Execution wiring**: thread the acting user through the 5 resolver call sites and the LLM client so `RequestOptions.resolve/2` receives the owner and returns owned credentials.
- **Real credential probe**: replace `CredentialValidator.default_probe/1` with a per-provider models-list request; statuses stamped as today.
- **Remote model listing**: a rate-limited, owner-only `:list_remote_models` action reusing the probe to return upstream model ids for the picker.
- **RPC exposure**: `typescript_rpc` blocks for the 2b-1 owned actions plus the new ones; `AshTypescript.Resource` on Provider.
- **Provider destroy with cascade**: destroying an owned provider destroys its owned models first (FK is restrict).
- **SPA `/settings/providers` page**: provider CRUD, validation-status display, per-provider model add/delete with a probe-powered model-id picker.

**Out of scope (2b-2b):** hard-stop on degradation + one-click remediation, cloud paid-plan gate on provider creation, clone/prefill affordance, global `Model` authorizer adoption + reader audit, media BYOK (Phase 5), workspace sharing (Phase 3), billing attribution (2c), and the 2b-1 deferred-Minors list (stamp_validation policy tightening, owner_user_id index/FK, selection-test breadth, doc comment fixes).

## Locked Decisions

1. **Vertical slice.** UI and execution wiring ship together so the SPA never displays models that cannot run.
2. **Dedicated `/settings/providers` page.** BYOK management is its own settings page mirroring the `mcp-servers` page shape. `/settings/models` stays pure curation; owned models appear there and in the chat picker automatically via the existing actor-scoped `list_active`.
3. **Probe-powered model-id picker.** The add-model form offers upstream model ids fetched live via the credential probe (owner-only, rate-limited, never persisted), with free-text fallback. No separate LLMDB-suggestion path.
4. **Actor semantics carried from the 2b-1 spec's Execution Wiring table.** The actor is the acting user via `Magus.Agents.Plugins.Support.Helpers.acting_user_id/2` (message sender, falling back to the agent owner). Never assumed to be the conversation owner in multiplayer.
5. **Fail-closed multiplayer stays.** User B chatting in a conversation pinned to user A's owned model resolves against B, degrades to the inherited default for B's message, and never uses or spends A's key. Degradation remains soft in this slice.
6. **`api_key` is write-only by construction.** It is `sensitive?`/non-public and therefore never serializes through RPC; the UI shows only a "key set" indicator and accepts a replacement value.
7. **No new schema.** No migration is expected; everything builds on 2b-1 columns. (If codegen disagrees, that is a plan-time error to investigate, not silently accept.)

## Backend Design

### Execution wiring

The five resolver call sites (all passing `nil` today) get the acting user, per the 2b-1 table:

| Call site | Actor source |
|---|---|
| Preflight main (preflight.ex:78) | `acting_user_id(agent, message_id)` |
| Preflight resume (preflight.ex:175) | `acting_user_id/2` for the resumed message; fall back to agent owner |
| Preflight debug/assembly (preflight.ex:247) | agent owner (`agent.state.user_id`), no message in scope |
| Preflight (preflight.ex:286) | `acting_user_id/2` (plan verifies the exact context) |
| MediaBypass (media_bypass.ex:35) | `acting_user_id/2` |

`Resolver.resolve/2` widens its actor derivation to accept a bare id: `actor_id(%{id: id}) when is_binary(id)` gains a sibling clause `actor_id(id) when is_binary(id), do: id`. Call sites pass the `acting_user_id/2` result directly.

The same acting-user id then travels to the LLM client: the ReAct worker/signal opts carry `:credential_actor_id`, and `Clients.LLM.with_provider_options/2` (llm.ex:88) pops it from opts (`Keyword.pop/2`, so it never reaches ReqLLM) and calls `RequestOptions.resolve(model, actor_id)` instead of `resolve/1`. Absent id keeps today's arity-1 behavior (safe fallback). Tool paths that construct their own LLM calls without the opt simply keep global behavior; they are not audited in this slice because fail-closed means they degrade, never leak.

### Credential probe

`Magus.Models.CredentialValidator` keeps its seam (`config :magus, :credential_validator` override) and gains a real default:
- Per `req_llm_id`: OpenAI-style `GET {base_url}/models` with `Authorization: Bearer <key>` for `openai`, `openrouter`, `xai`, `openai_compatible` (base_url from the row or the provider default); Anthropic `GET /v1/models` with `x-api-key` + `anthropic-version`; Google's models list with its key convention.
- Req with a short timeout (~5s), no retries. Mapping: 2xx -> `:valid`; 401/403 -> `:invalid`; anything else (timeout, DNS, 5xx) -> `:error`.
- The probe function also returns the parsed model ids on success (`{:valid, [ids]} | :invalid | :error` internally; the worker stamps only the status atom as today).
- No secrets in logs; errors are logged by class, never with the key.

### Remote model listing (`:list_remote_models`)

A generic action (or domain-level function) on Provider, owner-only policy, that runs the probe live and returns `%{model_ids: [...], status: :ok | :unauthorized | :unavailable}`. Rate-limited the same way validation enqueues are bounded (per-provider window; a plain process-independent check on last call time or reuse of the Oban-unique window is decided in the plan). Results are never persisted; the SPA calls it when the add-model form opens and falls back to free text.

### Cascade destroy

`Provider.:destroy_owned` (new action): owner-only, destroys the provider's owned models first, then the provider, in one transaction. The existing FK (models -> model_providers, restrict) stays untouched; the cascade is app-level, mirroring the account-deletion ordering. The SPA confirm dialog lists the models that will be deleted.

### RPC exposure

- `Magus.Models` domain gets a `typescript_rpc` block: `list_owned_providers`, `create_owned_provider`, `update_owned_provider`, `destroy_owned_provider` (the new cascade action), `validate_provider_credential`, `list_remote_models`.
- `Magus.Chat` adds `create_owned_model`, `list_owned_models`, `destroy_owned_model` (destroy scoped to owned rows; the plan adds an owner-scoped destroy action on Model since Model has no authorizer, mirroring `BuildOwnedModel`'s in-change enforcement).
- Provider gets `extensions: [AshTypescript.Resource]` + `typescript do type_name "ModelProvider"; field_names enabled?: "enabled" end`. Exposed public fields only; `api_key` and `owner_user_id` stay non-public. `validation_status`/`last_validated_at` are public already.
- Regenerate `frontend/src/lib/ash/ash_rpc.ts` via `mix ash.codegen`; hand-written wrappers in the SPA's api layer follow the existing pattern.

## SPA Design (`frontend/src/routes/settings/providers/`)

One page, mirroring `settings/mcp-servers/+page.svelte`'s shape, decomposed into focused components:

- **Provider list**: cards showing name, provider type, "key set" indicator (never the key), validation-status badge (`pending | valid | invalid | error`) with a re-validate button (calls `validate_provider_credential`; status refreshes on poll or manual reload — no PubSub in this slice), and an enabled toggle.
- **Add/edit provider form**: provider-type select from the allowlist (`anthropic`, `openai`, `openrouter`, `xai`, `google`, `openai_compatible`), name, api_key (password input, placeholder "unchanged" on edit), base_url shown only for `openai_compatible`. Server-side Ash errors (allowlist, SSRF, cap) surface on their fields per the existing form pattern.
- **Models section per provider** (expandable): list of that provider's owned models with delete; **add-model form** with the probe-powered searchable model-id picker (calls `list_remote_models` on open; free-text input always available, mandatory when listing fails), display name, and optional context window / input+output costs.
- **Empty state** explaining BYOK and linking the docs.

Owned models appear in `/settings/models` curation and the chat model picker automatically (actor-scoped `list_active` from 2b-1); no picker changes are in scope.

## Testing

- **Execution wiring (the core regression)**: with a mocked LLM client, the owner sending a message in a conversation pinned to their owned model gets a request whose model spec is the rewritten `req_llm_id:model` form with the owner's key in opts; a NON-owner sender in the same conversation degrades to the default model and never receives the owned key. Actor-sourcing unit tests per call site where feasible.
- **Probe**: stubbed HTTP (Req.Test or the config seam) for 200/401/timeout across provider types; worker still stamps statuses; `list_remote_models` returns ids for the owner, refuses non-owners, respects the rate window.
- **Cascade destroy**: provider with models destroys cleanly; non-owner refused.
- **RPC**: policy tests that a non-owner sees/creates/destroys nothing through the exposed actions.
- **SPA**: vitest for pure logic (form mapping, picker filtering); structural `data-*` assertions for page rendering per the no-brittle-UI-tests rule; no label/copy assertions.

## Risks and Limitations

- **Actor threading breadth**: the signal-opts path from plugin to LLM client crosses the Jido strategy; the plan maps the exact hop points before implementation (this was deliberately deferred out of 2b-1 for being deep plumbing). If a hop cannot carry the id cleanly, fail-closed means the feature degrades (owned model silently falls back) rather than leaks; the wiring test catches it.
- **Probe variance across providers**: Google's listing API differs most; if it proves awkward, `google` ships with probe-only validation and free-text model entry (picker degraded), which the design already tolerates.
- **Validation status freshness** in the UI is poll/reload-based in this slice; no live PubSub.
- **origin/main does not contain 2b-1** at the time of writing (merged locally only); this branch is based on local main. Pushing main is a prerequisite for any PR-based flow on this phase.
