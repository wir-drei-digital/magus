defmodule Magus.Chat.Folder.Changes.CascadeUnshareFromChildren do
  @moduledoc """
  `after_action` change that cascades a folder unshare to its direct child
  conversations and recursively to its sub-folders. The recursive call to
  `Magus.Chat.unshare_folder_from_team` re-enters this change for each
  sub-folder.

  Children the actor lacks permission to unshare are skipped silently; other
  errors are logged.

  Trade-off: a child that was previously shared independently (i.e. directly,
  not via the parent cascade) will also be unshared. This matches the
  folder-level mental model ("everything in this folder is private now") but
  loses provenance. To preserve direct shares, `ResourceAccess` would need an
  origin column.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, _opts, context) do
    actor = context.actor

    Ash.Changeset.after_action(changeset, fn _cs, folder ->
      require Ash.Query

      Magus.Chat.Conversation
      |> Ash.Query.filter(folder_id == ^folder.id and is_nil(deleted_at))
      |> Ash.read!(authorize?: false)
      |> Enum.each(&cascade_unshare_conversation(&1, actor))

      Magus.Chat.Folder
      |> Ash.Query.filter(parent_id == ^folder.id and workspace_id == ^folder.workspace_id)
      |> Ash.read!(authorize?: false)
      |> Enum.each(&cascade_unshare_folder(&1, actor))

      {:ok, folder}
    end)
  end

  defp cascade_unshare_conversation(conv, actor) do
    case Magus.Chat.unshare_conversation_from_team(conv, actor: actor) do
      {:ok, _} -> :ok
      {:error, %Ash.Error.Forbidden{}} -> :ok
      {:error, err} -> warn(:conversation, conv.id, err)
    end
  end

  defp cascade_unshare_folder(sub, actor) do
    case Magus.Chat.unshare_folder_from_team(sub, actor: actor) do
      {:ok, _} -> :ok
      {:error, %Ash.Error.Forbidden{}} -> :ok
      {:error, err} -> warn(:folder, sub.id, err)
    end
  end

  defp warn(kind, id, err) do
    Logger.warning("CascadeUnshareFromChildren: failed to unshare #{kind} #{id}: #{inspect(err)}")
  end
end
