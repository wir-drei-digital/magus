defmodule Magus.Agents.Steering do
  @moduledoc """
  Coordinates draining the per-conversation steering queue (`:queued` messages).

  Two drain paths, both delivering the whole queue as a unit:

    * `flush_conversation/1` (post-turn auto-flush): promote all queued messages
      and redispatch one run keyed to the newest.
    * `send_now/1` (mid-turn): cast `message.steer` to the running agent so the
      batch is injected at the next tool-call boundary; falls back to
      `flush_conversation/1` when no agent process exists.
  """

  alias Magus.Agents.Dispatcher
  alias Magus.Chat

  @doc "Promote every queued message for the conversation, oldest-first."
  @spec promote_queued(String.t()) :: [struct()]
  def promote_queued(conversation_id) do
    conversation_id
    |> Chat.list_queued_messages!(authorize?: false)
    |> Enum.flat_map(fn msg ->
      case Chat.flush_queued_message(msg, authorize?: false) do
        {:ok, promoted} -> [promoted]
        # Lost the race to a concurrent flusher; the row is already promoted.
        {:error, _} -> []
      end
    end)
  end

  @doc "Dispatch one run keyed to a (already promoted) message id."
  @spec redispatch(String.t(), String.t()) :: :ok
  def redispatch(_conversation_id, message_id) when is_binary(message_id) do
    case Chat.get_message(message_id, authorize?: false) do
      {:ok, %{} = message} ->
        _ = Dispatcher.dispatch_user_message(message)
        :ok

      _ ->
        :ok
    end
  end

  def redispatch(_conversation_id, _), do: :ok

  @doc "Promote the queue and deliver it as one new turn. No-op when empty."
  @spec flush_conversation(String.t()) :: :ok
  def flush_conversation(conversation_id) do
    case promote_queued(conversation_id) do
      [] ->
        :ok

      msgs ->
        newest = List.last(msgs)
        redispatch(conversation_id, newest.id)
    end
  end

  @doc """
  Deliver the queue into the conversation now. If a conversation agent is
  running, cast `message.steer` (InboundPlugin decides inject-vs-redispatch);
  otherwise flush directly.
  """
  @spec send_now(String.t()) :: :ok
  def send_now(conversation_id) do
    case running_agent(conversation_id) do
      {:ok, pid} ->
        signal = Jido.Signal.new!("message.steer", %{conversation_id: conversation_id})
        Jido.AgentServer.cast(pid, signal)
        :ok

      :error ->
        flush_conversation(conversation_id)
    end
  end

  # Returns {:ok, pid} for a live conversation agent, or :error when none is
  # running. Treats a missing InstanceManager registry (e.g. the test env, where
  # the manager is not started) the same as "no agent" so the flush fallback
  # always runs instead of raising ArgumentError out of Registry.lookup/2.
  defp running_agent(conversation_id) do
    Jido.Agent.InstanceManager.lookup(:conversations, "conv:#{conversation_id}")
  rescue
    ArgumentError -> :error
  end
end
