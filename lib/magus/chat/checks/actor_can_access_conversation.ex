defmodule Magus.Chat.Checks.ActorCanAccessConversation do
  @moduledoc """
  Verifies that the actor can access the target conversation.
  """

  use Ash.Policy.SimpleCheck

  require Ash.Query

  alias Magus.Chat.ConversationMember
  alias Magus.Checks.Helpers

  @impl true
  def describe(_opts), do: "actor can access the target conversation"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    field = Keyword.get(opts, :field, :conversation_id)
    allow_nil? = Keyword.get(opts, :allow_nil?, false)

    case Helpers.value_from_context(context, field) do
      nil -> allow_nil?
      conversation_id -> can_access?(actor, conversation_id)
    end
  end

  def can_access?(%{id: actor_id} = actor, conversation_id) when not is_nil(conversation_id) do
    case Magus.Chat.get_conversation(conversation_id, actor: actor) do
      {:ok, _conversation} ->
        true

      {:error, _} ->
        direct_member_access?(conversation_id, actor_id)
    end
  end

  def can_access?(_actor, _conversation_id), do: false

  defp direct_member_access?(conversation_id, actor_id) do
    ConversationMember
    |> Ash.Query.filter(
      conversation_id == ^conversation_id and
        user_id == ^actor_id and
        not is_nil(accepted_at)
    )
    |> Ash.count!(authorize?: false) > 0
  end
end
