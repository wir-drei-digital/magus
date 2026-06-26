defmodule Magus.Chat.Checks.ActorCanWriteConversation do
  @moduledoc """
  Verifies that the actor can write to the target conversation.

  Conversation owners can always write. Accepted members can write unless they
  only have the observer role.
  """

  use Ash.Policy.SimpleCheck

  require Ash.Query

  alias Magus.Chat.ConversationMember
  alias Magus.Checks.Helpers

  @impl true
  def describe(_opts), do: "actor can write to the target conversation"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    field = Keyword.get(opts, :field, :conversation_id)
    allow_nil? = Keyword.get(opts, :allow_nil?, false)

    case Helpers.value_from_context(context, field) do
      nil -> allow_nil?
      conversation_id -> can_write?(actor, conversation_id)
    end
  end

  def can_write?(%{id: actor_id} = actor, conversation_id) when not is_nil(conversation_id) do
    case Magus.Chat.get_conversation(conversation_id, actor: actor) do
      {:ok, %{user_id: ^actor_id}} ->
        true

      {:ok, _conversation} ->
        member_can_write?(conversation_id, actor_id)

      {:error, _} ->
        false
    end
  end

  def can_write?(_actor, _conversation_id), do: false

  defp member_can_write?(conversation_id, actor_id) do
    ConversationMember
    |> Ash.Query.filter(
      conversation_id == ^conversation_id and
        user_id == ^actor_id and
        not is_nil(accepted_at) and
        role != :observer
    )
    |> Ash.count!(authorize?: false) > 0
  end
end
