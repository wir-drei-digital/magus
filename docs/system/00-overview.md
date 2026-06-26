# System Architecture Overview

High-level overview of the Magus application architecture — how data flows through the system and how the key components fit together.

## System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                   CLIENTS                                       │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                      │
│   │   Web App    │    │   Telegram   │    │   Webhooks   │                      │
│   │  (LiveView)  │    │     Bot      │    │   (Custom)   │                      │
│   └──────┬───────┘    └──────┬───────┘    └──────┬───────┘                      │
│          │                   │                   │                              │
└──────────┼───────────────────┼───────────────────┼──────────────────────────────┘
           │                   │                   │
           ▼                   ▼                   ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              PHOENIX WEB LAYER                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   ┌──────────────────────┐    ┌──────────────────────┐                          │
│   │    LiveView Pages    │    │   WebhookController  │                          │
│   │   (ChatLive, etc.)   │    │   (POST /webhooks)   │                          │
│   └──────────┬───────────┘    └──────────┬───────────┘                          │
│              │                           │                                      │
│              │ PubSub                    │ Reactor                              │
│              │ Subscribe                 │                                      │
│              ▼                           ▼                                      │
│   ┌──────────────────────────────────────────────────────────────────┐          │
│   │                         Phoenix.PubSub                           │          │
│   │           (topics: agents:{id}, memory:{id}, etc.)               │          │
│   └──────────────────────────────────────────────────────────────────┘          │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              ASH FRAMEWORK LAYER                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                            ASH DOMAINS                                  │   │
│   ├──────────┬──────────┬──────────┬──────────┬──────────┬──────────────────┤   │
│   │ Accounts │   Chat   │ Library  │  Files   │  Memory  │  Integrations    │   │
│   │          │          │          │          │          │                  │   │
│   │ • User   │ • Convo  │ • Prompt │ • File   │ • Memory │ • Provider       │   │
│   │ • Auth   │ • Message│ • Tag    │ • Chunk  │ • Scope  │ • UserIntegr.    │   │
│   │          │ • Model  │          │          │          │ • InputMessage   │   │
│   ├──────────┴──────────┴──────────┴──────────┴──────────┴──────────────────┤   │
│   │ Subscriptions │ CustomAgents │ Agents     │ Plan             │        │   │
│   │               │              │            │                  │        │   │
│   │ • UsagePlan   │ • CustomAgent│ • AgentRun │ • Task           │        │   │
│   │ • UserSubscr. │ • AgentSecret│ • InboxEvt │ • TaskPaneState  │        │   │
│   │ • Override    │              │ • Activity │                  │        │   │
│   └──────────┴───────────────┴──────────────┴────────────┴──────────────────┘   │
│                                     │                                           │
│                                     │ Ash Changes trigger                       │
│                                     ▼ agent dispatch                            │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                           ASH REACTORS                                  │   │
│   │                                                                         │   │
│   │   ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐      │   │
│   │   │  DispatchInput  │   │ ProcessWebhook  │   │ExtractMemories  │      │   │
│   │   │ (Integration)   │   │  (Webhooks)     │   │  (Background)   │      │   │
│   │   └────────┬────────┘   └────────┬────────┘   └────────┬────────┘      │   │
│   │            │                     │                     │               │   │
│   └────────────┼─────────────────────┼─────────────────────┼───────────────┘   │
│                │                     │                     │                   │
└────────────────┼─────────────────────┼─────────────────────┼───────────────────┘
                 │                     │                     │
                 ▼                     ▼                     ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              JIDO AGENT LAYER                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │                        InstanceManager                                 │    │
│   │            (Manages agent lifecycle, hibernation, recovery)            │    │
│   └───────────────────────────────────┬────────────────────────────────────┘    │
│                                       │                                         │
│                                       │                                         │
│                                       ▼                                         │
│   ┌──────────────────┐                                                          │
│   │ ConversationAgent│                                                          │
│   │                  │                                                          │
│   │  ID: conv:       │                                                          │
│   │  {conv_id}       │                                                          │
│   └────────┬─────────┘                                                          │
│            │                                                                    │
│            │ ReactStrategy + Plugins                                            │
│            ▼                                                                    │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                       REACT STRATEGY                                     │   │
│   │                                                                          │   │
│   │   message.user ──▶ InboundPlugin ──▶ ai.react.query                     │   │
│   │                                          │                               │   │
│   │                                          ▼                               │   │
│   │                                   ┌─────────────┐                        │   │
│   │                                   │ ReAct Worker │                        │   │
│   │                                   │  (LLM call  │                        │   │
│   │                                   │  + tools)   │                        │   │
│   │                                   └──────┬──────┘                        │   │
│   │                                          │                               │   │
│   │                              ai.llm.* / ai.tool.* / ai.usage            │   │
│   │                                          │                               │   │
│   │                                          ▼                               │   │
│   │   ┌──────────────────────────────────────────────────────────────────┐   │   │
│   │   │                    PLUGIN PIPELINE                                │   │   │
│   │   │                                                                  │   │   │
│   │   │  InboxEvent │ Streaming  │ Persistence │ ToolEvent │ Usage      │   │   │
│   │   │  Plugin     │ Plugin     │ Plugin      │ Plugin    │ Plugin     │   │   │
│   │   │             │            │             │           │            │   │   │
│   │   │  @mentions  │ text.chunk │ DB writes   │ tool.*    │ record     │   │   │
│   │   │  approvals  │ thinking.* │ text.compl. │ persist   │ tokens     │   │   │
│   │   │             │            │             │           │            │   │   │
│   │   │  AgentRun   │ Activity   │ Integration │                        │   │   │
│   │   │  Completion │ Log        │ Reply       │                        │   │   │
│   │   │  Plugin     │ Plugin     │ Plugin      │                        │   │   │
│   │   └──────────────────────────────────────────────────────────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              EXTERNAL SERVICES                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐   │
│   │   OpenRouter  │  │     xAI       │  │    PublicAI   │  │   AIML API    │   │
│   │   (LLMs)      │  │   (Grok)      │  │               │  │               │   │
│   └───────────────┘  └───────────────┘  └───────────────┘  └───────────────┘   │
│                                                                                 │
│   ┌───────────────┐  ┌───────────────┐  ┌───────────────┐                      │
│   │    Exa.ai     │  │   Daytona /   │  │    Fal.ai     │                      │
│   │  (Web Search) │  │   Sprites     │  │   (Video)     │                      │
│   └───────────────┘  │  (Sandbox)    │  └───────────────┘                      │
│                       └───────────────┘                                         │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Ash Framework Domains

The application is organized into Ash domains, each managing a specific business area:

| Domain | Purpose | Key Resources |
|--------|---------|---------------|
| **Accounts** | User management, authentication | User, Session |
| **Chat** | Conversations and messaging | Conversation, Message, Model, RoutingSlot |
| **Library** | Reusable prompts and personas | Prompt, Tag, Favorite |
| **Files** | File storage and semantic search | File, Chunk |
| **Memory** | Agent memory with scopes | Memory (local/agent/global), MemoryVersion |
| **CustomAgents** | User-defined agent configurations | CustomAgent, AgentSecret |
| **Agents** | Agent execution and control plane | AgentRun, AgentInboxEvent, AgentActivityLog, AgentState |
| **Plan** | Collaborative task management | Task, TaskPaneState |
| **Integrations** | External service connections | UserIntegration, Credential, InputMessage, IngestionEntry |
| **Subscriptions** | Usage governance (spend caps, storage/upload limits, usage policies) | UsagePlan, UserSubscription, UserUsageOverride |
| **FeatureUsage** | Onboarding and feature tracking | FeatureUsageEvent, Announcement |

### 2. Jido Agent System

Agents are long-running processes that handle complex, multi-step workflows:

| Agent | ID Pattern | Purpose |
|-------|-----------|---------|
| **ConversationAgent** | `conv:{conversation_id}` | Processes user messages via ReAct loop with LLM + tools. Also handles autonomous wake-ups (heartbeat, manual trigger) in the agent's home conversation. |

```
┌─────────────────────────────────────────────────────────────┐
│                    JIDO AGENT LIFECYCLE                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   ┌─────────┐                                               │
│   │  START  │  Signal received (e.g., user message)         │
│   └────┬────┘                                               │
│        │                                                     │
│        ▼                                                     │
│   ┌─────────────────┐                                       │
│   │InstanceManager  │  get_or_start(agent_id)               │
│   │    .get()       │                                       │
│   └────────┬────────┘                                       │
│            │                                                 │
│     ┌──────┴──────┐                                         │
│     │  Exists?    │                                         │
│     └──────┬──────┘                                         │
│       Yes  │  No                                             │
│     ┌──────┴──────┐                                         │
│     ▼             ▼                                         │
│ ┌───────┐   ┌──────────────┐                                │
│ │Return │   │    Thaw      │  Load from PostgresStore       │
│ │  PID  │   │ (if exists)  │  or create new                 │
│ └───────┘   └──────┬───────┘                                │
│     │              │                                         │
│     └──────┬───────┘                                         │
│            ▼                                                 │
│   ┌─────────────────┐                                       │
│   │  Agent Process  │  Processing signals                   │
│   │    (GenServer)  │                                       │
│   └────────┬────────┘                                       │
│            │                                                 │
│            │  After 5 min idle                              │
│            ▼                                                 │
│   ┌─────────────────┐                                       │
│   │   Hibernate     │  checkpoint() → PostgresStore         │
│   │   (freeze)      │  Process terminates                   │
│   └─────────────────┘                                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 3. ConversationAgent Plugin Pipeline

The ConversationAgent uses composable plugins that intercept internal ReAct signals and translate them to PubSub broadcasts and database writes:

| Plugin | File | Responsibility |
|--------|------|----------------|
| **InboxEventPlugin** | `plugins/inbox_event_plugin.ex` | Detects @mentions and approval responses in `message.user` signals. Must be first. |
| **InboundPlugin** | `plugins/inbound_plugin.ex` | Transforms `message.user` → `ai.react.query` with pre-flight validation (model, limits, context). |
| **StreamingPlugin** | `plugins/streaming_plugin.ex` | Translates `ai.llm.delta` → PubSub `text.chunk` / `thinking.chunk`. |
| **PersistencePlugin** | `plugins/persistence_plugin.ex` | Persists completed responses to DB, broadcasts `text.complete` and `response.complete`. |
| **ToolEventPlugin** | `plugins/tool_event_plugin.ex` | Translates `ai.tool.*` → PubSub `tool.start` / `tool.complete`, persists tool results. |
| **UsagePlugin** | `plugins/usage_plugin.ex` | Records token usage and costs from `ai.usage` signals. |
| **AgentRunCompletionPlugin** | `plugins/agent_run_completion_plugin.ex` | Marks AgentRun records as complete/failed, auto-reports results to parent conversations. |
| **ActivityLogPlugin** | `plugins/activity_log_plugin.ex` | Logs agent activity for the control room audit trail. |
| **IntegrationReplyPlugin** | `plugins/integration_reply_plugin.ex` | Sends replies back to external channels (Telegram, etc.). |

### 4. Reactors (Workflow Orchestration)

Reactors are declarative workflow engines that orchestrate multi-step operations:

| Reactor | Trigger | Purpose |
|---------|---------|---------|
| **DispatchInput** | InputMessage created | Routes integration input to a conversation |
| **ProcessWebhook** | Webhook received | Parses webhook and creates InputMessage |

Note: Chat messages do not use a reactor. The `SignalAgent` Ash change dispatches directly to the ConversationAgent via `AgentBootstrap`.

### 5. Real-time Communication (PubSub)

```
┌────────────────────────────────────────────────────────────┐
│                     PUBSUB TOPICS                           │
├────────────────────────────────────────────────────────────┤
│                                                             │
│  agents:{conversation_id}                                   │
│  ├── state.change       (agent state transition)           │
│  ├── text.chunk         (streaming LLM response)           │
│  ├── text.complete      (streaming iteration done)         │
│  ├── thinking.chunk     (reasoning/thinking tokens)        │
│  ├── turn.started       (new LLM turn beginning)           │
│  ├── turn.completed     (LLM turn finished)                │
│  ├── response.complete  (full response cycle done)         │
│  ├── error              (error occurred)                   │
│  ├── tool.start         (tool execution begins)            │
│  ├── tool.progress      (tool status update)               │
│  ├── tool.complete      (tool finished)                    │
│  ├── tool.step.start    (tool sub-step begins)             │
│  ├── tool.step.progress (sub-step content streaming)       │
│  └── tool.step.complete (sub-step finished)                │
│                                                             │
│  memory:{user_id}                                           │
│  ├── memory_created  (new memory saved)                    │
│  ├── memory_updated  (memory modified)                     │
│  └── memory_deleted  (memory removed)                      │
│                                                             │
│  tasks:conversation:{conversation_id}                       │
│  ├── task.created    (task added)                          │
│  └── task.updated    (task status/title changed)           │
│                                                             │
│  agent_activity:user:{user_id}                              │
│  └── activity.new / activity.inbox_changed                 │
│                                                             │
│  feature_usage:{user_id}                                    │
│  └── feature.used   (for onboarding card removal)          │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

## Data Flow Patterns

### Pattern 1: User Message → Agent (Web UI)

The primary pattern for chat messages:

```
┌───────────┐     ┌─────────────┐     ┌───────────────┐     ┌─────────┐
│  Create   │────▶│ SignalAgent  │────▶│AgentBootstrap │────▶│  Agent  │
│  Message  │     │ (after_txn) │     │ (get/start)   │     │ Signal  │
└───────────┘     └─────────────┘     └───────────────┘     └─────────┘
```

1. `Chat.send_user_message()` creates Message resource
2. `SignalAgent` change runs after transaction commits
3. `AgentBootstrap.ensure_conversation_agent()` gets or starts the agent
4. `ConversationAgent` receives `message.user` signal

### Pattern 2: External Event → Webhook → Reactor → Agent

For external integrations:

```
┌───────────┐     ┌─────────────┐     ┌─────────────────┐     ┌─────────────┐
│  Webhook  │────▶│ Controller  │────▶│ ProcessWebhook  │────▶│DispatchInput│
│  (POST)   │     │ (validate)  │     │  (create)       │     │  (route)    │
└───────────┘     └─────────────┘     └─────────────────┘     └─────────────┘
                                             │                       │
                                             ▼                       ▼
                                      InputMessage ────────▶ ConversationAgent
```

### Pattern 3: @Mention → AgentRun → Target Agent

For multi-agent orchestration. The mention is dispatched directly through the run plane; there is no separate triage step.

```
┌───────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────┐
│ InboxEvent    │────▶│ RunOrchestrator │────▶│ AgentRun        │────▶│ Target Agent│
│ Plugin        │     │ .enqueue/1      │     │ (source:        │     │ (home conv) │
│ (@mention)    │     │                 │     │  :mention)      │     │             │
└───────────────┘     └─────────────────┘     └─────────────────┘     └─────────────┘
```

### Pattern 4: Heartbeat → AgentRun → Wake-up

For per-agent autonomous wake-ups. The HeartbeatScheduler enqueues runs on the same plane as @mentions; only the `source` label differs.

```
┌──────────────────┐     ┌─────────────────┐     ┌──────────────────┐     ┌──────────────────────┐
│ HeartbeatSched.  │────▶│ RunOrchestrator │────▶│ AgentRun         │────▶│ ConversationAgent    │
│ (Oban cron)      │     │ .enqueue/1      │     │ (source:         │     │ in home conversation │
│                  │     │                 │     │  :heartbeat)     │     │ + WakeupPreamble     │
└──────────────────┘     └─────────────────┘     └──────────────────┘     └──────────────────────┘
                                                                                     │
                                                                                     ▼
                                                                       tools (incl. autonomy
                                                                       tools) → terminal state
```

## Key Design Principles

1. **Event-Driven Architecture**: Ash changes trigger agent workflows via after-transaction callbacks
2. **Plugin-Based Signal Translation**: Internal ReAct signals are translated to PubSub/DB by composable plugins
3. **Agent Isolation**: Each conversation has its own agent process with independent lifecycle
4. **Graceful Degradation**: Agents hibernate after 5 minutes idle and recover automatically on next signal
5. **Real-time Updates**: PubSub broadcasts enable live UI updates across all connected clients
6. **Single Exit Point**: All agent response paths (success, error, cancel) funnel through PersistencePlugin
7. **Persistent Memory**: Context survives across sessions via direct memory actions and background extraction

## Documentation Index

| Document | Description |
|----------|-------------|
| [Conversation Flow](./01-conversation-flow.md) | Message processing pipeline and end-to-end interaction traces |
| [Signal Architecture](./02-signal-architecture.md) | Real-time signal flow, plugin pipeline, state machine, tool events |
| [LLM Context Assembly](./03-llm-context-assembly.md) | How the system builds the message payload for each LLM call |
| [Auto Router](./04-auto-router.md) | Per-message model selection based on intent, complexity, and usage policy |
| [Memory System](./05-memory-system.md) | Persistent memory with scopes, extraction, consolidation, and semantic search |
| [Custom Agents](./06-custom-agents.md) | User-defined agents with @mentions, tool scoping, secrets, and skills |
| [Agent Control Plane](./07-agent-control-plane.md) | Run plane, heartbeat scheduling, autonomy tools, inbox events, activity logging, multi-agent orchestration |
| [Integrations](./08-integrations.md) | Provider system, webhook routing, credential management, channel messaging |
| [Data Source Integrations](./09-data-source-integrations.md) | Log and RSS ingestion, threshold alerts, agent tools |
| [Sandbox Execution](./10-sandbox-execution.md) | Sandboxed code execution with output streaming and secret injection |
| [Plan & Tasks](./11-plan-tasks.md) | Collaborative task management between users and agents |
| [Onboarding](./12-onboarding.md) | Feature discovery and progressive disclosure for new users |
| [Web Knowledge Connector](./13-web-knowledge-connector.md) | Web crawling and content ingestion into the RAG pipeline |
| [Knowledge Brain](./14-knowledge-brain.md) | Collaborative page/block editor with semantic search, real-time presence, and agent tool access |
| [Super Brain](./15-super-brain.md) | Background-built knowledge graph fusing brain pages, memories, files, and drafts into a per-actor super graph for hybrid VectorRAG + GraphRAG retrieval |
