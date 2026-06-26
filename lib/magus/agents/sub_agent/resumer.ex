defmodule Magus.Agents.SubAgent.Resumer do
  @moduledoc """
  Wakes up a parent conversation agent when its last in-flight sub-agent
  finishes — but only if the parent is currently idle and has at least one
  undelivered subtask result.

  Called from `Magus.Agents.Plugins.AgentRunCompletionPlugin` after the run
  has been marked complete or failed.

  Outcomes (logged at info):
    * :resumed
    * :skipped_not_subtask
    * :skipped_other_in_flight
    * :skipped_busy
    * :skipped_no_undelivered
  """

  require Ash.Query
  require Logger

  alias Magus.Agents.AgentRun
  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Agents.Support.AgentBootstrap

  @type outcome ::
          :resumed
          | :skipped_not_subtask
          | :skipped_other_in_flight
          | :skipped_busy
          | :skipped_no_undelivered

  @spec maybe_resume_parent(AgentRun.t()) :: outcome()
  def maybe_resume_parent(%AgentRun{kind: kind}) when kind != :subtask do
    log(:skipped_not_subtask, nil)
    :skipped_not_subtask
  end

  def maybe_resume_parent(%AgentRun{} = run) do
    parent_id = run.source_conversation_id

    cond do
      other_in_flight?(parent_id, run.id) ->
        log(:skipped_other_in_flight, parent_id)
        :skipped_other_in_flight

      parent_busy?(parent_id) ->
        log(:skipped_busy, parent_id)
        :skipped_busy

      true ->
        case list_undelivered(parent_id) do
          [] ->
            log(:skipped_no_undelivered, parent_id)
            :skipped_no_undelivered

          undelivered ->
            do_resume(parent_id, undelivered)
        end
    end
  rescue
    e ->
      Logger.warning("SubAgentResumer error: #{Exception.message(e)}")
      :skipped_busy
  end

  defp other_in_flight?(parent_id, exclude_id) do
    AgentRun
    |> Ash.Query.filter(
      source_conversation_id == ^parent_id and
        kind == :subtask and
        status in [:pending, :running] and
        id != ^exclude_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      _ -> true
    end
  end

  defp parent_busy?(parent_id) do
    agent_id = "conv:#{parent_id}"

    case Jido.Agent.InstanceManager.lookup(:conversations, agent_id) do
      {:ok, pid} ->
        agent_busy?(pid)

      _ ->
        # Hibernated / not running — not busy
        false
    end
  rescue
    _ -> false
  end

  defp agent_busy?(pid) do
    case Jido.AgentServer.state(pid) do
      {:ok, agent} ->
        strategy_state = Helpers.get_strategy_state(agent)
        strategy_state[:status] in [:awaiting_llm, :awaiting_tool]

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp list_undelivered(parent_id) do
    AgentRun
    |> Ash.Query.filter(
      source_conversation_id == ^parent_id and
        kind == :subtask and
        status in [:complete, :error, :timed_out, :cancelled] and
        is_nil(delivered_to_parent_at)
    )
    |> Ash.read!(authorize?: false)
  end

  defp do_resume(parent_id, undelivered) do
    case AgentBootstrap.ensure_conversation_agent(parent_id, []) do
      {:ok, %{pid: pid}} ->
        # Mark delivered FIRST so a process crash between attach and cast doesn't
        # cause a duplicate resume on the next sub-agent completion. Trade-off:
        # if the cast itself fails (next branch), we've already marked delivered
        # and the wake-up is "lost" — but a missed wake is recoverable on the
        # next sub-agent completion, while a duplicate wake wastes spend.
        Enum.each(undelivered, fn run ->
          Magus.Agents.mark_delivered_agent_run(run, authorize?: false)
        end)

        signal =
          Jido.Signal.new!("agent.resume", %{
            reason: :sub_agents_completed,
            completed_task_ids: Enum.map(undelivered, & &1.id),
            completed_count: length(undelivered)
          })

        with :ok <- Jido.AgentServer.attach(pid),
             :ok <- Jido.AgentServer.cast(pid, signal) do
          log(:resumed, parent_id)
          :resumed
        else
          {:error, reason} ->
            Logger.warning(
              "SubAgentResumer: dispatch_resume failed for #{parent_id} after marking delivered: #{inspect(reason)}"
            )

            log(:skipped_busy, parent_id)
            :skipped_busy
        end

      {:error, reason} ->
        Logger.warning(
          "SubAgentResumer: ensure_conversation_agent failed for #{parent_id}: #{inspect(reason)}"
        )

        log(:skipped_busy, parent_id)
        :skipped_busy
    end
  end

  defp log(outcome, parent_id) do
    Logger.info("SubAgentResumer: #{outcome} parent=#{inspect(parent_id)}")
  end
end
