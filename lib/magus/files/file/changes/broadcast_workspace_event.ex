defmodule Magus.Files.File.Changes.BroadcastWorkspaceEvent do
  @moduledoc """
  Broadcasts a workspace-scoped PubSub event when a file belongs to a workspace.

  Topic format: workspaces:{workspace_id}:files

  This change handles all three action types:
  - :create / :update: broadcasts after_action
  - :destroy: captures workspace_id before deletion, broadcasts after_action

  Uses Magus.Endpoint.broadcast/3 to match Ash-notifier shape with
  Phoenix.Socket.Broadcast wrapping for consistency with Prompt and CustomAgent.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    action_type = changeset.action.type

    case action_type do
      :destroy ->
        workspace_id = changeset.data.workspace_id
        file_id = changeset.data.id

        if workspace_id do
          Ash.Changeset.after_action(changeset, fn _changeset, result ->
            broadcast(
              "workspaces:#{workspace_id}:files",
              "destroy",
              %{
                id: file_id,
                workspace_id: workspace_id,
                action: :deleted
              }
            )

            {:ok, result}
          end)
        else
          changeset
        end

      type when type in [:create, :update] ->
        event_name = if type == :create, do: "create", else: "update"
        action_label = if type == :create, do: :created, else: :updated

        Ash.Changeset.after_action(changeset, fn _changeset, file ->
          if file.workspace_id do
            broadcast(
              "workspaces:#{file.workspace_id}:files",
              event_name,
              %{
                id: file.id,
                workspace_id: file.workspace_id,
                action: action_label
              }
            )
          end

          {:ok, file}
        end)

      _ ->
        changeset
    end
  end

  defp broadcast(topic, event_name, payload) do
    Magus.Endpoint.broadcast(topic, event_name, payload)
  end
end
