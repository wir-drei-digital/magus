defmodule Magus.Chat.Reactors.DeleteConversation do
  @moduledoc """
  Orchestrates the full deletion of a conversation.

  Delegates to the :delete_full_conversation action which handles external
  resource cleanup (file storage, sandbox sprites) before DB cascade
  deletes all related records.

  ## Usage

      Reactor.run(Magus.Chat.Reactors.DeleteConversation, %{
        conversation_id: conversation.id,
        actor: current_user
      })

  ## Inputs

  - `conversation_id` - UUID of the conversation to delete
  - `actor` - The user performing the deletion (for authorization)

  ## Returns

      {:ok, :deleted}
  """

  use Ash.Reactor

  input :conversation_id
  input :actor

  read_one :conversation, Magus.Chat.Conversation, :read do
    inputs %{id: input(:conversation_id)}
    actor input(:actor)
    fail_on_not_found? true
  end

  destroy :delete_conversation, Magus.Chat.Conversation, :delete_full_conversation do
    initial result(:conversation)
    actor input(:actor)
    undo :never
  end

  step :finalize do
    argument :deleted, result(:delete_conversation)

    run fn _args, _context ->
      {:ok, :deleted}
    end
  end

  return :finalize
end
