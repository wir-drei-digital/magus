---
title: API Integration
description: Connect external services to your agents via REST API
order: 1
---

# API Integration

Integrate Magus agents into your own applications via a REST API. Send messages, receive responses (streaming or synchronous), and let your users interact with a full-featured AI agent (with RAG, tool calling, memory, and context management) all through simple HTTP requests.

## How It Works

Each API integration is bound to a custom agent. When you send a message to the API, it's routed to that agent, which processes it and returns a response. Conversations are managed automatically via session IDs; the same session ID always routes to the same conversation.

## Setup

### Step 1: Create a custom agent

Go to **Agents** and create a new agent. Configure its system prompt, tools, and model as needed. This agent will handle all messages coming through the API.

### Step 2: Create an API integration

Go to **Integrations** and add a new **API** integration. Select the agent you created in step 1. Once activated, you'll receive an API key (shown once; save it securely).

The API key looks like: `magus_sk_a1b2c3d4e5f6...`

### Step 3: Send your first message

```bash
curl -X POST https://your-magus-instance.com/api/v1/messages \
  -H "Authorization: Bearer magus_sk_your_key_here" \
  -H "Content-Type: application/json" \
  -d '{"content": "Hello!", "session_id": "my-session-1"}'
```

## Request Format

**POST /api/v1/messages**

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `content` | Yes | - | The message text |
| `session_id` | No | Auto-generated | Your identifier for the conversation. Same ID = same conversation. |
| `stream` | No | `false` | Set to `true` for Server-Sent Events streaming |
| `verbosity` | No | `"standard"` | Event detail level: `"minimal"`, `"standard"`, or `"full"` |
| `attachments` | No | `[]` | File attachments (base64 inline) |

### Attachments

```json
{
  "content": "Translate this document",
  "attachments": [
    {
      "type": "file",
      "name": "document.pdf",
      "data": "base64-encoded-content",
      "content_type": "application/pdf"
    }
  ]
}
```

## Non-Streaming Response

When `stream` is `false` (default), the API waits for the agent to finish and returns a single JSON response:

```json
{
  "id": "msg_abc123",
  "session_id": "my-session-1",
  "conversation_id": "uuid",
  "content": "Hello! How can I help you today?",
  "citations": [],
  "tool_calls": [],
  "attachments": [],
  "usage": {
    "prompt_tokens": 150,
    "completion_tokens": 25
  },
  "created_at": "2026-03-28T14:30:00Z"
}
```

## Streaming Response (SSE)

When `stream` is `true`, the response is a Server-Sent Events stream. Each event is a JSON object on a `data:` line:

```
data: {"event": "session.created", "session_id": "my-session-1", "conversation_id": "uuid"}

data: {"event": "message.started", "message_id": "msg_abc123"}

data: {"event": "text.chunk", "delta": "Hello! "}

data: {"event": "text.chunk", "delta": "How can I help you today?"}

data: {"event": "message.completed", "message_id": "msg_abc123", "usage": {"prompt_tokens": 150, "completion_tokens": 25}}

data: [DONE]
```

### Consuming SSE in code

**JavaScript:**
```javascript
const response = await fetch('/api/v1/messages', {
  method: 'POST',
  headers: {
    'Authorization': 'Bearer magus_sk_your_key',
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({ content: 'Hello', session_id: 'sess-1', stream: true })
});

const reader = response.body.getReader();
const decoder = new TextDecoder();

while (true) {
  const { done, value } = await reader.read();
  if (done) break;

  const text = decoder.decode(value);
  for (const line of text.split('\n')) {
    if (line.startsWith('data: ') && line !== 'data: [DONE]') {
      const event = JSON.parse(line.slice(6));
      if (event.event === 'text.chunk') {
        process.stdout.write(event.delta);
      }
    }
  }
}
```

**Python:**
```python
import requests
import json

response = requests.post(
    'https://your-instance.com/api/v1/messages',
    headers={'Authorization': 'Bearer magus_sk_your_key'},
    json={'content': 'Hello', 'session_id': 'sess-1', 'stream': True},
    stream=True
)

for line in response.iter_lines():
    if line and line.startswith(b'data: ') and line != b'data: [DONE]':
        event = json.loads(line[6:])
        if event['event'] == 'text.chunk':
            print(event['delta'], end='', flush=True)
```

**curl:**
```bash
curl -X POST https://your-instance.com/api/v1/messages \
  -H "Authorization: Bearer magus_sk_your_key" \
  -H "Content-Type: application/json" \
  -d '{"content": "Hello", "stream": true}' \
  --no-buffer
```

## Verbosity Levels

Control how much detail the SSE stream includes:

| Event | `minimal` | `standard` | `full` |
|-------|:---------:|:----------:|:------:|
| `session.created` | Yes | Yes | Yes |
| `message.started` | Yes | Yes | Yes |
| `text.chunk` | Yes | Yes | Yes |
| `message.completed` | Yes | Yes | Yes |
| `error` | Yes | Yes | Yes |
| `tool.started` | - | Yes | Yes |
| `tool.completed` | - | Yes | Yes |
| `tool.progress` | - | - | Yes |
| `thinking.chunk` | - | - | Yes |

Use `"minimal"` for simple chat UIs. Use `"standard"` (default) to show tool activity. Use `"full"` for debugging or advanced UIs that display reasoning.

## Session Management

Sessions map to conversations. The `session_id` you provide controls which conversation the message goes to:

- **Same `session_id`**: same conversation (agent remembers context)
- **Different `session_id`**: different conversation
- **No `session_id`**: new conversation (auto-generated ID returned in response)

The auto-generated session ID is returned in the response as `session_id`; save it if you want to continue the conversation.

## Error Responses

| Status | Code | Description |
|--------|------|-------------|
| 400 | `invalid_request` | Missing `content` or malformed request |
| 401 | `invalid_api_key` | Missing, invalid, or malformed API key |
| 403 | `integration_inactive` | Integration is disabled or suspended |
| 403 | `usage_limit_exceeded` | PAYG spend limit reached |
| 502 | `agent_error` | Agent encountered an error while processing |
| 504 | `timeout` | Agent did not respond within the time limit |

All errors follow the format:
```json
{"error": {"code": "invalid_api_key", "message": "Invalid API key"}}
```

## Usage Limits

The API shares your account's subscription and spending limits. Billable messages count toward the same PAYG monthly cap as the web UI and other integrations.

## Security

- API keys are shown once at creation; store them securely
- Keys are never stored in plaintext (only a hash is kept for lookup)
- Use environment variables or a secrets manager; never hardcode keys
- Each key is bound to one integration and one agent
- Rotate keys by creating a new integration and deactivating the old one
