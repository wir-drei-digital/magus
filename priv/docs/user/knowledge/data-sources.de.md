---
title: Datenquellen
description: Verbinde und verwalte externe Datenquellen für deine Agenten
order: 2
---

# Datenquellen

> **Hinweis:** Die Google-Verifizierung für unsere Datenquellen-Konnektoren steht noch aus. Wenn du in der Zwischenzeit Zugang zu Google-Integrationen (z.B. Google Drive) benötigst, kontaktiere [support@magus.digital](mailto:support@magus.digital). Wenn du an weiteren Integrationen interessiert bist, melde dich ebenfalls bei uns.

Magus unterstuetzt verschiedene Typen von Datenquellen, die du mit deinen eigenen Agenten verbinden kannst. Agenten können aufgenommene Daten durchsuchen, auf Fehler überwachen und dich proaktiv benachrichtigen, wenn etwas Aufmerksamkeit erfordert.

## Unterstuetzte Quellen

### Web

Verbinde webbasierte Inhalte (Dokumentationsseiten, CMS-APIs, Support-Seiten, Wikis) als Quelle mit deinen Agenten. Dein Agent kann diese Inhalte semantisch durchsuchen und referenzieren, genau wie hochgeladene Dateien.

Du gibst eine Ausgangs-URL an und Magus erkennt automatisch den besten Weg, Seiten zu entdecken:

- **OpenAPI / Swagger**: für CMS-APIs und dokumentierte REST-Endpunkte. Richte es auf eine OpenAPI-Spezifikations-URL und Magus nimmt alle GET-Endpunkte als durchsuchbare Dokumentation auf. Unterstuetzt Tag- und Pfad-Filterung.
- **Sitemap**: für Seiten mit einer `sitemap.xml`. Magus parst die Sitemap und nimmt alle aufgelisteten Seiten auf.
- **Link-Verfolgung**: für Seiten ohne Sitemap oder API. Magus crawlt von der Ausgangs-URL aus und folgt Links, mit konfigurierbaren erlaubten Domains, Pfadpräfixen, maximaler Tiefe und maximaler Seitenzahl.
- **Paginierung**: für paginierte APIs, die `Link: <url>; rel="next"`-Header oder JSON-Cursor-Felder verwenden.

Magus wählt automatisch die passende Strategie, oder du kannst eine explizit festlegen.

**Web-Quelle einrichten:**

1. Gehe zu **Verbundene Quellen** und fuege eine neue Quelle hinzu. Wähle **Web** als Anbieter.
2. Gib die Ausgangs-URL ein (eine OpenAPI-Spezifikations-URL, das Root einer Dokumentationsseite oder eine beliebige Webseite).
3. Lege optional Strategie, Authentifizierung (Bearer-Token oder Basic Auth) und Grenzregeln (erlaubte Domains, Pfadpräfixe, maximale Tiefe) fest.
4. Erstelle eine Sammlung aus der Quelle und löse eine vollständige Synchronisierung aus.

Magus synchronisiert Web-Quellen nach einem konfigurierbaren Zeitplan (Standard: stuendlich). Während der inkrementellen Synchronisierung werden neue Seiten aufgenommen, entfernte Seiten soft-gelöscht und geänderte Seiten erneut in Chunks aufgeteilt und eingebettet. Inhalts-Hashes (SHA-256) stellen sicher, dass nur tatsächlich geänderter Inhalt eine Neuverarbeitung auslöst.

für HTML-Inhalte verwendet Magus [Spider.cloud](https://spider.cloud) für saubere Inhaltsextraktion (erfordert `SPIDER_API_KEY`). Nicht-HTML-Quellen werden direkt abgerufen. Magus respektiert `robots.txt` und hält standardmässig einen Abstand von 500ms zwischen Anfragen ein.

### Log-Quelle

Nimm Anwendungslogs per Webhook auf. Funktioniert mit jedem Log-Shipper, der JSON per POST senden kann, einschliesslich [Fly Log Shipper](https://github.com/superfly/fly-log-shipper) (Vector), Logflare oder eigenen HTTP-Sendern.

**Was dein Agent tun kann:**
- Aktuelle Logs nach Stichwort, Schweregrad oder Zeitraum durchsuchen
- Eine Gesundheitsübersicht erhalten (Fehleranzahl, letzte Aktivität)
- Benachrichtigungen erhalten, wenn Fehlerschwellen überschritten werden (z.B. "5 Fehler in 5 Minuten")

### RSS-Feed

Abonniere RSS- oder Atom-Feeds. Magus fragt den Feed in einem konfigurierbaren Intervall ab und nimmt neue Einträge automatisch auf.

**Was dein Agent tun kann:**
- Feed-Inhalte nach Stichwort oder Zeitraum durchsuchen
- Eine Zusammenfassung der neuesten Einträge erhalten
- Benachrichtigungen erhalten, wenn neue Einträge erscheinen

## Einrichtung

### Schritt 1: Eigenen Agenten erstellen oder bearbeiten

Gehe zu **Agenten** und erstelle einen neuen Agenten (oder bearbeite einen vorhandenen). Der Agent muss Integrationen aktiviert haben (nicht in `disabled_tool_categories`).

### Schritt 2: Datenquellen-Integration hinzufuegen

Gehe in den Einstellungen des Agenten zu **Integrationen** und fuege eine hinzu:

#### für Log-Quelle:

1. Wähle **Log-Quelle** als Anbieter
2. Konfiguriere Schwellenwerte (optional):
   - **Fehlerschwelle**: Anzahl der Fehler im Fenster, um eine Benachrichtigung auszulösen (Standard: 5)
   - **Fenster-Minuten**: Grösse des rollierenden Fensters (Standard: 5)
   - **Aufbewahrungstage**: wie lange Einträge aufbewahrt werden (Standard: 7)
3. Speichere und aktiviere die Integration
4. Kopiere die Webhook-URL; du brauchst sie für deinen Log-Shipper

#### für RSS-Feed:

1. Wähle **RSS-Feed** als Anbieter
2. Gib die Konfiguration ein:
   - **Feed-URL**: die RSS- oder Atom-Feed-URL (z.B. `https://example.com/feed.xml`)
   - **Abfrageintervall in Minuten**: wie oft nach neuen Einträgen gesucht wird (Standard: 30)
   - **Aufbewahrungstage**: wie lange Einträge aufbewahrt werden (Standard: 30)
3. Speichere und aktiviere die Integration

### Schritt 3: Log-Shipper konfigurieren (nur für Log-Quelle)

Richte den HTTP-Output deines Log-Shippers auf die Webhook-URL aus Schritt 2.

#### Fly.io mit Log Shipper (Vector)

Deploye die [Fly Log Shipper](https://github.com/superfly/fly-log-shipper)-App und konfiguriere Vectors HTTP-Sink:

```toml
[sinks.magus]
type = "http"
uri = "https://deine-magus-instanz.com/webhooks/log_source/DEINE_INTEGRATION_ID"
encoding.codec = "json"
```

#### Eigener HTTP-Sender

Sende JSON per POST an deine Webhook-URL in diesem Format:

```json
{
  "message": "GenServer terminating: timeout",
  "level": "error",
  "timestamp": "2026-03-21T10:30:00Z",
  "metadata": {
    "fly_region": "iad",
    "app": "meineapp",
    "instance": "abc123"
  }
}
```

für Batch-Versand:

```json
{
  "entries": [
    {"message": "Request gestartet", "level": "info", "timestamp": "..."},
    {"message": "DB-Timeout", "level": "error", "timestamp": "..."}
  ]
}
```

**Unterstuetzte Felder:**
- `message` (erforderlich): der Inhalt der Log-Zeile
- `level` (optional): `debug`, `info`, `warning`, `error`, `critical` (Standard: `info`, falls nicht angegeben)
- `timestamp` (optional): ISO 8601 Datum/Uhrzeit (Standard: aktuelle Zeit)
- `metadata` (optional): beliebige strukturierte Daten, die du einbeziehen möchtest

### Schritt 4: Agent-Tools aktivieren

Die Datenquellen-Tools (**Aufgenommene Daten durchsuchen** und **Quellenstatus abrufen**) sind unter den aktivierten Tools der Integration verfuegbar. Stelle sicher, dass sie für deinen Agenten aktiviert sind.

## Wie Benachrichtigungen funktionieren

Datenquellen wecken deinen Agenten nicht bei jeder Log-Zeile oder jedem Feed-Eintrag. Stattdessen:

**für Logs:** Ein Schwellenwert-Pruefer läuft nach jedem Batch aufgenommener Einträge. Wenn die Anzahl der Fehler (Schweregrad `error` oder `critical`) im konfigurierten rollierenden Fenster den Schwellenwert erreicht oder überschreitet, wird ein einzelnes zusammengefasstes Inbox-Event für die Triage deines Agenten erstellt. Das Event enthält:
- Wie viele Fehler aufgetreten sind
- Die häufigsten unterschiedlichen Fehlermeldungen
- Beispiel-Eintrags-IDs zur Untersuchung

Das Inbox-Event verwendet Idempotenzschluessel, um doppelte Benachrichtigungen innerhalb desselben Fensters zu vermeiden.

**für RSS:** Wenn bei einer Abfrage neue Einträge aufgenommen werden, wird ein zusammengefasstes Inbox-Event erstellt, das die Titel der neuen Einträge auflistet. Ein Event pro Tag pro Feed.

In beiden Fällen hat das Inbox-Event **verzögerte Dringlichkeit**: die Triage deines Agenten wird es beim nächsten Heartbeat-Durchlauf aufgreifen, nicht sofort. Das hält die Kosten niedrig und stellt sicher, dass nichts übersehen wird.

## Automatische Bereinigung

Aufgenommene Einträge werden automatisch basierend auf deinen konfigurierten `retention_days` gelöscht (Standard: 7 für Logs, 30 für RSS). Ein täglicher Wartungsjob läuft um 3:00 UTC und löscht Einträge, die älter als die Aufbewahrungsfrist sind.

## Agent-Tools-Referenz

### Aufgenommene Daten durchsuchen (`search_ingested_data`)

Suche über alle deine Datenquellen. Verfuegbare Parameter:

| Parameter | Typ | Beschreibung |
|-----------|-----|-------------|
| `source_type` | `log`, `rss`, `email` | Nach Quellentyp filtern (optional) |
| `query` | String | Textsuche in Inhalt und Titel (optional) |
| `severity` | `critical`, `error`, `warning`, `info`, `debug` | Nach Schweregrad filtern (optional) |
| `since` | ISO 8601 Datum/Uhrzeit | Beginn des Zeitraums (optional) |
| `until` | ISO 8601 Datum/Uhrzeit | Ende des Zeitraums (optional) |
| `limit` | Integer | Max. Ergebnisse, Standard 20 (optional) |

### Quellenstatus abrufen (`get_source_status`)

Erhalte eine Gesundheitsübersicht deiner Datenquellen. Verfuegbare Parameter:

| Parameter | Typ | Beschreibung |
|-----------|-----|-------------|
| `source_type` | `log`, `rss`, `email` | Nach Quellentyp filtern (optional) |

Gibt pro Quelle zurück: Gesamteinträge der letzten Stunde, Fehleranzahl, letzte Synchronisierungszeit und aktuelle Konfiguration.

## Crash-Erkennung

Die Log-Quelle erkennt automatisch Crash-Signaturen und stuft deren Schweregrad auf `critical` hoch:

- `GenServer terminating`
- `** (EXIT)`
- `SIGTERM` / `SIGKILL`
- `** (RuntimeError)` / `** (FunctionClauseError)`
- `Process.*crashed`
- `Ranch listener.*connection process.*exit`

Diese Muster werden während der Aufnahme geprueft, ohne LLM-Kosten.

## Deduplizierung

Einträge werden pro Integration mittels eines SHA-256-Hashs des Inhalts dedupliziert. Wenn dieselbe Log-Zeile oder derselbe RSS-Eintrag zweimal gesendet wird, wird die zweite Aufnahme stillschweigend übersprungen. Das bedeutet:

- Erneutes Abfragen eines RSS-Feeds erzeugt keine doppelten Einträge
- Wiederholungsversuche des Log-Shippers erzeugen keine Duplikate
- Die Deduplizierung ist pro Integration, sodass derselbe Inhalt in verschiedenen Integrationen separate Einträge erzeugt
