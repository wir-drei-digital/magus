defmodule Magus.MCP.Server.Checks.ActorCanReadServer do
  @moduledoc """
  Authorizes the generic `:discover` action: allows it only when the actor can
  read the server identified by the `mcp_server_id` action argument. The action
  carries an `Ash.ActionInput` (not a changeset or query), so we resolve the
  server by re-running the actor-scoped `:read` through the domain.

  This is the first-line gate; `Magus.MCP.Discovery.discover_and_cache/2` then
  re-loads the server actor-scoped, so access is enforced again in depth.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor can read the referenced MCP server"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{action_input: %Ash.ActionInput{} = input}, _opts) do
    server_id = Ash.ActionInput.get_argument(input, :mcp_server_id)

    # Avoid pattern-matching the `%Magus.MCP.Server{}` struct literal here: that
    # would create a compile-time dependency back to the resource that uses this
    # check, deadlocking compilation. A successful actor-scoped read is enough.
    case server_id && Magus.MCP.get_server(server_id, actor: actor) do
      {:ok, record} when is_struct(record) -> true
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
