defmodule Magus.Chat.ConversationCompanion.Validations.ActorOwnsConversation do
  @moduledoc """
  Ensures the actor creating a `ConversationCompanion` can read the supplied
  `conversation_id`. Prevents a malicious caller from linking another user's
  conversation as the companion target (which would also lock the legitimate
  owner out of creating their own link, since `conversation_id` is unique).

  Authorization is delegated to `Magus.Chat.get_conversation/2` which goes
  through the existing workspace-scoped policies.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, context) do
    case context.actor do
      %{id: _} = actor ->
        case Ash.Changeset.get_attribute(changeset, :conversation_id) do
          nil ->
            # Required-attribute validation will fail; nothing to verify here.
            :ok

          conversation_id ->
            case Magus.Chat.get_conversation(conversation_id, actor: actor) do
              {:ok, _conversation} -> :ok
              _ -> {:error, field: :conversation_id, message: "is not accessible"}
            end
        end

      _ ->
        {:error, field: :conversation_id, message: "actor is required"}
    end
  end
end
