# Signal Architecture

How real-time signals flow from the agent layer to the UI — the plugin pipeline that translates internal ReAct signals to PubSub broadcasts, and how tool events (including sub-steps) are streamed to the browser.

## Design Principles

1. **Single source of truth**: All real-time UI state (thinking indicators, streaming status, tool events) is managed via the `agents:{conversation_id}` PubSub topic. Ash PubSub only manages the message list.
2. **Plugin-based signal translation**: Internal ReAct signals (`ai.*`) are translated to Magus PubSub events by composable plugins, each responsible for one concern.
3. **Single exit point**: All agent response paths (success, error, cancel, limit exceeded) funnel through the PersistencePlugin, guaranteeing the UI always receives a terminal signal.
4. **Hierarchical tool events**: Tools can emit sub-steps with streaming content, enabling Claude Code-style progress display.

## Signal Flow Overview

The ConversationAgent uses `ReactStrategy` which delegates LLM calls to an internal ReAct worker. The worker emits internal signals (`ai.*`), which are forwarded to the parent agent and intercepted by the plugin pipeline before reaching the strategy's signal router.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           SIGNAL FLOW                                           │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   ReAct Worker (internal)                                                      │
│        │                                                                        │
│        │  ai.llm.delta, ai.llm.response, ai.tool.started,                     │
│        │  ai.tool.result, ai.request.*, ai.usage                               │
│        │                                                                        │
│        ▼                                                                        │
│   ┌──────────────────────────────────────────────────────────────────────────┐  │
│   │              ReactStrategy (parent agent)                                 │  │
│   │                                                                           │  │
│   │   Receives via "ai.react.worker.event"                                   │  │
│   │   Unpacks runtime events → re-emits to plugin pipeline                   │  │
│   └──────────────────────────────────────────────────────────────────────────┘  │
│        │                                                                        │
│        ▼  Plugins intercept signals BEFORE strategy routing                    │
│   ┌──────────────────────────────────────────────────────────────────────────┐  │
│   │                         PLUGIN PIPELINE                                   │  │
│   │                                                                           │  │
│   │   StreamingPlugin:                                                        │  │
│   │     ai.llm.delta (content) → Signals.text_chunk()                        │  │
│   │     ai.llm.delta (thinking) → Signals.thinking_chunk()                   │  │
│   │     ai.request.started → Signals.state_change(:thinking|:reasoning)      │  │
│   │     ai.llm.turn.started → Signals.turn_started()                         │  │
│   │     ai.llm.turn.completed → Signals.turn_completed()                     │  │
│   │                                                                           │  │
│   │   PersistencePlugin:                                                      │  │
│   │     ai.llm.response → MessagePersistence.persist_response()              │  │
│   │                        + Signals.text_complete()                          │  │
│   │     ai.request.completed → Signals.state_change(:idle)                   │  │
│   │                            + Signals.response_complete()                  │  │
│   │     ai.request.failed → Signals.error() + idle + complete                │  │
│   │                                                                           │  │
│   │   ToolEventPlugin:                                                        │  │
│   │     ai.tool.started → Signals.broadcast_tool_start()                     │  │
│   │                       returns {:ok, {:override, Noop}}                    │  │
│   │     ai.tool.result → persist_tool_result() + broadcast_tool_complete()   │  │
│   │                      + Signals.state_change(:thinking)                    │  │
│   │                                                                           │  │
│   │   UsagePlugin:                                                            │  │
│   │     ai.usage → UsageRecorder.record!() (best-effort)                     │  │
│   │                                                                           │  │
│   │   AgentRunCompletionPlugin:                                               │  │
│   │     ai.request.completed → mark AgentRun complete (if child conv)        │  │
│   │     ai.request.failed → mark AgentRun failed (if child conv)             │  │
│   │                                                                           │  │
│   │   IntegrationReplyPlugin:                                                 │  │
│   │     ai.request.* → send reply to external channel (if linked)            │  │
│   └──────────────────────────────────────────────────────────────────────────┘  │
│        │                                                                        │
│        │  PubSub broadcasts                                                    │
│        ▼                                                                        │
│   ┌──────────────────────────────────────────────────────────────────────────┐  │
│   │                    ChatLive.handle_info/2                                  │  │
│   │                                                                           │  │
│   │   match: %Broadcast{topic: "agents:" <> conv_id, event: "agent_signal"}  │  │
│   │       │                                                                   │  │
│   │       └──▶ PubSubHandlers.handle_agent_signal(socket, conv_id, payload)  │  │
│   └──────────────────────────────────────────────────────────────────────────┘  │
│        │                                                                        │
│        ▼                                                                        │
│   ┌──────────────────────────────────────────────────────────────────────────┐  │
│   │                    PubSubHandlers                                          │  │
│   │                                                                           │  │
│   │   case payload.type do                                                    │  │
│   │     "text.chunk"      → stream_insert streaming message                 │  │
│   │     "text.complete"   → reset streaming assigns                         │  │
│   │     "thinking.chunk"  → update reasoning display                        │  │
│   │     "turn.started"    → track iteration/model info                      │  │
│   │     "turn.completed"  → handle tool_calls or final_answer turn type     │  │
│   │     "state.change"    → derive_thinking_state() → update assigns        │  │
│   │     "response.complete" → reset_streaming_state + refresh usage         │  │
│   │     "error"           → reset_streaming_state + log                     │  │
│   │     "tool.start"      → add to tracker + stream_insert ephemeral       │  │
│   │     "tool.progress"   → update tracker + stream_insert ephemeral       │  │
│   │     "tool.complete"   → mark complete + stream_insert ephemeral        │  │
│   │     "tool.step.*"     → update sub-step + stream_insert ephemeral      │  │
│   │   end                                                                     │  │
│   │                                                                           │  │
│   │   Result: socket assigns updated → LiveView re-renders                   │  │
│   └──────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Internal vs External Signals

The architecture has two signal layers:

### Internal Signals (ReAct Worker → Strategy → Plugins)

These are emitted by the ReAct worker and forwarded to the parent agent. Plugins intercept them before strategy routing.

| Internal Signal | Emitter | Description |
|-----------------|---------|-------------|
| `ai.llm.delta` | ReAct Worker | LLM streaming chunk (content or thinking) |
| `ai.llm.response` | ReAct Worker | Complete LLM response for a turn |
| `ai.llm.turn.started` | ReAct Worker | New LLM turn beginning |
| `ai.llm.turn.completed` | ReAct Worker | LLM turn finished (tool_calls or final_answer) |
| `ai.tool.started` | ReAct Worker | About to execute a tool |
| `ai.tool.result` | ReAct Worker | Tool execution completed |
| `ai.request.started` | ReAct Worker | ReAct loop beginning |
| `ai.request.completed` | ReAct Worker | ReAct loop finished successfully |
| `ai.request.failed` | ReAct Worker | ReAct loop failed or cancelled |
| `ai.usage` | ReAct Worker | Token usage data |
| `agent.task.spawned` | Strategy | Sub-agent task dispatched |
| `agent.task.progress` | Strategy | Sub-agent task progress |
| `agent.task.completed` | Strategy | Sub-agent task finished |
| `agent.task.failed` | Strategy | Sub-agent task errored |

### External Signals (Plugins → PubSub → LiveView)

These are broadcast to the `agents:{conversation_id}` PubSub topic by the plugin pipeline.

| External Signal | Source Plugin | Description |
|-----------------|---------------|-------------|
| `state.change` | StreamingPlugin / PersistencePlugin / ToolEventPlugin | Agent state transition |
| `text.chunk` | StreamingPlugin | Streaming text chunk |
| `thinking.chunk` | StreamingPlugin | Reasoning/thinking token stream |
| `turn.started` | StreamingPlugin | New LLM turn with iteration/model info |
| `turn.completed` | StreamingPlugin | LLM turn finished |
| `text.complete` | PersistencePlugin | Response persisted to DB |
| `response.complete` | PersistencePlugin | Full request cycle done |
| `error` | PersistencePlugin | Error occurred during processing |
| `tool.start` | ToolEventPlugin | Tool execution beginning |
| `tool.complete` | ToolEventPlugin | Tool execution finished |
| `tool.progress` | Tool (via Signals) | Progress update from tool |
| `tool.step.*` | Tool (via Signals) | Hierarchical sub-step events |
| `run.started` | AgentRunCompletionPlugin | AgentRun execution started |
| `run.progress` | AgentRunCompletionPlugin | AgentRun progress update |
| `run.completed` | AgentRunCompletionPlugin | AgentRun finished successfully |
| `run.failed` | AgentRunCompletionPlugin | AgentRun errored |

## Agent State Machine

The agent broadcasts state transitions at well-defined points. The UI uses `derive_thinking_state/1` to map these to visual indicators. State transitions are driven by plugins intercepting internal signals:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         AGENT STATE MACHINE                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│                              ┌──────────┐                                      │
│                    ┌────────▶│   IDLE   │◀──────────┐                          │
│                    │         └────┬─────┘           │                          │
│                    │              │                  │                          │
│                    │              │ message.user     │ PersistencePlugin        │
│                    │              │ signal           │ (ai.request.completed    │
│                    │              ▼                  │  or ai.request.failed)   │
│                    │         ┌──────────┐           │                          │
│                    │    ┌───▶│ THINKING │───┐       │                          │
│                    │    │    └──────────┘   │       │                          │
│                    │    │         │         │       │                          │
│                    │    │    first chunk    │       │                          │
│                    │    │    arrives        │       │                          │
│                    │    │    ┌──────┴───┐   │       │                          │
│                    │    │    ▼          ▼   │       │                          │
│                    │    │ ┌─────────┐ ┌─────────┐  │                          │
│                    │    │ │STREAMING│ │REASONING│  │                          │
│                    │    │ │ (text)  │ │(thought)│  │                          │
│                    │    │ └────┬────┘ └────┬────┘  │                          │
│                    │    │      │            │       │                          │
│                    │    │      └─────┬──────┘       │                          │
│                    │    │            │               │                          │
│                    │    │     has tool calls?        │                          │
│                    │    │      yes   │   no          │                          │
│                    │    │      ┌─────┴─────┐         │                          │
│                    │    │      ▼           │         │                          │
│                    │    │ ┌──────────────┐ │         │                          │
│                    │    │ │RUNNING_TOOLS │ │         │                          │
│                    │    │ └──────┬───────┘ │         │                          │
│                    │    │       │          │         │                          │
│                    │    │  tools done     │         │                          │
│                    │    │       │          │         │                          │
│                    │    └───────┘          └─────────┘                          │
│                                                                                 │
│   Special media modes (bypasses ReAct via InboundPlugin):                      │
│   ┌──────────────────┐  ┌──────────────────┐                                  │
│   │ GENERATING_IMAGE │  │ GENERATING_VIDEO │                                  │
│   └──────────────────┘  └──────────────────┘                                  │
│   (entered from THINKING, exits to IDLE via PersistencePlugin)                │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### State Transition Points

Every `Signals.state_change()` call, which plugin triggers it, and where:

| # | Plugin / Module | Signal Trigger | State | Purpose |
|---|-----------------|----------------|-------|---------|
| 1 | StreamingPlugin | `ai.request.started` | `:thinking` or `:reasoning` | Initial entry — mode-dependent |
| 2 | StreamingPlugin | `ai.llm.delta` (first thinking chunk) | `:reasoning` | Reasoning tokens arriving |
| 3 | StreamingPlugin | `ai.llm.turn.completed` (with tool_calls) | `:running_tools` | Turn ended with tool calls |
| 4 | ToolEventPlugin | `ai.tool.started` | `:running_tools` | Tool execution beginning |
| 5 | ToolEventPlugin | `ai.tool.result` | `:thinking` | Tool done, returning focus to model |
| 6 | PersistencePlugin | `ai.request.completed` | `:idle` | Terminal — all processing done |
| 7 | PersistencePlugin | `ai.request.failed` | `:idle` | Terminal — error or cancellation |
| 8 | InboundPlugin | `ai.request.error` (rejection) | `:idle` | Terminal — request rejected (busy) |
| 9 | InboundPlugin (MediaBypass) | media generation start | `:generating_image` / `:generating_video` | Media generation in progress |

Note: The UI helper `derive_thinking_state/1` also handles `:streaming` state (maps to `is_streaming: true`), but this state is not currently emitted by any plugin. It is reserved for future use.

### UI State Mapping

`Helpers.derive_thinking_state/1` maps agent states to UI assigns:

| Agent State | `waiting_for_response` | `thinking_status` | `is_streaming` |
|-------------|------------------------|--------------------|----------------|
| `:idle` | `false` | `nil` | `false` |
| `:thinking` | `true` | `:thinking` | `false` |
| `:streaming` | `true` | `:generating_response` | `true` |
| `:reasoning` | `true` | `:reasoning` | `false` |
| `:running_tools` / `:tool_calling` | `true` | `:running_tools` | `false` |
| `:generating_image` | `true` | `:generating_image` | `false` |
| `:generating_video` | `true` | `:generating_video` | `false` |

## Signal Types Reference

### Text Streaming

| Signal | Payload | Persisted? | Description |
|--------|---------|------------|-------------|
| `text.chunk` | `message_id`, `text`, `delta` | No | Streaming chunk for real-time display |
| `text.complete` | `message_id`, `text`, `usage` | No* | End of one streaming iteration |
| `thinking.chunk` | `message_id`, `text`, `delta` | No | Reasoning/thinking token stream |

*The final message is persisted separately by the PersistencePlugin and arrives via Ash PubSub.

### Turn Lifecycle

| Signal | Payload | Description |
|--------|---------|-------------|
| `turn.started` | `iteration`, `turn_id`, `call_id`, `model` | New LLM call beginning |
| `turn.completed` | `turn_type` (`:tool_calls` or `:final_answer`), `iteration` | LLM call finished |

### State & Lifecycle

| Signal | Payload | Description |
|--------|---------|-------------|
| `state.change` | `state` (atom) | Agent state transition |
| `response.complete` | `triggering_message_id` | Full response cycle done — resets all UI state |
| `error` | `message_id`, `error_type`, `error_message` | Error occurred during processing |

### Tool Events

| Signal | Payload | Description |
|--------|---------|-------------|
| `tool.start` | `event_id`, `tool_name`, `display_name`, `inputs` | Tool execution beginning |
| `tool.progress` | `event_id`, `tool_name`, `progress_type`, `data` | Incremental progress update |
| `tool.complete` | `event_id`, `tool_name`, `status`, `output_summary`, `duration_ms`, `error` | Tool execution finished |

### Tool Sub-Steps

Sub-steps provide hierarchical progress within a single tool execution (tool → steps → streaming content).

| Signal | Payload | Description |
|--------|---------|-------------|
| `tool.step.start` | `event_id`, `step_id`, `step_index`, `label`, `data` | New sub-step beginning |
| `tool.step.progress` | `event_id`, `step_id`, `content`, `mode` | Stream content into sub-step (`:append` or `:replace`) |
| `tool.step.complete` | `event_id`, `step_id`, `status`, `summary` | Sub-step finished |

## PubSub Topic Ownership

The `agents:{conversation_id}` topic is the **single source of truth** for all real-time UI state. Other topics serve different purposes:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          PUBSUB TOPIC OWNERSHIP                              │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   agents:{conversation_id}         ← OWNS real-time UI state               │
│   ├── state.change                    (thinking indicators, streaming)       │
│   ├── text.chunk / text.complete      (message content)                     │
│   ├── thinking.chunk                  (reasoning display)                    │
│   ├── turn.started / turn.completed   (LLM turn lifecycle)                  │
│   ├── response.complete               (terminal reset)                      │
│   ├── error                           (error reset)                         │
│   ├── tool.*                          (tool lifecycle events)               │
│   └── tool.step.*                     (tool sub-step events)                │
│                                                                              │
│   chat:messages:{conversation_id}  ← OWNS message list (Ash PubSub)        │
│   └── Message created/updated/destroyed                                     │
│       (stream_insert / stream_delete for the messages stream)               │
│       NOTE: Does NOT modify thinking_status or is_streaming.                │
│       Exception: :job_trigger messages set initial thinking state.          │
│                                                                              │
│   chat:typing:{conversation_id}    ← Multiplayer typing indicators          │
│   ├── thinking (broadcast to other users when agent starts/stops)           │
│   └── user_typing (human typing indicators)                                 │
│                                                                              │
│   chat:conversations:{id}          ← Conversation metadata (Ash PubSub)    │
│   chat:members:{id}                ← Multiplayer membership changes         │
│   chat:events:{id}                 ← Multiplayer events (join/leave)        │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Tool Event Lifecycle

Tool events render through the `:messages` stream — the same stream used for persisted messages. This eliminates duplicate rendering by leveraging Phoenix LiveView's native ID-based deduplication: when a persisted message arrives with the same ID as an ephemeral entry, `stream_insert` replaces it automatically.

The `tool_event_tracker` is a state-only map (not used for rendering) that accumulates progress and steps across incremental signal updates.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        TOOL EVENT LIFECYCLE IN UI                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   tool.start signal (from ToolEventPlugin)                                     │
│       │                                                                         │
│       ▼                                                                         │
│   ┌─────────────────────────────┐  ┌──────────────────────────────────┐        │
│   │  tool_event_tracker[id]     │  │  stream_insert(:messages,        │        │
│   │  (state accumulator)        │  │    build_ephemeral_event(tool),   │        │
│   │  status: :in_progress       │  │    at: 0)                        │        │
│   └─────────────┬───────────────┘  └──────────────────────────────────┘        │
│                 │                                                               │
│                 │  tool.progress / tool.step.* signals                         │
│                 │  (update tracker + stream_insert updated ephemeral)          │
│                 │                                                               │
│   tool.complete signal (from ToolEventPlugin)                                  │
│       │                                                                         │
│       ▼                                                                         │
│   ┌─────────────────────────────┐  ┌──────────────────────────────────┐        │
│   │  tool_event_tracker[id]     │  │  stream_insert(:messages,        │        │
│   │  status: :complete          │  │    build_ephemeral_event(tool),   │        │
│   │  output_summary: "Found 5"  │  │    at: 0)                        │        │
│   └─────────────────────────────┘  └──────────────────────────────────┘        │
│                                                                                 │
│   Persisted event message arrives via Ash PubSub                               │
│       │  (message.id == event_id — SAME ID)                                   │
│       ▼                                                                         │
│   ┌─────────────────────────────┐                                              │
│   │  stream_insert(:messages,   │  Replaces ephemeral entry in-place          │
│   │    persisted_message)       │  (native LiveView stream dedup)             │
│   │                             │                                              │
│   │  maybe_clean_tracker/2      │  Removes entry from tracker                 │
│   └─────────────────────────────┘                                              │
│                                                                                 │
│   response.complete signal (from PersistencePlugin)                            │
│       │                                                                         │
│       └──▶ reset_streaming_state/1 clears tool_event_tracker (safety net)     │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Why This Works

The `event_id` (UUIDv7) used for real-time tool signals is the same value as the persisted event message's `id`. The `build_ephemeral_event/1` function shapes the tracker data into a map that routes through the same `event_message/1` → `tool_call_entry/1` component path as persisted messages. When the Ash PubSub message arrives with the same ID, `stream_insert` replaces the ephemeral entry seamlessly — no flash, no duplicate, no custom deduplication logic.

## Tool Sub-Steps (Hierarchical Progress)

Tools can emit sub-steps for detailed progress display. Each sub-step can stream content independently:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          TOOL WITH SUB-STEPS                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   Tool: WebSearch                                                              │
│   ├── Step 0: "Searching web"          status: :complete                       │
│   │   └── content: "Found 5 results"                                           │
│   ├── Step 1: "Fetching example.com"   status: :in_progress                   │
│   │   └── content: "Loading page..." (streaming via tool.step.progress)       │
│   └── Step 2: "Summarizing"           status: :in_progress                    │
│       └── content: ""                                                          │
│                                                                                 │
│   Tool context provides emit helpers:                                          │
│                                                                                 │
│     Signals.emit_tool_step_start(context, 0, "Searching web")                 │
│     # ... do work ...                                                          │
│     Signals.emit_tool_step_progress(context, 0, "Found 5 results")            │
│     Signals.emit_tool_step_complete(context, 0)                                │
│                                                                                 │
│     Signals.emit_tool_step_start(context, 1, "Fetching example.com")          │
│     Signals.emit_tool_step_progress(context, 1, "chunk1...")                   │
│     Signals.emit_tool_step_progress(context, 1, "chunk2...")  # appends       │
│     Signals.emit_tool_step_complete(context, 1, :complete, "Page loaded")     │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Emitting Signals from Tools

Tools receive event metadata in their context (prefixed with `__`). The `Signals` module provides context-based helpers that extract this metadata automatically:

```elixir
defmodule Magus.Agents.Tools.MyTool do
  use Jido.Action, name: "my_tool", schema: [query: [type: :string, required: true]]

  alias Magus.Agents.Signals

  def run(params, context) do
    # Tool-level progress (flat)
    Signals.emit_tool_progress(context, :searching, %{query: params.query})

    # Sub-step progress (hierarchical)
    Signals.emit_tool_step_start(context, 0, "Searching")
    results = do_search(params.query)
    Signals.emit_tool_step_complete(context, 0, :complete, "Found #{length(results)} results")

    Signals.emit_tool_step_start(context, 1, "Processing results")
    Enum.each(results, fn r ->
      Signals.emit_tool_step_progress(context, 1, "- #{r.title}\n")
    end)
    Signals.emit_tool_step_complete(context, 1)

    {:ok, %{results: results}}
  end
end
```

## Error Handling

All error paths converge through the PersistencePlugin which guarantees the UI receives terminal signals:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           ERROR PATH CONVERGENCE                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   ReAct worker error ──▶ ai.request.failed signal                              │
│                               │                                                 │
│                               ▼                                                 │
│                          PersistencePlugin                                      │
│                               │                                                 │
│                               ├──▶ Log error (unless cancelled)                │
│                               ├──▶ Signals.error(conv_id, msg_id, type, msg)   │
│                               ├──▶ Signals.state_change(conv_id, :idle)        │
│                               └──▶ Signals.response_complete(conv_id, ...)     │
│                                                                                 │
│   Media generation error ──▶ InboundPlugin (MediaBypass) handles error         │
│                               │                                                 │
│                               ├──▶ Creates error event message                 │
│                               ├──▶ Signals.error(conv_id, msg_id, type, msg)   │
│                               ├──▶ Signals.state_change(conv_id, :idle)        │
│                               └──▶ Signals.response_complete(conv_id, ...)     │
│                                                                                 │
│   Request rejected ────────▶ InboundPlugin (ai.request.error handler)          │
│   (agent busy)                │                                                 │
│                               ├──▶ Signals.error(conv_id, msg_id, type, msg)   │
│                               ├──▶ Signals.state_change(conv_id, :idle)        │
│                               └──▶ Signals.response_complete(conv_id, ...)     │
│                                                                                 │
│   Limit exceeded ──────────▶ InboundPlugin (Preflight rejects)                 │
│                               │                                                 │
│                               ├──▶ Creates limit event message                 │
│                               ├──▶ Signals.state_change(conv_id, :idle)        │
│                               └──▶ Signals.response_complete(conv_id, ...)     │
│                                                                                 │
│   The UI's handle_response_complete resets ALL streaming state via              │
│   reset_streaming_state/1, ensuring no stuck indicators.                       │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Key Files Reference

| File | Responsibility |
|------|----------------|
| `lib/magus/agents/signals.ex` | All PubSub broadcast functions + context-based emit helpers |
| `lib/magus/agents/strategies/react_strategy.ex` | ReAct strategy with worker delegation, signal routing |
| `lib/magus/agents/plugins/inbound_plugin.ex` | Signal transformation, pre-flight, media bypass |
| `lib/magus/agents/plugins/streaming_plugin.ex` | LLM streaming → PubSub, state transitions |
| `lib/magus/agents/plugins/persistence_plugin.ex` | Response persistence, request lifecycle |
| `lib/magus/agents/plugins/tool_event_plugin.ex` | Tool events → PubSub, tool result persistence |
| `lib/magus/agents/plugins/usage_plugin.ex` | Token usage recording |
| `lib/magus/agents/plugins/agent_run_completion_plugin.ex` | AgentRun completion + auto-report to parent |
| `lib/magus/agents/plugins/activity_log_plugin.ex` | Audit trail for control room |
| `lib/magus/agents/plugins/integration_reply_plugin.ex` | Channel reply sending |
| `lib/magus_web/live/chat_live.ex` | PubSub subscription + dispatch to handlers |
| `lib/magus_web/live/chat_live/pubsub_handlers.ex` | Signal → socket assign mapping |
| `lib/magus_web/live/chat_live/helpers.ex` | `derive_thinking_state/1`, usage computation |
