---
title: API-Integration
description: Verbinde externe Dienste über die REST-API mit deinen Agenten
order: 1
---

# API-Integration

Integriere Magus-Agenten in deine eigenen Anwendungen über eine REST-API. Sende Nachrichten, empfange Antworten (Streaming oder synchron) und lass deine Nutzer mit einem voll ausgestatteten KI-Agenten interagieren: mit RAG, Tool-Aufrufen, Gedächtnis und Kontextmanagement, alles über einfache HTTP-Anfragen.

## So funktioniert es

Jede API-Integration ist an einen eigenen Agenten gebunden. Wenn du eine Nachricht an die API sendest, wird sie an diesen Agenten weitergeleitet, der sie verarbeitet und eine Antwort zurückgibt. Unterhaltungen werden automatisch über Session-IDs verwaltet; dieselbe Session-ID leitet immer zur selben Unterhaltung.

## Einrichtung

### Schritt 1: Eigenen Agenten erstellen

Gehe zu **Agenten** und erstelle einen neuen Agenten. Konfiguriere seinen System-Prompt, seine Tools und sein Modell nach Bedarf. Dieser Agent wird alle Nachrichten verarbeiten, die über die API eingehen.

### Schritt 2: API-Integration erstellen

Gehe zu **Integrationen** und fuege eine neue **API**-Integration hinzu. Wähle den Agenten, den du in Schritt 1 erstellt hast. Nach der Aktivierung erhältst du einen API-Schluessel (wird nur einmal angezeigt, speichere ihn sicher).

Der API-Schluessel sieht so aus: `magus_sk_a1b2c3d4e5f6...`

### Schritt 3: Erste Nachricht senden

```bash
curl -X POST https://deine-magus-instanz.com/api/v1/messages \
  -H "Authorization: Bearer magus_sk_dein_schluessel" \
  -H "Content-Type: application/json" \
  -d '{"content": "Hallo!", "session_id": "meine-session-1"}'
```

## Anfrage-Format

**POST /api/v1/messages**

| Feld | Erforderlich | Standard | Beschreibung |
|------|-------------|----------|-------------|
| `content` | Ja | - | Der Nachrichtentext |
| `session_id` | Nein | Automatisch generiert | Deine Kennung für die Unterhaltung. Gleiche ID = gleiche Unterhaltung. |
| `stream` | Nein | `false` | Auf `true` setzen für Server-Sent Events Streaming |
| `verbosity` | Nein | `"standard"` | Detailgrad der Events: `"minimal"`, `"standard"` oder `"full"` |
| `attachments` | Nein | `[]` | Dateianhange (Base64 inline) |

### Anhange

```json
{
  "content": "übersetze dieses Dokument",
  "attachments": [
    {
      "type": "file",
      "name": "dokument.pdf",
      "data": "base64-kodierter-inhalt",
      "content_type": "application/pdf"
    }
  ]
}
```

## Nicht-Streaming-Antwort

Wenn `stream` `false` ist (Standard), wartet die API, bis der Agent fertig ist, und gibt eine einzelne JSON-Antwort zurück:

```json
{
  "id": "msg_abc123",
  "session_id": "meine-session-1",
  "conversation_id": "uuid",
  "content": "Hallo! Wie kann ich dir heute helfen?",
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

## Streaming-Antwort (SSE)

Wenn `stream` `true` ist, ist die Antwort ein Server-Sent Events Stream. Jedes Event ist ein JSON-Objekt auf einer `data:`-Zeile:

```
data: {"event": "session.created", "session_id": "meine-session-1", "conversation_id": "uuid"}

data: {"event": "message.started", "message_id": "msg_abc123"}

data: {"event": "text.chunk", "delta": "Hallo! "}

data: {"event": "text.chunk", "delta": "Wie kann ich dir heute helfen?"}

data: {"event": "message.completed", "message_id": "msg_abc123", "usage": {"prompt_tokens": 150, "completion_tokens": 25}}

data: [DONE]
```

### SSE im Code konsumieren

**JavaScript:**
```javascript
const response = await fetch('/api/v1/messages', {
  method: 'POST',
  headers: {
    'Authorization': 'Bearer magus_sk_dein_schluessel',
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({ content: 'Hallo', session_id: 'sess-1', stream: true })
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
    'https://deine-instanz.com/api/v1/messages',
    headers={'Authorization': 'Bearer magus_sk_dein_schluessel'},
    json={'content': 'Hallo', 'session_id': 'sess-1', 'stream': True},
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
curl -X POST https://deine-instanz.com/api/v1/messages \
  -H "Authorization: Bearer magus_sk_dein_schluessel" \
  -H "Content-Type: application/json" \
  -d '{"content": "Hallo", "stream": true}' \
  --no-buffer
```

## Detailstufen

Steuere, wie viel Detail der SSE-Stream enthält:

| Event | `minimal` | `standard` | `full` |
|-------|:---------:|:----------:|:------:|
| `session.created` | Ja | Ja | Ja |
| `message.started` | Ja | Ja | Ja |
| `text.chunk` | Ja | Ja | Ja |
| `message.completed` | Ja | Ja | Ja |
| `error` | Ja | Ja | Ja |
| `tool.started` | - | Ja | Ja |
| `tool.completed` | - | Ja | Ja |
| `tool.progress` | - | - | Ja |
| `thinking.chunk` | - | - | Ja |

Verwende `"minimal"` für einfache Chat-Oberflächen. Verwende `"standard"` (Standard), um Tool-Aktivität anzuzeigen. Verwende `"full"` für Debugging oder fortgeschrittene Oberflächen, die das Reasoning anzeigen.

## Session-Verwaltung

Sessions werden Unterhaltungen zugeordnet. Die `session_id`, die du angibst, bestimmt, an welche Unterhaltung die Nachricht geht:

- **Gleiche `session_id`** = gleiche Unterhaltung (Agent erinnert sich an den Kontext)
- **Andere `session_id`** = andere Unterhaltung
- **Keine `session_id`** = neue Unterhaltung (automatisch generierte ID in der Antwort)

Die automatisch generierte Session-ID wird in der Antwort als `session_id` zurückgegeben; speichere sie, wenn du die Unterhaltung fortsetzen möchtest.

## Fehlerantworten

| Status | Code | Beschreibung |
|--------|------|-------------|
| 400 | `invalid_request` | Fehlender `content` oder fehlerhafte Anfrage |
| 401 | `invalid_api_key` | Fehlender, ungueltiger oder fehlerhafter API-Schluessel |
| 403 | `integration_inactive` | Integration ist deaktiviert oder gesperrt |
| 403 | `usage_limit_exceeded` | Pay-as-you-go-Ausgabenlimit erreicht |
| 502 | `agent_error` | Agent hat bei der Verarbeitung einen Fehler festgestellt |
| 504 | `timeout` | Agent hat nicht innerhalb des Zeitlimits geantwortet |

Alle Fehler folgen dem Format:
```json
{"error": {"code": "invalid_api_key", "message": "Ungueltiger API-Schluessel"}}
```

## Nutzungslimits

Die API teilt die Abonnement- und Ausgabenlimits deines Kontos. Abrechenbare Nachrichten zählen zum selben Pay-as-you-go-Monatslimit wie Web-Oberfläche und andere Integrationen.

## Sicherheit

- API-Schluessel werden bei der Erstellung nur einmal angezeigt; speichere sie sicher
- Schluessel werden nie im Klartext gespeichert (nur ein Hash wird für die Suche aufbewahrt)
- Verwende Umgebungsvariablen oder einen Secrets-Manager; hardcode Schluessel niemals
- Jeder Schluessel ist an eine Integration und einen Agenten gebunden
- Rotiere Schluessel, indem du eine neue Integration erstellst und die alte deaktivierst
