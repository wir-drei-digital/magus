defmodule Magus.Files.File.Checks.ActorCanCreateConnectorFile do
  @moduledoc """
  Allows connector-backed file creation only when the actor manages the
  knowledge source behind the target collection. A connector file must always
  be tied to a collection; creating one without a collection is forbidden.
  """

  use Ash.Policy.SimpleCheck

  alias Magus.Checks.Helpers

  @impl true
  def describe(_opts) do
    "actor can create the target connector-backed file"
  end

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    collection_id =
      Ash.Changeset.get_argument(changeset, :knowledge_collection_id) ||
        Ash.Changeset.get_attribute(changeset, :knowledge_collection_id)

    actor_manages_collection?(actor, collection_id)
  end

  def match?(_actor, _context, _opts), do: false

  # Returns true when the actor directly owns the knowledge source behind a
  # collection, or is an admin of the source's workspace.
  defp actor_manages_collection?(_actor, nil), do: false

  defp actor_manages_collection?(actor, collection_id) do
    require Ash.Query

    Magus.Knowledge.KnowledgeCollection
    |> Ash.Query.filter(id == ^collection_id)
    |> Ash.Query.load(:knowledge_source)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{knowledge_source: %{user_id: user_id, workspace_id: workspace_id}}} ->
        user_id == actor.id ||
          Helpers.active_workspace_member?(workspace_id, actor.id, admin_only?: true)

      _ ->
        false
    end
  end
end
