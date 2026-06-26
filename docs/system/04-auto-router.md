# Auto Router

Per-message model selection based on intent classification, message complexity, usage policy tier limits, and routing slots — replacing the static "one model for everything" approach with cost-effective routing.

## High-Level Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           AUTO ROUTER PIPELINE                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   User Message                                                                   │
│        │                                                                         │
│        ▼                                                                         │
│   ┌──────────────────────────────────────────────────────────────────────────┐   │
│   │  Step 2: ResolveModelKeys                                                │   │
│   │                                                                          │   │
│   │   Priority: Conversation > CustomAgent > User default > :auto           │   │
│   │                                                                          │   │
│   │   Returns: %{chat: :auto | "model-key", image: "key", video: "key"}     │   │
│   └──────────────────────────────────┬───────────────────────────────────────┘   │
│                                      │                                           │
│                               chat == :auto?                                     │
│                              ╱              ╲                                     │
│                           Yes                No                                  │
│                            │                  │                                   │
│                            ▼                  ▼                                   │
│   ┌────────────────────────────────┐   ┌────────────────────────┐               │
│   │  Step 3: AutoRoute            │   │  Passthrough           │               │
│   │                                │   │  (use explicit model)  │               │
│   │  1. Classify intent            │   └────────────┬───────────┘               │
│   │  2. Get max_tier from plan     │                │                            │
│   │  3. Match model via slots      │                │                            │
│   │  4. Generate routing_reason    │                │                            │
│   └───────────────┬────────────────┘                │                            │
│                   │                                  │                            │
│                   └──────────────┬───────────────────┘                            │
│                                  │                                                │
│                                  ▼                                                │
│   ┌──────────────────────────────────────────────────────────────────────────┐   │
│   │  Signal Data (sent to ConversationAgent)                                 │   │
│   │                                                                          │   │
│   │   model_keys: %{chat: "resolved-key", image: "key", video: "key"}       │   │
│   │   routing_reason: "Auto-routed to Grok 4.1 Fast for coding"            │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Intent Classification

The `ClassifyIntent` action determines what the user is trying to do and how complex the request is.

### Intents and Complexity

| Intent | Description | Example |
|--------|-------------|---------|
| `:chat` | General conversation, Q&A | "What's the capital of France?" |
| `:coding` | Programming, debugging, code review | "Fix this Python function" |
| `:search` | Web lookup, current events | "Latest news about Elixir" |
| `:reasoning` | Math, logic, analysis | "Prove this theorem" |
| `:creative` | Writing, brainstorming, storytelling | "Write a poem about rain" |

| Complexity | Signals | Typical Model Tier |
|------------|---------|-------------------|
| `:simple` | Short message, single question, greeting | Cheap/fast model |
| `:medium` | Multiple questions, code blocks, 100+ words | Mid-range model |
| `:hard` | Multiple paragraphs, lists, 200+ words | Frontier model |

### Classification Method

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         INTENT CLASSIFICATION                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   Message Text                                                                   │
│        │                                                                         │
│        ▼                                                                         │
│   ┌──────────────────────┐                                                      │
│   │  Fast Path: Search?  │  mode == :search                                    │
│   └──────────┬───────────┘                                                      │
│         No   │   Yes ──▶ {intent: :search, confidence: 1.0, method: :heuristic} │
│              ▼                                                                   │
│   ┌──────────────────────┐                                                      │
│   │  Fast Path: Greeting │  Regex for EN/DE/FR greetings + thank yous          │
│   └──────────┬───────────┘                                                      │
│         No   │   Yes ──▶ {intent: :chat, complexity: :simple, method: :heuristic}│
│              ▼                                                                   │
│   ┌──────────────────────┐                                                      │
│   │  LLM Classification  │  Small model (Ministral 3B) via structured output   │
│   │  (zero-shot)         │                                                      │
│   └──────────┬───────────┘                                                      │
│              │                                                                   │
│              ▼                                                                   │
│   ┌──────────────────────┐                                                      │
│   │  Heuristic Complexity│  Always computed from message structure:             │
│   │  Estimation          │                                                      │
│   │                      │  • Word count (>100 → medium, >200 → hard)          │
│   │                      │  • Multiple questions (2+ question marks)            │
│   │                      │  • Code blocks present                               │
│   │                      │  • Lists/bullet points                               │
│   │                      │  • Multiple paragraphs                               │
│   └──────────────────────┘                                                      │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Configuration**: The classification model is set in `config/config.exs`:

```elixir
config :magus, :agents,
  classification_model: "openrouter:mistralai/ministral-3b-2512"
```

Setting this to `nil` disables LLM classification (all messages default to `:chat` intent).

## Routing Slots

Routing slots are a database resource that maps `{specialty, tier}` pairs to specific models. This decouples routing decisions from model identity — administrators can reassign models without changing any code.

### Schema

```
┌──────────────────────────────────────────────────┐
│                  RoutingSlot                       │
├──────────────────────────────────────────────────┤
│  id:         UUID                                 │
│  specialty:  :general | :coding | :search |       │
│              :reasoning | :creative |             │
│              :image | :text_to_video |            │
│              :image_to_video                      │
│  tier:       :simple | :standard | :complex       │
│  model_id:   UUID (belongs_to Model)              │
├──────────────────────────────────────────────────┤
│  unique constraint: {specialty, tier}             │
│  (one model per slot, but a model can fill many)  │
└──────────────────────────────────────────────────┘
```

### Example Slot Configuration

| Specialty | Simple | Standard | Complex |
|-----------|--------|----------|---------|
| **general** | Grok 4.1 Fast | Claude Sonnet 4.5 | Claude Opus 4.6 |
| **coding** | Grok 4.1 Fast | Claude Sonnet 4.5 | Claude Opus 4.6 |
| **search** | — | Sonar Pro Search | Sonar Pro Search |
| **reasoning** | — | Grok 4 | Grok 4 |
| **creative** | Grok 4.1 Fast | Mistral Large 2512 | Claude Opus 4.6 |

## Model Matching

The `ModelMatcher` maps classified intents to routing slots using a fixed rule table, then applies a cascading fallback strategy when the exact slot is empty.

### Routing Rules

```
{intent, complexity}  →  {specialty, tier}

Chat:
  {chat, simple}      →  {general, simple}
  {chat, medium}      →  {general, standard}
  {chat, hard}        →  {general, complex}

Coding:
  {coding, simple}    →  {coding, simple}
  {coding, medium}    →  {coding, standard}
  {coding, hard}      →  {coding, complex}

Search:
  {search, simple}    →  {search, standard}
  {search, medium}    →  {search, standard}
  {search, hard}      →  {search, complex}

Reasoning:
  {reasoning, simple} →  {reasoning, standard}
  {reasoning, medium} →  {reasoning, complex}
  {reasoning, hard}   →  {reasoning, complex}

Creative:
  {creative, simple}  →  {creative, simple}
  {creative, medium}  →  {creative, standard}
  {creative, hard}    →  {creative, complex}
```

### Fallback Strategy

When the target slot has no model assigned:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         MATCHING FALLBACK CASCADE                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   1. Exact match       {coding, complex}   → assigned model                     │
│                              │ empty                                             │
│                              ▼                                                   │
│   2. Specialty fallback  {coding, *}        → any tier in same specialty        │
│                              │ empty                                             │
│                              ▼                                                   │
│   3. Tier fallback       {*, complex}       → any specialty at same tier        │
│                              │ empty                                             │
│                              ▼                                                   │
│   4. Any fallback        {*, *}             → first available slot              │
│                              │ empty                                             │
│                              ▼                                                   │
│   5. No match            :no_route          → system default model              │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Tier Capping (Usage Governance Integration)

The user's usage plan limits which model tier they can access. This prevents lower-tier users from being auto-routed to expensive frontier models.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           TIER CAPPING                                           │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   Usage Policy.max_routing_tier:                                                │
│                                                                                  │
│   ┌──────────┬──────────────────────┬─────────────────────────┐                 │
│   │  Plan    │  max_routing_tier    │  Accessible Tiers       │                 │
│   ├──────────┼──────────────────────┼─────────────────────────┤                 │
│   │  Free    │  :simple             │  simple only            │                 │
│   │  Starter │  :standard           │  simple, standard       │                 │
│   │  Pro     │  :complex            │  simple, standard, complex │              │
│   └──────────┴──────────────────────┴─────────────────────────┘                 │
│                                                                                  │
│   Additional degradation:                                                        │
│                                                                                  │
│   If user has zero remaining daily credits                                       │
│     → tier capped to :simple (regardless of plan)                               │
│                                                                                  │
│   If user has limits[:exempt] == true                                            │
│     → no tier capping applied                                                    │
│                                                                                  │
│   Example:                                                                       │
│     Starter user sends a hard coding question                                   │
│     → ClassifyIntent: {coding, hard} → target {coding, complex}                │
│     → Tier capped: complex → standard (plan max)                                │
│     → ModelMatcher looks up {coding, standard} slot                             │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Signal Data Flow

A critical design decision: the auto-routed `model_keys` are passed through the signal data to the InboundPlugin (Preflight), not just stored in agent state. This ensures freshly routed keys override stale persisted state from hibernated agents.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         MODEL KEYS DATA FLOW                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   Dispatch Pipeline (SignalAgent → AgentBootstrap)                               │
│        │                                                                         │
│        ├─ ResolveModelKeys                                                       │
│        │    → %{chat: :auto, image: "key", video: "key"}                        │
│        │                                                                         │
│        ├─ AutoRouteResolver                                                      │
│        │    → %{model_keys: %{chat: "resolved", ...}, routing_reason: "..."}    │
│        │                                                                         │
│        ├─ Build agent config (initial_state includes model_keys)                 │
│        │    → Used when agent is first created                                   │
│        │                                                                         │
│        ├─ Build signal data (includes model_keys)                                │
│        │    → Used on EVERY message, even for thawed agents                      │
│        │                                                                         │
│        └─ Send signal to agent                                                   │
│             → Signal carries model_keys + routing_reason                         │
│                                                                                  │
│   InboundPlugin (Preflight, via message.user signal)                             │
│        │                                                                         │
│        ├─ Extract signal model_keys from params                                  │
│        │                                                                         │
│        ├─ Prefer signal model_keys over persisted state                          │
│        │   (fresh routing decision wins over stale hibernated state)              │
│        │                                                                         │
│        └─ Pass active keys to ai.react.query signal                              │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Integration with Dispatch Pipeline

The auto router runs as part of the message dispatch pipeline in `SignalAgent` → `AgentBootstrap`:

| Step | Name | Purpose |
|------|------|---------|
| 1 | Load conversation | Fetch conversation with model relationships |
| **2** | **ResolveModelKeys** | **Conversation > User > `:auto` priority chain** |
| **3** | **AutoRoute** | **Classify intent, cap tier, match model** |
| 4 | Build agent config | Agent ID + initial state with model_keys |
| 5 | Ensure agent started | Get or create ConversationAgent |
| 6 | Build signal data | Include model_keys + routing_reason |
| 7 | Send agent signal | Deliver `"message.user"` to agent |

## Configuration Reference

```elixir
# config/config.exs

config :magus, :agents,
  # Classification model (nil disables LLM classification)
  classification_model: "openrouter:mistralai/ministral-3b-2512",

  # Fallback when no routing slot matches
  default_model: nil  # nil = use database default, then "openrouter:anthropic/claude-sonnet-4"
```

```elixir
# Magus.Usage.Policy resource (usage governance)
max_routing_tier: :simple | :standard | :complex
```

## Key Files Reference

| File | Purpose |
|------|---------|
| `lib/magus/agents/routing/auto_router.ex` | Public API: `AutoRouter.route/2` |
| `lib/magus/agents/actions/classify_intent.ex` | Intent classification (fast paths + LLM) |
| `lib/magus/agents/routing/model_matcher.ex` | Routing rules + fallback cascade |
| `lib/magus/chat/routing_slot.ex` | Database resource: `{specialty, tier} → model` |
| `lib/magus/agents/routing/model_key_resolver.ex` | Model key priority resolution |
| `lib/magus/agents/routing/auto_route_resolver.ex` | Tier capping + routing orchestration |
| `lib/magus/agents/plugins/support/preflight.ex` | Consumes signal model_keys during pre-flight |
| `lib/magus/agents/dispatcher.ex` | Message dispatch pipeline |
| `lib/magus/usage/policy.ex` | `max_routing_tier` attribute (usage governance) |
