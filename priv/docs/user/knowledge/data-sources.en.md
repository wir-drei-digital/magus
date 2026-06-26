---
title: Data Sources
description: Connect and manage external data sources for your agents
order: 2
---

# Data Sources

> **Note:** Google verification for our data source connectors is still pending. If you need access to Google integrations (such as Google Drive) in the meantime, contact [support@magus.digital](mailto:support@magus.digital). If you're interested in other integrations, reach out to us as well.

Magus supports several types of data sources you can connect to your custom agents. Agents can search ingested data, monitor for errors, and proactively alert you when something needs attention.

## Supported Sources

### Web

Connect web-based content (documentation sites, CMS APIs, support pages, wikis) to your agents as a source. Your agent can search and reference this content semantically, just like uploaded files.

You provide a seed URL and Magus auto-detects the best way to discover pages:

- **OpenAPI / Swagger**: for CMS APIs and documented REST endpoints. Point it at an OpenAPI spec URL and Magus ingests all GET endpoints as searchable documentation. Supports tag and path filtering.
- **Sitemap**: for sites with a `sitemap.xml`. Magus parses the sitemap and ingests all listed pages.
- **Link Following**: for sites without a sitemap or API. Magus crawls from the seed URL following links, with configurable allowed domains, path prefixes, max depth, and max pages.
- **Pagination**: for paginated APIs using `Link: <url>; rel="next"` headers or JSON cursor fields.

Magus auto-selects the right strategy, or you can choose one explicitly.

**Setting up a web source:**

1. Go to **Connected Sources** and add a new source. Select **Web** as the provider.
2. Enter the seed URL (an OpenAPI spec URL, a docs site root, or any web page).
3. Optionally set the strategy, authentication (bearer token or basic auth), and boundary rules (allowed domains, path prefixes, max depth).
4. Create a collection from the source and trigger a full sync.

Magus syncs web sources on a configurable schedule (default: hourly). During incremental sync, new pages are ingested, removed pages are soft-deleted, and changed pages are re-chunked and re-embedded. Content hashes (SHA-256) ensure only genuinely changed content triggers re-processing.

For HTML content, Magus uses [Spider.cloud](https://spider.cloud) for clean content extraction (requires `SPIDER_API_KEY`). Non-HTML sources are fetched directly. Magus respects `robots.txt` and applies a default 500ms delay between requests.

### Log Source

Ingest application logs via webhook. Works with any log shipper that can POST JSON, including [Fly Log Shipper](https://github.com/superfly/fly-log-shipper) (Vector), Logflare, or custom HTTP senders.

**What your agent can do:**
- Search recent logs by keyword, severity, or time range
- Get a health summary (error counts, last activity)
- Receive alerts when error thresholds are breached (e.g., "5 errors in 5 minutes")

### RSS Feed

Subscribe to RSS or Atom feeds. Magus polls the feed at a configurable interval and ingests new items automatically.

**What your agent can do:**
- Search feed content by keyword or time range
- Get a summary of recent items
- Receive notifications when new items appear

## Setup

### Step 1: Create or edit a custom agent

Go to **Agents** and create a new agent (or edit an existing one). The agent needs to have integrations enabled (not in `disabled_tool_categories`).

### Step 2: Add a data source integration

In the agent's settings, go to **Integrations** and add one:

#### For Log Source:

1. Select **Log Source** as the provider
2. Configure thresholds (optional):
   - **Error threshold**: number of errors in the window to trigger an alert (default: 5)
   - **Window minutes**: rolling window size (default: 5)
   - **Retention days**: how long to keep entries (default: 7)
3. Save and activate the integration
4. Copy the webhook URL (you'll need it for your log shipper)

#### For RSS Feed:

1. Select **RSS Feed** as the provider
2. Enter configuration:
   - **Feed URL**: the RSS or Atom feed URL (e.g., `https://example.com/feed.xml`)
   - **Poll interval minutes**: how often to check for new items (default: 30)
   - **Retention days**: how long to keep entries (default: 30)
3. Save and activate the integration

### Step 3: Configure your log shipper (Log Source only)

Point your log shipper's HTTP output at the webhook URL from Step 2.

#### Fly.io with Log Shipper (Vector)

Deploy the [Fly Log Shipper](https://github.com/superfly/fly-log-shipper) app and configure Vector's HTTP sink:

```toml
[sinks.magus]
type = "http"
uri = "https://your-magus-instance.com/webhooks/log_source/YOUR_INTEGRATION_ID"
encoding.codec = "json"
```

#### Custom HTTP sender

POST JSON to your webhook URL in this format:

```json
{
  "message": "GenServer terminating: timeout",
  "level": "error",
  "timestamp": "2026-03-21T10:30:00Z",
  "metadata": {
    "fly_region": "iad",
    "app": "myapp",
    "instance": "abc123"
  }
}
```

For batch sending:

```json
{
  "entries": [
    {"message": "Request started", "level": "info", "timestamp": "..."},
    {"message": "DB timeout", "level": "error", "timestamp": "..."}
  ]
}
```

**Supported fields:**
- `message` (required): the log line content
- `level` (optional): `debug`, `info`, `warning`, `error`, `critical` (defaults to `info` if missing)
- `timestamp` (optional): ISO 8601 datetime (defaults to current time)
- `metadata` (optional): any structured data you want to include

### Step 4: Enable agent tools

The data source tools (**Search Ingested Data** and **Get Source Status**) are available under the integration's enabled tools. Make sure they're enabled for your agent.

## How alerts work

Data sources don't wake your agent on every log line or feed item. Instead:

**For logs:** a threshold checker runs after each batch of ingested entries. If the number of errors (severity `error` or `critical`) in the configured rolling window meets or exceeds the threshold, a single summarized inbox event is created for your agent's triage. The event includes:
- How many errors occurred
- The top distinct error messages
- Sample entry IDs for investigation

The inbox event uses idempotency keys to avoid duplicate alerts within the same window.

**For RSS:** when new items are ingested during a poll, a summarized inbox event is created listing the titles of new items. One event per day per feed.

In both cases, the inbox event has **deferred urgency**: your agent's triage will pick it up on the next heartbeat sweep, not immediately. This keeps costs low while ensuring nothing is missed.

## Automatic cleanup

Ingested entries are automatically purged based on your configured `retention_days` (default: 7 for logs, 30 for RSS). A daily maintenance job runs at 3 AM UTC and deletes entries older than the retention period.

## Agent tools reference

### Search Ingested Data (`search_ingested_data`)

Search across all your data sources. Available parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `source_type` | `log`, `rss`, `email` | Filter by source type (optional) |
| `query` | string | Text search on content and title (optional) |
| `severity` | `critical`, `error`, `warning`, `info`, `debug` | Filter by severity (optional) |
| `since` | ISO 8601 datetime | Start of time range (optional) |
| `until` | ISO 8601 datetime | End of time range (optional) |
| `limit` | integer | Max results, default 20 (optional) |

### Get Source Status (`get_source_status`)

Get a health summary of your data sources. Available parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `source_type` | `log`, `rss`, `email` | Filter by source type (optional) |

Returns per-source: total entries in the last hour, error count, last sync time, and current configuration.

## Crash detection

The log source automatically detects crash signatures and escalates their severity to `critical`:

- `GenServer terminating`
- `** (EXIT)`
- `SIGTERM` / `SIGKILL`
- `** (RuntimeError)` / `** (FunctionClauseError)`
- `Process.*crashed`
- `Ranch listener.*connection process.*exit`

These patterns are checked during ingestion; no LLM cost involved.

## Deduplication

Entries are deduplicated per integration using a SHA-256 hash of the content. If the same log line or RSS item is sent twice, the second ingestion is silently skipped. This means:

- Re-polling an RSS feed won't create duplicate entries
- Log shipper retries won't create duplicates
- The dedup is per-integration, so the same content in different integrations creates separate entries
