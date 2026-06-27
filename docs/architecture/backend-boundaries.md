# Backend boundaries

This document defines the structural rules for `lib/magus`: how domains depend on
each other, when to call Ash directly, how authorization bypasses are allowed,
how side effects relate to the database, and the adapter/module conventions that
keep the codebase navigable for outside contributors.

It complements, and does not repeat, the micro-conventions already in
[`CLAUDE.md`](../../CLAUDE.md) (Ash code interfaces, custom changes, actor usage,
LiveView streams/forms). Where CLAUDE.md says how to write one resource, this doc
says how the pieces fit together.

Some rules below are **established** (already the norm, hold the line) and some
are **target** (the direction the largest orchestration areas should be refactored
into). Each section notes which, and links the tracking issue. Migrate the worst
offenders first; see the `magus-03x8` audit epic.

---

## Scope: the classic workbench is frozen

The classic workbench (`lib/magus_web/workbench/` and `lib/magus_web/legacy/`) is
legacy LiveView UI being replaced by the SPA (`frontend/`). The goal is to move to
the SPA as quickly as possible, so **do not refactor workbench LiveViews to satisfy
these rules**: restructuring code that is about to be deleted is wasted effort.

The rules below apply to backend and shared code (`lib/magus/...`), the API surface
the SPA consumes (`lib/magus_web/api/...`), and any new web code. Where a rule names
a workbench offender (the direct `Ash.*` calls in §2, oversized modules like
`conversation_view.ex` in §8, the remaining `Task.start` sites in §5), it is listed
for completeness only and is **out of scope** while the workbench is frozen.

---

## 1. Domains are the boundary

Each Ash domain (Accounts, Chat, Files, Brain, Agents, Sandbox, Super Brain, ...)
is a bounded context. Treat the domain module as its public surface.

- **Do** depend on another domain only through its public code interface
  (`Magus.Files.create_file/2`, `Magus.Chat.delete_full_conversation/2`) or an
  explicit workflow module.
- **Do not** reach into another domain's resources, changes, or private helpers
  from outside that domain's folder.
- Cross-domain orchestration lives in an explicit, named workflow module, not
  hidden inside a resource change or a LiveView.

Status: **established** in principle (CLAUDE.md), unevenly enforced in practice.

## 2. Calling Ash: code interface vs. direct `Ash.*`

The line is the resource boundary, not "is it convenient".

- **Inside** a resource module and its own `changes/`, `actions/`,
  `calculations/`, `preparations/`: direct `Ash.read/load/update/bulk_*` is fine.
  You are inside the boundary and own the query policy.
- **Outside** (web, controllers, Oban workers, other domains, shared helpers):
  call the domain's code interface, not `Ash.*` directly. The interface is where
  authorization and query conventions are pinned.

Current state: roughly 90 direct `Ash.*` call sites under `lib/magus_web`
(`magus-dg2k`) and ~237 more elsewhere in `lib/magus` outside resource modules.
Most of the `lib/magus_web` sites are in the frozen workbench and are out of scope
(see Scope): the migration target is the API surface the SPA consumes and any new
web code. Do not rewrite in one pass; convert opportunistically when you touch an
in-scope file, and never add new direct calls outside a resource.

Status: **target**. Tracking: `magus-dg2k`.

## 3. Authorization and the system actor

- **Default**: pass a real actor (a user). Do not reach for `authorize?: false`
  in application code. (CLAUDE.md.)
- **AI operations** already have a non-user actor: `%Magus.Agents.Support.AiAgent{}`,
  with `ai_actor()` used in policy expressions. Use it instead of bypassing.
- `authorize?: false` is a privilege bypass. It is allowed only when it is one of:
  1. inside a resource action/change (you are the boundary), or
  2. inside an explicitly internal workflow/worker module whose job is system
     work, or
  3. annotated with a one-line reason comment.

There are ~566 `authorize?: false` sites across ~229 files today, many outside
those three cases. The target is a single internal **system actor** pathway
(analogous to `AiAgent`) so every bypass is greppable, attributable, and
reviewable, plus an audit of the existing sites against this policy.

Status: **target**. Tracking: `magus-0873`.

## 4. Side-effect lifecycle

External effects (storage writes, remote provider calls, emails) must not be
entangled with a DB transaction in a way that can orphan state. Follow the
lifecycle:

> validate intent -> create/track the DB record -> perform the external effect
> -> compensate on failure, **or** perform the effect only after the DB commits
> via a durable job.

- **Do not** make remote calls, retries, or `Process.sleep/1` inside a
  `before_action`/destroy transaction.
- **Do** compensate when a side effect precedes a DB write that can fail.
- **Do** capture what an out-of-band job needs before the row is gone, and
  enqueue it transactionally so it runs only if the change commits.

Exemplars in the tree:

- Compensate-on-failure: [`lib/magus/files/upload.ex`](../../lib/magus/files/upload.ex)
  deletes the stored bytes if `create_file` is rejected.
- Durable post-commit cleanup:
  [`lib/magus/sandbox/workers/destroy_remote_sandbox.ex`](../../lib/magus/sandbox/workers/destroy_remote_sandbox.ex),
  enqueued transactionally from the conversation delete (no remote calls in the
  delete transaction).
- Persist the truth: `Magus.Files.Storage.backend_name/0` stamps the configured
  backend so deletes route to where the bytes actually went.

Status: **partly established** (the above shipped). Formalizing `Magus.Files` as
the reference lifecycle is **target**. Tracking: `magus-35i7`.

## 5. Background work and supervision

No raw `Task.start/1` in request, UI, or worker paths. Choose:

- **Oban** (`ash_oban` triggers on resources) for durable, retryable work.
- **`Task.Supervisor.start_child`** under a named supervisor for fire-and-forget.
  Existing supervisors live in
  [`lib/magus/application.ex`](../../lib/magus/application.ex):
  `Magus.AgentLoopTaskSupervisor` (general purpose),
  `Magus.Integrations.WebhookTaskSupervisor`, `Magus.Knowledge.SyncTaskSupervisor`.
- **`start_async`** for LiveView-scoped async whose result returns to the view.

Documented exception: the Super Brain extraction enqueues use `after_action`
`Oban.insert/1` directly rather than `ash_oban` triggers (see CLAUDE.md and the
iteration-2 design note).

Status: **established** for backend/API paths (`magus-ce6j`). Classic-workbench
LiveView call sites are intentionally left for the SPA migration.

## 6. External payload normalization

Normalize external payloads (LLM tool arguments, webhook bodies, decoded JSON) to
one key shape at the entry boundary. Do not check atom-or-string per field
downstream.

- Prefer **string** keys at the boundary. Never `String.to_atom/1` on untrusted
  input (atom-table exhaustion).
- Exemplar:
  [`lib/magus/agents/actions/extract_turn_memories.ex`](../../lib/magus/agents/actions/extract_turn_memories.ex)
  `run/2` normalizes once with `normalize_keys/1`.

There are ~184 `params[:k] || params["k"]`-style sites in `lib/magus` today. They
need this single convention applied per boundary, not a blind sweep.

Status: **target**. Tracking: `magus-t1dx`.

## 7. Adapters and capability gating

External-provider integrations sit behind a behaviour with a default
implementation and a config-selected provider. This is what lets the cloud or
enterprise build swap an implementation without forking the caller.

- The **behaviour**, the **default implementation**, and any **cloud/enterprise
  override** each live in their own file.
- Gate optional capabilities by a `configured?/0` so a self-host instance without
  a key never offers a dead tool.

Exemplars:

- Behaviours: `Magus.Agents.Clients.{LLM,VideoGen,ImageGen}Behaviour` (contract)
  next to their default `*` implementations, each in its own file.
- Gating: `Magus.Capabilities.Search.configured?/0`,
  `Magus.Sandbox.Provider.configured?/0`, applied in
  [`lib/magus/agents/tools/tool_builder.ex`](../../lib/magus/agents/tools/tool_builder.ex)
  so web/sandbox tools drop out when their provider is absent.

Status: **established** as a pattern (`magus-22j8` split the behaviours out).

## 8. Module and file conventions

- **One module per file.** Co-locate a small private struct or behaviour only when
  it is genuinely idiomatic. (`magus-22j8`.)
- **Resources describe the model and action surface.** Non-trivial behavior moves
  into named modules under `<domain>/<resource>/{changes,actions,calculations,
  preparations}/`, not inline anonymous functions or fat action bodies.
  (`magus-j33k`.)
- **Size is a signal.** When a module passes ~800-1000 lines it is usually doing
  several jobs. Split along stable seams: client adapter, normalization,
  planning, persistence, retry/compensation, public API. (`magus-u33k`,
  `magus-897q`, `magus-gcnk`, `magus-ug16`.) Workbench LiveViews (such as the
  2435-line `conversation_view.ex`) are exempt: they are frozen pending the SPA
  migration (see Scope), so do not split them.

Status: **target** for the oversized modules; **established** as the rule for new
code.

## 9. Enforcement and evolution

- `test/magus/open_core_boundary_test.exs` guards open-core/cloud leakage.
- `mix compile --warnings-as-errors` is a CI gate (keep it green).
- `mix credo --strict` surfaces atom/string access, nesting, and complexity.

This document is the source of truth for backend structure. When a convention
changes, update this file in the same change. New code is held to the **target**
rules now; existing offenders are migrated worst-first under the `magus-03x8`
epic, and the five structural refactors (`897q`, `gcnk`, `ug16`, `j33k`, `dg2k`)
are gated on this document existing.
