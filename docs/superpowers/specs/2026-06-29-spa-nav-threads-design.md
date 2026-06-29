# SPA Conversation Nav: Threads Sub-List

Date: 2026-06-29
Status: Approved

## Problem

The classic LiveView workbench rendered a conversation's **threads** as an
always-visible nested sub-list under their parent conversation in the left nav.
The SvelteKit SPA (`frontend/`), which is replacing the classic workbench, has
thread support only as right-rail companions and as chips on branched messages.
The nav sub-list is missing. This spec ports that nav behavior into the SPA.

Per project convention: fix the SPA only. The classic workbench is not touched.

## Background

A "thread" is a child `Magus.Chat.Conversation` with `is_thread == true`,
`parent_conversation_id` set, and `branched_at_message_id` recording the message
it branched from. Backend support is complete:

- Read actions `threads_for_conversation` (singular) and
  `threads_for_conversations` (plural/batch) exist in
  `lib/magus/chat/conversation.ex` (lines 317 and 328).
- Code interfaces `threads_for_conversation` / `threads_for_conversations` exist
  in `lib/magus/chat/chat.ex` (lines 288-289).
- The singular action is already exposed to the SPA as RPC
  `conversation_threads`; the **batch** action is not yet exposed.
- All conversation-list read actions (`my_conversations`, `personal_conversations`,
  `workspace_conversations`, `my_favorites`, `history`) already filter
  `is_thread != true`, so threads never appear as top-level nav rows.
- Threads are soft-deleted; the SPA already exposes `archive_conversation`
  (`:soft_delete`), which works on a thread conversation.

SPA-side facts:

- The nav lives in `frontend/src/lib/components/shell/chat-nav.svelte`. The
  `conversationRow` snippet (around line 220) is shared by favorites, foldered,
  and unfiled conversation groups.
- Conversations load via `workbench.load()` /
  `workbench.refreshConversations()` (`frontend/src/lib/stores/workbench.svelte.ts`)
  using `personalConversations()` / `workspaceConversations()`.
- Companions are tab-scoped: `workbench.setCompanion(tabId, spec)` with
  `spec = { type: 'thread', id }`. The route page
  `frontend/src/routes/chat/[conversationId]/+page.svelte` owns the conversation
  store and opens companions via `openCompanion(conversationId, spec)`.
- The existing `pending-message` stash (`frontend/src/lib/chat/pending-message.ts`)
  is the pattern for handing off state across a navigation.

## Decisions

1. **Display:** always-visible nested sub-list under the parent, matching
   classic. No per-conversation expand/collapse for the thread sub-list.
2. **Fetching:** batch — expose the existing plural read action as an RPC and
   load threads for all visible conversations in one call. Avoids N+1.
3. **Actions:** click-to-open + delete-on-hover (trash button), matching classic.
4. **Open target:** thread opens as the existing `{ type: 'thread' }` companion
   on the parent conversation's tab.

## Design

### 1. Backend: expose the batch RPC

In `lib/magus/chat/chat.ex`, in the `Conversation` typescript RPC block, add
next to the singular action (line 36):

```elixir
rpc_action :conversations_threads, :threads_for_conversations
```

Regenerate the TS client with `mix ash_typescript.codegen`. No new actions, no
migration.

### 2. Data layer (`frontend/src/lib/ash/api.ts`)

- Add `parentConversationId` to the thread field selection so batch results can
  be grouped by parent. Either widen `ThreadSummary` with an optional
  `parentConversationId` or introduce a `ThreadNavSummary` type that includes it.
- Add a wrapper:

```ts
export function conversationsThreads(
  conversationIds: string[]
): Promise<RpcResult<ThreadNavSummary[]>>
```

  Returns `[]` short-circuit when `conversationIds` is empty (skip the RPC).

### 3. State (`frontend/src/lib/stores/workbench.svelte.ts`)

- Add reactive `threadsByParent = $state<Map<string, ThreadNavSummary[]>>(...)`.
- Populate it in the same path that loads conversations (`load()` and
  `refreshConversations()`): after conversations are fetched, call
  `conversationsThreads(conversations.map(c => c.id))` and group by
  `parentConversationId` (oldest-first ordering preserved from the backend sort).
- Expose `threadsFor(conversationId): ThreadNavSummary[]` (empty array default).
- On thread delete, remove the entry from `threadsByParent` optimistically.
- Provide a way to reflect a newly created thread (created from
  conversation-view): simplest is to refresh threads as part of
  `refreshConversations()`, and have conversation-view's `startThread` trigger a
  nav refresh. Keep real-time channel sync out of scope (classic relied on
  LiveView; nav refresh on mutation matches current SPA behavior).

### 4. UI (`frontend/src/lib/components/shell/chat-nav.svelte`)

In the shared `conversationRow` snippet, after the conversation's
`Sidebar.MenuButton`/actions, render (only when `threadsFor(id)` is non-empty) a
`Sidebar.MenuSub` containing one row per thread:

- Icon: `corner-down-right` (lucide) to signal a branch.
- Label: `thread.title ?? 'Thread'`, truncated.
- Click: open the thread (see section 5).
- Hover-revealed trash button (`data-testid="thread-delete"`) for delete
  (section 6).

Reuse the nesting/indentation chrome that `folderRow` uses for its
`Sidebar.MenuSub`. Add `data-testid="thread-row"` (and the thread id) to each
row for tests. Because `conversationRow` is shared, threads appear under
favorites, foldered, and unfiled conversations automatically.

### 5. Open behavior

A new helper (in the nav or workbench) opens a thread:

- If the parent conversation already has an active tab
  (`workbench.tabForConversation(parentId)`), call
  `workbench.setCompanion(tab.id, { type: 'thread', id: threadId })` directly.
- Otherwise, stash the companion via a new
  `frontend/src/lib/chat/pending-companion.ts` (mirroring `pending-message.ts`,
  keyed by conversation id) and `goto('/chat/{parentId}')`. The route page
  `[conversationId]/+page.svelte` consumes the pending companion after the tab
  is opened/ready and calls `openCompanion`.

### 6. Delete behavior

Hover trash → `confirmAction(...)` → `archive_conversation(thread.id)` → remove
from `threadsByParent`. Reuse the existing archive/soft-delete API wrapper.

### 7. Tests

Add a frontend test (matching the SPA's existing test setup and `data-testid`
conventions used in the nav, e.g. `conversation-delete`) covering:

- A conversation with threads renders a `thread-row` per thread under it.
- A conversation without threads renders no thread rows.
- The delete action invokes archive and removes the row.

## Out of scope

- Real-time channel sync of nav threads (refresh-on-mutation only).
- Creating threads from the nav (creation stays on branched messages).
- Per-conversation collapse of the thread sub-list.
- Any change to the classic workbench.

## Files touched

- `lib/magus/chat/chat.ex` (one RPC line)
- generated `frontend/src/lib/ash/ash_rpc.ts` (codegen)
- `frontend/src/lib/ash/api.ts`
- `frontend/src/lib/stores/workbench.svelte.ts`
- `frontend/src/lib/components/shell/chat-nav.svelte`
- `frontend/src/lib/chat/pending-companion.ts` (new)
- `frontend/src/routes/chat/[conversationId]/+page.svelte`
- frontend test file(s)
