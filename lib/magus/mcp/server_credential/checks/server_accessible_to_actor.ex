defmodule Magus.MCP.ServerCredential.Checks.ServerAccessibleToActor do
  @moduledoc "Allows creating a credential only for a server the actor can access."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor has read access to the referenced MCP server"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    server_id =
      Ash.Changeset.get_attribute(changeset, :mcp_server_id) ||
        Ash.Changeset.get_argument(changeset, :mcp_server_id)

    case server_id && Magus.MCP.get_server(server_id, actor: actor) do
      {:ok, %Magus.MCP.Server{}} -> true
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
