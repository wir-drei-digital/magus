defmodule MagusWeb.Workbench.Chat.PendingChatAction do
  @moduledoc """
  Ephemeral, single-shot store for chat actions that arrive via URL query
  params (e.g. `/chat?agent=X`, `/chat?use_prompt=Y`) and need to be applied
  when the new-chat `ConversationView` mounts.

  WorkbenchLive captures the action when handling its URL params and writes
  it here keyed by user id; the freshly-mounted ConversationView for the
  "new" conversation tab takes the action (consuming it) and applies it.

  Actions are simple tuples; see `t:action/0`.
  """

  @table :magus_workbench_pending_chat_actions

  @type action ::
          {:set_custom_agent, map()}
          | {:activate_system_prompt, map()}
          | {:insert_text, String.t()}

  @doc """
  Creates the backing ETS table. Called from the application supervisor at
  startup. Idempotent so app restarts in dev / iex don't crash on the
  already-existing table.
  """
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @spec put(String.t(), action()) :: :ok
  def put(user_id, action) when is_binary(user_id) do
    :ets.insert(@table, {user_id, action})
    :ok
  end

  @spec take(String.t()) :: action() | nil
  def take(user_id) when is_binary(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, action}] ->
        :ets.delete(@table, user_id)
        action

      [] ->
        nil
    end
  end
end
