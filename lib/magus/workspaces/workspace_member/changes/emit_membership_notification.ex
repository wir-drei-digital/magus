defmodule Magus.Workspaces.WorkspaceMember.Changes.EmitMembershipNotification do
  @moduledoc """
  Emits an in-app notification to the target member on workspace membership
  lifecycle events. Configure via `kind` option in the `change` declaration.

  Only fires when the member has a resolved user_id (invited-but-unregistered
  members have nothing to notify in-app yet; they rely on email).
  """
  use Ash.Resource.Change

  require Logger

  @valid_kinds [
    :workspace_invite,
    :workspace_role_changed,
    :workspace_removed,
    :workspace_ownership_transferred
  ]

  @impl true
  def init(opts) do
    kind = Keyword.fetch!(opts, :kind)

    unless kind in @valid_kinds do
      raise ArgumentError,
            "invalid kind #{inspect(kind)}. Must be one of #{inspect(@valid_kinds)}"
    end

    {:ok, opts}
  end

  @impl true
  def change(changeset, opts, _context) do
    kind = Keyword.fetch!(opts, :kind)

    Ash.Changeset.after_action(changeset, fn _changeset, member ->
      if member.user_id do
        emit(kind, member)
      end

      {:ok, member}
    end)
  end

  @doc """
  Public so TransferOwnership can emit directly without a changeset context.
  """
  def emit(kind, member) when kind in @valid_kinds and not is_nil(member.user_id) do
    workspace =
      case Ash.load(member, :workspace, authorize?: false) do
        {:ok, loaded} -> loaded.workspace
        _ -> nil
      end

    workspace_name = if workspace, do: workspace.name, else: "a workspace"

    attrs = %{
      user_id: member.user_id,
      notification_type: kind,
      title: notification_title(kind, workspace_name),
      body: notification_body(kind, workspace_name)
    }

    case Magus.Notifications.Notification
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "EmitMembershipNotification(#{kind}) failed for user #{member.user_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  def emit(_kind, _member), do: :ok

  defp notification_title(:workspace_invite, ws), do: "You were invited to #{ws}"
  defp notification_title(:workspace_role_changed, ws), do: "Your role in #{ws} changed"
  defp notification_title(:workspace_removed, ws), do: "You were removed from #{ws}"

  defp notification_title(:workspace_ownership_transferred, ws),
    do: "You are now the owner of #{ws}"

  defp notification_body(:workspace_invite, ws), do: "Check your invitations to join #{ws}."

  defp notification_body(:workspace_role_changed, ws),
    do: "An owner updated your role in #{ws}."

  defp notification_body(:workspace_removed, ws),
    do: "You no longer have access to #{ws}."

  defp notification_body(:workspace_ownership_transferred, ws),
    do: "You now have full control of #{ws}."
end
