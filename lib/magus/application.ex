defmodule Magus.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Suppress noisy Jido action execution logs (Noop fires on every passthrough signal)
    # Logger.log macro is compiled in Jido.Action.Util (cond_log), not Telemetry
    Logger.put_module_level(Jido.Action.Util, :warning)

    # Backing ETS table for one-shot chat actions captured from URL params.
    MagusWeb.Workbench.Chat.PendingChatAction.init()

    # Backing ETS table for one-shot `?highlight=` message ids (deep link).
    MagusWeb.Workbench.Chat.PendingMessageHighlight.init()

    # Register custom LLM providers
    ReqLLM.Providers.register(Magus.Agents.Providers.PublicAI)
    ReqLLM.Providers.register(Magus.Agents.Providers.OpenRouterWithCitations)
    ReqLLM.Providers.register(Magus.Models.Providers.OpenAICompatible)

    # Seed config-driven integration providers (open-core seam) before any
    # lookup, so cloud/external providers register at boot. No-op in core.
    Magus.Integrations.Registry.seed_from_config()

    children = child_specs()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Magus.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = result ->
        # Attach the Super Brain telemetry-to-Logger handler after the
        # supervisor is up so a Logger failure here can never block
        # startup. The handler is safe to attach more than once
        # (`attach/0` collapses `:already_exists` to `:ok`).
        :ok = Magus.SuperBrain.TelemetryHandler.attach()

        result

      other ->
        other
    end
  end

  @doc """
  Builds the supervision child spec list.

  Public so the open-core / `magus_cloud` composition seam is testable without
  booting a second supervision tree. Two seams are wired here:

    * the web endpoint is resolved through `Magus.Endpoint.endpoint/0`
      (`:magus, :endpoint`, default `MagusWeb.Endpoint`), so `magus_cloud` can
      serve `MagusCloudWeb.Endpoint`;
    * `:magus, :extra_children` (default `[]`) lets `magus_cloud` start billing
      supervisors before the endpoint without core naming them.
  """
  @spec child_specs() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def child_specs do
    base_children() ++
      instance_manager_children() ++
      extra_children() ++
      final_children()
  end

  # Core children that always run
  # USD->internal-cost-unit FX via the ExchangeRate seam. The core default
  # (Identity, 1:1) is processless and contributes no child; the billing
  # edition's hourly Stripe refresher (Magus.Billing.FxRates) is supervised
  # here without core naming it.
  defp base_children do
    [
      MagusWeb.Telemetry,
      Magus.Repo,
      # Initial DB -> LLMDB model catalog sync + serialized on-demand reloads
      Magus.Models.CatalogSync.Server,
      Magus.Cache
    ] ++
      Magus.Usage.ExchangeRate.child_specs() ++
      [
        # FalkorDB connection pool (Redis-protocol graph DB) - must start early
        # so anything depending on Magus.Graph has it available.
        Magus.Graph.Connection,
        {Magus.Graph.CircuitBreaker,
         name: Magus.Graph.CircuitBreaker,
         threshold: 10,
         reset_after: 30_000,
         disabled:
           Keyword.get(
             Application.get_env(:magus, Magus.Graph, []),
             :circuit_breaker_disabled,
             false
           )},
        Magus.Agents.Skills.Registry,
        # Integrations infrastructure
        Magus.Integrations.Vault,
        Magus.Integrations.RateLimiter,
        # MCP client process registry + dynamic supervisor
        Magus.MCP.Supervisor,
        # MCP registry discovery cache (browse the public server catalog)
        Magus.MCP.Registry,
        # Task supervisor for webhook async operations
        {Task.Supervisor, name: Magus.Integrations.WebhookTaskSupervisor},
        # General-purpose task supervisor for async operations (LiveView, components, changes)
        {Task.Supervisor, name: Magus.AgentLoopTaskSupervisor},
        # Task supervisor for knowledge sync operations
        {Task.Supervisor, name: Magus.Knowledge.SyncTaskSupervisor},
        # Reset collections stuck in :syncing after restart
        Magus.Knowledge.SyncRecovery,
        {DNSCluster, query: Application.get_env(:magus, :dns_cluster_query) || :ignore},
        {Oban,
         AshOban.config(
           Application.fetch_env!(:magus, :ash_domains),
           Application.fetch_env!(:magus, Oban)
         )},
        {Phoenix.PubSub, name: Magus.PubSub},
        Magus.Presence,
        # Jido instance for agent execution
        Magus.Jido
      ]
  end

  # Jido Agent InstanceManager - disabled in tests (agent processes can't access Ecto sandbox)
  defp instance_manager_children do
    instance_manager_config = Application.get_env(:magus, :jido_instance_manager, [])

    if instance_manager_config[:enabled] != false do
      store = instance_manager_config[:store] || {Magus.Agents.Persistence.PostgresStore, []}

      [
        # ConversationAgent InstanceManager - 5 minute idle timeout
        {Jido.Agent.InstanceManager,
         [
           name: :conversations,
           agent: Magus.Agents.ConversationAgent,
           idle_timeout: Application.get_env(:magus, :agent_idle_timeout, :timer.minutes(5)),
           storage: store,
           agent_opts: [jido: Magus.Jido, agent_module: Magus.Agents.ConversationAgent]
         ]}
      ]
    else
      []
    end
  end

  # Open-core composition seam: magus_cloud injects its billing supervisors here
  # (e.g. a Stripe webhook processor or seat-sync worker) without core naming
  # them. Empty in a pure-OSS install.
  defp extra_children, do: Application.get_env(:magus, :extra_children, [])

  # The web endpoint is resolved through the Magus.Endpoint facade so magus_cloud
  # can serve MagusCloudWeb.Endpoint via `config :magus, :endpoint`. Listed last
  # so it begins serving requests only after the rest of the tree is up.
  defp final_children do
    [
      Magus.Endpoint.endpoint(),
      {AshAuthentication.Supervisor, [otp_app: :magus]}
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def prep_stop(state) do
    Magus.Agents.GracefulShutdown.checkpoint_active_agents()
    state
  end

  @impl true
  def config_change(changed, _new, removed) do
    Magus.Endpoint.endpoint().config_change(changed, removed)
    :ok
  end
end
