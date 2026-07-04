defmodule Magus.Agents.Recovery do
  @moduledoc """
  Handles mid-turn recovery when an agent restores from hibernation
  with an interrupted turn.

  When an agent was mid-turn (status :awaiting_llm or :awaiting_tool) at
  checkpoint time, recovery will:
  1. Broadcast "thinking" state so the LiveView shows the spinner
  2. Mark any stuck streaming messages as errored
  3. Re-dispatch the last user message to retry the turn
  """

  require Logger
  require Ash.Query

  alias Magus.Agents.Signals
  alias Magus.Agents.Support.AutonomyTrace

  @doc """
  Check if the agent needs recovery and trigger auto-retry if so.
  Called from strategy init after the agent is fully initialized.

  Returns the agent with `__recovery__` cleared from state to prevent
  infinite recovery loops (if the recovered turn is checkpointed mid-flight,
  the next restore must not trigger recovery again).

  Runs async to avoid blocking agent initialization.
  """
  def maybe_recover(agent) do
    recovery = get_in(agent.state || %{}, [:__recovery__])

    if is_map(recovery) && recovery[:was_active] do
      conversation_id = agent.state[:conversation_id]

      Logger.info(
        "Agent #{agent.id}: recovering interrupted turn for conversation #{conversation_id}"
      )

      # Broadcast thinking state so LiveView shows spinner immediately
      Signals.state_change(conversation_id, :running)

      active_message_id = recovery[:active_message_id]

      # Run recovery async to not block init
      Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
        recover_interrupted_turn(conversation_id, active_message_id)
      end)

      # Clear recovery metadata so a subsequent checkpoint/restore cycle
      # does not trigger recovery again
      cleared_state = Map.delete(agent.state, :__recovery__)
      %{agent | state: cleared_state}
    else
      agent
    end
  end

  @doc false
  # Exposed (not private) so tests can invoke recovery synchronously and
  # assert on the tagged return value instead of racing the async Task
  # spawned by `maybe_recover/1`. Not part of the public API.
  @spec recover_interrupted_turn(String.t(), String.t() | nil) ::
          {:dispatched, term()} | :skipped_newer | :aborted_not_ready | :no_message | :error
  def recover_interrupted_turn(conversation_id, active_message_id) do
    case await_agent_ready(conversation_id) do
      :ok ->
        # Mark any stuck streaming messages as error
        cleanup_interrupted_messages(conversation_id)

        maybe_redispatch(conversation_id, active_message_id)

      :timeout ->
        # Mark any stuck streaming messages as error even though we're aborting
        cleanup_interrupted_messages(conversation_id)

        Signals.state_change(conversation_id, :idle)

        trace_recovery(
          conversation_id,
          "Recovery aborted: agent never became ready",
          %{conversation_id: conversation_id}
        )

        :aborted_not_ready
    end
  rescue
    error ->
      Logger.error("Recovery failed for conversation #{conversation_id}: #{inspect(error)}")

      Signals.state_change(conversation_id, :idle)
      :error
  end

  defp maybe_redispatch(conversation_id, active_message_id) do
    # Find the interrupted message and re-dispatch it, unless a newer user
    # message has since arrived (that message will drive its own turn, so
    # re-dispatching the stale one would duplicate work / interleave turns).
    case find_interrupted_message(conversation_id, active_message_id) do
      {:ok, message} ->
        if newer_user_message_exists?(conversation_id, message) do
          Logger.info(
            "Recovery: newer user message supersedes #{message.id} in #{conversation_id}; skipping re-dispatch"
          )

          trace_recovery(
            conversation_id,
            "Recovery skipped: a newer user message superseded the interrupted turn",
            %{conversation_id: conversation_id, message_id: message.id}
          )

          :skipped_newer
        else
          Logger.info(
            "Recovery: re-dispatching message #{message.id} for conversation #{conversation_id}"
          )

          Magus.Agents.Dispatcher.dispatch_user_message(message)

          trace_recovery(
            conversation_id,
            "Recovery re-dispatched the interrupted turn",
            %{conversation_id: conversation_id, message_id: message.id}
          )

          {:dispatched, message.id}
        end

      :error ->
        Logger.warning("Recovery: no user message found for conversation #{conversation_id}")

        Signals.state_change(conversation_id, :idle)
        :no_message
    end
  end

  # Best-effort activity-log trace of the recovery outcome. Only traces
  # conversations owned by a custom agent (plain user conversations have
  # nothing to attribute the entry to and are skipped entirely).
  # AutonomyTrace.log/5 already never raises, so no rescue is added here.
  defp trace_recovery(conversation_id, summary, metadata) do
    case Ash.get(Magus.Chat.Conversation, conversation_id, authorize?: false) do
      {:ok, %{custom_agent_id: custom_agent_id, user_id: user_id}}
      when not is_nil(custom_agent_id) ->
        AutonomyTrace.log(custom_agent_id, user_id, :recovery, summary, metadata)

      _ ->
        :ok
    end
  end

  defp newer_user_message_exists?(conversation_id, message) do
    Magus.Chat.Message
    |> Ash.Query.filter(
      conversation_id == ^conversation_id and role == :user and
        inserted_at > ^message.inserted_at
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      _ -> true
    end
  rescue
    # Fail open toward dispatching: a duplicated turn is recoverable, a
    # silently dropped one is not.
    _ -> false
  end

  defp await_agent_ready(conversation_id, attempts \\ 0)

  defp await_agent_ready(_conversation_id, attempts) when attempts >= 10 do
    Logger.warning("Recovery: agent not ready after #{attempts} attempts, aborting recovery")
    :timeout
  end

  defp await_agent_ready(conversation_id, attempts) do
    agent_id = "conv:#{conversation_id}"

    case Jido.Agent.InstanceManager.lookup(:conversations, agent_id) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: do_await_retry(conversation_id, attempts)

      _ ->
        do_await_retry(conversation_id, attempts)
    end
  rescue
    _ -> do_await_retry(conversation_id, attempts)
  end

  defp do_await_retry(conversation_id, attempts) do
    Process.sleep(50)
    await_agent_ready(conversation_id, attempts + 1)
  end

  defp cleanup_interrupted_messages(conversation_id) do
    streaming_messages =
      Magus.Chat.Message
      |> Ash.Query.filter(conversation_id == ^conversation_id and status == :streaming)
      |> Ash.read!(authorize?: false)

    if streaming_messages != [] do
      %Ash.BulkResult{status: status, error_count: error_count} =
        Ash.bulk_update(
          streaming_messages,
          :mark_error,
          %{
            error: %{
              "reason" => "interrupted",
              "detail" =>
                "Streaming row left behind by an interrupted/hibernated turn; swept on recovery."
            }
          },
          authorize?: false
        )

      count = length(streaming_messages)

      if status == :success do
        Logger.info("Recovery: marked #{count} streaming messages as error")
      else
        Logger.warning(
          "Recovery: failed to mark #{error_count}/#{count} streaming messages as error"
        )
      end
    end
  end

  # Try to find the specific interrupted message by ID first,
  # fall back to the last user message in the conversation.
  defp find_interrupted_message(conversation_id, active_message_id)
       when is_binary(active_message_id) and active_message_id != "" do
    case Ash.get(Magus.Chat.Message, active_message_id, authorize?: false) do
      {:ok, message} ->
        {:ok, message}

      {:error, _} ->
        Logger.warning(
          "Recovery: active_message_id #{active_message_id} not found, falling back to last user message"
        )

        find_last_user_message(conversation_id)
    end
  end

  defp find_interrupted_message(conversation_id, _), do: find_last_user_message(conversation_id)

  defp find_last_user_message(conversation_id) do
    case Magus.Chat.Message
         |> Ash.Query.filter(conversation_id == ^conversation_id and role == :user)
         |> Ash.Query.sort(inserted_at: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> :error
      {:ok, message} -> {:ok, message}
      {:error, _} -> :error
    end
  end
end
