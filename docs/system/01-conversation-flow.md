# Conversation Flow

How messages flow through the Magus conversation system — from user input through agent processing to real-time UI updates, including end-to-end traces for each interaction pattern.

## Message Processing Pipeline

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         CONVERSATION MESSAGE FLOW                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  USER INPUT                                                                      │
│      │                                                                           │
│      ▼                                                                           │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                         1. LIVEVIEW LAYER                                 │   │
│  │                                                                           │   │
│  │   ChatLive                                                                │   │
│  │        │                                                                  │   │
│  │        │ handle_event("send_message", ...)                               │   │
│  │        │                                                                  │   │
│  │        ▼                                                                  │   │
│  │   Chat.send_user_message(conversation_id, text, actor: user)             │   │
│  │                                                                           │   │
│  └───────────────────────────────┬──────────────────────────────────────────┘   │
│                                  │                                              │
│                                  ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                         2. ASH DOMAIN LAYER                               │   │
│  │                                                                           │   │
│  │   Chat Domain                                                             │   │
│  │        │                                                                  │   │
│  │        │ create action with changes:                                     │   │
│  │        │   - SetRole (:user)                                             │   │
│  │        │   - SetCreatedBy                                                │   │
│  │        │   - SignalAgent ← triggers agent after transaction              │   │
│  │        │                                                                  │   │
│  │        ▼                                                                  │   │
│  │   Message resource created in PostgreSQL                                 │   │
│  │        │                                                                  │   │
│  │        │ after_transaction callback                                      │   │
│  │        ▼                                                                  │   │
│  │   SignalAgent.dispatch_to_agent(message)                                 │   │
│  │                                                                           │   │
│  └───────────────────────────────┬──────────────────────────────────────────┘   │
│                                  │                                              │
│                                  ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                         3. AGENT BOOTSTRAP                                │   │
│  │                                                                           │   │
│  │   SignalAgent dispatches directly (no reactor):                           │   │
│  │        │                                                                  │   │
│  │        ├──▶ AgentBootstrap.ensure_conversation_agent()                   │   │
│  │        │    - Resolves model keys (conversation > user > auto)           │   │
│  │        │    - Runs AutoRouter if model is :auto                          │   │
│  │        │    - Gets or starts ConversationAgent via InstanceManager       │   │
│  │        │                                                                  │   │
│  │        └──▶ Sends "message.user" signal to agent                         │   │
│  │             (with message_id, text, mode, model_keys, attachments)       │   │
│  │                                                                           │   │
│  └───────────────────────────────┬──────────────────────────────────────────┘   │
│                                  │                                              │
│                                  ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                         4. AGENT LAYER                                    │   │
│  │                                                                           │   │
│  │   ConversationAgent (Jido Agent)                                         │   │
│  │        │                                                                  │   │
│  │        │ Signal received: "message.user"                                 │   │
│  │        │                                                                  │   │
│  │        ▼                                                                  │   │
│  │   Plugin pipeline processes signal (see ReAct Loop below)                │   │
│  │                                                                           │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## The ReAct Loop (ReactStrategy + Plugins)

The ConversationAgent uses `ReactStrategy` which delegates LLM calls and tool execution to an internal ReAct worker. Composable plugins translate the worker's internal signals into PubSub broadcasts and database writes.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         REACT LOOP + PLUGIN PIPELINE                             │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   "message.user" signal arrives at ConversationAgent                            │
│        │                                                                         │
│        ▼                                                                         │
│   ┌──────────────────────────────────────────────────────────────────────────┐   │
│   │                         INBOUND PLUGIN                                    │   │
│   │                                                                           │   │
│   │   1. Pre-flight validation (via Preflight module):                        │   │
│   │      - Check usage limits (LimitEnforcer)                                │   │
│   │      - Resolve model key for current mode                                │   │
│   │      - Build LLM context (system prompt, memories, history, tools)       │   │
│   │                                                                           │   │
│   │   2. Media bypass check:                                                  │   │
│   │      - :image_generation → dispatch GenerateImage (skip ReAct)           │   │
│   │      - :video_generation → dispatch GenerateVideo (skip ReAct)           │   │
│   │                                                                           │   │
│   │   3. Transform signal:                                                    │   │
│   │      "message.user" → "ai.react.query"                                  │   │
│   │      "message.cancel" → "ai.react.cancel"                               │   │
│   │                                                                           │   │
│   └───────────────────────────────┬──────────────────────────────────────────┘   │
│                                   │                                              │
│                                   ▼                                              │
│   ┌──────────────────────────────────────────────────────────────────────────┐   │
│   │                        REACT STRATEGY                                     │   │
│   │                                                                           │   │
│   │   Routes "ai.react.query" → spawns internal ReAct worker                 │   │
│   │                                                                           │   │
│   │   ┌─────────────────────────────────────────────────────────────────┐    │   │
│   │   │                    ReAct Worker Loop                             │    │   │
│   │   │                                                                  │    │   │
│   │   │   1. Call LLM (streaming) ──▶ emit ai.llm.delta events          │    │   │
│   │   │                                                                  │    │   │
│   │   │   2. Receive response ──▶ emit ai.llm.response                  │    │   │
│   │   │                                                                  │    │   │
│   │   │   3. If tool calls present:                                      │    │   │
│   │   │      ├──▶ emit ai.tool.started for each tool                    │    │   │
│   │   │      ├──▶ Execute tool (Jido Action)                             │    │   │
│   │   │      ├──▶ emit ai.tool.result with output                       │    │   │
│   │   │      └──▶ Loop back to step 1 with tool results                 │    │   │
│   │   │                                                                  │    │   │
│   │   │   4. If final answer: emit ai.request.completed                  │    │   │
│   │   │                                                                  │    │   │
│   │   │   5. Emit ai.usage with token counts                            │    │   │
│   │   │                                                                  │    │   │
│   │   └─────────────────────────────────────────────────────────────────┘    │   │
│   │                                                                           │   │
│   │   Worker events forwarded to parent via "ai.react.worker.event"          │   │
│   │   Parent unpacks and re-emits to plugin pipeline                         │   │
│   │                                                                           │   │
│   └───────────────────────────────┬──────────────────────────────────────────┘   │
│                                   │                                              │
│                   ai.llm.* / ai.tool.* / ai.request.* / ai.usage                │
│                                   │                                              │
│                                   ▼                                              │
│   ┌──────────────────────────────────────────────────────────────────────────┐   │
│   │                         PLUGIN PIPELINE                                   │   │
│   │                                                                           │   │
│   │   Each plugin intercepts signals it cares about:                         │   │
│   │                                                                           │   │
│   │   StreamingPlugin ──▶ ai.llm.delta → PubSub text.chunk / thinking.chunk │   │
│   │                       ai.request.started → PubSub state.change           │   │
│   │                       ai.llm.turn.* → PubSub turn.started/completed     │   │
│   │                                                                           │   │
│   │   PersistencePlugin ▶ ai.llm.response → DB write + PubSub text.complete │   │
│   │                       ai.request.completed → PubSub response.complete    │   │
│   │                       ai.request.failed → PubSub error + idle            │   │
│   │                                                                           │   │
│   │   ToolEventPlugin ──▶ ai.tool.started → PubSub tool.start               │   │
│   │                       ai.tool.result → DB write + PubSub tool.complete   │   │
│   │                                                                           │   │
│   │   UsagePlugin ──────▶ ai.usage → DB write (MessageUsage)                │   │
│   │                                                                           │   │
│   │   AgentRunCompletionPlugin ▶ ai.request.* → mark AgentRun complete      │   │
│   │                                                                           │   │
│   │   IntegrationReplyPlugin ─▶ ai.request.completed → send to channel      │   │
│   │                                                                           │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Model Resolution

The system resolves which LLM model to use with a priority chain:

```
Resolution Order (highest to lowest priority):

  1. Conversation.selected_{mode}_model    (conversation-specific setting)
           │ if nil
           ▼
  2. CustomAgent pinned model              (agent config)
           │ if nil
           ▼
  3. User.selected_{mode}_model            (user's default preference)
           │ if nil
           ▼
  4. :auto → AutoRouter                    (intent classification + tier capping)
     or System Default                     (configured fallback)
```

See [Auto Router](./04-auto-router.md) for the full auto-routing pipeline.

## Tool Execution Detail

When the ReAct worker encounters tool calls in the LLM response:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            TOOL EXECUTION FLOW                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   1. Worker emits ai.tool.started                                               │
│      → ToolEventPlugin broadcasts tool.start to PubSub                          │
│      → ToolEventPlugin broadcasts state.change(:running_tools)                  │
│                                                                                  │
│   2. Worker executes Jido Action (e.g., WebSearch)                              │
│      → Tool may emit tool.progress via Signals.emit_tool_progress()             │
│      → Tool may emit tool.step.* for sub-step progress                          │
│      → Returns {:ok, %{results: [...]}}                                         │
│                                                                                  │
│   3. Worker emits ai.tool.result                                                │
│      → ToolEventPlugin calls Tool.summarize_output(result)                      │
│      → ToolEventPlugin persists tool result to DB                               │
│      → ToolEventPlugin broadcasts tool.complete to PubSub                       │
│      → ToolEventPlugin broadcasts state.change(:thinking)                       │
│                                                                                  │
│   4. Worker adds tool result to LLM context → loops back to LLM call           │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Available Tools by Mode

| Mode | Tools |
|------|-------|
| **:chat** (default) | WebSearch, WebFetch, SearchMemories, DiceRoll, CreateNote, RunCode, InstallPackages, LoadSkill, CreateJob/UpdateJob/ListJobs/StopJob/PauseJob/ResumeJob, SearchConversationHistory, FetchConversationHistory, SendEmail, CreateTask/UpdateTask/ListTasks/ClearTasks, SpawnSubAgent/AwaitSubAgents |
| **:search** | No tools — uses model's native search capability |
| **:reasoning** | No tools — pure reasoning mode |
| **:image_generation** | Bypasses ReAct entirely — InboundPlugin dispatches GenerateImage |
| **:video_generation** | Bypasses ReAct entirely — InboundPlugin dispatches GenerateVideo |

Tool availability is further filtered by `CustomAgent.disabled_tool_categories` and integration-specific tools.

## Message Persistence

| Message Type | Created By | When | Status |
|-------------|-----------|------|--------|
| User (role: `:user`) | `Chat.send_user_message()` | Before agent processing starts | `:complete` |
| Agent (role: `:agent`) | PersistencePlugin | On `ai.llm.response` signal | `:complete` |
| Tool (role: `:tool`) | ToolEventPlugin | On `ai.tool.result` signal | `:complete`, `message_type: :event` |

Note: `text.chunk` events are NOT persisted — they are only broadcast for real-time display.

## Real-time Updates Flow

> For the full signal architecture (plugin pipeline, state machine, tool sub-steps, error handling), see [Signal Architecture](./02-signal-architecture.md).

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                          REAL-TIME UPDATE FLOW                                   │
├──────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   ChatLive                                 Plugin Pipeline                       │
│        │                                        │                                │
│        │  mount()                               │                                │
│        │    │                                   │                                │
│        │    └──▶ PubSub.subscribe("agents:{conv_id}")                            │
│        │                                        │                                │
│        │    ┌───────────────────────────────────                                  │
│        │    │                                                                    │
│        │◀───┤  state.change {:thinking}            (StreamingPlugin)             │
│        │◀───┤  text.chunk {delta: "Hello"}          (StreamingPlugin)             │
│        │◀───┤  text.chunk {delta: " world"}         (StreamingPlugin)             │
│        │◀───┤  text.complete {message_id, text}     (PersistencePlugin)          │
│        │◀───┤  tool.start {tool_name: "web_search"} (ToolEventPlugin)            │
│        │◀───┤  tool.progress {type: :searching}     (from tool via Signals)      │
│        │◀───┤  tool.complete {status: :success}     (ToolEventPlugin)            │
│        │◀───┤  state.change {:idle}                 (PersistencePlugin)          │
│        │◀───┤  response.complete                    (PersistencePlugin)          │
│        │    │                                                                    │
│        │    └───────────────────────────────────                                  │
│        │                                                                         │
│        ▼                                                                         │
│   PubSubHandlers dispatches each signal type to socket assign updates            │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## End-to-End Interaction Traces

### 1. Regular Conversation (Web UI)

The simplest flow — user sends a message in the browser, agent responds.

```
User types message in LiveView chat
         │
         ▼
LiveView sends "send_message" event
         │
         ▼
Magus.Chat.send_user_message()
  → Creates Message (role: :user, status: :complete)
  → SignalAgent change fires (after_transaction)
         │
         ▼
SignalAgent dispatches to ConversationAgent
  → AgentBootstrap.ensure_conversation_agent()
  → Jido.Agent.InstanceManager.get(:conversations, "conv:<id>")
  → Sends "message.user" signal
         │
         ▼
ConversationAgent plugin pipeline:
  1. InboxEventPlugin — checks for @mentions (none here), checks for approval responses (none)
  2. InboundPlugin — transforms "message.user" → "ai.react.query" (builds system prompt, history, tools)
  3. Signal routes to ReactStrategy
         │
         ▼
ReactStrategy spawns ReAct worker:
  → LLM call (streaming) → StreamingPlugin broadcasts text.chunk → LiveView renders
  → If tool calls: ToolEventPlugin broadcasts tool.start/complete → LiveView renders
  → Loop until done
         │
         ▼
Response complete:
  → PersistencePlugin persists agent message + broadcasts text.complete
  → UsagePlugin records token usage
  → IntegrationReplyPlugin — no integration linked, skips
         │
         ▼
LiveView receives PubSub events → updates UI in real-time
```

### 2. Council (Multi-Perspective Advisory)

User asks for diverse perspectives on a decision. The agent spawns sub-agents synchronously within its turn.

```
User: "/council Should we use Redis or PostgreSQL for caching?"
         │
         ▼
[Regular conversation flow — message.user → InboundPlugin → ReactStrategy]
         │
         ▼
Agent loads "council" skill (load_skill tool)
  → Skill instructions: "Spawn 3 sub-agents with different perspectives"
         │
         ▼
Agent calls spawn_sub_agent × 3 (inline mode, different models):
  → "The Pragmatist" (Anthropic model)
  → "The Innovator" (Google model)
  → "The Critic" (OpenAI model)
  │
  Each spawn:
    → Creates child conversation (is_task_conversation: true)
    → Creates AgentRun (kind: :consult)
    → RunOrchestrator.enqueue → starts child ConversationAgent
    → Child agent processes objective with its perspective
         │
         ▼
Agent calls await_sub_agents (tool)
  → Polls AgentRun records until all 3 reach terminal state
  → Returns results from each sub-agent
         │
         ▼
Agent synthesizes:
  → Presents each perspective with color-coded sections
  → Identifies consensus and disagreements
  → Gives balanced recommendation
```

**Key difference from orchestration**: Council is **synchronous** — the parent agent stays in its ReAct turn, polls for completion, and synthesizes in the same turn.

### 3. Complex Task with Orchestration

User asks an orchestrator agent to coordinate a multi-agent project. Fully asynchronous.

```
User: "@orchestrator Build a landing page with copy, design, and code"
         │
         ▼
[Regular conversation flow — message reaches ConversationAgent]
         │
         ▼
InboxEventPlugin intercepts "message.user" (BEFORE InboundPlugin):
  → MentionParser finds @orchestrator
  → Creates AgentInboxEvent (type: :mention, urgency: :immediate)
  → Dispatches DIRECTLY to RunOrchestrator
  → Returns {:ok, :continue} — conversation flow continues normally
         │
         ▼
@orchestrator's ConversationAgent activates in home conversation:
  → System prompt includes "Available Agents: @designer, @coder, @copywriter"
  → Agent loads "orchestrate" skill
         │
         ▼
Agent creates plan + delegates:
  → create_task("Write copy", assigned_to: @copywriter, assigned_by: self)
  → create_task("Design mockup", assigned_to: @designer, assigned_by: self)
  → create_task("Build components", assigned_to: @coder, assigned_by: self)
  → Responds: "I've delegated to 3 agents. Results will appear here."
  → Turn ends
         │
         ▼
NotifyAgentAssignment fires for each task (after_transaction):
  → Creates :task_assigned inbox event on each agent
  → No immediate dispatch; the assignee picks up the event on its
    next heartbeat wake-up
         │
         ▼
On its next heartbeat AgentRun, each worker's ConversationAgent:
  → Sees the :task_assigned event in the WakeupPreamble inbox section
  → Calls list_inbox_events / link_inbox_event and then works on the task
    in its home conversation using its regular tools
         │
         ▼
Worker finishes:
  → AgentRunCompletionPlugin:
    1. Run marked :complete, result_text captured
    2. Task updated: status=:done, result_summary set
    3. Auto-report: posts result as message in @orchestrator's conversation
    4. NotifyTaskCompletion → inbox event on assigning agent
```

**Key difference from council**: Orchestration is **asynchronous** — the orchestrator's turn ends after creating tasks. Results flow back programmatically via auto-report.

### 4. Telegram Conversation

User sends a message via Telegram. The response flows back through the integration.

```
User sends Telegram message
         │
         ▼
Telegram delivers webhook to POST /webhooks/telegram/:integration_id
         │
         ▼
WebhookController:
  → Loads integration + credentials
  → Verifies webhook signature
  → ProcessWebhook reactor:
    → TelegramMessageParser extracts text, attachments, sender info
    → Creates InputMessage
         │
         ▼
SignalInputAgent change (after_transaction):
  → DispatchInput reactor:
    → Finds or creates conversation for this Telegram chat
    → Creates Message (role: :user) in the conversation
    → SignalAgent fires → dispatches to ConversationAgent
         │
         ▼
[Same ConversationAgent flow as regular conversation]
         │
         ▼
During processing:
  → IntegrationReplyPlugin detects integration link:
    → ai.request.started: sends Telegram "typing..." indicator
    → ai.llm.delta: re-sends typing (throttled every 4s)
         │
         ▼
Response complete:
  → PersistencePlugin persists message
  → IntegrationReplyPlugin:
    → ReplyDispatcher.dispatch(integration, response_text)
    → Telegram API: sendMessage with response text
         │
         ▼
User sees response in Telegram
```

The ConversationAgent doesn't know or care about the channel — it processes the same signals regardless of whether the message came from web, Telegram, or email.

### 5. External Event: Deferred Inbox Processing

An event arrives passively and the agent decides what to do on its next heartbeat wake-up.

```
External event (e.g., RSS item, task completion, content alert)
  → Creates AgentInboxEvent (urgency: :deferred)
  → Event sits in inbox
         │
         ▼
HeartbeatScheduler (Oban cron, every 5 min):
  → Finds agents where heartbeat_enabled and not is_paused and
    next_scheduled_at <= now
  → For each due agent: RunOrchestrator.enqueue(%{source: :heartbeat, ...})
  → On :ok writes a "Heartbeat started" :event message in the home
    conversation via HeartbeatEventMessage
  → On rejection (:already_running, :budget_exceeded, :insufficient_credits)
    writes a "Heartbeat skipped: ..." event and advances next_scheduled_at
         │
         ▼
RunOrchestrator dispatches to ConversationAgent in the agent's home
conversation:
  → Builder prepends WakeupPreamble (current time, inbox stats, open tasks,
    recent activity, tool hints) to the agent's regular system prompt
  → ConversationAgent runs its standard ReAct loop with full tools plus
    four autonomy-only tools: list_inbox_events, dismiss_event,
    set_next_wakeup, link_inbox_event
         │
         ▼
AgentRunCompletionPlugin handles the terminal signal:
  → On success, resolves linked inbox events with
    resolved_by: :run_completed
  → On failure, unlinks them so they reappear on the next heartbeat
  → Advances next_scheduled_at by heartbeat_default_interval_minutes
    when set_next_wakeup was not called
         │
         ▼
The HeartbeatEventMessage transitions through running -> complete | skipped | failed.
```

The human can intervene at any point via the control room: see what was dismissed, override decisions, or open the agent's conversation to guide it directly.

## Key Files Reference

| File | Purpose |
|------|---------|
| `lib/magus/chat/message/changes/signal_agent.ex` | Triggers agent dispatch after message creation |
| `lib/magus/agents/support/agent_bootstrap.ex` | Agent start/thaw helper via InstanceManager |
| `lib/magus/agents/conversation_agent.ex` | Agent definition with plugins and lifecycle |
| `lib/magus/agents/strategies/react_strategy.ex` | ReAct strategy with worker delegation |
| `lib/magus/agents/plugins/inbound_plugin.ex` | Signal transformation + pre-flight validation |
| `lib/magus/agents/plugins/streaming_plugin.ex` | LLM streaming → PubSub translation |
| `lib/magus/agents/plugins/persistence_plugin.ex` | Response persistence + request lifecycle |
| `lib/magus/agents/plugins/tool_event_plugin.ex` | Tool event translation + persistence |
| `lib/magus/agents/plugins/usage_plugin.ex` | Token usage recording |
| `lib/magus/agents/plugins/inbox_event_plugin.ex` | @mention detection + approval responses |
| `lib/magus/agents/plugins/agent_run_completion_plugin.ex` | AgentRun completion + auto-report to parent |
| `lib/magus/agents/plugins/integration_reply_plugin.ex` | Channel reply sending (Telegram, etc.) |
| `lib/magus/agents/plugins/activity_log_plugin.ex` | Audit trail for control room |
| `lib/magus/agents/signals.ex` | PubSub broadcast helpers |
| `lib/magus_web/live/chat_live.ex` | LiveView with PubSub handlers |
| `lib/magus_web/live/chat_live/pubsub_handlers.ex` | Signal → socket assign mapping |
