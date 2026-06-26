# Onboarding & Feature Discovery

How the system guides new users through feature discovery and tracks feature usage for progressive disclosure.

## Architecture Overview

```
New Chat Page (UI)
    |
    v
FeatureUsage domain queries
    - undiscovered_features(user_id)
    - unseen_announcements(user_id)
    |
    v
Three view states:
    1. First-time user: Welcome heading + all 4 feature cards (2x2 grid)
    2. Returning user: "New Conversation" + announcements + remaining cards
    3. Fully onboarded: "New Conversation" + announcements only
    |
    v
User clicks feature card
    |
    +---> Navigate to /chat?skill=onboarding&topic={feature}
    |
    v
Onboarding skill guides user through feature
    |
    v
Feature usage tracked (Ash resource + PubSub broadcast)
    |
    v
LiveView receives PubSub event → removes card in real-time
```

## Four Layers

| Layer | Purpose | Files |
|-------|---------|-------|
| **Feature Usage Domain** | Track usage events, query onboarding state | `lib/magus/feature_usage/` |
| **Action Cards Component** | Generic reusable interactive card UI | `lib/magus_web/app/components/action_cards.ex` |
| **New Chat Page** | Empty state with progressive disclosure | `lib/magus_web/app/live/chat_live/new_chat_page.ex` |
| **Onboarding Skill** | Guided walkthrough per feature | `priv/skills/onboarding.md` |

## Feature Usage Domain

An isolated Ash domain (`Magus.FeatureUsage`) for tracking which features users have interacted with. Serves both analytics and onboarding state.

### FeatureUsageEvent (`lib/magus/feature_usage/feature_usage_event.ex`)

Ash resource backed by `feature_usage_events` table.

**Attributes:**

| Field | Type | Notes |
|-------|------|-------|
| `id` | uuid_v7 | Primary key |
| `feature` | string | Feature key (e.g. `"prompts"`, `"web_search"`) |
| `action` | string | Action type (e.g. `"create"`, `"execute"`, `"seen"`) |
| `metadata` | map | Optional context (e.g. `%{"announcement_id" => key}`) |
| `user_id` | uuid | Foreign key to User |
| `inserted_at` | timestamp | Auto-generated |

**Actions:**
- `:track` — Create action. Accepts `user_id` as argument, `feature`/`action`/`metadata` as attributes. Runs `BroadcastUsage` change after insert.
- `:for_user` — Read action filtered by `actor(:id)`, sorted by `inserted_at` desc.

**Index:** Composite index on `(user_id, feature)` for efficient lookups.

### Announcement (`lib/magus/feature_usage/announcement.ex`)

Ash resource for feature announcements shown on the new chat page.

**Attributes:** `key` (unique), `title` (map — locale map `%{"en" => "...", "de" => "..."}`), `description` (map — locale map), `icon`, `action_type`, `action_payload`, `active` (boolean).

**Actions:**
- `:active` — Read action filtered by `active == true`
- `:deactivate` — Sets `active` to false

Seen-state is tracked via FeatureUsageEvent records with `feature: "announcement"`, `action: "seen"`, and `metadata: %{"announcement_id" => key}`.

### BroadcastUsage Change (`lib/magus/feature_usage/changes/broadcast_usage.ex`)

After a `:track` action completes, broadcasts to PubSub topic `feature_usage:{user_id}`:

```elixir
%{
  type: "feature.used",
  feature: event.feature,
  action: event.action,
  user_id: event.user_id,
  metadata: event.metadata,
  timestamp: event.inserted_at
}
```

### Domain Helper API (`lib/magus/feature_usage.ex`)

The domain module doubles as a convenience API (same pattern as `Magus.Memory`):

| Function | Purpose |
|----------|---------|
| `track(user_id, feature, action, metadata \\ %{})` | Record a usage event |
| `discovered?(user_id, feature)` | Check if user has used a feature |
| `undiscovered_features(user_id)` | List of onboarding features not yet used |
| `unseen_announcements(user_id)` | Active announcements user hasn't dismissed |
| `mark_announcement_seen(user_id, key)` | Track announcement as seen |
| `onboarding_features()` | Returns map of feature key → card metadata (title, description, icon, action) |
| `onboarding_feature_keys()` | Returns `["prompts", "reminders", "web_search", "draft_mode", "council", "sandbox"]` |

### Emission Points

Feature usage is tracked at the point where users actually use a feature:

| Feature | Emission Point | File |
|---------|---------------|------|
| `prompts` | Prompt `:create` action `after_action` | `lib/magus/library/prompt.ex` |
| `reminders` | `create_job` tool execution | `lib/magus/agents/plugins/tool_event_plugin.ex` |
| `web_search` | `web_search` tool execution | `lib/magus/agents/plugins/tool_event_plugin.ex` |
| `draft_mode` | Draft `:create` action `after_action` | `lib/magus/drafts/draft.ex` |
| `announcement` | Dismiss button click | `lib/magus_web/live/chat_live.ex` |

Tool-based tracking uses `maybe_track_feature_usage/2` in `ToolEventPlugin`, which maps tool names to feature keys on `ai.tool.result` signals.

## Action Cards Component (`lib/magus_web/components/action_cards.ex`)

A generic, reusable Phoenix function component for rendering interactive cards. Used by onboarding but designed for any context (e.g., agent-generated choices in messages).

### Data Model

```elixir
%{
  "layout" => "grid" | "list",
  "cards" => [
    %{
      "icon" => "✏️",                              # grid layout only
      "title" => "Create a reusable prompt",
      "description" => "Save instructions you use often",
      "action" => %{
        "type" => "navigate" | "send_message" | "prefill",
        "payload" => "/chat?skill=onboarding&topic=prompts"
      }
    }
  ]
}
```

### Layouts

- **`"grid"`** — 2-column grid (`grid grid-cols-2 gap-3`). Shows icon + title + description.
- **`"list"`** — Single column (`flex flex-col gap-2`). Shows letter labels (A, B, C…) + title + description.

### Action Types

| Type | Rendering | Behavior |
|------|-----------|----------|
| `"navigate"` | `<.link navigate={payload}>` | Client-side navigation. Only renders as link if payload starts with `/` (prevents open redirect). |
| `"send_message"` | `<div phx-click="action_card_click">` | Emits event, LiveView sends payload as user message. |
| `"prefill"` | `<div phx-click="action_card_click">` | Emits event, LiveView inserts payload into composer via `push_event("insert_text", ...)`. |

### Usage in Messages

Action cards can be embedded in agent messages via `metadata`:

```elixir
%{metadata: %{"action_cards" => %{"layout" => "list", "cards" => [...]}}}
```

Rendered in `MessageStreamComponent` after citations, gated to agent messages.

## New Chat Page (`lib/magus_web/live/chat_live/new_chat_page.ex`)

Phoenix function component that replaces the default empty state when no conversation is selected.

### Three View States

**1. First-time user** (`first_time? == true`):
- "What would you like to explore?" heading
- All 6 feature cards in a grid via `ActionCards.action_cards`

**2. Returning user** (`undiscovered_features != []`):
- "What's on your mind?" heading
- Announcements section (if any unseen)
- Remaining undiscovered feature cards

**3. Fully onboarded** (`undiscovered_features == []`):
- "New Conversation" heading
- Announcements section only

### Onboarding Cards

Defined as a private function (`onboarding_cards/0`) rather than a module attribute, because `gettext/1` must be evaluated at runtime for correct locale resolution:

```elixir
defp onboarding_cards do
  %{
    "prompts" => %{
      "icon" => "✏️",
      "title" => gettext("Create a reusable prompt"),
      "description" => gettext("Save instructions you use often"),
      "action" => %{"type" => "navigate", "payload" => "/chat?skill=onboarding&topic=prompts"}
    },
    # ... reminders, web_search, draft_mode
  }
end
```

## LiveView Integration (`lib/magus_web/live/chat_live.ex`)

### Mount

- Subscribes to `feature_usage:{user_id}` PubSub topic
- Initializes `undiscovered_features`, `first_time?`, `announcements` assigns

### handle_params (no conversation)

Loads fresh onboarding state:
```elixir
undiscovered = FeatureUsage.undiscovered_features(current_user.id)
announcements = FeatureUsage.unseen_announcements(current_user.id)
first_time? = length(undiscovered) == length(FeatureUsage.onboarding_feature_keys())
```

### Real-Time Card Removal

When a feature is used anywhere in the system, `BroadcastUsage` fires a PubSub event. The LiveView handles it:

```elixir
def handle_info(%{type: "feature.used", feature: feature}, socket) do
  # Remove the feature from undiscovered_features
  # Update first_time? flag
  # Re-render new chat page with fewer cards
end
```

### Announcement Dismissal

The dismiss button emits `phx-click="dismiss_announcement"` with `phx-value-key`. The handler calls `FeatureUsage.mark_announcement_seen/2` and removes the announcement from assigns.

### Skill Topic Routing

Feature cards navigate to `/chat?skill=onboarding&topic={feature}`. The `handle_skill_param` function in ChatLive:

1. Extracts the optional `topic` query parameter
2. Threads it into metadata and the initial message text as "Start: {topic}"
3. The onboarding skill reads the topic from this message to determine which feature to guide

## Onboarding Skill (`priv/skills/onboarding.md`)

A standard skill file with YAML frontmatter. The agent loads it via `LoadSkill` when a conversation starts with `?skill=onboarding`.

**Behavior:**
- Reads the topic from the "Start: {topic}" message
- Guides the user hands-on through the specific feature (prompts, reminders, web_search, or draft_mode)
- After completion, checks remaining undiscovered features and suggests trying them

## File Reference

| Component | File |
|-----------|------|
| FeatureUsage domain | `lib/magus/feature_usage.ex` |
| FeatureUsageEvent resource | `lib/magus/feature_usage/feature_usage_event.ex` |
| Announcement resource | `lib/magus/feature_usage/announcement.ex` |
| BroadcastUsage change | `lib/magus/feature_usage/changes/broadcast_usage.ex` |
| Action Cards component | `lib/magus_web/app/components/action_cards.ex` |
| New Chat Page component | `lib/magus_web/app/live/chat_live/new_chat_page.ex` |
| ChatLive integration | `lib/magus_web/app/live/chat_live.ex` |
| Message rendering | `lib/magus_web/app/live/chat_live/components/message/message_stream_component.ex` |
| Onboarding skill | `priv/skills/onboarding.md` |
| Tool tracking | `lib/magus/agents/plugins/tool_event_plugin.ex` |
| Prompt tracking | `lib/magus/library/prompt.ex` |
| Draft tracking | `lib/magus/drafts/draft.ex` |
| Migration | `priv/repo/migrations/*_create_feature_usage_events.exs` |
| Tests | `test/magus/feature_usage/`, `test/magus_web/components/action_cards_test.exs`, `test/magus_web/live/chat_live/new_chat_page_test.exs` |
