defmodule Magus.Files.File.Validations.ActorCanAccessContext do
  @moduledoc """
  Ensures that user-facing file actions only attach files to contexts the actor
  can legitimately use.
  """

  use Ash.Resource.Validation

  alias Magus.Checks.Helpers

  @impl true
  def validate(changeset, _opts, context) do
    case context.actor do
      %Magus.Agents.Support.AiAgent{} ->
        :ok

      %{id: actor_id} = actor ->
        with :ok <- validate_workspace(changeset, actor_id),
             :ok <- validate_folder(changeset, actor),
             :ok <- validate_conversation(changeset, actor),
             :ok <- validate_workspace_match(changeset, actor) do
          :ok
        end

      _ ->
        {:error, field: :user_id, message: "actor is required"}
    end
  end

  defp validate_workspace(changeset, actor_id) do
    case Ash.Changeset.get_attribute(changeset, :workspace_id) do
      nil ->
        :ok

      workspace_id ->
        if Helpers.active_workspace_member?(workspace_id, actor_id) do
          :ok
        else
          {:error,
           field: :workspace_id, message: "must be an active workspace the actor belongs to"}
        end
    end
  end

  defp validate_folder(changeset, actor) do
    case Ash.Changeset.get_attribute(changeset, :folder_id) do
      nil ->
        :ok

      folder_id ->
        case Magus.Chat.get_folder(folder_id, actor: actor) do
          {:ok, folder} when folder.user_id == actor.id -> :ok
          _ -> {:error, field: :folder_id, message: "must be a folder the actor owns"}
        end
    end
  end

  defp validate_conversation(changeset, actor) do
    case Ash.Changeset.get_attribute(changeset, :conversation_id) do
      nil ->
        :ok

      conversation_id ->
        if Magus.Chat.Checks.ActorCanWriteConversation.can_write?(actor, conversation_id) do
          :ok
        else
          {:error,
           field: :conversation_id, message: "must be a conversation the actor can write to"}
        end
    end
  end

  defp validate_workspace_match(changeset, actor) do
    workspace_id = Ash.Changeset.get_attribute(changeset, :workspace_id)
    conversation_id = Ash.Changeset.get_attribute(changeset, :conversation_id)

    if is_nil(workspace_id) || is_nil(conversation_id) do
      :ok
    else
      case Magus.Chat.get_conversation(conversation_id, actor: actor) do
        {:ok, conversation} when conversation.workspace_id == workspace_id ->
          :ok

        {:ok, _conversation} ->
          {:error, field: :workspace_id, message: "must match the workspace of the conversation"}

        {:error, _} ->
          {:error,
           field: :conversation_id, message: "must be a conversation the actor can access"}
      end
    end
  end
end
