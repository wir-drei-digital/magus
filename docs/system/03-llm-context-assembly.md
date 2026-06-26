# LLM Context Assembly Pipeline

How the system builds the full message payload sent to the LLM on each user message.

## Architecture Overview

```
User Message
    |
    v
InboundPlugin (signal transform + validation)
    |
    v
Preflight (model resolution, usage limits, context orchestration)
    |
    v
Builder.build_llm_context/7 (single entry point)
    |
    +---> Phase 1: Parallel DB queries
    |       - WorkspaceContext.build
    |       - JobsContext.build
    |       - DraftContext.build
    |       - TaskContext.build
    |       - BuildMemoryContext.build (semantic search)
    |       - RagContext.build (file knowledge retrieval)
    |
    +---> Phase 2: System prompt composition
    |       - SystemPrompts.build (base rules + mode + custom layer + time + tasks + skills)
    |       - append_memory_context (memory search results)
    |       - append_rag_context (file knowledge results)
    |
    +---> Phase 3: Message history
    |       - BuildMessageHistory (Ash action)
    |         - Load messages from DB via :for_llm_context
    |         - Limit to last 20 messages
    |         - Recovery: detect interrupted turns, append text annotations
    |
    +---> Phase 4: Current message
    |       - Text with selection context (message, draft, PDF)
    |       - Attachments (images as binary ContentParts)
    |
    v
Returns {system_prompt, messages}
    |
    v
Preflight builds react signal:
    - system_prompt -> Thread system prompt
    - messages -> initial_messages (prepended before thread)
    - query -> Thread user message (appended by Runner)
    |
    v
Runner.run_llm_step:
    messages = initial_messages ++ thread_messages
    (sent to LLM)
```

## Component Responsibilities

### Builder (`lib/magus/agents/context/builder.ex`)

The orchestrator. Single entry point: `build_llm_context/7`.

**Inputs:** conversation, message_id, text, attachments, mode, model, selections

**Returns:** `{system_prompt :: String.t(), messages :: [ReqLLM.Message.t()]}`

Responsibilities:
- Runs 6 context queries in parallel (workspace, jobs, drafts, tasks, memory, RAG)
- Composes the system prompt via `SystemPrompts.build` + memory + RAG context
- Delegates message history to the `BuildMessageHistory` Ash action
- Builds the current user message with attachments and selection context
- Returns a clean tuple -- no `ReqLLM.Context` wrapping

The system prompt string includes (in order):
1. Base rules and mode-specific instructions (from `SystemPrompts`)
2. Custom agent instructions or active system prompt
3. Time context in user's timezone
4. Workspace/draft/jobs/tasks context
5. Skill listings (when tools are available)
6. Memory context (semantic search results, pinned memories)
7. RAG context (file knowledge retrieval results)

### BuildMessageHistory (`lib/magus/chat/conversation/actions/build_message_history.ex`)

An Ash generic action on `Conversation`. Returns a flat list of `ReqLLM.Message` structs.

**Arguments:** `conversation_id`, `current_message_id` (optional), `is_multiplayer` (default false)

Responsibilities:
- Loads messages via the `:for_llm_context` read action (excludes events, disabled messages, and optionally the current message)
- Converts each message to an `ReqLLM.Message` via the `as_llm_message` calculation
- Limits to the most recent 20 messages
- Detects and recovers interrupted turns (see Recovery below)

Does NOT handle:
- System prompt composition (that's Builder's job)
- Current user message (that's Builder's job)
- Tool/result pairing or sanitization (recovery handles this as text)

### Preflight (`lib/magus/agents/plugins/support/preflight.ex`)

Pre-flight validation before the ReAct strategy runs. Called by `InboundPlugin`.

Responsibilities:
- Resolves the model (including auto-routing)
- Checks usage limits
- Calls `Builder.build_llm_context` and destructures `{system_prompt, initial_messages}`
- Builds tool context and tool list
- Resolves runtime overrides (sampling settings, max iterations)
- Constructs the `ai.react.query` signal with all resolved values

### Runner (`lib/magus/agents/strategies/react/runner.ex`)

The ReAct loop executor. Receives `initial_messages` and `query` via the signal/config.

On each LLM call:
```
messages = initial_messages ++ Thread.to_messages(thread)
```

Where `thread` contains:
- System prompt (set from Preflight's resolved system_prompt)
- The user query (appended by `State.new`)
- Tool calls and results from the current ReAct iteration loop

The thread grows during the agentic loop (tool calls/results accumulate), while `initial_messages` stays fixed as conversation history context.

### MediaBypass (`lib/magus/agents/plugins/support/media_bypass.ex`)

Handles image/video generation requests, bypassing ReAct entirely.

Calls `build_message_history!` directly (no Builder) since media generation only needs conversation history for context, not the full system prompt composition. Wraps the result in `ReqLLM.Context.new()` for compatibility with `MediaGenerator`.

## Message Flow: What the LLM Sees

On iteration 1, the LLM receives these messages in order:

```
[initial_messages]
  1. user: "Previous question"              # from DB (BuildMessageHistory)
  2. assistant: "Previous answer..."         # from DB
  ...
  N. user: "Current question [+ images]"    # built by Builder

[thread_messages]
  1. system: "You are Magus..."              # from SystemPrompts + memory
  2. user: "Current question"                # query text only (no images)
```

Note: The current user message appears twice -- once in `initial_messages` (with attachments/images) and once in the thread (text only). This is by design: `initial_messages` provides the full multimodal context, while the thread's query is what the ReAct loop operates on.

On subsequent iterations (tool loop), `thread_messages` grows:

```
[thread_messages]
  1. system: "You are Magus..."
  2. user: "Current question"
  3. assistant: "Let me search." + tool_calls
  4. tool: "Search result: ..."
```

## Recovery: Interrupted Turn Detection

When a turn is interrupted (error, cancellation, crash mid-tool-execution), the next request needs context about what happened. `BuildMessageHistory` handles this by appending plain text annotations to the last assistant message.

### Detection Logic (`find_recovery_tool_calls`)

```
Both last_agent and last_user are nil?
  -> [] (empty conversation, skip)

last_agent is nil?
  -> DB fallback: find hidden agent messages with tool_call_data

last_agent.status in [:error, :streaming]?
  -> Extract tool_calls from tool_call_data

last_agent.status == :complete AND tool_call_data present?
  -> Extract tool_calls (cancellation case: message marked complete but tools recorded)

last_agent.status == :complete AND no tool_call_data?
  -> [] (normal completion, no recovery needed)
```

### Text Annotation Format

When recovery triggers, the last assistant message gets text appended:

```
[Previous turn called: web_search, update_draft]
[web_search result: Found 3 results about Elixir]
[update_draft result: interrupted]
```

Each tool either has a matching event with an `output_summary`, or gets labeled "interrupted". Summaries are truncated to 500 characters.

### Why Text Instead of Structured Messages

Earlier versions synthesized structured `tool_calls` + `tool_result` message pairs for recovery. This was fragile:

- LLM APIs require strict tool_use/tool_result pairing -- orphaned results cause errors
- `ReqLLM.Message` structs can't have keys deleted via `Map.delete` without breaking
- Required a separate `sanitize_tool_pairing` pass (~115 lines) in the Runner to clean up any pairing violations

Text annotations avoid all of this. The LLM gets natural-language context about what happened, and there are no structural constraints to violate.

## Key Design Decisions

### Builder returns `{system_prompt, messages}`, not `ReqLLM.Context`

The system prompt needs to be passed separately to the ReAct strategy (it goes into `Thread.system_prompt`), while messages become `initial_messages`. Returning a tuple makes this explicit and avoids the old pattern of wrapping in `ReqLLM.Context` only to immediately extract the system message back out.

### Message history is a separate Ash action

`BuildMessageHistory` is a generic Ash action on `Conversation`, not a function in Builder. This gives it:
- Its own authorization policy (bypassed for system use)
- A clean domain interface (`Magus.Chat.build_message_history!`)
- Testability independent of Builder's orchestration

### Builder owns system prompt + memory composition

System prompt assembly (mode rules, custom agent instructions, skills, memory context) all happens in Builder. The Ash action just returns raw message history. This keeps the Ash action simple and focused.

### MediaBypass skips Builder entirely

Image/video generation only needs conversation history for prompt context. It calls `build_message_history!` directly and doesn't need system prompt composition, tool context, or the full Builder orchestration.

## File Reference

| Component | File |
|-----------|------|
| Builder | `lib/magus/agents/context/builder.ex` |
| SystemPrompts | `lib/magus/agents/context/system_prompts.ex` |
| BuildMessageHistory | `lib/magus/chat/conversation/actions/build_message_history.ex` |
| ForLlmContext prep | `lib/magus/chat/message/preparations/for_llm_context.ex` |
| Preflight | `lib/magus/agents/plugins/support/preflight.ex` |
| MediaBypass | `lib/magus/agents/plugins/support/media_bypass.ex` |
| Runner | `lib/magus/agents/strategies/react/runner.ex` |
| WorkspaceContext | `lib/magus/agents/context/workspace_context.ex` |
| JobsContext | `lib/magus/agents/context/jobs_context.ex` |
| DraftContext | `lib/magus/agents/context/draft_context.ex` |
| TaskContext | `lib/magus/agents/context/task_context.ex` |
| BuildMemoryContext | `lib/magus/agents/actions/build_memory_context.ex` |
| RagContext | `lib/magus/agents/context/rag_context.ex` |
| ToolCallHelpers | `lib/magus/chat/message/tool_call_helpers.ex` |
