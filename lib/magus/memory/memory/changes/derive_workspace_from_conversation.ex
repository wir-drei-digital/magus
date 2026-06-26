defmodule Magus.Memory.Memory.Changes.DeriveWorkspaceFromConversation do
  @moduledoc """
  On `:local` memory create, copies workspace_id from the parent conversation.

  Rejects the change if the caller passed a workspace_id that doesn't match
  the conversation's workspace_id.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      conversation_id = Ash.Changeset.get_argument(cs, :conversation_id)

      case load_conversation(conversation_id) do
        nil ->
          cs

        conv ->
          existing = Ash.Changeset.get_attribute(cs, :workspace_id)

          if not is_nil(existing) and existing != conv.workspace_id do
            Ash.Changeset.add_error(cs,
              field: :workspace_id,
              message: "must match the conversation's workspace_id"
            )
          else
            Ash.Changeset.force_change_attribute(cs, :workspace_id, conv.workspace_id)
          end
      end
    end)
  end

  defp load_conversation(nil), do: nil

  defp load_conversation(id) do
    case Magus.Chat.Conversation
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.select([:id, :workspace_id])
         |> Ash.read_one(authorize?: false) do
      {:ok, conv} -> conv
      _ -> nil
    end
  end
end
