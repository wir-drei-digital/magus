# Web Knowledge Connector

How web-based content (documentation sites, CMS APIs, wikis) is crawled and ingested into the RAG pipeline via the Knowledge domain's Connector behaviour.

## Overview

The web connector is a `:web` provider in the Knowledge domain that implements the `Connector` behaviour. It discovers URLs via pluggable strategies, fetches content (Spider for HTML, Req for APIs), and feeds pages through the existing File → Chunk → Embedding pipeline. No new database tables — it maps onto `KnowledgeSource`, `KnowledgeCollection`, and `File`.

## Architecture

```
KnowledgeSource (provider: :web)
        │
        │  connect/1 (auto-detect strategy, parse robots.txt)
        ▼
┌─────────────────────────────────────────────────────────┐
│                    Web Connector                         │
│                                                          │
│   AutoDetector ──▶ Strategy Selection                    │
│        │                                                 │
│        ▼                                                 │
│   ┌──────────────────────────────────┐                   │
│   │       Discovery Strategies       │                   │
│   ├──────────┬──────────┬────────────┤                   │
│   │ Sitemap  │ OpenAPI  │ Pagination │ LinkFollow        │
│   │ (SweetXml)│(JSON/YAML)│(Link/JSON)│ (BFS+Floki)     │
│   └──────────┴──────────┴────────────┘                   │
│        │                                                 │
│        │  list_items/3 (paginated URL discovery)         │
│        ▼                                                 │
│   Boundary ──▶ normalize + filter (domain/path/depth)    │
│        │                                                 │
│        │  fetch_content/2                                │
│        ▼                                                 │
│   Fetcher ──▶ Spider (HTML) or Req (JSON/XML)            │
│        │       + content hash (SHA-256)                  │
│        │       + rate limiting                           │
│        ▼                                                 │
│   {content, %{"etag" => hash, "content_hash" => hash}}   │
│                                                          │
└─────────────────────────────────────────────────────────┘
        │
        │  FullSync / IncrementalSync (existing pipeline)
        ▼
   File (source: :connector, external_id: url, external_etag: content_hash)
        │
        ▼
   Chunk + Embedding (pgvector) ──▶ RAG search
```

## Module Structure

```
lib/magus/knowledge/connectors/web/
├── web.ex                  # Connector behaviour implementation
├── auto_detector.ex        # Probes seed URL, picks strategy, parses robots.txt
├── fetcher.ex              # Spider/Req routing, content hashing, rate limiting
├── boundary.ex             # URL normalization + boundary rule checking
└── strategies/
    ├── strategy.ex         # Behaviour for discovery strategies
    ├── sitemap.ex          # Sitemap XML parsing (SweetXml)
    ├── openapi.ex          # OpenAPI spec parsing, GET-only, tag/path filtering
    ├── pagination.ex       # Link header + JSON cursor pagination
    └── link_follow.ex      # Bounded BFS link-following (Floki)
```

## Connector Behaviour Mapping

| Callback | Implementation |
|----------|---------------|
| `connect/1` | Extracts seed URL from auth_config, builds auth headers, runs auto-detection or explicit strategy override, fetches robots.txt + crawl-delay |
| `list_folders/2` | Returns single folder (web sources are flat) |
| `list_items/3` | Delegates to `strategy_module.discover/3`, translates to `Connector.item()` format |
| `fetch_content/2` | Routes to Spider (HTML) or Req (JSON/XML), returns content + SHA-256 hash in metadata |
| `detect_changes/3` | Returns `{:error, :not_supported}` — delegates to IncrementalSync fallback |
| `register_webhook/3` | Returns `{:error, :not_supported}` — uses polling |
| `create_item/5` | Returns `{:error, :not_supported}` — read-only |
| `update_item/5` | Returns `{:error, :not_supported}` — read-only |

### Settings Access

The `Connector.connect/1` callback only receives `auth_config`. Web-specific config (seed URL, strategy) is embedded in `auth_config` by the KnowledgeSource create action:

```elixir
# auth_config for :web sources
%{
  "auth_type" => "bearer",
  "token" => "sk-...",
  "seed_url" => "https://cms.example.com/api/v1/openapi.json",
  "strategy" => "auto"
}
```

Boundary rules and strategy-specific config live in `KnowledgeCollection.settings`.

### Item Translation

Strategy discover returns `%{url, metadata}` maps. The connector translates to `Connector.item()`:

```elixir
%{
  id: normalized_url,          # URL as unique identifier (via Boundary.normalize/1)
  name: title_or_url_path,     # from metadata title, fallback to URL path
  etag: nil,                   # computed during fetch_content, not discovery
  updated_at: parsed_datetime, # from metadata last_modified if available
  mime_type: "text/markdown"   # all web content stored as markdown
}
```

### Etag Flow (Content Hash)

The etag is `nil` at discovery time. During `fetch_content/2`, the content hash is computed and returned in metadata as `"etag"`. The modified `FullSync.create_file_from_item/6` uses `Map.get(metadata, "etag", item.etag)` to store the hash as `external_etag` on the File record. This enables IncrementalSync's fallback etag comparison to detect content changes.

## Discovery Strategies

### Strategy Behaviour

```elixir
@callback discover(connection :: term(), collection_settings :: map(), cursor :: map() | nil) ::
  {:ok, [%{url: String.t(), metadata: map()}], new_cursor :: map() | nil} | {:error, term()}
```

### SitemapStrategy

Parses `sitemap.xml` using SweetXml. Extracts `<loc>` URLs and `<lastmod>` timestamps. Supports sitemap index files (fetches each child sitemap). Returns all URLs in one call (no cursor pagination).

### OpenApiStrategy

Parses OpenAPI/Swagger specs (JSON via Jason, YAML via YamlElixir). GET endpoints only. Two modes:

- **spec_only** (default): generates markdown documentation from the spec (endpoint description, parameters, responses). Content stored in metadata as `:spec_content`, used directly by `fetch_content/2`.
- **content**: items point to live endpoint URLs for `fetch_content` to hit.

Endpoint filtering with precedence: `include_tags` → `exclude_tags` → `include_paths` → `exclude_paths`.

### PaginationStrategy

Follows paginated APIs. Two modes:
- **link_header**: parses `Link: <url>; rel="next"` HTTP headers
- **json_cursor**: extracts next-page URL/cursor from JSON response via configurable dot-path

### LinkFollowStrategy

Bounded BFS crawl. Uses Floki for `<a href>` link extraction, resolves relative URLs via `URI.merge/2`. Frontier stored in cursor, visited set reconstructed from existing File `external_id` records (not stored in cursor, to keep cursor size bounded).

Key limits: batch size 20, frontier capped at 2× max_pages, stops on empty frontier / max_depth / max_pages.

## AutoDetector

Probes the seed URL during `connect/1`:

1. GET seed URL → if JSON with `"openapi"` or `"swagger"` key → OpenApiStrategy
2. HEAD `{origin}/sitemap.xml` → if 200 → SitemapStrategy
3. GET `{origin}/robots.txt` → parse rules + crawl-delay
4. Fallback → LinkFollowStrategy

User can override with explicit `"strategy"` in auth_config. `strategy_for_override/1` maps strings to modules.

Robots.txt parser handles: stacked user-agents, `Disallow`, `Crawl-delay` (integer and fractional, converted to ms), `Sitemap` directives.

## Boundary Module

Pure functions for URL filtering:

- `normalize(url)` — lowercase scheme/host, remove default ports, strip fragments, strip tracking params (`utm_*`, `fbclid`, `gclid`), normalize trailing slashes
- `allowed?(url, config, robots_rules, depth)` — scheme check → domain check → path check → depth check → extension filter → robots.txt check

Blocked extensions: archives, images, media, fonts, CSS, JS.

## Fetcher

Routes content fetching based on content type (detected via HEAD request):

| Content Type | Fetch Method | Output |
|-------------|-------------|--------|
| HTML | Spider.cloud `/scrape` (requires `SPIDER_API_KEY`) | Clean markdown |
| JSON | Direct Req.get | Markdown code block |
| XML / Other | Direct Req.get | Raw content |

Features:
- SHA-256 content hashing (`"sha256:..."` prefix)
- UTF-8 safe truncation at 500KB (via `:unicode.characters_to_binary/1`)
- Rate limiting via `Process.sleep` (respects crawl-delay from robots.txt)
- Retry on 429/5xx with exponential backoff

## Change Detection

The web connector returns `{:error, :not_supported}` from `detect_changes/3`, triggering `IncrementalSync`'s fallback path:

1. Re-lists all items via `list_items` (re-runs discovery)
2. Compares content hashes (`external_etag`) against stored files
3. Creates new files, updates changed files, soft-deletes removed files

Content hashes ensure only genuinely changed content triggers re-chunking and re-embedding.

## Integration Points

### Modified Existing Files

| File | Change |
|------|--------|
| `connector.ex` | Added `connector_for(:web)` clause |
| `knowledge_source.ex` | Added `:web` to provider enum |
| `full_sync.ex` | Use `metadata["etag"]` as `external_etag` when present |

### Dependencies

- `SweetXml` — sitemap XML parsing (existing dependency)
- `Floki` — HTML link extraction in LinkFollowStrategy (added)
- `YamlElixir` — YAML OpenAPI spec parsing (made explicit, was transitive)
- Spider.cloud API — HTML content extraction (existing, via `SPIDER_API_KEY`)

## Key File Paths

| File | Purpose |
|------|---------|
| `lib/magus/knowledge/connectors/web/web.ex` | Connector behaviour implementation |
| `lib/magus/knowledge/connectors/web/boundary.ex` | URL normalization + filtering |
| `lib/magus/knowledge/connectors/web/fetcher.ex` | Content fetching + hashing |
| `lib/magus/knowledge/connectors/web/auto_detector.ex` | Strategy auto-detection + robots.txt parsing |
| `lib/magus/knowledge/connectors/web/strategies/strategy.ex` | Strategy behaviour definition |
| `lib/magus/knowledge/connectors/web/strategies/sitemap.ex` | Sitemap discovery |
| `lib/magus/knowledge/connectors/web/strategies/openapi.ex` | OpenAPI discovery |
| `lib/magus/knowledge/connectors/web/strategies/pagination.ex` | Pagination discovery |
| `lib/magus/knowledge/connectors/web/strategies/link_follow.ex` | Link-following discovery |
| `lib/magus/knowledge/connector.ex` | Connector behaviour + registry |
| `lib/magus/knowledge/knowledge_collection/changes/full_sync.ex` | Sync pipeline (etag fix) |
