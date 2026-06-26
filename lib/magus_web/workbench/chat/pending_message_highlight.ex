defmodule MagusWeb.Workbench.Chat.PendingMessageHighlight do
  @moduledoc """
  Ephemeral, single-shot store for a message id to highlight, arriving via the
  `?highlight=` URL query param. WorkbenchLive writes it in `handle_params`
  keyed by conversation id; the freshly-mounted `ConversationView` takes it
  (consuming it) and highlights/scrolls to the message.

  Mirrors `MagusWeb.Workbench.Chat.PendingChatAction`. The put happens in the
  parent's `handle_params` (which runs in both the dead and connected render
  phases) so the balanced take at child mount works in both phases.
  """
  @table :magus_workbench_pending_message_highlights

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @spec put(String.t(), String.t()) :: :ok
  def put(conversation_id, message_id)
      when is_binary(conversation_id) and is_binary(message_id) do
    # Orphan note: if the child ConversationView never mounts (e.g. a failed
    # conversation load that does not `take`), this entry persists until the next
    # successful mount of that conversation overwrites or consumes it. Bounded to
    # one small tuple per conversation id (`:set` table); matches PendingChatAction.
    :ets.insert(@table, {conversation_id, message_id})
    :ok
  end

  @spec take(String.t()) :: String.t() | nil
  def take(conversation_id) when is_binary(conversation_id) do
    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, message_id}] ->
        :ets.delete(@table, conversation_id)
        message_id

      [] ->
        nil
    end
  end
end
