import Config
config :magus, Oban, testing: :manual

# Lets local/Bypass MCP servers on 127.0.0.1 pass SSRF validation in tests.
# Small init timeout so unreachable-server tests fail fast instead of waiting 10s.
config :magus, Magus.MCP, allow_private_urls: true, init_timeout_ms: 200
config :magus, token_signing_secret: "/kGClFEsHQGu7Qq6vHVbBD6EWKzeMkSs"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :magus, Magus.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "magus_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# server: true is set at runtime in config/runtime.exs when E2E=1,
# so that mix aliases using System.put_env can enable it.
config :magus, MagusWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "2Lz1qcDEPBqtGOFrBPCXv+/+Y70dCvnhHSN//9ajXRcnLODj3WqzdC2V6Zx70oOw",
  server: false

# Enable SQL sandbox plug for browser-based E2E tests
config :magus, sql_sandbox: true

# In test we don't send emails
config :magus, Magus.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Suppress logs during test (expected validation errors would be noisy)
config :logger, level: :none

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Use local file storage in tests
config :magus, :storage_backend, :local

# Use mock LLM client in tests
config :magus, :llm_client, Magus.Test.Mocks.LLMMock

# Use mock image generation client in tests
config :magus, :image_gen_client, Magus.Test.Mocks.ImageGenMock

# Use mock video generation client in tests
config :magus, :video_gen_client, Magus.Test.Mocks.VideoGenMock

config :magus, :openrouter_video_client, Magus.Test.Mocks.OpenRouterVideoMock

# Req.Test plug so the real OpenRouterVideo provider can be HTTP-stubbed in its
# own unit test (the action tests use the mock client above instead).
config :magus, :openrouter_video_req_options,
  plug: {Req.Test, Magus.Agents.Providers.OpenRouterVideo}

# Stub external provider billing/usage fetches so the admin Providers LiveView
# never makes real network calls during tests.
config :magus, :provider_usage_fetcher, Magus.Test.StubProviderUsage

# Super Brain stays enabled in tests so the feature suite exercises the real
# code paths (the kill switch itself is covered by dedicated tests that flip
# this per-test).
config :magus, :super_brain_enabled, true

# Use mock SuperBrain LLM client in tests
config :magus, :super_brain_llm_client, Magus.SuperBrain.LLMMock

# Use mock SuperBrain embedder in tests
config :magus, :super_brain_embedder, Magus.Embeddings.EmbedderMock

# Use mock SuperBrain extraction batch embedder in tests
config :magus, :super_brain_extraction_embedder, Magus.Embeddings.BatchEmbedderMock

# Use test sandbox provider to prevent provisioning real services
config :magus, Magus.Sandbox, provider: :test

# Use Req.Test plug for Spider API in tests
config :magus, :spider_req_options, plug: {Req.Test, Magus.Agents.Tools.Web.WebFetch}

# Use Req.Test plug for HttpRequest tool in tests
config :magus, :http_request_req_options,
  plug: {Req.Test, Magus.Agents.Tools.Integrations.HttpRequest}

# Use Req.Test plug for Brain source ingestion in tests
config :magus, :brain_source_req_options, plug: {Req.Test, Magus.Brain.Source.IngestWorker}

# Disable LLM-based classification in tests (use heuristic fallback)
config :magus, :agents, classification_model: nil

# Run activity log writes synchronously in tests
config :magus, activity_log_async: false

# Disable Jido InstanceManager in tests - agent processes can't access Ecto sandbox
# For full agent integration tests, see test/magus/agents/integration_test.exs
config :magus, :jido_instance_manager, enabled: false

# PhoenixTest configuration for browser-based E2E tests
config :phoenix_test,
  endpoint: MagusWeb.Endpoint,
  otp_app: :magus,
  playwright: [
    browser_pools: [[id: :default_pool, browser: :chromium]],
    assets_dir: "./assets",
    timeout: :timer.seconds(10),
    js_logger: false
  ]

config :magus, Magus.Graph,
  host: System.get_env("FALKORDB_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("FALKORDB_PORT", "6380")),
  pool_size: 5,
  graph_name_prefix: "test_",
  # ExUnit runs many graph-touching tests in parallel; transient FalkorDB
  # errors from unrelated tests would otherwise sum into a global breaker
  # trip and produce ~7-13 spurious failures per `mix precommit` run. The
  # breaker is a prod hot-loop safety net, not a test-isolation primitive.
  circuit_breaker_disabled: true
