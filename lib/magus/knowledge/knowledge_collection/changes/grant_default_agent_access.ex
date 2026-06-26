defmodule Magus.Knowledge.KnowledgeCollection.Changes.GrantDefaultAgentAccess do
  @moduledoc """
  After a KnowledgeCollection is created, automatically grants access to
  the source owner's default custom agent (if one exists).

  This ensures all knowledge connectors are enabled for the default agent
  without requiring manual configuration.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, collection ->
      grant_to_default_agent(collection)
      {:ok, collection}
    end)
  end

  defp grant_to_default_agent(collection) do
    collection = Ash.load!(collection, [knowledge_source: [:user]], authorize?: false)
    user = collection.knowledge_source.user

    case Magus.Agents.get_default_agent(actor: user) do
      {:ok, agent} ->
        case Magus.Workspaces.grant_access(
               %{
                 resource_type: :knowledge_collection,
                 resource_id: collection.id,
                 grantee_type: :custom_agent,
                 grantee_id: agent.id,
                 role: :editor
               },
               actor: user
             ) do
          {:ok, _} ->
            Logger.info("Auto-granted collection #{collection.id} to default agent #{agent.id}")

          {:error, reason} ->
            Logger.warning(
              "Failed to auto-grant collection #{collection.id} to default agent: #{inspect(reason)}"
            )
        end

      {:error, _} ->
        # No default agent — nothing to grant
        :ok
    end
  end
end
