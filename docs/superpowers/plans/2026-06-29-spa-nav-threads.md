# SPA Nav Threads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a conversation's threads as an always-visible nested sub-list under their parent in the SPA conversation nav, with click-to-open (as a thread companion) and delete-on-hover, matching the classic workbench.

**Architecture:** Expose the existing batch `threads_for_conversations` read action as an RPC; load all visible conversations' threads in one call into the workbench store, grouped by parent; render them in the shared `conversationRow` snippet; open a thread by navigating to its parent conversation and setting the existing `{ type: 'thread' }` companion (via a `pending-companion` hand-off for the not-yet-mounted case); delete via the existing `archive_conversation` (`:soft_delete`) RPC.

**Tech Stack:** Elixir/Ash (AshTypescript RPC), SvelteKit 2 / Svelte 5 runes, TypeScript, Vitest, shadcn-svelte Sidebar components, `@lucide/svelte` icons.

## Global Constraints

- **SPA only.** Do not modify the classic LiveView workbench (`lib/magus_web/workbench/**`). The only Elixir change allowed is the one RPC line in `lib/magus/chat/chat.ex`.
- **No new migrations, no new Ash actions.** The batch read action and code interface already exist.
- **No em dashes** in code comments or copy (use colons/periods/commas).
- **Codegen caution:** `mix ash_typescript.codegen` compiles the project. Do NOT run it while a Tidewave/`mix phx.server` dev server is running (it can wedge the code reloader). Stop the dev server first or run when it is not active.
- **Warnings as errors:** before considering Elixir work done, the project must compile clean. There is only a one-line Elixir change here, but if you touch anything else, run `MIX_ENV=test mix compile --warnings-as-errors`.
- **Frontend tests** are pure-logic Vitest unit tests (`*.test.ts`). There are no Svelte component tests for the shell; do not introduce a component-testing harness. Test extracted pure functions.
- Run frontend commands from `frontend/`. Test command: `npm test` (Vitest). Type/lint: `npm run check`.

---

### Task 1: Expose the batch threads RPC + regenerate the TS client

**Files:**
- Modify: `lib/magus/chat/chat.ex` (the `Conversation` RPC block, around line 36)
- Generated (do not hand-edit): `frontend/src/lib/ash/ash_rpc.ts`

**Interfaces:**
- Consumes: existing read action `threads_for_conversations` (arg `conversation_ids :: {:array, :uuid}`) and code interface `Magus.Chat.threads_for_conversations/1`.
- Produces: generated RPC function `rpc.conversationsThreads({ input: { conversationIds }, fields })` and field type `rpc.ConversationsThreadsFields` in `ash_rpc.ts`.

- [ ] **Step 1: Add the RPC action line**

In `lib/magus/chat/chat.ex`, directly below the existing singular thread RPC (line 36):

```elixir
      rpc_action :conversation_threads, :threads_for_conversation
      rpc_action :conversations_threads, :threads_for_conversations
```

(Add only the second line; the first already exists. Keep them adjacent.)

- [ ] **Step 2: Verify no dev server is running, then regenerate the client**

Confirm `mix phx.server` / Tidewave is not running (see Global Constraints). Then from the repo root:

Run: `mix ash_typescript.codegen`
Expected: writes `frontend/src/lib/ash/ash_rpc.ts`; `git diff --stat` shows that file changed.

- [ ] **Step 3: Confirm the generated function exists**

Run: `grep -n "conversationsThreads\|ConversationsThreadsFields" frontend/src/lib/ash/ash_rpc.ts`
Expected: matches for both the function and the fields type.

- [ ] **Step 4: Commit**

```bash
git add lib/magus/chat/chat.ex frontend/src/lib/ash/ash_rpc.ts
git commit -m "feat(chat): expose batch conversation-threads RPC for SPA nav"
```

---

### Task 2: `groupThreadsByParent` pure helper + type

**Files:**
- Modify: `frontend/src/lib/ash/api.ts` (add `ThreadNavSummary` type + `conversationsThreads` wrapper)
- Create: `frontend/src/lib/chat/thread-nav.ts`
- Test: `frontend/src/lib/chat/thread-nav.test.ts`

**Interfaces:**
- Consumes: `rpc.conversationsThreads`, `rpc.ConversationsThreadsFields` (Task 1); `run<T>()` and `RpcResult<T>` from `api.ts`.
- Produces:
  - `export type ThreadNavSummary = { id: string; title: string | null; parentConversationId: string | null; insertedAt: string; messageCount: number }`
  - `export function conversationsThreads(conversationIds: string[]): Promise<RpcResult<ThreadNavSummary[]>>`
  - `export function groupThreadsByParent(threads: ThreadNavSummary[]): Map<string, ThreadNavSummary[]>`

- [ ] **Step 1: Add the type and RPC wrapper in `api.ts`**

In `frontend/src/lib/ash/api.ts`, in the `// ─── Threads ───` section (after the existing `conversationThreads` wrapper, ~line 2086):

```ts
export type ThreadNavSummary = {
	id: string;
	title: string | null;
	parentConversationId: string | null;
	insertedAt: string;
	messageCount: number;
};

const THREAD_NAV_FIELDS: rpc.ConversationsThreadsFields = [
	'id',
	'title',
	'parentConversationId',
	'insertedAt',
	'messageCount'
];

/** Threads for many parent conversations, oldest first, grouped by the caller. */
export function conversationsThreads(
	conversationIds: string[]
): Promise<RpcResult<ThreadNavSummary[]>> {
	if (conversationIds.length === 0) return Promise.resolve({ success: true, data: [] });
	return run((opts) =>
		rpc.conversationsThreads({
			input: { conversationIds },
			fields: THREAD_NAV_FIELDS,
			...opts
		})
	);
}
```

If `rpc.ConversationsThreadsFields` does not accept `'parentConversationId'`, re-check Task 1's codegen output; the field name must match the generated camelCase attribute.

- [ ] **Step 2: Write the failing test for the grouping helper**

Create `frontend/src/lib/chat/thread-nav.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { groupThreadsByParent } from './thread-nav';
import type { ThreadNavSummary } from '$lib/ash/api';

function thread(overrides: Partial<ThreadNavSummary>): ThreadNavSummary {
	return {
		id: crypto.randomUUID(),
		title: 'Thread',
		parentConversationId: 'parent-1',
		insertedAt: '2026-06-29T08:00:00Z',
		messageCount: 0,
		...overrides
	};
}

describe('groupThreadsByParent', () => {
	it('returns an empty map for no threads', () => {
		expect(groupThreadsByParent([]).size).toBe(0);
	});

	it('groups threads under their parent conversation id', () => {
		const a = thread({ parentConversationId: 'p1' });
		const b = thread({ parentConversationId: 'p1' });
		const c = thread({ parentConversationId: 'p2' });
		const map = groupThreadsByParent([a, b, c]);
		expect(map.get('p1')).toEqual([a, b]);
		expect(map.get('p2')).toEqual([c]);
	});

	it('preserves input order within a parent', () => {
		const first = thread({ id: 'first', parentConversationId: 'p1' });
		const second = thread({ id: 'second', parentConversationId: 'p1' });
		const map = groupThreadsByParent([first, second]);
		expect(map.get('p1')?.map((t) => t.id)).toEqual(['first', 'second']);
	});

	it('skips threads with a null parent', () => {
		const map = groupThreadsByParent([thread({ parentConversationId: null })]);
		expect(map.size).toBe(0);
	});
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd frontend && npx vitest run src/lib/chat/thread-nav.test.ts`
Expected: FAIL — cannot resolve `./thread-nav` / `groupThreadsByParent` is not a function.

- [ ] **Step 4: Implement the helper**

Create `frontend/src/lib/chat/thread-nav.ts`:

```ts
import type { ThreadNavSummary } from '$lib/ash/api';

/**
 * Groups nav threads under their parent conversation id, preserving the
 * backend's oldest-first order. Threads without a parent (should not happen for
 * real threads) are skipped.
 */
export function groupThreadsByParent(
	threads: ThreadNavSummary[]
): Map<string, ThreadNavSummary[]> {
	const map = new Map<string, ThreadNavSummary[]>();
	for (const thread of threads) {
		if (!thread.parentConversationId) continue;
		const list = map.get(thread.parentConversationId);
		if (list) list.push(thread);
		else map.set(thread.parentConversationId, [thread]);
	}
	return map;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd frontend && npx vitest run src/lib/chat/thread-nav.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/ash/api.ts frontend/src/lib/chat/thread-nav.ts frontend/src/lib/chat/thread-nav.test.ts
git commit -m "feat(spa): batch nav-threads RPC wrapper + groupThreadsByParent helper"
```

---

### Task 3: `pending-companion` hand-off module

**Files:**
- Create: `frontend/src/lib/chat/pending-companion.ts`
- Test: `frontend/src/lib/chat/pending-companion.test.ts`

**Interfaces:**
- Consumes: `CompanionSpec` from `$lib/ash/api`.
- Produces:
  - `export function setPendingCompanion(conversationId: string, companion: CompanionSpec): void`
  - `export function takePendingCompanion(conversationId: string): CompanionSpec | null`

- [ ] **Step 1: Write the failing test**

Create `frontend/src/lib/chat/pending-companion.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { setPendingCompanion, takePendingCompanion } from './pending-companion';

describe('pending-companion', () => {
	it('returns null when nothing is pending', () => {
		expect(takePendingCompanion('missing')).toBeNull();
	});

	it('round-trips a stashed companion by conversation id', () => {
		setPendingCompanion('conv-1', { type: 'thread', id: 't1' });
		expect(takePendingCompanion('conv-1')).toEqual({ type: 'thread', id: 't1' });
	});

	it('is single-use — a taken companion is cleared', () => {
		setPendingCompanion('conv-2', { type: 'thread', id: 't2' });
		expect(takePendingCompanion('conv-2')).not.toBeNull();
		expect(takePendingCompanion('conv-2')).toBeNull();
	});

	it('keeps companions isolated per conversation', () => {
		setPendingCompanion('a', { type: 'thread', id: 'ta' });
		setPendingCompanion('b', { type: 'thread', id: 'tb' });
		expect(takePendingCompanion('b')?.id).toBe('tb');
		expect(takePendingCompanion('a')?.id).toBe('ta');
	});
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd frontend && npx vitest run src/lib/chat/pending-companion.test.ts`
Expected: FAIL — cannot resolve `./pending-companion`.

- [ ] **Step 3: Implement the module**

Create `frontend/src/lib/chat/pending-companion.ts`:

```ts
import type { CompanionSpec } from '$lib/ash/api';

/**
 * Hand-off for opening a companion on a conversation tab that is not mounted
 * yet. Opening a thread from the nav navigates to the parent conversation and
 * stashes the companion here; the conversation route applies it once the tab is
 * ready. Mirrors pending-message. Module-level Map survives the client-side
 * goto.
 */
const pending = new Map<string, CompanionSpec>();

export function setPendingCompanion(conversationId: string, companion: CompanionSpec): void {
	pending.set(conversationId, companion);
}

/** Returns and removes the pending companion (single-use). */
export function takePendingCompanion(conversationId: string): CompanionSpec | null {
	const companion = pending.get(conversationId);
	if (companion) pending.delete(conversationId);
	return companion ?? null;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd frontend && npx vitest run src/lib/chat/pending-companion.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/chat/pending-companion.ts frontend/src/lib/chat/pending-companion.test.ts
git commit -m "feat(spa): pending-companion hand-off for cross-route companion open"
```

---

### Task 4: Workbench store — load, expose, and mutate nav threads

**Files:**
- Modify: `frontend/src/lib/stores/workbench.svelte.ts`

**Interfaces:**
- Consumes: `conversationsThreads`, `ThreadNavSummary` (Task 2); `groupThreadsByParent` (Task 2); existing `archiveConversation` (already imported).
- Produces (on the `workbench` singleton):
  - `threadsByParent: Map<string, ThreadNavSummary[]>` (`$state`)
  - `threadsFor(conversationId: string): ThreadNavSummary[]`
  - `refreshThreads(): Promise<void>`
  - `deleteThread(threadId: string, parentConversationId: string): Promise<boolean>`

- [ ] **Step 1: Add imports**

In `frontend/src/lib/stores/workbench.svelte.ts`, extend the `$lib/ash/api` import list with `conversationsThreads` and `type ThreadNavSummary`, and add a new import for the grouping helper:

```ts
	conversationsThreads,
	// ...existing named imports...
	type ConversationSummary,
	type ThreadNavSummary,
```

```ts
import { groupThreadsByParent } from '$lib/chat/thread-nav';
```

(`archiveConversation` is already imported at the top of the file.)

- [ ] **Step 2: Add the reactive field**

Below `conversations = $state<ConversationSummary[]>([]);` (~line 51):

```ts
	threadsByParent = $state<Map<string, ThreadNavSummary[]>>(new Map());
```

- [ ] **Step 3: Add a private loader and call it from `load()` and `refreshConversations()`**

Add this private method (place it near `refreshConversations`):

```ts
	async #loadThreadsFor(conversationIds: string[]): Promise<void> {
		const result = await conversationsThreads(conversationIds);
		if (result.success) this.threadsByParent = groupThreadsByParent(result.data);
	}
```

In `load()`, after the `if (conversationsResult.success) { ... }` block that sorts conversations (~line 195), add:

```ts
		if (conversationsResult.success) {
			void this.#loadThreadsFor(conversationsResult.data.map((c) => c.id));
		}
```

In `refreshConversations()`, inside the `if (result.success) { ... }` block, after `this.#persistSnapshot();`:

```ts
			void this.#loadThreadsFor(result.data.map((c) => c.id));
```

- [ ] **Step 4: Add `threadsFor`, `refreshThreads`, and `deleteThread`**

Add these methods (place near `conversation(id)` / `archiveConversation`):

```ts
	/** Threads branched off a conversation, oldest first (empty when none). */
	threadsFor(conversationId: string): ThreadNavSummary[] {
		return this.threadsByParent.get(conversationId) ?? [];
	}

	/** Reload nav threads for the currently loaded conversations. */
	async refreshThreads(): Promise<void> {
		await this.#loadThreadsFor(this.conversations.map((c) => c.id));
	}

	/** Soft-deletes a thread (a child conversation) and drops it from the nav. */
	async deleteThread(threadId: string, parentConversationId: string): Promise<boolean> {
		const result = await archiveConversation(threadId);
		if (!result.success) return false;

		const list = this.threadsByParent.get(parentConversationId);
		if (list) {
			const next = list.filter((thread) => thread.id !== threadId);
			const map = new Map(this.threadsByParent);
			if (next.length > 0) map.set(parentConversationId, next);
			else map.delete(parentConversationId);
			this.threadsByParent = map;
		}
		return true;
	}
```

- [ ] **Step 5: Type-check**

Run: `cd frontend && npm run check`
Expected: no new type errors referencing `workbench.svelte.ts`, `ThreadNavSummary`, or `conversationsThreads`.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/stores/workbench.svelte.ts
git commit -m "feat(spa): load, expose, and mutate nav threads in workbench store"
```

---

### Task 5: Render threads + actions in the nav `conversationRow`

**Files:**
- Modify: `frontend/src/lib/components/shell/chat-nav.svelte`

**Interfaces:**
- Consumes: `workbench.threadsFor`, `workbench.deleteThread`, `workbench.setCompanion`, `workbench.tabForConversation` (Task 4 + existing); `setPendingCompanion` (Task 3); `ThreadNavSummary`, `CompanionSpec` (Task 2 + existing); existing `confirmAction`, `goto`, `base`, `page`.
- Produces: thread sub-rows under each conversation in the nav, each with `data-testid="thread-row"` and a `data-testid="thread-delete"` action.

- [ ] **Step 1: Add imports**

In the `<script>` of `frontend/src/lib/components/shell/chat-nav.svelte`:

- Add `CornerDownRight` to the existing `@lucide/svelte` import (the block ending at line 17). `Trash2` is already imported.
- Add to the `$lib/ash/api` type imports: `type ThreadNavSummary`, `type CompanionSpec`.
- Add: `import { setPendingCompanion } from '$lib/chat/pending-companion';`

- [ ] **Step 2: Add the open + delete handlers**

In the `<script>`, near the other handlers (e.g. after `openConversation`):

```ts
	async function openThreadRow(thread: ThreadNavSummary) {
		if (!thread.parentConversationId) return;
		const parentId = thread.parentConversationId;
		const spec: CompanionSpec = { type: 'thread', id: thread.id };
		const onParent = page.url.pathname.endsWith(`/chat/${parentId}`);
		const tab = workbench.tabForConversation(parentId);
		if (onParent && tab) {
			await workbench.setCompanion(tab.id, spec);
			return;
		}
		setPendingCompanion(parentId, spec);
		await goto(`${base}/chat/${parentId}`);
	}

	async function deleteThreadRow(thread: ThreadNavSummary) {
		if (!thread.parentConversationId) return;
		const ok = await confirmAction({
			title: 'Delete thread?',
			description: 'The thread and its messages are removed.',
			confirmLabel: 'Delete thread'
		});
		if (!ok) return;
		await workbench.deleteThread(thread.id, thread.parentConversationId);
	}
```

- [ ] **Step 3: Render the thread sub-list inside `conversationRow`**

In the `{#snippet conversationRow(conversation: ConversationSummary)}` block, immediately after the closing `</span>` of the hover-actions block (line 285) and BEFORE the snippet's closing `</Sidebar.MenuItem>` (line 286), insert:

```svelte
		{#if workbench.threadsFor(conversation.id).length > 0}
			<Sidebar.MenuSub class="mr-0 pr-0">
				{#each workbench.threadsFor(conversation.id) as thread (thread.id)}
					<Sidebar.MenuItem class="group/thread">
						<Sidebar.MenuButton
							data-testid="thread-row"
							onclick={() => void openThreadRow(thread)}
						>
							<CornerDownRight class="text-muted-foreground" />
							<span class="min-w-0 flex-1 truncate">{thread.title ?? 'Thread'}</span>
						</Sidebar.MenuButton>
						<span
							class="absolute right-1 top-1/2 flex -translate-y-1/2 items-center opacity-0 transition-opacity group-hover/thread:opacity-100"
						>
							<button
								type="button"
								class="rounded p-1 text-muted-foreground hover:bg-accent hover:text-destructive"
								title="Delete thread"
								data-testid="thread-delete"
								onclick={() => void deleteThreadRow(thread)}
							>
								<Trash2 class="size-3" />
							</button>
						</span>
					</Sidebar.MenuItem>
				{/each}
			</Sidebar.MenuSub>
		{/if}
```

- [ ] **Step 4: Type/lint check**

Run: `cd frontend && npm run check`
Expected: no new errors in `chat-nav.svelte`.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/shell/chat-nav.svelte
git commit -m "feat(spa): render thread sub-list with open + delete in conversation nav"
```

---

### Task 6: Apply pending companion on the conversation route

**Files:**
- Modify: `frontend/src/routes/chat/[conversationId]/+page.svelte`

**Interfaces:**
- Consumes: `takePendingCompanion` (Task 3); existing `workbench.openTab`, `workbench.setCompanion`, `workbench.tabForConversation`, `openCompanion`.
- Produces: applies a stashed thread companion once the conversation's tab is open/active.

- [ ] **Step 1: Add the import**

In `frontend/src/routes/chat/[conversationId]/+page.svelte` `<script>`:

```ts
	import { takePendingCompanion } from '$lib/chat/pending-companion';
```

- [ ] **Step 2: Consume the pending companion in the deep-link effect**

Replace the existing deep-link `$effect` (lines 35-45) with:

```ts
	$effect(() => {
		const session = workbench.session;
		if (!session || !conversationId) return;

		const existing = session.tabs.find(
			(tab) => tab.primary.type === 'conversation' && tab.primary.id === conversationId
		);
		if (existing && session.activeTabId === existing.id) {
			const pending = takePendingCompanion(conversationId);
			if (pending) void workbench.setCompanion(existing.id, pending);
			return;
		}

		void workbench.openTab({ type: 'conversation', id: conversationId }).then(() => {
			const pending = takePendingCompanion(conversationId);
			const tab = workbench.tabForConversation(conversationId);
			if (pending && tab) void workbench.setCompanion(tab.id, pending);
		});
	});
```

- [ ] **Step 3: Type/lint check**

Run: `cd frontend && npm run check`
Expected: no new errors in `+page.svelte`.

- [ ] **Step 4: Commit**

```bash
git add "frontend/src/routes/chat/[conversationId]/+page.svelte"
git commit -m "feat(spa): apply pending thread companion when its tab is ready"
```

---

### Task 7: Reflect newly created threads in the nav

**Files:**
- Modify: `frontend/src/lib/components/chat/conversation-view.svelte`

**Interfaces:**
- Consumes: existing `workbench` singleton; `workbench.refreshThreads()` (Task 4).
- Produces: after a thread is created from a message, the nav sub-list updates without a manual refresh.

- [ ] **Step 1: Ensure workbench is imported**

In `frontend/src/lib/components/chat/conversation-view.svelte`, confirm/add:

```ts
	import { workbench } from '$lib/stores/workbench.svelte';
```

(Check the existing imports first; only add if absent.)

- [ ] **Step 2: Refresh nav threads after creating a thread**

In `startThread`, after the successful `createThread` path updates the local cache (after `writeThreads(conversationId, threads);`, ~line 158), add:

```ts
		void workbench.refreshThreads();
```

The function now reads:

```ts
	async function startThread(messageId: string) {
		// Reuse an existing thread for the message (classic does the same).
		const existing = threadsByMessage.get(messageId);
		if (existing) return onCompanionRequest?.({ type: 'thread', id: existing.id });

		const result = await createThread(conversationId, messageId);
		if (!result.success) return;

		threads = [...threads, result.data];
		writeThreads(conversationId, threads);
		void workbench.refreshThreads();
		onCompanionRequest?.({ type: 'thread', id: result.data.id });
	}
```

- [ ] **Step 3: Type/lint check**

Run: `cd frontend && npm run check`
Expected: no new errors.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/lib/components/chat/conversation-view.svelte
git commit -m "feat(spa): refresh nav threads after creating a thread from a message"
```

---

### Task 8: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full frontend test suite**

Run: `cd frontend && npm test`
Expected: PASS, including `thread-nav.test.ts` and `pending-companion.test.ts`.

- [ ] **Step 2: Type/lint the whole frontend**

Run: `cd frontend && npm run check`
Expected: no errors.

- [ ] **Step 3: Confirm Elixir still compiles clean (only chat.ex changed)**

Run (only if no dev server is running): `MIX_ENV=test mix compile --warnings-as-errors`
Expected: compiles with no warnings.

- [ ] **Step 4: Manual smoke (optional but recommended)**

Start the SPA dev environment, open a conversation, create a thread from a message, and confirm: (a) the thread appears nested under its parent in the left nav across favorites/folder/unfiled placement; (b) clicking the thread row opens the thread companion (navigating to the parent if needed); (c) hovering shows a trash button that deletes the thread and removes the row.

- [ ] **Step 5: Final commit (if any verification fixes were needed)**

```bash
git add -A
git commit -m "chore(spa): verification fixes for nav threads"
```

---

## Self-Review Notes

- **Spec coverage:** backend RPC (Task 1) → spec §1; data layer wrapper/type (Task 2) → spec §2; store load/expose/delete (Task 4) → spec §3 + §6; nav UI render + delete (Task 5) → spec §4 + §6; open-as-companion with pending hand-off (Tasks 3, 5, 6) → spec §5; create-reflection (Task 7) → spec §3 refresh note; tests (Tasks 2, 3, 8) → spec §7. The spec's §7 asked for render/delete tests; the codebase has no Svelte component test harness, so coverage is via the extracted pure helpers (`groupThreadsByParent`, `pending-companion`) plus a manual smoke step, consistent with existing conventions.
- **Type consistency:** `ThreadNavSummary` (with `parentConversationId`) is defined in Task 2 and used identically in Tasks 4 and 5. `groupThreadsByParent`, `setPendingCompanion`/`takePendingCompanion`, `threadsFor`, `refreshThreads`, `deleteThread` names are used consistently across tasks.
- **No placeholders:** every code step contains the full code.
