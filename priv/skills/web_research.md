---
name: web_research
description: Search the web and fetch pages like a human researcher — iterative, curious, and thorough
tags:
  - web
  - search
  - research
  - crawl
tools:
  - web_search
  - web_fetch
---

# Web Research

You have access to web search and web fetching tools. Use them together like a human researcher — don't just fire one search and stop. Be iterative, curious, and thorough.

## Tools

| Tool | Purpose | Key Params |
|------|---------|------------|
| `web_search` | Search the web for pages matching a query | `query`, `num_results` (1-10), `category` (news, research paper, github, tweet) |
| `web_fetch` | Fetch and read the actual content of URLs | `urls` (1-10), `crawl_depth` (0=scrape, 1+=crawl), `crawl_limit`, `return_format` |

## How to Research Like a Human

### 1. Search → Evaluate → Fetch the Best

Don't fetch every search result. Read the titles and snippets first, pick the most promising one or two, then fetch those.

```
1. web_search: "best practices for PostgreSQL indexing"
2. Read titles and snippets from results
3. web_fetch: fetch the 1-2 most relevant/authoritative URLs
4. Synthesize the answer from the fetched content
```

### 2. Follow Interesting Links

When you fetch a page and find links to deeper content (documentation subpages, referenced articles, related resources), follow them. Don't stop at the surface.

```
1. web_fetch: fetch the main documentation page
2. Notice links to subtopics in the content
3. web_fetch: fetch the specific subtopic pages that are relevant
```

### 3. Refine Your Search

If the first search doesn't give great results, rephrase and try again — just like a human would. Try different angles, more specific terms, or different categories.

```
1. web_search: "elixir genserver timeout" → results are too generic
2. web_search: "elixir genserver handle_info timeout hibernate" → better results
3. web_fetch the best match
```

### 4. Crawl for Multi-Page Content

When dealing with documentation sites, tutorials, or multi-page articles, use `crawl_depth` to automatically follow links from the starting page.

```
1. web_fetch: urls=["https://docs.example.com/guide"], crawl_depth=1, crawl_limit=5
   → Fetches the guide page plus up to 5 linked subpages
```

### 5. Cross-Reference Multiple Sources

For factual or technical questions, don't trust a single source. Search, fetch from 2-3 sources, and compare.

```
1. web_search: "node.js vs deno performance 2026"
2. web_fetch: fetch top 2-3 results from different domains
3. Compare claims across sources, note agreements and contradictions
```

## Common Patterns

### Answering a Factual Question
1. `web_search` with a clear, specific query
2. Evaluate results — pick the most authoritative source
3. `web_fetch` that source
4. If the answer is incomplete, search again with a refined query or fetch a second source
5. Synthesize and present with sources

### Researching a Topic in Depth
1. `web_search` for an overview (e.g., "X explained" or "guide to X")
2. `web_fetch` the best overview article
3. Identify subtopics or gaps from the overview
4. `web_search` or `web_fetch` linked pages for each subtopic
5. Compile findings into a structured summary

### Finding Current Information
1. `web_search` with `category: "news"` for recent events
2. `web_fetch` the top news article
3. If needed, search for additional context or background

### Exploring Documentation
1. `web_fetch` the documentation landing page or table of contents
2. Identify the relevant sections from the page structure
3. `web_fetch` specific section URLs, or use `crawl_depth: 1` to grab linked pages
4. Extract the relevant information

### Comparing Options
1. `web_search` for "X vs Y" or "best Z for [use case]"
2. `web_fetch` 2-3 comparison articles from different sources
3. Present a balanced comparison with pros/cons from each source

## Important Rules

- **Embed relevant images.** When fetched content contains images that help the user (recipe photos, product images, diagrams, charts), include them in your response as markdown images: `![description](https://example.com/image.jpg)`. Pick the most relevant one or two — don't dump every image from the page.
- **Always cite sources.** After using search results, include a "Sources:" section with markdown links at the end of your response.
- **Don't over-fetch.** Fetching 10 URLs at once wastes time. Be selective — fetch 1-3 at a time, then decide if you need more.
- **Read before you fetch more.** Process what you've already fetched before reaching for the next URL.
- **Use crawl mode sparingly.** Crawling is powerful but returns a lot of content. Use it for documentation sites where you need multiple connected pages, not for random articles.
- **Prefer specific queries.** "How to configure nginx reverse proxy for websockets" beats "nginx configuration".
- **Try different search categories** when the default results aren't great. `category: "github"` finds repos, `category: "research paper"` finds academic content.
