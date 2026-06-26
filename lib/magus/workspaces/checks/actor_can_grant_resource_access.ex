defmodule Magus.Workspaces.Checks.ActorCanGrantResourceAccess do
  @moduledoc """
  Authorizes grant/revoke/update_role actions on ResourceAccess.

  Authorized if the actor is:
    * creator (`user_id`) of the target resource, OR
    * a workspace admin on the resource's workspace, OR
    * holds a `:owner` grant on the resource.
  """
  use Ash.Policy.SimpleCheck

  alias Magus.Workspaces.AccessCheck

  @impl true
  def describe(_opts), do: "actor can grant/revoke access on the target resource"

  @impl true
  def match?(nil, _ctx, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    resource_type =
      Ash.Changeset.get_attribute(changeset, :resource_type) ||
        Ash.Changeset.get_argument(changeset, :resource_type)

    resource_id =
      Ash.Changeset.get_attribute(changeset, :resource_id) ||
        Ash.Changeset.get_argument(changeset, :resource_id)

    check(actor, resource_type, resource_id)
  end

  def match?(actor, %{subject: %Ash.Changeset{} = cs}, opts),
    do: match?(actor, %{changeset: cs}, opts)

  def match?(actor, %{subject: %Ash.Query{} = query}, _opts) do
    resource_type = Ash.Query.get_argument(query, :resource_type)
    resource_id = Ash.Query.get_argument(query, :resource_id)
    check(actor, resource_type, resource_id)
  end

  def match?(_actor, _ctx, _opts), do: false

  defp check(_actor, nil, _), do: false
  defp check(_actor, _, nil), do: false

  defp check(actor, resource_type, resource_id) do
    creator_or_admin?(actor, resource_type, resource_id) ||
      AccessCheck.has_access?(resource_type, resource_id, actor, :owner)
  end

  defp creator_or_admin?(actor, :knowledge_collection, resource_id) do
    case fetch_knowledge_collection(resource_id) do
      nil ->
        false

      %{knowledge_source: source} ->
        source.user_id == actor.id ||
          (source.workspace_id != nil &&
             Magus.Checks.Helpers.active_workspace_member?(
               source.workspace_id,
               actor.id,
               admin_only?: true
             ))
    end
  end

  defp creator_or_admin?(actor, resource_type, resource_id) do
    case fetch_resource(resource_type, resource_id) do
      nil ->
        false

      record ->
        creator_id = Map.get(record, :user_id)
        workspace_id = Map.get(record, :workspace_id)

        creator_id == actor.id ||
          (workspace_id != nil &&
             Magus.Checks.Helpers.active_workspace_member?(
               workspace_id,
               actor.id,
               admin_only?: true
             ))
    end
  end

  defp fetch_resource(:folder, id),
    do: Magus.Chat.Folder |> Ash.get(id, authorize?: false) |> ok()

  defp fetch_resource(:file, id),
    do: Magus.Files.File |> Ash.get(id, authorize?: false) |> ok()

  defp fetch_resource(:conversation, id),
    do: Magus.Chat.Conversation |> Ash.get(id, authorize?: false) |> ok()

  defp fetch_resource(:prompt, id),
    do: Magus.Library.Prompt |> Ash.get(id, authorize?: false) |> ok()

  defp fetch_resource(:custom_agent, id),
    do: Magus.Agents.CustomAgent |> Ash.get(id, authorize?: false) |> ok()

  defp fetch_resource(:brain, id),
    do: Magus.Brain.BrainResource |> Ash.get(id, authorize?: false) |> ok()

  defp fetch_resource(:mcp_server, id),
    do: Magus.MCP.Server |> Ash.get(id, authorize?: false) |> ok()

  defp fetch_resource(_, _), do: nil

  defp fetch_knowledge_collection(id) do
    Magus.Knowledge.KnowledgeCollection
    |> Ash.get(id, load: [:knowledge_source], authorize?: false)
    |> ok()
  end

  defp ok({:ok, record}), do: record
  defp ok(_), do: nil
end
