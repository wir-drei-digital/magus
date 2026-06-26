defmodule Magus.Library.Prompt.Changes.CreateFromMessage do
  @moduledoc """
  Ash change module for creating a prompt from a single message.

  Loads the message by ID, uses its text as prompt content,
  and generates a title if not provided.
  """
  use Ash.Resource.Change

  alias Magus.Agents.Actions.GenerateTitle

  @impl true
  def change(changeset, _opts, _context) do
    message_id = Ash.Changeset.get_argument(changeset, :message_id)
    name_override = Ash.Changeset.get_argument(changeset, :name)
    content_override = Ash.Changeset.get_argument(changeset, :content)
    type = Ash.Changeset.get_argument(changeset, :type)

    case Magus.Chat.get_message(message_id, authorize?: false) do
      {:ok, message} ->
        # Use content override if provided, otherwise use message text
        content = content_override || message.text
        # Generate name if not provided
        name = name_override || generate_name(message)

        changeset
        |> Ash.Changeset.change_attribute(:content, content)
        |> Ash.Changeset.change_attribute(:name, name)
        |> Ash.Changeset.change_attribute(:type, type)

      {:error, _} ->
        Ash.Changeset.add_error(changeset, field: :message_id, message: "Message not found")
    end
  end

  defp generate_name(message) do
    case GenerateTitle.run(
           %{
             messages: [%{source: message.source, text: message.text}],
             user_id: message.created_by_id,
             conversation_id: message.conversation_id
           },
           %{}
         ) do
      {:ok, %{text: title}} -> String.slice(title, 0, 100)
      _ -> "New Prompt"
    end
  end
end
