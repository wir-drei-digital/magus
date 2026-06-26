# Integrations

How external services connect to Magus via a plugin-based provider system with secure credential management, type-specific behaviours, webhook routing, and conversation management.

## Overview

The Integrations domain provides a unified framework for connecting to external services. Providers are Elixir modules that implement behaviours defining their contract. Each provider declares a `source_type` that classifies its purpose. There is no database-backed Provider resource — provider metadata comes from the modules themselves via a compile-time registry.

## Provider Type Taxonomy

| Type | source_type | Purpose | Examples |
|------|------------|---------|----------|
| **Channel** | `:channel` | Bidirectional messaging — receives messages, routes to conversations, sends replies | Telegram, SimpleWebhook, API |
| **Tool Provider** | `:tool_provider` | Exposes API operations as agent tools — no message flow | Google Calendar |
| **Data Source** | `:data_source` | Ingests streaming data for querying + threshold alerts | LogSource, RssSource |
| **Knowledge** | `:knowledge` | Syncs documents into RAG pipeline (chunks + embeddings) | Google Drive, Notion, Nextcloud, Affine |

## Architecture

```
                     Magus.Integrations Domain
                (Credential management, audit logging, registry)
                                  |
                  ________________|________________
                 |                |                |                |
            :channel         :tool_provider   :data_source    :knowledge
            providers        providers        providers        providers
                 |                |                |                |
                 v                v                v                v
          ChannelBehaviour   (base only)   DataSourceBehaviour ConnectorBehaviour
          +WebhookChannel    tools/0       parse_ingestion    connect/1
           or ApiChannel     execute/3     classify/1         list_items/3
          conversation       operations/0  poll/2             fetch_content/2
          routing                                |                |
                 |                               v                v
                 v                         IngestionEntry    File + Chunk
           InputMessage                   (Curation)        (RAG/pgvector)
           OutputMessage
           Conversation routing
```

## Behaviour Hierarchy

### ProviderBehaviour (base — all providers)

`lib/magus/integrations/providers/behaviour.ex`

Required callbacks:

| Callback | Return Type | Description |
|----------|-------------|-------------|
| `key/0` | atom | Unique identifier (`:telegram`, `:log_source`, etc.) |
| `name/0` | string | Human-readable display name |
| `description/0` | string | Capability description |
| `auth_type/0` | atom | `:oauth2`, `:api_key`, `:imap`, `:webhook_only`, `:none` |
| `source_type/0` | atom | `:channel`, `:tool_provider`, `:data_source`, `:knowledge` |

Optional callbacks:

| Callback | Description |
|----------|-------------|
| `tools/0` | Jido Action tool definitions for agents |
| `operations/0` | Supported operation atoms for `execute/3` |
| `execute/3` | Execute an operation with decrypted credentials |
| `auth_fields/0` | Field definitions for API key auth setup |
| `oauth_config/0` | OAuth2 configuration |
| `on_credentials_saved/2` | Setup hook (e.g., register webhook) |
| `on_credentials_removed/2` | Cleanup hook (e.g., remove webhook) |
| `requires_admin?/0` | Whether provider requires admin setup |
| `auth_help/0` | Help text for authentication setup |

### ChannelBehaviour (messaging providers — transport-agnostic)

`lib/magus/integrations/providers/channel_behaviour.ex`

Base behaviour for all channel integrations. Transport-agnostic — both webhook-based and API-based channels implement this.

| Callback | Required | Description |
|----------|----------|-------------|
| `conversation_identifier/1` | Yes | Extract routing ID from parsed input (e.g., sender_id, session_id) |
| `default_conversation_mode/0` | Yes | `:single` or `:multi` conversation routing |
| `default_async_reply_enabled?/0` | Yes | Whether IntegrationReplyPlugin dispatches async replies |
| `authorize_sender/2` | No | Check if sender is allowed (returns `:ok`, `{:pending, reason}`, or `{:error, term}`) |
| `extract_message_content/1` | No | Extract message text from parsed input (default: tries `text`/`content` keys) |
| `extract_recipient_id/1` | No | Extract recipient ID for reply routing (default: tries `sender_id`/`chat_id` keys) |

### WebhookChannelBehaviour (webhook-based channels)

`lib/magus/integrations/providers/webhook_channel_behaviour.ex`

For channels that receive HTTP webhooks (Telegram, SimpleWebhook). Extends ChannelBehaviour.

| Callback | Required | Description |
|----------|----------|-------------|
| `verify_webhook/2` | Yes | Verify incoming webhook signature |
| `parse_webhook/2` | Yes | Parse payload into InputMessage format |
| `webhook_response/1` | No | Custom HTTP response for the webhook |

### ApiChannelBehaviour (synchronous request/response channels)

`lib/magus/integrations/providers/api_channel_behaviour.ex`

For channels that receive direct HTTP requests and return responses synchronously or via SSE streaming. Extends ChannelBehaviour.

| Callback | Required | Description |
|----------|----------|-------------|
| `parse_request/2` | Yes | Parse API request body and headers into normalized map |
| `supports_streaming?/0` | Yes | Whether SSE streaming is supported |
| `stream_event_types/1` | Yes | Event types to include for a given verbosity level |

### DataSourceBehaviour (data ingestion)

`lib/magus/integrations/providers/data_source_behaviour.ex`

See [Data Source Integrations](./09-data-source-integrations.md) for full details.

### ConnectorBehaviour (knowledge/RAG)

`lib/magus/knowledge/connector.ex`

Lives in the Knowledge domain, not Integrations.

| Callback | Required | Description |
|----------|----------|-------------|
| `connect/1` | Yes | Establish connection with auth config |
| `list_folders/2` | Yes | List available folders/containers |
| `list_items/3` | Yes | Paginate through items in a collection |
| `fetch_content/2` | Yes | Download item content |
| `detect_changes/3` | No | Incremental change detection |

## Provider Registry

Providers are registered in a compile-time `@provider_modules` map in `lib/magus/integrations.ex`. No database seeding required — the UI uses `list_available_providers/0` to display available integrations.

| Function | Description |
|----------|-------------|
| `get_provider_module(key)` | Returns module for a provider key, or nil |
| `list_provider_modules()` | Returns the full registry map |
| `list_available_providers()` | Metadata (name, description, auth_type, source_type) for all providers |
| `list_available_providers(source_type)` | Filtered by type (e.g., `:channel`) |
| `get_enabled_tools_for_agent(agent_id)` | Tool modules across active integrations |

### Current Provider Matrix

| Provider | Registry Key | source_type | Base | Channel | Webhook | ApiChannel | DataSource | Connector |
|----------|-------------|-------------|:----:|:-------:|:-------:|:----------:|:----------:|:---------:|
| Telegram | `:telegram` | `:channel` | Yes | Yes | Yes | — | — | — |
| SimpleWebhook | `:simple_webhook` | `:channel` | Yes | Yes | Yes | — | — | — |
| API | `:api` | `:channel` | Yes | Yes | — | Yes | — | — |
| Custom API | `:custom_api` | `:channel` | Yes | Yes | Yes | — | — | — |
| Google Calendar | `:google_calendar` | `:tool_provider` | Yes | — | — | — | — | — |
| LogSource | `:log_source` | `:data_source` | Yes | — | — | — | Yes | — |
| RssSource | `:rss_source` | `:data_source` | Yes | — | — | — | Yes | — |
| Google Drive | `:google_drive_knowledge` | `:knowledge` | Yes | — | — | — | — | Yes |
| Notion | `:notion_knowledge` | `:knowledge` | Yes | — | — | — | — | Yes |
| Nextcloud | `:nextcloud_knowledge` | `:knowledge` | Yes | — | — | — | — | Yes |
| Affine | `:affine_knowledge` | `:knowledge` | Yes | — | — | — | — | Yes |
| Web | `:web` | `:knowledge` | Yes | — | — | — | — | Yes |

## Webhook Routing

Webhook-based channels arrive at `POST /webhooks/:provider/:integration_id`. The API channel has its own route at `POST /api/v1/messages` (see API Channel Routing below).

```
POST /webhooks/:provider/:integration_id
    |
    v
WebhookController.webhook/2
    |
    v
Load integration → verify webhook → check rate limit
    |
    v
provider_module.source_type()
    |
    +---> :channel     → ProcessWebhook reactor → InputMessage → conversation routing
    +---> :data_source → ProcessIngestion module → IngestionEntry → ThresholdChecker
    +---> :knowledge   → Knowledge sync trigger
```

### Channel Webhook Flow (detail)

```
┌──────────────────────────────────────────────────────────────────────────┐
│                      PROCESSWEBHOOK REACTOR                              │
│                                                                          │
│   Inputs: user_id, provider_key, integration_id, payload, headers       │
│        │                                                                 │
│        ├──▶ Step 1: Parse payload                                       │
│        │    (provider.parse_webhook(payload, headers))                  │
│        │    → Extracts: type, text, sender_id, external_id             │
│        │                                                                 │
│        ├──▶ Step 2: Create InputMessage                                 │
│        │    (triggers SignalInputAgent change)                          │
│        │                                                                 │
│        └──▶ Step 3: Create audit log (async)                           │
│                                                                          │
│   Returns: {input_message_id, external_id}                              │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                      DISPATCHINPUT REACTOR                               │
│                                                                          │
│   Inputs: input_message_id, user_id                                     │
│        │                                                                 │
│        ├──▶ Load user, InputMessage, and UserIntegration                │
│        ├──▶ Resolve conversation (get or create based on mode)          │
│        ├──▶ Send message to conversation (Chat.send_user_message)      │
│        └──▶ Mark input as processed                                     │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## API Channel Routing

The API channel uses a different flow from webhooks. Instead of async dispatch via `SignalInputAgent`, the controller handles everything synchronously to avoid a PubSub subscription race condition.

```
POST /api/v1/messages
    |
    v
ApiAuthPlug (Bearer token → Credential lookup by key_hash → UserIntegration + User)
    |
    v
MessageController.create/2
    |
    v
ApiProvider.parse_request/2 (validate content, normalize session_id)
    |
    v
Resolve session → IntegrationConversation lookup/create → conversation_id
    |
    v
Subscribe to PubSub "agents:{conversation_id}"
    |
    v
Create InputMessage (dispatched: true) → DispatchInput reactor (synchronous)
    |
    v
Agent processes message, emits signals to PubSub
    |
    +---> stream=true:  SseStreamer filters by verbosity, chunks SSE events to client
    +---> stream=false: Controller accumulates text.chunk deltas, returns JSON on response.complete
    |
    v
Unsubscribe from PubSub, close connection
```

**Key differences from webhook flow:**
- **Sync dispatch**: The `dispatched: true` flag on InputMessage prevents `SignalInputAgent` from doing async dispatch. The controller calls `DispatchInput` directly.
- **Direct response**: Instead of `IntegrationReplyPlugin` dispatching an async reply, the controller subscribes to PubSub and streams/accumulates the response itself. `async_reply_enabled: false` ensures the plugin skips this integration.
- **SSE streaming**: The `SseStreamer` module translates PubSub signals to Server-Sent Events with configurable verbosity (`minimal`, `standard`, `full`).

### API Authentication

API keys use the format `magus_sk_<32 hex chars>`. On request:
1. Extract bearer token from `Authorization` header
2. Compute SHA-256 hash
3. Look up `Credential` by indexed `key_hash` field
4. Load `UserIntegration` (must be `:active`, provider `:api`)
5. Load owner `User` → becomes actor for all downstream operations

## Conversation Modes

Integrations support two conversation routing modes:

### Single Mode

All messages from an integration go to ONE conversation. Stored as `UserIntegration.conversation_id`.

### Multi Mode

Messages are routed by external identifier (e.g., `sender_id`). Each unique sender gets their own conversation via an `IntegrationConversation` mapping table (`user_integration_id` + `external_identifier` → `conversation_id`).

Resolution logic:
1. Extract identifier via `provider.conversation_identifier(payload)` or fall back to `payload["sender_id"]`
2. Look up `IntegrationConversation` by `(integration_id, identifier)`
3. If found → return existing conversation. If not → create new conversation + mapping.

## UserIntegration

`lib/magus/integrations/user_integration.ex`

A user's enabled instance of a provider, bound to a custom agent.

| Field | Type | Description |
|-------|------|-------------|
| `provider_key` | atom | Provider identifier (direct attribute, not a FK) |
| `custom_agent_id` | uuid | Agent this integration is bound to |
| `user_id` | uuid | Owner |
| `status` | atom | `:pending`, `:active`, `:error`, `:disabled` |
| `config` | map | Provider-specific configuration |
| `enabled_tools` | [atom] | Which of the provider's tools are enabled |
| `conversation_mode` | atom | `:single` or `:multi` (channels) |
| `async_reply_enabled` | boolean | Whether IntegrationReplyPlugin dispatches async replies (false for API channel) |
| `external_id` | string | Provider's identifier for routing (e.g., Telegram chat_id) |
| `last_sync_at` | datetime | Last successful sync timestamp |
| `error_message` | string | Last error message (if status is `:error`) |

## Credential Management

`lib/magus/integrations/credential.ex`

Credentials are encrypted at rest using Cloak (AES-256-GCM). They are:
- Never exposed to agent code or tools
- Accessed via `get_credential_for_integration` with `authorize?: false`
- Audit-logged on every access
- Decrypted just-in-time for `execute/3`, `poll/2`, or `connect/1` calls

## Rate Limiting

```
RateLimiter.check(user_id, provider_key, :webhook)

Key: "webhook:#{user_id}:#{provider_key}"

Default limits (configurable per provider):
  - 60 requests per minute
  - 1000 requests per hour

Returns: :ok | {:error, :rate_limited} → 429 response
```

## Adding a New Provider

### Webhook Channel (e.g., Discord)

1. Create `lib/magus/integrations/providers/discord.ex`
2. Implement `@behaviour Behaviour` + `@behaviour ChannelBehaviour` + `@behaviour WebhookChannelBehaviour`
3. `source_type: :channel`
4. Implement `verify_webhook/2`, `parse_webhook/2` (WebhookChannelBehaviour — required)
5. Implement `conversation_identifier/1`, `default_conversation_mode/0`, `default_async_reply_enabled?/0` (ChannelBehaviour — required)
6. Implement `execute/3` for outbound (`:send_message`, etc.)
7. Register in `@provider_modules`

### API Channel

1. Create `lib/magus/integrations/providers/my_api.ex`
2. Implement `@behaviour Behaviour` + `@behaviour ChannelBehaviour` + `@behaviour ApiChannelBehaviour`
3. `source_type: :channel`, `default_async_reply_enabled?: false`
4. Implement `parse_request/2`, `supports_streaming?/0`, `stream_event_types/1` (ApiChannelBehaviour)
5. Implement `on_credentials_saved/2` to generate and hash API keys
6. Register in `@provider_modules`

See `lib/magus/integrations/providers/api.ex` for the reference implementation.

### Tool Provider (e.g., GitHub)

1. Create `lib/magus/integrations/providers/github.ex`
2. Implement `@behaviour Behaviour` only
3. `source_type: :tool_provider`
4. Implement `tools/0` with Jido Action tool modules
5. Implement `execute/3` for API operations
6. Register in `@provider_modules`

### Data Source

See [Data Source Integrations](./09-data-source-integrations.md) for the full guide.

### Knowledge (e.g., Confluence)

1. Create provider in `lib/magus/integrations/providers/confluence.ex` — minimal, just auth
2. Create connector in `lib/magus/knowledge/connectors/confluence.ex` — implements `Connector` behaviour
3. Register provider in `@provider_modules`

## Key File Paths

| File | Purpose |
|------|---------|
| `lib/magus/integrations.ex` | Domain module, provider registry, code interfaces |
| `lib/magus/integrations/providers/behaviour.ex` | Base provider behaviour |
| `lib/magus/integrations/providers/channel_behaviour.ex` | Channel behaviour (transport-agnostic) |
| `lib/magus/integrations/providers/webhook_channel_behaviour.ex` | Webhook channel behaviour |
| `lib/magus/integrations/providers/api_channel_behaviour.ex` | API channel behaviour |
| `lib/magus/integrations/providers/api.ex` | API channel provider |
| `lib/magus_web/api/plugs/api_auth_plug.ex` | API key authentication plug |
| `lib/magus_web/api/controllers/message_controller.ex` | API message endpoint |
| `lib/magus_web/api/controllers/sse_streamer.ex` | PubSub-to-SSE streaming |
| `lib/magus/integrations/providers/data_source_behaviour.ex` | Data source behaviour |
| `lib/magus/integrations/user_integration.ex` | User's enabled integration instance |
| `lib/magus/integrations/credential.ex` | Encrypted auth storage |
| `lib/magus/integrations/input_message.ex` | Channel webhook input |
| `lib/magus/integrations/output_message.ex` | Channel outbound message |
| `lib/magus/integrations/audit_log.ex` | Security audit trail |
| `lib/magus/integrations/rate_limiter.ex` | Rate limiting logic |
| `lib/magus/integrations/reactors/setup_integration.ex` | Integration setup flow |
| `lib/magus_web/controllers/webhook_controller.ex` | Webhook routing |
| `lib/magus/knowledge/connector.ex` | Knowledge connector behaviour |
