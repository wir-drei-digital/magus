defmodule Magus.Sandbox.Provider do
  @moduledoc """
  Behaviour for sandbox providers (Sprites, Daytona).

  Defines the generic primitives that all sandbox providers must implement:
  lifecycle management, command execution, file operations, checkpointing,
  and HTTP proxying.

  Provider-specific concepts (pip_install, service management, network policy
  details) stay in the Orchestrator or individual provider modules.

  ## Open-core capability seam

  The active provider is config-swapped via `:magus, Magus.Sandbox` `:provider`
  and resolves to a client module through `client/0` / `client_for/1`.
  `configured?/0` reports whether the active provider has working credentials,
  letting agent tool registration gate the sandbox tools off on a self-host
  instance with no provider key (mirroring `Magus.Capabilities.Search`/`Crawl`).

  ## Dynamic dispatch

  Ash changes use `apply(client, :function, [args])` instead of `client.function(args)`
  to avoid compile-time warnings about modules that may not yet be compiled.
  This is intentional — the trade-off is that dialyzer and IDE navigation won't
  trace through these calls, but it avoids false compilation warnings with
  `--warnings-as-errors`.
  """

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type sandbox_info :: %{sandbox_id: String.t(), url: String.t() | nil}
  @type exec_result :: %{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: integer(),
          duration_ms: non_neg_integer()
        }
  @type proxy_response :: %{
          status: integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  # ---------------------------------------------------------------------------
  # Required callbacks (all providers must implement)
  # ---------------------------------------------------------------------------

  # Lifecycle
  @callback configured?() :: boolean()
  @callback create_sandbox(opts :: keyword()) :: {:ok, sandbox_info()} | {:error, term()}
  @callback destroy(sandbox_id :: String.t()) :: :ok | {:error, term()}
  @callback get_sandbox(sandbox_id :: String.t()) :: {:ok, map()} | {:error, term()}

  # Execution
  @callback exec(sandbox_id :: String.t(), command :: String.t(), opts :: keyword()) ::
              {:ok, exec_result()} | {:error, term()}

  # File operations
  @callback read_file(sandbox_id :: String.t(), path :: String.t()) ::
              {:ok, binary()} | {:error, term()}
  @callback write_file(sandbox_id :: String.t(), path :: String.t(), content :: binary()) ::
              :ok | {:error, term()}
  @callback list_files(sandbox_id :: String.t(), path :: String.t()) ::
              {:ok, list(map())} | {:error, term()}
  @callback ensure_directory(sandbox_id :: String.t(), path :: String.t()) ::
              :ok | {:error, term()}
  @callback reset(sandbox_id :: String.t(), path :: String.t()) ::
              :ok | {:error, term()}

  # Suspend / Resume
  # checkpoint/1 returns {:ok, checkpoint_id} when provider snapshots state,
  # or :ok when provider handles suspend without a checkpoint (e.g. auto-hibernate).
  @callback checkpoint(sandbox_id :: String.t()) :: :ok | {:ok, String.t()} | {:error, term()}
  @callback restore(sandbox_id :: String.t(), checkpoint_id :: String.t() | nil) ::
              {:ok, map()} | {:error, term()}

  # Proxy — structured HTTP request/response
  # request = %{method: String, path: String, headers: [{name, value}], body: binary}
  @callback proxy_request(sandbox_id :: String.t(), port :: integer(), request :: map()) ::
              {:ok, proxy_response()} | {:error, term()}

  # Service management (create_service, start_service, stop_service) is
  # intentionally NOT part of this behaviour. Each provider handles services
  # differently — Sprites uses its sprite-env CLI, Daytona runs them in a
  # persistent session via exec. The Orchestrator dispatches based on the
  # sandbox's provider field in do_start_service/do_stop_service.

  @doc """
  Returns the currently configured provider atom (`:sprites`, `:daytona`, or `:test`).
  """
  def active_provider do
    Application.get_env(:magus, Magus.Sandbox)[:provider] || :sprites
  end

  @doc """
  Returns the client module for the active provider.
  """
  def client do
    case active_provider() do
      :test -> Magus.Sandbox.Clients.Test
      :daytona -> Magus.Sandbox.Clients.Daytona
      _ -> Magus.Sandbox.Clients.Sprites
    end
  end

  @doc """
  Returns the client module for a specific sandbox record.

  Uses the sandbox's stored `provider` field so existing sandboxes
  keep working even when the global config changes. Legacy/unknown provider
  values (e.g. removed adapters) fall back to Sprites rather than crashing.
  """
  def client_for(%{provider: :test}), do: Magus.Sandbox.Clients.Test
  def client_for(%{provider: :daytona}), do: Magus.Sandbox.Clients.Daytona
  def client_for(_), do: Magus.Sandbox.Clients.Sprites

  @doc """
  Whether the active sandbox provider has working credentials.

  Lets agent tool registration drop the sandbox tools on a self-host instance
  that has not configured a Daytona/Sprites key, so the agent never offers a
  tool it cannot run. The `:test` provider reports `false`.
  """
  @spec configured?() :: boolean()
  def configured?, do: client().configured?()
end
