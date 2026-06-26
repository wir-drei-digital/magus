defmodule Magus.Chat.Conversation.Changes.CreateThread do
  @moduledoc """
  Change module for the `create_thread` action.

  Loads the parent conversation and branch message, validates one-level nesting,
  copies settings from parent, and after creation copies accepted members.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    parent_id = Ash.Changeset.get_argument(changeset, :parent_conversation_id)
    message_id = Ash.Changeset.get_argument(changeset, :branched_at_message_id)
    actor = context.actor

    with {:parent, {:ok, parent}} <-
           {:parent, Ash.get(Magus.Chat.Conversation, parent_id, actor: actor, load: [:members])},
         :ok <- validate_not_nested_thread(parent),
         {:message, {:ok, message}} <-
           {:message, Ash.get(Magus.Chat.Message, message_id, actor: actor)},
         :ok <- validate_message_belongs_to_parent(message, parent) do
      changeset
      |> Ash.Changeset.force_change_attribute(:is_thread, true)
      |> Ash.Changeset.force_change_attribute(:parent_conversation_id, parent.id)
      |> Ash.Changeset.force_change_attribute(:branched_at_message_id, message.id)
      |> Ash.Changeset.force_change_attribute(:branched_at, message.inserted_at)
      |> copy_parent_config(parent)
      |> Ash.Changeset.after_action(fn _changeset, thread ->
        copy_members(thread, parent, actor)
        copy_workspace_grant(thread, parent)
        {:ok, thread}
      end)
    else
      {:parent, {:error, _}} ->
        Ash.Changeset.add_error(changeset,
          field: :parent_conversation_id,
          message: "parent conversation not found"
        )

      {:nested, message} ->
        Ash.Changeset.add_error(changeset,
          field: :parent_conversation_id,
          message: message
        )

      {:message, {:error, _}} ->
        Ash.Changeset.add_error(changeset,
          field: :branched_at_message_id,
          message: "branch point message not found"
        )

      {:error, msg} ->
        Ash.Changeset.add_error(changeset,
          field: :branched_at_message_id,
          message: msg
        )
    end
  end

  defp validate_not_nested_thread(parent) do
    if parent.is_thread do
      {:nested, "cannot create a thread within a thread"}
    else
      :ok
    end
  end

  defp validate_message_belongs_to_parent(message, parent) do
    if message.conversation_id == parent.id do
      :ok
    else
      {:error, "message does not belong to the parent conversation"}
    end
  end

  defp copy_parent_config(changeset, parent) do
    changeset
    |> Ash.Changeset.force_change_attribute(:chat_mode, parent.chat_mode)
    |> Ash.Changeset.force_change_attribute(:selected_model_id, parent.selected_model_id)
    |> Ash.Changeset.force_change_attribute(
      :selected_image_model_id,
      parent.selected_image_model_id
    )
    |> Ash.Changeset.force_change_attribute(
      :selected_video_model_id,
      parent.selected_video_model_id
    )
    |> Ash.Changeset.force_change_attribute(:system_prompt_id, parent.system_prompt_id)
    |> Ash.Changeset.force_change_attribute(:custom_agent_id, parent.custom_agent_id)
    |> Ash.Changeset.force_change_attribute(:sampling_settings, parent.sampling_settings)
    |> Ash.Changeset.force_change_attribute(:workspace_id, parent.workspace_id)
    |> Ash.Changeset.force_change_attribute(:is_multiplayer, parent.is_multiplayer)
    |> Ash.Changeset.force_change_attribute(:visibility, parent.visibility)
  end

  # Preserve the parent's workspace-level resource_accesses grant (if any) on
  # the new thread so that members who could see the parent can still see the
  # thread. Previously this was driven by copying `workspace_visibility`.
  defp copy_workspace_grant(thread, parent) do
    if parent.workspace_id do
      require Ash.Query

      parent_grant =
        Magus.Workspaces.ResourceAccess
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(
          resource_type == :conversation and
            resource_id == ^parent.id and
            grantee_type == :workspace and
            grantee_id == ^parent.workspace_id
        )
        |> Ash.read_one(authorize?: false)

      case parent_grant do
        {:ok, nil} ->
          :ok

        {:ok, grant} ->
          case Magus.Workspaces.ResourceAccess
               |> Ash.Changeset.for_create(:grant, %{
                 resource_type: :conversation,
                 resource_id: thread.id,
                 grantee_type: :workspace,
                 grantee_id: thread.workspace_id,
                 role: grant.role
               })
               |> Ash.create(authorize?: false) do
            {:ok, _} -> :ok
            {:error, %Ash.Error.Invalid{}} -> :ok
            {:error, err} -> Logger.warning("copy thread grant failed: #{inspect(err)}")
          end

        {:error, err} ->
          Logger.warning("copy thread grant read failed: #{inspect(err)}")
      end
    end
  end

  defp copy_members(thread, parent, actor) do
    if parent.is_multiplayer do
      ai_actor = %Magus.Agents.Support.AiAgent{}
      creator_id = if is_map(actor), do: Map.get(actor, :id), else: nil

      # Add thread creator as owner member
      if creator_id do
        case Magus.Chat.add_conversation_owner(thread.id, creator_id, actor: actor) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.warning("Failed to add owner to thread: #{inspect(reason)}")
        end
      end

      # Copy non-creator members as regular members
      accepted_members =
        parent.members
        |> Enum.filter(fn m -> m.accepted_at != nil end)
        |> Enum.reject(fn m -> m.user_id == creator_id end)

      Enum.each(accepted_members, fn member ->
        case Magus.Chat.add_conversation_member(thread.id, member.user_id, actor: ai_actor) do
          {:ok, cm} ->
            case Magus.Chat.accept_conversation_invitation(cm, actor: ai_actor) do
              {:ok, _} ->
                :ok

              {:error, reason} ->
                Logger.warning("Failed to accept member invitation: #{inspect(reason)}")
            end

          {:error, reason} ->
            Logger.warning(
              "Failed to copy member #{member.user_id} to thread: #{inspect(reason)}"
            )
        end
      end)
    end
  end
end
