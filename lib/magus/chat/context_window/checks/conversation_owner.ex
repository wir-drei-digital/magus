defmodule Magus.Chat.ContextWindow.Checks.ConversationOwner do
  @moduledoc """
  Verifies the actor owns the conversation a `ContextWindow` belongs to.

  Used to gate the `:get_or_create` upsert: since that action returns the
  existing row for any `conversation_id`, an `always()` policy would let a
  non-owner read another user's window/summary by supplying an arbitrary id.
  The `belongs_to :conversation` relationship does not exist yet at create
  time, so this check resolves the conversation by the accepted
  `conversation_id` (argument or attribute) and compares its `user_id` to the
  actor.

  It also gates the conversation-keyed generic actions
  (`:clear_for_conversation`, `:compact_for_conversation`,
  `:set_strategy_for_conversation`), whose authorizer context carries an
  `Ash.ActionInput` rather than a changeset. In that case the
  `conversation_id` is read from the action arguments.

  System callers (the AI agent and the Oban compaction interaction) never reach
  this check; they are covered by the bypass policies above it.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor owns the conversation"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(%{id: actor_id}, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    changeset
    |> Ash.Changeset.get_argument_or_attribute(:conversation_id)
    |> owner?(actor_id)
  end

  def match?(%{id: actor_id}, %{action_input: %Ash.ActionInput{} = input}, _opts) do
    input
    |> Ash.ActionInput.get_argument(:conversation_id)
    |> owner?(actor_id)
  end

  def match?(_actor, _context, _opts), do: false

  defp owner?(nil, _actor_id), do: false

  defp owner?(conversation_id, actor_id) do
    case Ash.get(Magus.Chat.Conversation, conversation_id, authorize?: false) do
      {:ok, %{user_id: ^actor_id}} -> true
      _ -> false
    end
  end
end
