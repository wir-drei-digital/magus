defmodule Magus.Library.Prompt.Changes.CreateFromConversation do
  @moduledoc """
  Ash change module for creating a prompt from conversation patterns.

  Loads conversation messages, analyzes them with AI to extract patterns,
  and creates a reusable prompt from the analysis.
  """
  use Ash.Resource.Change

  alias Magus.Agents.Actions.GeneratePromptFromConversation

  @impl true
  def change(changeset, _opts, _context) do
    conversation_id = Ash.Changeset.get_argument(changeset, :conversation_id)
    name_override = Ash.Changeset.get_argument(changeset, :name)
    content_override = Ash.Changeset.get_argument(changeset, :content)
    type_override = Ash.Changeset.get_argument(changeset, :type)

    # Load conversation messages
    messages = load_messages(conversation_id)

    if Enum.empty?(messages) do
      Ash.Changeset.add_error(changeset,
        field: :conversation_id,
        message: "No messages found in conversation"
      )
    else
      # Get user_id from the changeset (set by relate_actor)
      user_id = Ash.Changeset.get_attribute(changeset, :user_id)

      # Generate prompt from conversation
      case GeneratePromptFromConversation.run(
             %{messages: messages, user_id: user_id, conversation_id: conversation_id},
             %{}
           ) do
        {:ok, result} ->
          changeset
          |> Ash.Changeset.change_attribute(:content, content_override || result.content)
          |> Ash.Changeset.change_attribute(:name, name_override || result.suggested_name)
          |> Ash.Changeset.change_attribute(:type, type_override || result.suggested_type)

        {:error, _} ->
          Ash.Changeset.add_error(changeset,
            field: :content,
            message: "Failed to generate prompt from conversation"
          )
      end
    end
  end

  defp load_messages(conversation_id) do
    require Ash.Query

    Magus.Chat.Message
    |> Ash.Query.filter(conversation_id == ^conversation_id)
    |> Ash.Query.filter(disabled != true)
    |> Ash.Query.filter(message_type == :message)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(50)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn msg ->
      %{source: msg.source, text: msg.text}
    end)
  end
end
