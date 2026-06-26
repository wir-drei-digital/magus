defmodule Magus.Chat.Folder.Changes.CascadeShareToChildren do
  @moduledoc """
  `after_action` change that cascades a folder share to its direct child
  conversations and recursively to its sub-folders. The recursive call to
  `Magus.Chat.share_folder_to_team` re-enters this change for each sub-folder.

  Children the actor lacks permission to share are skipped silently; other
  errors are logged. Files are intentionally NOT cascaded — they have no
  per-resource share action and are governed by their own workspace_id +
  policies.
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
      |> Enum.each(&cascade_share_conversation(&1, actor))

      Magus.Chat.Folder
      |> Ash.Query.filter(parent_id == ^folder.id and workspace_id == ^folder.workspace_id)
      |> Ash.read!(authorize?: false)
      |> Enum.each(&cascade_share_folder(&1, actor))

      {:ok, folder}
    end)
  end

  defp cascade_share_conversation(conv, actor) do
    case Magus.Chat.share_conversation_to_team(conv, actor: actor) do
      {:ok, _} -> :ok
      {:error, %Ash.Error.Forbidden{}} -> :ok
      {:error, err} -> warn(:conversation, conv.id, err)
    end
  end

  defp cascade_share_folder(sub, actor) do
    case Magus.Chat.share_folder_to_team(sub, actor: actor) do
      {:ok, _} -> :ok
      {:error, %Ash.Error.Forbidden{}} -> :ok
      {:error, err} -> warn(:folder, sub.id, err)
    end
  end

  defp warn(kind, id, err) do
    Logger.warning("CascadeShareToChildren: failed to share #{kind} #{id}: #{inspect(err)}")
  end
end
