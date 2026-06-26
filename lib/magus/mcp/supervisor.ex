defmodule Magus.MCP.Supervisor do
  @moduledoc """
  Hosts the registry and dynamic supervisor for per-server `anubis_mcp` clients,
  plus a `Task.Supervisor` for the executor's timeout-bounded tool calls.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Magus.MCP.ClientRegistry},
      {DynamicSupervisor, name: Magus.MCP.ClientDynamicSupervisor, strategy: :one_for_one},
      # Unlinked tasks for `Magus.MCP.Executor`'s timeout-bounded tool calls, so
      # a crashed anubis client surfaces as `{:exit, reason}` to `Task.yield`
      # rather than killing the caller through a link.
      {Task.Supervisor, name: Magus.MCP.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
