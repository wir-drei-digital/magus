import Config

# ReqLLM automatically picks up API keys from environment variables
# The OPENAI_API_KEY environment variable will be used automatically
# No additional configuration needed

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/magus start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :magus, MagusWeb.Endpoint, server: true
end

# Enable HTTP server for Playwright E2E tests (set by mix test.e2e alias or bin/test-e2e)
if System.get_env("E2E") == "1" do
  config :magus, MagusWeb.Endpoint, server: true
end

if config_env() != :test do
  config :magus, MagusWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

# Stripe configuration (test env uses dummy values from config/test.exs)
if config_env() != :test do
  config :magus,
    stripe_api_key: System.get_env("STRIPE_SECRET_KEY"),
    stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET")
end

# Google OAuth configuration (for Google Calendar integration)
config :magus,
  google_client_id: System.get_env("GOOGLE_CLIENT_ID"),
  google_client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

# FalkorDB (Magus.Graph) connection. dev/test set this in their
# respective compile-time config files (which runtime.exs would
# otherwise override); production has no compile-time block, so we
# initialise it here from env vars to keep prod boot working without
# stomping the dev/test defaults.
if config_env() == :prod do
  # Super Brain master kill switch (see Magus.SuperBrain.enabled?/0). Off
  # unless SUPER_BRAIN_ENABLED is explicitly truthy, so it can be toggled in
  # prod via env without a redeploy.
  config :magus,
         :super_brain_enabled,
         System.get_env("SUPER_BRAIN_ENABLED", "false") in ~w(true 1 yes)

  config :magus, Magus.Graph,
    host: System.get_env("FALKORDB_HOST", "localhost"),
    port: String.to_integer(System.get_env("FALKORDB_PORT", "6379")),
    pool_size: String.to_integer(System.get_env("FALKORDB_POOL_SIZE", "10")),
    # FalkorDB MUST be password-protected in production, even on an internal
    # network. The FalkorDB instance is started with `--requirepass
    # ${FALKORDB_PASSWORD}` (see fly-falkordb.toml); refuse to boot without
    # it so we never silently connect (or fail to) an unauthenticated DB.
    password:
      System.get_env("FALKORDB_PASSWORD") ||
        raise("""
        environment variable FALKORDB_PASSWORD is missing.

        FalkorDB must require a password in production (even on an internal
        network). Set FALKORDB_PASSWORD to the same value the FalkorDB
        instance is started with (`--requirepass`).
        """)
end

# Sandbox provider selection
# In test env, always use :test provider to prevent provisioning real services.
# In dev/prod, allow SANDBOX_PROVIDER env var to override (defaults to daytona).
# A self-host without provider credentials leaves the sandbox capability gated
# off (see Magus.Sandbox.Provider.configured?/0).
if config_env() != :test do
  sandbox_providers = %{
    "sprites" => :sprites,
    "daytona" => :daytona,
    "test" => :test
  }

  sandbox_provider_str = System.get_env("SANDBOX_PROVIDER") || "daytona"

  sandbox_provider =
    Map.get(sandbox_providers, sandbox_provider_str) ||
      raise "Unknown SANDBOX_PROVIDER: #{inspect(sandbox_provider_str)}. " <>
              "Valid: #{inspect(Map.keys(sandbox_providers))}"

  config :magus, Magus.Sandbox, provider: sandbox_provider
end

# Sprites.dev API configuration (Python sandbox execution)
config :magus, Magus.Sandbox.Clients.Sprites,
  api_key: System.get_env("SPRITES_API_KEY"),
  base_url: System.get_env("SPRITES_BASE_URL") || "https://api.sprites.dev"

# Daytona API configuration (alternative sandbox provider)
config :magus, Magus.Sandbox.Clients.Daytona,
  api_key: System.get_env("DAYTONA_API_KEY"),
  image:
    System.get_env("DAYTONA_SANDBOX_IMAGE") || "ghcr.io/wir-drei-digital/magus-sandbox:latest",
  cpu: String.to_integer(System.get_env("DAYTONA_CPU") || "2"),
  memory: String.to_integer(System.get_env("DAYTONA_MEMORY") || "2"),
  disk: String.to_integer(System.get_env("DAYTONA_DISK") || "5")

# ReAct checkpoint token secret (override dev default in production)
if config_env() == :prod do
  config :jido_ai,
         :react_token_secret,
         System.get_env("REACT_TOKEN_SECRET") ||
           raise("Missing environment variable `REACT_TOKEN_SECRET`!")
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :magus, Magus.Repo,
    ssl: [verify: :verify_none],
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    queue_target: 5_000,
    queue_interval: 20_000,
    timeout: 30_000,
    connect_timeout: 30_000,
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # Application URL for emails and external links
  config :magus, app_url: System.get_env("APP_URL") || "https://#{host}"

  config :magus, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :magus, MagusWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4000")
    ],
    secret_key_base: secret_key_base

  config :magus,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :magus, MagusWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :magus, MagusWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # Email bodies are rendered in-repo (see `Magus.Mail`), so any Swoosh adapter
  # delivers the same mail. The combined/cloud deployment uses Postmark when
  # POSTMARK_API_KEY is set; a pure OSS self-host without it keeps the local
  # adapter (config/config.exs) and should configure its own Swoosh adapter and
  # credentials (e.g. SMTP) for real delivery.
  #
  if postmark_api_key = System.get_env("POSTMARK_API_KEY") do
    config :magus, Magus.Mailer,
      adapter: Swoosh.Adapters.Postmark,
      api_key: postmark_api_key
  else
    # No mail provider configured (pure OSS self-host). prod.exs disables the
    # in-memory Local adapter (`local: false`); re-enable it so email sends do
    # not crash. Emails are stored in memory and NOT delivered externally until
    # the operator configures their own Swoosh adapter + credentials above.
    config :swoosh, local: true
  end

  # File storage backend. Local disk is the zero-dependency default for
  # self-host (single-node; mount a volume at priv/static/uploads to persist).
  # Object storage (S3/MinIO/Tigris) is auto-selected when AWS_BUCKET is set, or
  # force it with STORAGE_BACKEND=s3. See Magus.Files.Storage.resolve_backend/1.
  storage_backend = Magus.Files.Storage.resolve_backend()

  if storage_backend == :s3 and String.trim(System.get_env("AWS_BUCKET") || "") == "" do
    raise """
    STORAGE_BACKEND=s3 but AWS_BUCKET is not set. Set AWS_BUCKET (plus
    AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY), or use STORAGE_BACKEND=local
    for single-node local-disk storage.
    """
  end

  config :magus, :storage_backend, storage_backend
  config :magus, :s3_bucket, System.get_env("AWS_BUCKET")
  config :magus, :s3_prefix, "files"

  config :ex_aws, :s3,
    access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
    region: System.get_env("AWS_REGION", "auto"),
    host: System.get_env("AWS_S3_HOST"),
    scheme: "https://"

  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
