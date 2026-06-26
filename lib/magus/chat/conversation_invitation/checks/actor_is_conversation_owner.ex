defmodule Magus.Chat.ConversationInvitation.Checks.ActorIsConversationOwner do
  @moduledoc """
  Checks if the actor is an owner of the conversation being invited to.
  Used for create actions where we can't use relationship-based filters.
  """
  use Ash.Policy.SimpleCheck

  require Ash.Query

  @impl true
  def describe(_opts) do
    "actor is owner of the conversation"
  end

  @impl true
  def match?(actor, %{changeset: changeset}, _opts) when not is_nil(actor) do
    conversation_id = Ash.Changeset.get_argument(changeset, :conversation_id)

    if conversation_id do
      # Check if the actor is an owner of this conversation
      case Magus.Chat.ConversationMember
           |> Ash.Query.filter(
             conversation_id == ^conversation_id and user_id == ^actor.id and role == :owner
           )
           |> Ash.read_one(authorize?: false) do
        {:ok, nil} -> false
        {:ok, _member} -> true
        {:error, _} -> false
      end
    else
      false
    end
  end

  def match?(_, _, _), do: false
end
