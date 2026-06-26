defmodule Magus.Chat.Message.Checks.CanCreateInConversation do
  @moduledoc """
  Policy check that verifies the actor can create messages in the target conversation.

  Allows message creation if:
  - The actor owns the conversation
  - The actor is an accepted member of the conversation with role :owner or :member
  - The actor has a workspace grant on the conversation (:viewer or higher)
  - No conversation_id is provided (a new conversation will be created for the actor)

  Observers (role :observer) are not allowed to send messages.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor can create messages in the conversation (not observer)"
  end

  @impl true
  def match?(nil, _authorizer, _context), do: false

  def match?(actor, %{changeset: changeset}, _context) do
    conversation_id =
      Ash.Changeset.get_argument(changeset, :conversation_id) ||
        Ash.Changeset.get_attribute(changeset, :conversation_id)

    # If no conversation_id, a new one will be created for the actor
    if is_nil(conversation_id) do
      true
    else
      require Ash.Query

      # Check if actor owns the conversation
      case Magus.Chat.get_conversation(conversation_id, actor: actor) do
        {:error, _} ->
          false

        {:ok, conversation} ->
          if conversation.user_id == actor.id do
            # Conversation owner can always send
            true
          else
            # For members, check role — observers cannot send
            members =
              Magus.Chat.ConversationMember
              |> Ash.Query.filter(
                conversation_id == ^conversation_id and
                  user_id == ^actor.id and
                  not is_nil(accepted_at)
              )
              |> Ash.read!(authorize?: false)

            case members do
              [%{role: :observer}] ->
                false

              [_member] ->
                true

              [] ->
                Magus.Workspaces.AccessCheck.has_access?(
                  :conversation,
                  conversation_id,
                  actor,
                  :viewer
                )

              _ ->
                false
            end
          end
      end
    end
  end

  # Fallback for any other pattern
  def match?(_actor, _authorizer, _context), do: false
end
