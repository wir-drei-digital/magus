defmodule Magus.Chat.Folder.Changes.SyncWorkspaceShareWithFolder do
  @moduledoc """
  `after_action` change that aligns a record's `:workspace` grant with its
  new container folder's share state, so that moving an item into a shared
  folder doesn't leave the chat-mode nav with an orphaned row (folder in
  Shared section, contents in Personal section).

  - Target container is shared → idempotently share the record.
  - Target container is unshared → idempotently unshare the record.
  - Target is nil (root / unfiled) → preserve current share state.

  The "preserve on root" rule is intentional: a record that was deliberately
  shared and is later moved out of any folder still has a valid place in the
  workspace nav (Shared > unfiled), and stripping its grant would surprise
  the user.

  The share/unshare action names are passed via opts so the same change can
  serve both `Conversation.move_to_folder` (container is `:folder_id`) and
  `Folder.move_to_folder` (container is `:parent_id`).

      change {Magus.Chat.Folder.Changes.SyncWorkspaceShareWithFolder,
              container_field: :folder_id,
              share_action: :share_to_team,
              unshare_action: :unshare_from_team}
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, context) do
    container_field = Keyword.get(opts, :container_field, :folder_id)
    share_action = Keyword.fetch!(opts, :share_action)
    unshare_action = Keyword.fetch!(opts, :unshare_action)
    actor = context.actor

    Ash.Changeset.after_action(changeset, fn _cs, record ->
      container_id = Map.get(record, container_field)
      sync(record, container_id, share_action, unshare_action, actor)
      {:ok, record}
    end)
  end

  defp sync(_record, nil, _share, _unshare, _actor), do: :ok

  defp sync(record, container_id, share, unshare, actor) do
    case Magus.Chat.get_folder(container_id, actor: actor) do
      {:ok, container} ->
        container = Ash.load!(container, :is_shared_to_workspace, actor: actor)

        if Map.get(container, :is_shared_to_workspace, false) do
          run(record, share, actor)
        else
          run(record, unshare, actor)
        end

      _ ->
        :ok
    end
  end

  defp run(record, action, actor) do
    case Ash.update(record, action: action, actor: actor) do
      {:ok, _} ->
        :ok

      {:error, %Ash.Error.Invalid{} = err} ->
        # Most common: action validates workspace_id presence and the record
        # has none (personal record outside any workspace) — nothing to sync.
        if missing_workspace_id?(err) do
          :ok
        else
          warn(record, action, err)
        end

      {:error, %Ash.Error.Forbidden{}} ->
        :ok

      {:error, err} ->
        warn(record, action, err)
    end
  end

  defp missing_workspace_id?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %{field: :workspace_id} -> true
      _ -> false
    end)
  end

  defp missing_workspace_id?(_), do: false

  defp warn(record, action, err) do
    Logger.warning(
      "SyncWorkspaceShareWithFolder: #{action} failed for #{inspect(record.__struct__)} #{record.id}: #{inspect(err)}"
    )
  end
end
