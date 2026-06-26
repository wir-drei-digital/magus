defmodule Magus.Chat.Message.Changes.AssociateFilesWithConversation do
  @moduledoc """
  Associates attached files with the message's conversation.

  When files are uploaded before a conversation exists, they are created without
  a conversation_id. This change module runs after the conversation is created (or
  determined) and updates any files that don't have a conversation_id.

  This ensures all attached files are properly linked to the conversation for:
  - Organization in the Files sidebar
  - Context retrieval in future messages
  - Cleanup when conversation is deleted

  ## Arguments

  - `:files` - List of Files.File structs to associate
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, message ->
      files = Ash.Changeset.get_argument(changeset, :resources) || []
      conversation_id = message.conversation_id

      # Update files that don't have a conversation_id
      files
      |> Enum.filter(&is_nil(&1.conversation_id))
      |> Enum.each(fn file ->
        Magus.Files.move_file_to_context(file, %{conversation_id: conversation_id},
          authorize?: false
        )
      end)

      {:ok, message}
    end)
  end
end
