# Knowledge Brain

Collaborative knowledge workspace with a block-based page editor, semantic search, real-time presence, and agent tool access.

## Overview

The Knowledge Brain is an Ash domain that gives users a structured workspace for organizing information across pages and blocks. Each brain contains pages; each page contains ordered blocks. Agents can read and write brain content via dedicated tools when a brain page is open in the UI pane. Brain context is injected into the system prompt so the agent is always aware of the open page's content.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          KNOWLEDGE BRAIN ARCHITECTURE                            │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                          Brain Domain (Ash)                               │   │
│  │   BrainResource  ──→  Page  ──→  Block  ──→  Connection                  │   │
│  │                                              BrainAccess                  │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│            │                    │                                                │
│            ▼                    ▼                                                │
│  BroadcastBrainEvent       AshOban Triggers                                     │
│  (after every mutation)    - generate_embedding (Block)                         │
│            │               - ingest_source (Block)                              │
│            ▼                    │                                                │
│  PubSub: brain:{id}             └──→ GenerateBlockEmbedding / IngestSource      │
│          brain:{id}:page:{id}                                                   │
│            │                                                                    │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│  LiveView Layer                                                                 │
│                                                                                 │
│  BrainSidebarComponent                                                          │
│    (brain/page list, select page)                                               │
│            │ send {:open_brain_page, id, page_id}                               │
│            ▼                                                                    │
│  ChatLive ──→ BrainHandlers                                                     │
│    handle_open_brain_page: subscribe, track presence, load blocks               │
│            │                                                                    │
│  BrainPaneComponent (right pane)                                                │
│    TipTap editor (brain_editor.js hook)                                         │
│    brain_editor_save ──→ Sync.sync_blocks ──→ DB ──→ reload                   │
│            │                                                                    │
│  BrainPubSubHandlers                                                            │
│    block.created/updated/deleted ──→ update brain_pane_blocks                  │
│    presence.changed ──→ update brain_page_viewers                               │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│  Agent Context Pipeline                                                         │
│                                                                                 │
│  ChatLive sends brain_id/brain_page_id in message metadata                     │
│            │                                                                    │
│  Preflight extracts ──→ adds to tool context and selections                    │
│            │                                                                    │
│  ToolBuilder adds brain tools (Tier 7, when brain_id present)                  │
│            │                                                                    │
│  BrainContext.build() ──→ loads brain + page + blocks ──→ system prompt        │
│  BrainRagContext.build() ──→ semantic search on every message ──→ appended     │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│  Agent Tools (2 consolidated)                                                   │
│                                                                                 │
│  NavigateBrain (list_pages, read_page, search, find_page, get_backlinks)        │
│  EditBrain (write_page, rename_page, delete_page, add_block,                   │
│             edit_block, delete_block, move_block, link)                         │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Data Model

### BrainResource (`lib/magus/brain/brain_resource.ex`)

Table: `brains`

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | uuid_v7 | Primary key |
| `title` | string | Required |
| `slug` | string | Auto-generated from title; unique per user |
| `description` | string | Optional |
| `icon` | string | Emoji or icon name |
| `color` | string | Optional accent color |
| `is_archived` | boolean | Default false; archived brains excluded from list |
| `user_id` | FK (User) | Owner; on_delete: :delete |

### Page (`lib/magus/brain/page.ex`)

Table: `brain_pages`

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | uuid_v7 | Primary key |
| `title` | string | Required |
| `slug` | string | Auto-generated; unique per brain |
| `position` | float | Fractional ordering (AutoPosition change) |
| `icon` | string | Optional |
| `brain_id` | FK (BrainResource) | on_delete: :delete |
| `contributor_type` | atom | `:user` or `:custom_agent` |
| `contributor_id` | uuid | ID of the creating user or agent |

### Block (`lib/magus/brain/block.ex`)

Table: `brain_blocks`

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | uuid_v7 | Primary key |
| `type` | atom | See Block Types table |
| `content` | map | Type-specific content (see Block Types table) |
| `position` | float | Fractional ordering within parent scope |
| `depth` | integer | Nesting depth; 0 = top-level |
| `metadata` | map | Ingestion state, custom flags |
| `is_pinned` | boolean | Default false |
| `parent_block_id` | FK (Block) | Nullable; for nested blocks (on_delete: :delete) |
| `page_id` | FK (Page) | on_delete: :delete |
| `contributor_type` | atom | `:user` or `:custom_agent` |
| `contributor_id` | uuid | ID of the last editor |
| `embedding` | vector | pgvector embedding for semantic search |
| `lock_version` | integer | Optimistic lock counter |

**Versioning:** Block uses `AshPaperTrail.Resource` in `:snapshot` mode. Every create/update/destroy produces a version in `brain_blocks_versions`. Ignored attributes: `inserted_at`, `updated_at`, `embedding`, `lock_version`. The auto-generated `Magus.Brain.Block.Version` resource is registered in the Brain domain.

### Connection (`lib/magus/brain/connection.ex`)

Table: `brain_connections`

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | uuid_v7 | Primary key |
| `type` | atom | `:reference`, `:semantic`, `:supports`, `:contradicts`, `:derived_from`, `:relates_to` |
| `weight` | float | 0.0--1.0; default 0.5; incremented by `:reinforce` action |
| `is_explicit` | boolean | User/agent-created vs. auto-parsed |
| `source_block_id` | FK (Block) | Required; on_delete: :delete |
| `target_block_id` | FK (Block) | One of target_block_id or target_page_id required |
| `target_page_id` | FK (Page) | One of target_block_id or target_page_id required |
| `contributor_type` | atom | `:user` or `:custom_agent` |
| `contributor_id` | uuid | |

### BrainAccess (`lib/magus/brain/brain_access.ex`)

Table: `brain_accesses`

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | uuid_v7 | Primary key |
| `brain_id` | FK (BrainResource) | on_delete: :delete |
| `grantee_type` | atom | `:user`, `:workspace`, or `:custom_agent` |
| `grantee_id` | uuid | ID of the grantee |
| `role` | atom | `:viewer`, `:editor`, or `:admin` |

Identity: `unique_grantee_per_brain` on `(brain_id, grantee_type, grantee_id)`.

## Block Types

| Type | Content Schema | Embeddable | Notes |
|------|---------------|------------|-------|
| `:paragraph` | `%{"text" => string}` | Yes | Default type |
| `:heading` | `%{"text" => string, "level" => 1..3}` | Yes | |
| `:list_item` | `%{"text" => string}` | Yes | Depth drives visual nesting |
| `:code` | `%{"text" => string, "language" => string}` | Yes | Language for syntax highlighting |
| `:quote` | `%{"text" => string}` | Yes | |
| `:callout` | `%{"text" => string, "variant" => string}` | Yes | Variants: info, warning, tip, important |
| `:source` | `%{"text" => string, "url" => string, "source_type" => string, "description" => string, "author" => string}` | Yes | URL triggers async ingestion |
| `:message` | `%{"message_id" => uuid, "conversation_id" => uuid, "preview_text" => string}` | No | Dragged from chat |
| `:file` | `%{"file_id" => uuid, "caption" => string}` | No | |
| `:image` | `%{"file_id" => uuid, "caption" => string}` | No | |
| `:divider` | `%{}` | No | |

`BlockContent` (`lib/magus/brain/block_content.ex`) provides shared helpers: `text_content/1` for embedding/search extraction and `display_text/1` for outline previews.

## Ash Domain

**File:** `lib/magus/brain/brain.ex`

| Interface | Action | Notes |
|-----------|--------|-------|
| `create_brain/1` | `BrainResource.create` | Actor sets `user_id` |
| `get_brain/1` | `BrainResource.read` (by id) | |
| `list_brains/0` | `BrainResource.list_for_user` | Filters `is_archived == false`, actor |
| `update_brain/2` | `BrainResource.update` | |
| `archive_brain/1` | `BrainResource.archive` | Sets `is_archived = true` |
| `destroy_brain/1` | `BrainResource.destroy` | |
| `create_page/2` | `Page.create` | Args: `brain_id` |
| `get_page/1` | `Page.read` (by id) | |
| `list_pages/1` | `Page.for_brain` | Sorted by position asc |
| `update_page_title/2` | `Page.update_title` | |
| `find_page_by_title/2` | `Page.by_title_in_brain` | Args: `brain_id, title` |
| `destroy_page/1` | `Page.destroy` | |
| `create_block/2` | `Block.create` | Args: `page_id` |
| `get_block/1` | `Block.read` (by id) | |
| `list_blocks/1` | `Block.for_page` | Sorted by position asc |
| `update_block/2` | `Block.update` | |
| `update_block_locked/2` | `Block.update_locked` | Requires `lock_version` argument |
| `reposition_block/2` | `Block.reposition` | |
| `destroy_block/1` | `Block.destroy` | |
| `search_blocks/3` | `Block.semantic_search` | Args: `brain_id, embedding`; pgvector L2 sort |
| `restore_block_version/2` | `Block.restore_version` | Args: `version_id`; restores content from paper trail snapshot |
| `ingest_source_block/1` | `Block.ingest_source` | Called by AshOban |
| `create_connection/1` | `Connection.create` | |
| `connections_for_block/1` | `Connection.for_block` | |
| `connections_for_page/1` | `Connection.for_page` | |
| `reinforce_connection/1` | `Connection.reinforce` | Increments weight by 0.1, max 1.0 |
| `destroy_connection/1` | `Connection.destroy` | |
| `grant_access/1` | `BrainAccess.grant` | |
| `list_access/1` | `BrainAccess.for_brain` | |
| `revoke_access/1` | `BrainAccess.destroy` | |

## Key Modules

### Changes

| Module | Purpose |
|--------|---------|
| `lib/magus/brain/changes/auto_position.ex` | Assigns `position = max_sibling_position + 1.0`; parameterized by scope and optional parent attribute |
| `lib/magus/brain/changes/broadcast_brain_event.ex` | Broadcasts PubSub events after every block/page mutation; fires both `brain:{id}` and `brain:{id}:page:{id}` for blocks |
| `lib/magus/brain/changes/generate_block_embedding.ex` | Calls `EmbeddingModel.embed/1` on the block's text content; stores result in `embedding` column |
| `lib/magus/brain/changes/ingest_source.ex` | After-action for `:source` blocks: fetches URL, updates title, creates child paragraph blocks, marks `metadata["ingested"]` |
| `lib/magus/brain/changes/parse_references.ex` | Detects `[[Page Name]]` syntax in block text; creates `:reference` connections; auto-creates target pages that do not exist |
| `lib/magus/brain/changes/slugify.ex` | Generates URL-safe slug from a string attribute |

### Checks

| Module | Purpose |
|--------|---------|
| `lib/magus/brain/checks/actor_owns_brain.ex` | Parameterized policy check used across resources. Strategies: `:brain_id_argument` (Page create), `:brain_id_attribute` (BrainAccess create), `:via_page` (Block create), `:via_block` (Connection create) |

### Validations

| Module | Purpose |
|--------|---------|
| `lib/magus/brain/block/validations/lock_version.ex` | Validates the `lock_version` argument matches `changeset.data.lock_version` before the DB-level optimistic lock fires |

### Support

| Module | Purpose |
|--------|---------|
| `lib/magus/brain/block_content.ex` | Shared text extraction: `text_content/1` for embedding/search; `display_text/1` for outline labels |
| `lib/magus/brain/brain_presence.ex` | Elixir Registry (duplicate keys) tracking which users view which pages. `track/3`, `untrack/2`, `list_viewers/1`, `viewing?/2` |
| `lib/magus/brain/sync.ex` | Data loading helpers (`load_brain_sources/1`, `load_related_pages/3`, `load_brain_activity/1`) and `sync_blocks/3` reconciliation |
| `lib/magus/brain/source_ingester.ex` | URL fetch + HTML text extraction + child block creation for `:source` blocks |
| `lib/magus/brain/topics.ex` | `brain/1` and `page/2` PubSub topic name helpers |

## Agent Tools

The 3 consolidated tools live in `lib/magus/agents/tools/brain/` and are categorized as `:brain` in the `ToolBuilder` category map.

| Module | Tool Name | Actions | Description |
|--------|-----------|---------|-------------|
| `navigate_brain.ex` | `navigate_brain` | list_pages, read_page, search, find_page, get_backlinks | Read-only brain navigation and discovery |
| `edit_brain.ex` | `edit_brain` | write_page, rename_page, delete_page, add_block, edit_block, delete_block, move_block, link | All create/update/delete mutations |

### Key Capabilities

- **write_page**: Accepts markdown content, parses via MarkdownToBlocks into typed blocks. Auto-appends when page title matches an existing page.
- **edit_block search-and-replace**: Two modes: old_text/new_text for search-and-replace (block or page scoped), or content map for full rewrite. Falls back to fuzzy matching on errors.
- **find_page**: Semantic page matching across all user brains. Groups results by page, ranks by match density.
- **link bidirectional**: Pass source_page_id + target_page_id for bidirectional page connections.
- **add_block with source**: Source blocks created via add_block with block_type="source".
- **Response hints**: All actions return contextual hints guiding the agent's next step.

All tools use `BrainResolver` (`lib/magus/agents/tools/brain/brain_resolver.ex`) for smart brain/page auto-discovery when IDs are not explicitly provided.

### MarkdownToBlocks (`lib/magus/brain/markdown_to_blocks.ex`)

Converts markdown strings into brain block specs by reusing `ProseMirrorConverter.from_markdown/1`:
1. Parses markdown into ProseMirror JSON via MDEx
2. Maps ProseMirror nodes to brain block specs
3. Preserves inline formatting (bold, italic, code, links) as markdown in block text
4. Handles tables, task lists, nested lists with depth tracking

### Brain Management Skill (`priv/skills/brain_management.md`)

Loadable skill with placement heuristics for agent-driven knowledge management:
- Detection heuristics (when to capture vs skip)
- Multi-brain routing via find_page
- Create vs append decision tree
- Content structuring guidance
- Knowledge graph building patterns

## Context Injection Pipeline

How brain context flows from the UI into the agent's system prompt:

```
1. User sends message with brain pane open
   ChatLive appends brain_id + brain_page_id to message metadata map

2. InboundPlugin / Dispatcher passes metadata as signal data

3. Preflight (lib/magus/agents/plugins/support/preflight.ex)
   Extracts brain_id and brain_page_id from signal data
   Adds both to base_tool_context and to the selections map passed to Builder

4. ToolBuilder.build_tools/6 (Tier 7)
   When brain_id is present OR agent has BrainAccess, appends all 3 brain tools
   Passes brain_id and brain_page_id into each tool's context

5. Context.Builder (lib/magus/agents/context/builder.ex)
   Calls BrainContext.build(brain_id, brain_page_id) directly (not via Task)
   Runs BrainRagContext.build/3 in parallel via Task.async (when brain_id present)
   Passes brain_context into SystemPrompts.build/1
   Appends brain_rag_context after memory_context and rag_context

6. BrainContext.build/2 (lib/magus/agents/context/brain_context.ex)
   Loads brain, page, blocks, and page list
   Composes a ## Knowledge Brain section for the system prompt
   Lists all pages with [ACTIVE] marker on the current page
   Formats blocks as markdown (headings, code fences, quotes, callouts, etc.)
   Appends a tool usage hint listing all 3 available brain tools

7. BrainRagContext.build/3 (lib/magus/agents/context/brain_rag_context.ex)
   Embeds the user's query text
   Performs semantic search (pgvector) across all user brains the agent can access
   Returns the top 5 results with surrounding sibling blocks for context
   Appended to the system prompt as a ## Relevant Brain Content section
```

`BrainContext.build/2` returns `nil` when either ID is absent or a DB load fails. `BrainRagContext.build/3` returns `nil` when no relevant results are found. The `append_context` helper in `Builder` ignores `nil` values.

## PubSub Architecture

### Topics

| Topic | Scope | Managed By |
|-------|-------|-----------|
| `brain:{brain_id}` | Brain-wide events | `Magus.Brain.Topics.brain/1` |
| `brain:{brain_id}:page:{page_id}` | Page-specific events | `Magus.Brain.Topics.page/2` |

### Event Types

| Event | Payload Fields | Subscriber Action |
|-------|---------------|------------------|
| `block.created` | `%{record: Block, actor_id: uuid}` | Insert block sorted by position |
| `block.updated` | `%{record: Block, actor_id: uuid}` | Replace block in list by id |
| `block.deleted` | `%{record: Block, actor_id: uuid}` | Remove block from list by id |
| `page.created` | `%{record: Page, brain_id: uuid, actor_id: uuid}` | (handled by ChatLive for sidebar refresh) |
| `page.updated` | `%{record: Page, brain_id: uuid, actor_id: uuid}` | Update `brain_pane_page` if current page |
| `page.deleted` | `%{record: Page, brain_id: uuid, actor_id: uuid}` | Close pane if current page |
| `presence.changed` | `%{page_id: uuid, viewers: [viewer]}` | Update `brain_page_viewers` |

### Broadcast Flow

`BroadcastBrainEvent` change fires in `after_transaction` on every block and page mutation:

1. For `:update` and `:destroy` actions, `brain_id` is resolved eagerly from `changeset.data` before the transaction (avoids an extra DB query in `after_transaction`).
2. For `:create` actions, `brain_id` is resolved from the returned record.
3. Broadcasts to `brain:{brain_id}` for all resource types.
4. Additionally broadcasts to `brain:{brain_id}:page:{page_id}` for block events.
5. `actor_id` is included so subscribers can filter self-updates.

### LiveView Subscription Lifecycle

`BrainHandlers.handle_open_brain_page/3` subscribes to both topics and calls `BrainPresence.track/3` when the pane opens. On close or process termination, it unsubscribes and calls `BrainPresence.untrack/2`, then broadcasts a `presence.changed` event so other viewers update promptly.

`BrainPubSubHandlers` (`lib/magus_web/app/live/chat_live/brain_pubsub_handlers.ex`) processes all broadcast events. Self-updates are skipped when `actor_id == current_user.id`.

## Presence

`BrainPresence` (`lib/magus/brain/brain_presence.ex`) uses an Elixir `Registry` with duplicate keys keyed by `{:page, page_id}`.

| Function | Description |
|----------|-------------|
| `track(user_id, page_id, meta)` | Registers calling process; meta can include `%{name: "Display Name"}` |
| `untrack(user_id, page_id)` | Unregisters calling process from that page key |
| `viewing?(user_id, page_id)` | Returns true if user has any process registered for the page |
| `list_viewers(page_id)` | Returns deduplicated list of `%{user_id, name, meta}` entries |

Registry registrations are automatically cleaned up when the LiveView process terminates (tab close, navigate away, disconnect), so stale entries are not possible.

## Optimistic Locking

Block updates from the TipTap editor use two-layer conflict detection:

1. `LockVersion` validation (`lib/magus/brain/block/validations/lock_version.ex`) compares the `lock_version` argument against `changeset.data.lock_version`. Fires before the DB write; returns `Ash.Error.Changes.StaleRecord` on mismatch.
2. `optimistic_lock(:lock_version)` change on `update_locked` action performs a DB-level conditional update as a second guard.

`Sync.sync_blocks/3` (`lib/magus/brain/sync.ex`) calls `update_block_locked` for every modified block and accumulates a `conflict?` boolean. If any conflict occurred, `BrainHandlers.handle_brain_editor_save/2` pushes a `brain:reload_blocks` JS event to the editor with the canonical server-side block list, forcing the TipTap document to resync.

## Source Ingestion

When a `:source` block is created with a URL, an AshOban trigger fires asynchronously:

```
AshOban trigger :ingest_source
  where: type == :source AND metadata does not contain "ingested" or "ingestion_error"
  scheduler_cron: "* * * * *"
        |
        v
IngestSource change (lib/magus/brain/changes/ingest_source.ex)
  after_action callback:
    1. Reads URL from content["url"]
    2. Calls SourceIngester.fetch_url/1
       - Req.get with redirect follow and 15s timeout
       - Strips scripts/styles, collapses whitespace, truncates at 50,000 chars
       - Extracts <title> from HTML
    3. Updates source block title if fetched title is better
    4. SourceIngester.create_child_blocks/3
       - Splits on double newlines, max 50 child blocks
       - Truncates paragraphs at 2,000 chars
       - Creates :paragraph blocks with parent_block_id = source block
    5. Sets metadata["ingested"] = true
       OR metadata["ingestion_error"] = inspect(reason) on failure
```

## Embedding Pipeline

Text-bearing blocks are embedded asynchronously:

```
AshOban trigger :generate_embedding
  where: is_nil(embedding) AND type in [:paragraph, :heading, :list_item, :quote, :callout, :code, :source]
  scheduler_cron: "* * * * *"
        |
        v
GenerateBlockEmbedding change (lib/magus/brain/changes/generate_block_embedding.ex)
  before_action callback:
    1. Calls BlockContent.text_content/1 to extract text
    2. Skips if text is nil or <= 10 chars
    3. Calls Magus.Files.EmbeddingModel.embed/1
    4. force_change_attribute(:embedding, vector)
```

Semantic search uses pgvector L2 distance. The `Block.semantic_search` action computes `embedding <-> ?::vector` as a calculation, sorts by it ascending, and limits to `arg(:limit)` (default 10).

## UI Components

### LiveComponents and Handlers

| Module | Path | Purpose |
|--------|------|---------|
| `BrainPaneComponent` | `lib/magus_web/app/live/chat_live/components/brain/brain_pane_component.ex` | Right-side editor pane with TipTap, tabbed panels (Outline, Sources, Related, Activity), and presence dots |
| `BrainSidebarComponent` | `lib/magus_web/app/live/chat_live/components/brain/brain_sidebar_component.ex` | Brain and page list for navigation; sends `open_brain_page` and `create_page_in_brain` messages to parent |
| `SourceBlockComponent` | `lib/magus_web/app/live/chat_live/components/brain/blocks/source_block_component.ex` | Renders source blocks with URL and ingestion state |
| `FileBlockComponent` | `lib/magus_web/app/live/chat_live/components/brain/blocks/file_block_component.ex` | Renders file attachment blocks |
| `MessageBlockComponent` | `lib/magus_web/app/live/chat_live/components/brain/blocks/message_block_component.ex` | Renders message reference blocks |
| `CalloutBlockComponent` | `lib/magus_web/app/live/chat_live/components/brain/blocks/callout_block_component.ex` | Renders callout blocks with variant styling |
| `ImageBlockComponent` | `lib/magus_web/app/live/chat_live/components/brain/blocks/image_block_component.ex` | Renders image blocks |
| `BrainHandlers` | `lib/magus_web/app/live/chat_live/brain_handlers.ex` | Socket orchestration: open/close pane, create brain/page, sync editor, add message/source blocks |
| `BrainPubSubHandlers` | `lib/magus_web/app/live/chat_live/brain_pubsub_handlers.ex` | Dispatches PubSub broadcasts to socket state; skips self-updates |
| `Sync` | `lib/magus/brain/sync.ex` | Data queries (sources, related pages, activity) and `sync_blocks/3` reconciliation |

### JavaScript

| File | Purpose |
|------|---------|
| `assets/js/hooks/brain_editor.js` | TipTap editor hook. Pushes `brain_editor_save` with block list on change. Handles `brain:reload_blocks` push event by replacing TipTap content on conflict. Emits `brain_text_selected`/`brain_text_cleared` on selection change. |
| `assets/js/hooks/draggable_message.js` | Attached to the per-message grip handle. Puts the message payload on the drag data transfer and fades the source bubble during drag; the `brain_tiptap_editor.js` drop handler inserts a `messageBlock` node at the drop position so autosave syncs it via `brain_editor_save`. Falls back to a direct `add_message_to_brain` event only when the editor is not yet mounted. |

## LiveView Event Flow

| Event | Direction | Handler | Action |
|-------|-----------|---------|--------|
| `brain_editor_save` | Client to Server | `ChatLive` | Delegates to `BrainHandlers.handle_brain_editor_save/2`; runs `Sync.sync_blocks/3`; pushes `brain:reload_blocks` if conflicts detected |
| `add_message_to_brain` | Client to Server | `ChatLive` | Appends a `:message` block to the active page with message preview. Used by the "Add to brain" icon and as a fallback for drops that arrive before the editor is ready; drops with the editor mounted insert the block at the drop position via `brain_editor_save` instead. |
| `add_source_from_message` | Client to Server | `ChatLive` | Creates `:source` block from a URL/title dragged from a citation |
| `brain_text_selected` | Client to Server | `ChatLive` | Stores `%{text, page_title}` in `brain_selection` assign for context inclusion |
| `brain_text_cleared` | Client to Server | `ChatLive` | Clears `brain_selection` assign |
| `ask_about_block` | Client to Server | `ChatLive` | Injects block text and page title into the next message send as context |
| `brain:reload_blocks` | Server to Client | `brain_editor.js` | Forces TipTap to replace its document with canonical server blocks after conflict |

## Block Versioning (AshPaperTrail)

Block uses `AshPaperTrail.Resource` with `:snapshot` mode. The Brain domain uses `AshPaperTrail.Domain`.

```
Block create/update/destroy
        |
        v
AshPaperTrail creates version in brain_blocks_versions
  - version_action_type: :create | :update | :destroy
  - version_action_name: e.g. :update, :restore_version
  - changes: full snapshot of all tracked attributes
  - user_id: actor FK (belongs_to_actor)
```

**Restore flow:** The `restore_version` action on Block takes a `version_id` argument. `RestoreVersion` change (`lib/magus/brain/block/changes/restore_version.ex`) fetches the version, validates it belongs to the target block (`version_source_id == block.id`), then force-sets `content` and `metadata` from the snapshot. The restore itself creates a new version entry.

**Helper:** `Brain.list_block_versions(block_id)` queries `Block.Version` sorted by `version_inserted_at` desc.

## Autonomous Agent Access

Custom agents with `BrainAccess` (grantee_type: `:custom_agent`) can work on brains during autonomous heartbeat wake-ups without a user having a brain pane open.

### Heartbeat Integration

```
HeartbeatScheduler (Oban, every 5 min) finds due agents
        |
        v
RunOrchestrator.enqueue (source: :heartbeat)
        |
        v
Builder prepends WakeupPreamble to the agent's system prompt
        |
        v
ConversationAgent ReAct loop in the home conversation
  - Brain access flows through the standard Builder context (BrainContext,
    BrainRagContext) just like a chat turn
  - ToolBuilder (Tier 7) injects the 2 brain tools when the agent holds
    BrainAccess (5+8 actions across navigate_brain and edit_brain)
```

Brain context is gathered through the same `BrainContext` and `BrainRagContext` modules used for normal chat turns; there is no separate triage-time brain context module. `BrainRagContext` works for custom agents with `BrainAccess`, providing semantic search across all brains the agent can access on every turn (chat or wake-up).

The consolidated tools accept optional `brain_id` and `page_id` parameters resolved via `BrainResolver` so autonomous agents can target specific brains and pages without an active pane.

## Key Files Reference

| File | Purpose |
|------|---------|
| `lib/magus/brain/brain.ex` | Domain definition with all code interfaces |
| `lib/magus/brain/brain_resource.ex` | BrainResource Ash resource |
| `lib/magus/brain/page.ex` | Page Ash resource |
| `lib/magus/brain/block.ex` | Block Ash resource with AshOban triggers |
| `lib/magus/brain/connection.ex` | Connection Ash resource |
| `lib/magus/brain/brain_access.ex` | BrainAccess Ash resource |
| `lib/magus/brain/topics.ex` | PubSub topic name helpers |
| `lib/magus/brain/brain_presence.ex` | Registry-based viewer presence tracking |
| `lib/magus/brain/sync.ex` | Data loading and block reconciliation |
| `lib/magus/brain/source_ingester.ex` | URL fetch + HTML extraction + child block creation |
| `lib/magus/brain/block_content.ex` | Shared text extraction helpers |
| `lib/magus/brain/changes/auto_position.ex` | Fractional position assignment |
| `lib/magus/brain/changes/broadcast_brain_event.ex` | PubSub broadcast on every mutation |
| `lib/magus/brain/changes/generate_block_embedding.ex` | pgvector embedding for blocks |
| `lib/magus/brain/changes/ingest_source.ex` | Async source URL ingestion |
| `lib/magus/brain/changes/parse_references.ex` | `[[Page Name]]` wikilink parsing |
| `lib/magus/brain/changes/slugify.ex` | Slug generation |
| `lib/magus/brain/checks/actor_owns_brain.ex` | Parameterized policy check |
| `lib/magus/brain/block/validations/lock_version.ex` | Client-side staleness check |
| `lib/magus/brain/block/changes/restore_version.ex` | Restores block content from paper trail version |
| `lib/magus/brain/markdown_to_blocks.ex` | Markdown to brain block spec converter |
| `lib/magus/agents/context/brain_context.ex` | System prompt section builder |
| `lib/magus/agents/context/brain_rag_context.ex` | Semantic RAG context from brain content on every message |
| `lib/magus/agents/tools/brain/` | 2 consolidated agent tools (navigate_brain, edit_brain) |
| `lib/magus/agents/tools/brain/brain_resolver.ex` | Smart brain/page auto-discovery for all tools |
| `lib/magus/agents/tools/tool_builder.ex` | Tier 7 brain tool injection when brain_id present or agent has BrainAccess |
| `priv/skills/brain_management.md` | Placement heuristics skill |
| `lib/magus_web/app/live/chat_live/brain_handlers.ex` | Socket orchestration |
| `lib/magus_web/app/live/chat_live/brain_pubsub_handlers.ex` | PubSub event dispatch |
| `assets/js/hooks/brain_editor.js` | TipTap editor hook |
| `assets/js/hooks/draggable_message.js` | Message drag-to-brain hook |
