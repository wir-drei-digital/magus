defmodule Magus.Agents.GracefulShutdown do
  @moduledoc """
  Pre-shutdown checkpointing for active agents.

  Called from `Application.prep_stop/1` before the supervision tree shuts down.
  Ensures agents mid-turn have their state persisted so they can recover on
  next startup.
  """

  require Logger

  @checkpoint_timeout :timer.seconds(15)

  @doc """
  Checkpoint all currently active (running) conversation agents.
  """
  def checkpoint_active_agents do
    sup_name = Jido.Agent.InstanceManager.dynamic_supervisor_name(:conversations)

    case Process.whereis(sup_name) do
      nil ->
        Logger.debug("GracefulShutdown: No InstanceManager supervisor found, skipping")
        :ok

      _pid ->
        children = DynamicSupervisor.which_children(sup_name)

        agent_pids =
          children
          |> Enum.filter(fn {_, pid, _, _} -> is_pid(pid) and Process.alive?(pid) end)
          |> Enum.map(fn {_, pid, _, _} -> pid end)

        if agent_pids == [] do
          Logger.debug("GracefulShutdown: No active agents to checkpoint")
          :ok
        else
          Logger.info("GracefulShutdown: Checkpointing #{length(agent_pids)} agent(s)")

          results =
            agent_pids
            |> Task.async_stream(&checkpoint_if_active/1,
              timeout: @checkpoint_timeout,
              on_timeout: :kill_task
            )
            |> Enum.to_list()

          checkpointed = Enum.count(results, &match?({:ok, :checkpointed}, &1))
          skipped = Enum.count(results, &match?({:ok, :idle}, &1))
          failed = length(results) - checkpointed - skipped

          Logger.info(
            "GracefulShutdown: Done. checkpointed=#{checkpointed} skipped=#{skipped} failed=#{failed}"
          )

          :ok
        end
    end
  rescue
    error ->
      Logger.error("GracefulShutdown failed: #{Exception.message(error)}")
      :ok
  end

  defp checkpoint_if_active(pid) do
    case Jido.AgentServer.status(pid) do
      {:ok, %{snapshot: %{status: :running}}} ->
        do_checkpoint(pid)

      _ ->
        :idle
    end
  rescue
    _ -> :error
  end

  defp do_checkpoint(pid) do
    case Jido.AgentServer.state(pid) do
      {:ok, state} ->
        agent = state.agent
        agent_module = state.agent_module

        case agent_module.checkpoint(agent, %{}) do
          {:ok, checkpoint_data} ->
            persistence_key = {agent_module, agent.id}

            case Magus.Agents.Persistence.PostgresStore.put_checkpoint(
                   persistence_key,
                   checkpoint_data,
                   []
                 ) do
              :ok ->
                Logger.debug("GracefulShutdown: Checkpointed #{agent.id}")
                :checkpointed

              {:error, reason} ->
                Logger.error(
                  "GracefulShutdown: put_checkpoint failed for #{agent.id}: #{inspect(reason)}"
                )

                :error
            end

          {:error, reason} ->
            Logger.error(
              "GracefulShutdown: checkpoint/2 failed for #{agent.id}: #{inspect(reason)}"
            )

            :error
        end

      {:error, reason} ->
        Logger.error("GracefulShutdown: get_state failed: #{inspect(reason)}")
        :error
    end
  end
end
