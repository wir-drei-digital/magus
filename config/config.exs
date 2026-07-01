# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configure Elixir to use tzdata for timezone support
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :ash_oban, pro?: false

# ReqLLM streaming configuration
# LLM responses with tool calls can take several minutes between chunks
# Default 30s is too short for complex agentic workflows
config :req_llm,
  # Timeout between stream chunks (5 minutes for regular models)
  receive_timeout: 300_000,
  # Extended timeout for reasoning/thinking models (10 minutes)
  thinking_timeout: 600_000,
  # Metadata collection timeout (10 minutes)
  metadata_timeout: 600_000,
  # Override default Finch pool (default: size 1, count 8 = only 8 concurrent connections)
  # Each LLM stream holds a connection for minutes, so we need more headroom
  finch: [
    pools: %{
      :default => [
        protocols: [:http1],
        size: 4,
        count: 16
      ]
    }
  ]

# Data region configuration for provider routing
config :magus, :data_regions,
  regions: %{
    "US" => %{label: "United States", requires_consent: false},
    "EU" => %{label: "Europe", requires_consent: false},
    "CH" => %{label: "Switzerland", requires_consent: false},
    "CN" => %{label: "China", requires_consent: true},
    "SG" => %{label: "Singapore", requires_consent: true}
  },
  default_allowed: ["US", "EU", "CH"],
  providers: %{
    # US providers
    "anthropic" => "US",
    "openai" => "US",
    "google-ai-studio" => "US",
    "google-vertex" => "US",
    "amazon-bedrock" => "US",
    "amazon-nova" => "US",
    "azure" => "US",
    "together" => "US",
    "deepinfra" => "US",
    "fireworks" => "US",
    "groq" => "US",
    "cerebras" => "US",
    "sambanova" => "US",
    "novita" => "US",
    "parasail" => "US",
    "chutes" => "US",
    "baseten" => "US",
    "venice" => "US",
    "perplexity" => "US",
    "nvidia" => "US",
    "inflection" => "US",
    "cohere" => "US",
    "crusoe" => "US",
    "hyperbolic" => "US",
    "ai21" => "US",
    "inceptron" => "US",
    "nextbit" => "US",
    "ionstream" => "US",
    "phala" => "US",
    "gmicloud" => "US",
    "atlascloud" => "US",
    "ambient" => "US",
    "io-net" => "US",
    "xai" => "US",
    # EU providers
    "mistral" => "EU",
    "nebius" => "EU",
    "cloudflare" => "EU",
    # CH providers
    "publicai" => "CH",
    # CN providers
    "deepseek" => "CN",
    "alibaba" => "CN",
    "siliconflow" => "SG",
    "minimax" => "SG",
    "moonshot-ai" => "SG",
    "z-ai" => "SG"
    # SG providers — to be populated as needed
  },
  api_provider_regions: %{
    xai: "US",
    publicai: "CH",
    aimlapi: "US",
    fal: "US"
  }

# Custom LLMDB providers/models are synced at runtime from the DB catalog
# (Provider + Model rows) by `Magus.Models.CatalogSync` — at boot and on
# every catalog write. See `Magus.Models.CatalogSync.build_custom/0`.

# ReAct token secret for checkpoint token signing (prevents ephemeral secret warning)
config :jido_ai, :react_token_secret, "magus-dev-react-token-secret-change-in-prod"

# Agents configuration - centralized LLM model settings
config :magus, :agents,
  # default_model: nil means use database default, then fallback to hardcoded
  default_model: nil,
  summary_model: "openrouter:anthropic/claude-haiku-4.5",
  title_model: "openrouter:anthropic/claude-haiku-4.5",
  embedding_model: "openai/text-embedding-3-small",
  classification_model: "openrouter:mistralai/ministral-3b-2512",
  max_iterations: 100,
  max_parallel_runs_per_target: 3,
  # When the model returns a blank final answer (no text, no tool calls) the
  # runner re-asks the LLM up to `empty_response_max_retries` times with an
  # exponential backoff (base * 2^attempt). Set max retries to 0 to disable.
  empty_response_max_retries: 3,
  empty_response_retry_backoff_ms: 500,
  # Wall-clock ceiling for consuming a single streamed LLM turn. Guards against
  # a provider stream that stalls without ever closing (a "stuck" turn).
  llm_stream_timeout_ms: 300_000

config :magus, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [
    default: 10,
    # Out-of-band reconciliation of zero-token usage rows against OpenRouter's
    # generation endpoint (rate-limited external API polling)
    usage_reconciliation: [limit: 5],
    # LLM responses can take 5+ minutes with complex tool calls
    chat_responses: [limit: 10, dispatch_cooldown: 100],
    conversations: [limit: 10],
    file_processing: [limit: 10],
    memory_extraction: [limit: 5],
    # Daily memory consolidation (runs at 3 AM)
    memory_consolidation: [limit: 2],
    # Job execution triggers LLM responses, needs longer timeout
    workflow_jobs: [limit: 10, dispatch_cooldown: 100],
    # Sandbox maintenance (suspend inactive, terminate stale)
    sandbox_maintenance: 10,
    # Knowledge collection sync
    knowledge_sync: [limit: 5],
    # Agent run stale cleanup
    agent_run_cleanup: 1,
    # Stale streaming message cleanup
    maintenance: 1,
    # Agent heartbeat scheduler (checks every 5 min via cron)
    heartbeat: 1,
    # Trashed conversation cleanup (daily, deletes after 30 days)
    conversation_cleanup: 1,
    # Context-window compaction (summarize older messages, advance the pointer).
    # Enqueued on-demand by ContextWindow.request_compaction; a */1 cron is the
    # safety net. One LLM summary call per job.
    context_compaction: [limit: 5],
    # Trashed brain page cleanup (daily, deletes after 30 days)
    brain_page_cleanup: 1,
    # Data source polling (RSS feeds, etc.)
    integrations: [limit: 5],
    brain_name_page: [limit: 2],
    # Brain chunk embedding generation (page chunks + source chunks).
    brain_embedding: [limit: 5],
    # Super Brain entity/edge extraction from brain pages, files, etc.
    super_brain_extraction: 4
  ],
  repo: Magus.Repo,
  plugins: [
    # Rescue jobs orphaned in :executing by a hard BEAM kill back to :available.
    # Without this, the */1 compaction cron's unique-job re-insert dedupes against
    # the orphan (states: :incomplete includes :executing), so a crashed worker
    # would leave its :pending row locked forever. 5 min comfortably exceeds a
    # normal single-summary compaction pass.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(5)},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", Magus.Integrations.Workers.PurgeIngestionEntries},
       {"*/5 * * * *", Magus.Agents.Workers.HeartbeatScheduler},
       {"*/10 * * * *", Magus.SuperBrain.Workers.MigrationSweeper},
       {"*/15 * * * *", Magus.SuperBrain.Workers.BackfillScheduler},
       {"30 3 * * *", Magus.SuperBrain.Workers.NightlyBuildSuperScheduler},
       {"0 4 * * *", Magus.SuperBrain.Workers.SuperGraphMaintenance},
       {"15 3 * * *", Magus.Accounts.Workers.DeleteExpiredTestAccounts}
     ]}
  ]

config :mime,
  extensions: %{
    "json" => "application/vnd.api+json",
    "eml" => "message/rfc822",
    "msg" => "application/vnd.ms-outlook"
  },
  types: %{
    "application/vnd.api+json" => ["json"],
    "message/rfc822" => ["eml"],
    "application/vnd.ms-outlook" => ["msg"]
  }

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

# Typed RPC layer for the SvelteKit workbench (frontend/). Actions are exposed
# per-domain via `typescript_rpc` blocks; `mix ash.codegen` regenerates the
# committed TypeScript client. See docs/superpowers/specs/2026-06-11-sveltekit-
# workbench-migration-design.md.
config :ash_typescript,
  output_file: "frontend/src/lib/ash/ash_rpc.ts",
  run_endpoint: "/rpc/run",
  validate_endpoint: "/rpc/validate",
  input_field_formatter: :camel_case,
  output_field_formatter: :camel_case,
  type_mapping_overrides: [
    # Cloak-encrypted string (AgentSecret.value) — plain string on the wire;
    # the SPA never selects it (write-only from its perspective).
    {Magus.Agents.AgentSecret.EncryptedString, "string"}
  ]

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :admin,
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :json_api,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [
        :admin,
        :json_api,
        :resources,
        :policies,
        :authorization,
        :domain,
        :execution
      ]
    ]
  ]

config :magus,
  ecto_repos: [Magus.Repo],
  generators: [timestamp_type: :utc_datetime],
  eval_results_dir: "eval/results",
  # Cheap by default to protect the OpenRouter budget. Wave 0.1 (LongMemEval)
  # will pin a full GPT-4o-class judge for leaderboard comparability.
  eval_judge_model: "openrouter:openai/gpt-4o-mini",
  eval_judge_prompt_version: "v1",
  # The core Ash domain list (read by Ash tooling + AshOban at boot). Mirrors
  # `Magus.Domains.core_domains/0`, kept as a literal here because config is
  # evaluated before the app modules are compiled.
  ash_domains: [
    Magus.Chat,
    Magus.Models,
    Magus.Accounts,
    Magus.Library,
    Magus.Files,
    Magus.Memory,
    Magus.Workflows,
    Magus.Usage,
    Magus.Sandbox,
    Magus.Agents,
    Magus.Integrations,
    Magus.Notifications,
    Magus.Drafts,
    Magus.Workspaces,
    Magus.Organizations,
    Magus.FeatureUsage,
    Magus.Plan,
    Magus.Knowledge,
    Magus.Brain,
    Magus.Workbench,
    Magus.SuperBrain,
    Magus.MCP,
    Magus.Skills
  ]

# MCP client configuration. `init_timeout_ms` bounds how long a discovery
# client waits for the MCP handshake before giving up. `registry_base_url` points
# at the public MCP registry used for server discovery (swap for a self-hosted
# registry or aggregator); `registry_cache_ttl_ms` is the browse-catalog cache TTL.
config :magus, Magus.MCP,
  init_timeout_ms: 10_000,
  registry_base_url: "https://registry.modelcontextprotocol.io",
  registry_cache_ttl_ms: :timer.minutes(60)

# Memory domain configuration
config :magus, Magus.Memory,
  max_content_chars: 8_000,
  max_summary_chars: 500,
  max_memories_per_conversation: 20,
  # Extraction settings
  extraction_message_threshold: 5,
  extraction_inactivity_minutes: 5

# SuperBrain master kill switch. Disabled by default: when false, all
# extraction/build/scheduler jobs cancel, enqueue sites skip, the per-message
# retrieval context is not injected, and the super_brain tools are not offered.
# test.exs sets this to true; prod reads SUPER_BRAIN_ENABLED in runtime.exs.
config :magus, :super_brain_enabled, false

# SuperBrain extraction LLM client (overridden in test.exs to a Mox mock)
config :magus, :super_brain_llm_client, Magus.SuperBrain.LLMClient.ReqLLM

# SuperBrain retrieval-time text embedder (overridden in test.exs to a Mox mock)
config :magus, :super_brain_embedder, Magus.Embeddings.OpenAIEmbedder

# SuperBrain extraction-time batch embedder (overridden in test.exs to a Mox mock)
config :magus, :super_brain_extraction_embedder, Magus.Embeddings.OpenAIBatchEmbedder

# Admin-created workshop/demo test accounts: the email domain their logins are
# synthesised under (e.g. demo1@magus.digital). Override per-deployment via the
# TEST_ACCOUNT_EMAIL_DOMAIN env var (see runtime.exs).
config :magus, :test_accounts, email_domain: "magus.digital"

# Per-user caps for the user-owned model catalog (BYOK). A user may own at most
# max_providers providers and max_models models.
config :magus, :user_model_limits, max_providers: 10, max_models: 50

# ReqLLM provider ids a user-owned provider may target. Keeps BYOK on
# vetted, well-behaved provider modules; "openai_compatible" covers custom
# OpenAI-compatible endpoints (which additionally require a safe base_url).
config :magus,
       :user_provider_req_llm_allowlist,
       ~w(anthropic openai openrouter xai google openai_compatible)

# Chat domain configuration
config :magus, Magus.Chat, unfiled_conversations_limit: 20

# Context-window state + compaction defaults (per-conversation overrides live on
# Magus.Chat.ContextWindow.strategy). See lib/magus/chat/context_window.ex.
config :magus, Magus.Chat.ContextWindow,
  default_strategy: :rolling,
  rolling_target_fraction: 0.6,
  message_count_backstop: 200,
  compaction_tail: 6,
  warn_fraction: 0.75,
  alert_fraction: 0.90,
  auto_compact_fraction: 0.85,
  auto_compact_enabled: true

# Billing: default monthly spend cap (integer cents, CHF) applied to pay-per-use
# overage when a user has not set their own `monthly_spend_cap_cents`. nil cap on
# the subscription means "use this default", not "unlimited". 2000 = CHF 20.
config :magus, :default_monthly_spend_cap_cents, 2000

# Billing: one-time free-trial usage allowance (integer cents, CHF) for
# non-billable (free) users. NOT a recurring monthly grant: it does not reset
# for free users (only Stripe billing cycles reset usage). 100 = CHF 1.
config :magus, :free_trial_spend_cap_cents, 100

# Open-core edition: the Usage cloud-seam adapters (metering, account-lifecycle,
# exchange-rate, seat-grant) use their in-core defaults (no-op / 1:1 Identity),
# the always-loaded workbench Subscription section falls back to its neutral
# Default (subscription management unavailable), and `Magus.Usage.billing_edition?/0`
# is false. The commercial billing edition (magus_cloud) overrides these via config.

# Email tool configuration
config :magus, Magus.Agents.Tools.Email.SendEmail,
  rate_limit_minutes: 15,
  max_subject_length: 100,
  max_body_length: 10_000

# Application URL (used in emails + outbound provider Referer headers).
# Overridden in production from APP_URL/PHX_HOST (see config/runtime.exs).
config :magus, app_url: "http://localhost:4000"

config :magus, Magus.Repo, types: Magus.PostgrexTypes

# Configure the endpoint
config :magus, MagusWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MagusWeb.ErrorHTML, json: MagusWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Magus.PubSub,
  live_view: [signing_salt: "ZyLC7qYv"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :magus, Magus.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  magus: [
    args:
      ~w(js/app.js js/companions/spreadsheet/univer_adapter.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" => [
        Path.expand("../deps", __DIR__),
        Path.expand("../assets/node_modules", __DIR__),
        Mix.Project.build_path()
      ]
    }
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  magus: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :run_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Redact sensitive params from request logs
config :phoenix, :filter_parameters, [
  "token",
  "plaintext",
  "password",
  "secret",
  "api_key",
  "key_hash"
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
