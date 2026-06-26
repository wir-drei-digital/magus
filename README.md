# ◬ Magus

An open-source, self-hostable AI chat platform built with Elixir, Phoenix LiveView, and the Ash Framework. Agentic tool execution, a prompt library, multiple AI providers, persistent memory, a cross-resource knowledge graph, and configurable usage governance.

## Features

- **Multi-Model Chat** - Support for multiple AI providers (OpenRouter, xAI, etc.) with text, image, and video generation
- **Auto Router** - Per-message model selection based on intent classification and usage policy
- **Agentic Tool Execution** - AI can use tools like web search, memory persistence, scheduled jobs, and semantic document search
- **Custom Agents** - User-defined AI personas with @mentions, tool scoping, secrets, and multi-agent orchestration
- **Prompt Library** - Create, share, and discover reusable system prompts with semantic search
- **Skills System** - Specialized instruction sets the AI can load for specific tasks
- **Real-time Streaming** - Live streaming of AI responses via Phoenix PubSub and LiveView
- **Persistent Memory** - Three-scope memory system (local, user, agent) with automatic extraction and semantic search
- **Multiplayer Conversations** - Share conversations with others via invite links
- **File Management** - Upload documents for semantic search (RAG) with pgvector
- **Integrations** - External service connections (Telegram, webhooks, data sources, knowledge/RAG connectors)
- **Collaborative Tasks** - Shared task lists between users and AI agents with real-time updates
- **Usage Governance** - Configurable spend caps, storage and upload limits, usage policies, and per-message cost accounting

## Tech Stack

- **Framework**: [Phoenix](https://www.phoenixframework.org/) 1.8 with LiveView 1.1
- **Data Layer**: [Ash Framework](https://ash-hq.org/) 3.x with AshPostgres
- **AI Agents**: [Jido](https://hexdocs.pm/jido) for agent lifecycle, state management, and tools; [ReqLLM](https://hexdocs.pm/req_llm) for LLM streaming
- **Background Jobs**: [Oban](https://hexdocs.pm/oban) with AshOban integration
- **Auth**: AshAuthentication (password + magic link)
- **Frontend**: Tailwind CSS 4.x, DaisyUI, esbuild
- **Vector Search**: pgvector for semantic similarity
- **Markdown**: MDEx for rendering

## Getting Started

### Prerequisites

- Elixir 1.15+ and Erlang/OTP 26+
- PostgreSQL 16+ with the `pgvector` extension
- Node.js 20+ (for the SvelteKit workbench)
- (optional) FalkorDB for the Super Brain knowledge graph

### Setup

```bash
# 1. Configure: copy the example env and fill in the required values
cp .env.example .env
#    (DATABASE_URL or PG*, SECRET_KEY_BASE, TOKEN_SIGNING_SECRET,
#     INTEGRATION_ENCRYPTION_KEY, and at least one LLM provider key)

# 2. Check your configuration (reports which features each key unlocks)
mix magus.doctor

# 3. Install deps, create + migrate the DB, build assets, seed defaults
set -a && source .env && set +a
mix setup
(cd frontend && npm install)   # SvelteKit workbench

# 4. Start the server
set -a && source .env && set +a && mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000). The first registered user
becomes the admin; add a provider API key in the admin UI and import models.

### Docker

A self-contained Compose file brings up Postgres (with pgvector), FalkorDB, and
the app together:

```bash
docker compose -f docker-compose.selfhost.yml up
```

## Development

### Common Commands

```bash
# Database
mix ash.setup                # Create database, run migrations
mix ash.codegen              # Generate code after schema changes
mix ash.migrate              # Run migrations only

# Testing
mix test                     # Run all tests
mix test path/to/test.exs    # Run specific test file
mix test path/to/test.exs:42 # Run specific test at line
mix test.e2e                 # Run browser-based E2E tests (requires Playwright)

# Code Quality
mix precommit                # Format, compile with warnings, run tests

# Assets
mix assets.build             # Compile tailwind and esbuild
mix assets.deploy            # Build minified assets for production

# Simulate a Telegram webhook locally (server must be running)
mix magus.test_telegram --user-id <user_id>
mix magus.test_telegram --user-id <user_id> --text "Hi!" --chat-id 999
```

### Dev Routes

- `/dev/dashboard` - Phoenix LiveDashboard
- `/dev/mailbox` - Swoosh email preview
- `/oban` - Oban Web dashboard
- `/admin` - Ash Admin interface

### Production Seeds

```bash
bin/magus eval "Magus.Release.seed()"
```

## Architecture

### Domains

The application is organized into Ash Framework domains:

| Domain | Purpose |
|--------|---------|
| **Accounts** | User authentication, settings, model selection |
| **Chat** | Conversations, messages, models, routing slots, usage tracking |
| **Library** | Prompt library with tags, favorites, examples |
| **Files** | File storage and semantic chunks for RAG |
| **Memory** | Persistent memory with local/user/agent scopes and semantic search |
| **Agents** | Custom agents, agent runs, inbox events, activity logs, autonomy, secrets |
| **Plan** | Collaborative task management between users and agents |
| **Integrations** | External services (Telegram, webhooks, data sources, knowledge connectors) |
| **Knowledge** | Document sync and RAG pipeline from external sources |
| **Usage** | Usage governance: spend caps, storage/upload limits, policy enforcement, cost accounting |
| **FeatureUsage** | Onboarding and feature discovery tracking |

## Evaluation (Benchmarks)

A benchmark-agnostic eval harness (`lib/magus/eval/`) drives the **real** agent
pipeline as a black box: it ingests history, settles memory extraction, asks a
question, captures the answer, scores it, and appends the run to a scoreboard.
This turns harness, memory, and context-engineering changes into measurable
iteration-over-iteration deltas instead of guesses.

### Running a benchmark

```bash
# <benchmark> is one of: coverage_smoke | longmemeval | gaia
MIX_ENV=test mix magus.eval coverage_smoke

# Validate cheaply on a tiny subset (recommended first)
MIX_ENV=test mix magus.eval longmemeval --limit 2

# Common flags
MIX_ENV=test mix magus.eval longmemeval \
  --limit 5 \                       # only the first N cases
  --judge openrouter:openai/gpt-4o \ # override the LLM judge model (judged benchmarks)
  --out tmp/eval \                  # results dir (default: eval/results)
  --dry-run                         # run + score but do NOT write the scoreboard
```

It must run under `MIX_ENV=test`: the task and the live `Subject` reuse
test-only fixtures (`Magus.Generators`, `Magus.LiveE2ECase`), so they live in
`test/support/` and are kept out of the dev/prod build. Runs go through the
configured **eval database**, never dev or prod data.

**Required environment:**

- `OPENROUTER_API_KEY` - always (the agent and the default judge call OpenRouter).
- The default judge is the cheap `openrouter:openai/gpt-4o-mini`
  (`:eval_judge_model` in `config/config.exs`). For leaderboard-comparable
  LongMemEval numbers, pin a GPT-4o-class judge with `--judge`.
- `HF_TOKEN` - only for `gaia` (a gated HuggingFace dataset), unless you supply a
  local file (see below).

### The benchmarks

| Benchmark | Type | Scoring | Dataset |
|-----------|------|---------|---------|
| `coverage_smoke` | Built-in smoke test | Deterministic (gold-fact containment), no judge | Bundled (`priv/eval/coverage_smoke/`), no download |
| `longmemeval` | Long-term memory | LLM judge (reference-guided, abstention-aware), per-ability breakdown | LongMemEval-S, local-first |
| `gaia` | General agentic | Deterministic quasi-exact-match, per-level breakdown | GAIA validation (text-only), gated |

`coverage_smoke` needs no external dataset and is the fastest way to prove the
loop end to end.

### Datasets (local-first)

Real datasets are loaded local-first so you can run by dropping a file on disk;
a download is only attempted as a fallback. Cache files live under `eval/cache/`
and are git-ignored (never committed).

- **LongMemEval-S:** place the JSON at `eval/cache/longmemeval_s.json`, or point
  `EVAL_LONGMEMEVAL_PATH` at it (optional `EVAL_LONGMEMEVAL_URL` to download).
- **GAIA:** place the validation JSON at `eval/cache/gaia_validation.json`, or
  point `EVAL_GAIA_PATH` at it. Otherwise it needs `HF_TOKEN` plus an
  `EVAL_GAIA_URL` to fetch the gated dataset. Without either, the run reports
  `:gaia_access` and skips gracefully.

> **Cost:** full runs are expensive (LongMemEval-S is 500 questions, each
> ingesting tens of sessions, so thousands of extraction LLM calls even on cheap
> models). Always validate with `--limit` first; a full run is a deliberate,
> costed decision.

### Results

Each run appends one JSON line to `eval/results/<benchmark>.jsonl`, keyed by git
sha, with the aggregate score, config, and per-case detail (diff these files to
track deltas across iterations). Per-question hypotheses are written alongside as
`<benchmark>.hyp.jsonl`.

### Adding a benchmark

Implement the `Magus.Eval.Benchmark` behaviour in `lib/magus/eval/benchmarks/`
(`name/0`, `load_dataset/1`, `cases/2`, `emit_hypotheses/2`, `score/2`) and add
one entry to the `@benchmarks` map in `test/support/mix/tasks/magus.eval.ex`.
A `case` is `%{id, ingest_items: [%{role: :user | :assistant, text}], question,
gold, meta}`; the `result` passed to `score/2` is `%{id, question, gold, answer,
meta}`. Reuse `Magus.Eval.Judge` for LLM-judged scoring or `Magus.Eval.GaiaScore`
for deterministic quasi-exact-match. Benchmark modules in `lib/` must not depend
on test-only modules; the live `Subject` is wired by the runner.

### Tests

```bash
# Pure unit tests (no LLM, fast)
MIX_ENV=test mix test test/magus/eval/

# Live end-to-end proof on cheap models (one case each of LongMemEval + GAIA)
bin/test-e2e-live test/e2e_live/eval_benchmarks_test.exs
```

## License

Licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
