defmodule Magus.Workspaces.BroadcastHelpers do
  @moduledoc """
  Shared helpers for emitting workspace pubsub events.

  Emits events to the creator's per-user topic always. Emits to the workspace
  topic only when the record has any workspace-level grant.
  """

  alias Phoenix.PubSub

  @pubsub Magus.PubSub

  def broadcast_user(topic_prefix, user_id, payload) do
    PubSub.broadcast(@pubsub, "#{topic_prefix}:#{user_id}", payload)
  end

  def broadcast_workspace(topic_suffix, workspace_id, payload) do
    PubSub.broadcast(@pubsub, "workspaces:#{workspace_id}:#{topic_suffix}", payload)
  end

  @doc """
  Returns true if the given resource has at least one workspace-level grant.
  """
  def workspace_grant?(resource_type, resource_id, workspace_id) do
    import Ash.Query

    Magus.Workspaces.ResourceAccess
    |> for_read(:read)
    |> filter(
      resource_type == ^resource_type and
        resource_id == ^resource_id and
        grantee_type == :workspace and
        grantee_id == ^workspace_id
    )
    |> Ash.exists?(authorize?: false)
  end
end
