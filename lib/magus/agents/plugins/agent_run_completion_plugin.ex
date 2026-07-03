defmodule Magus.Agents.Plugins.AgentRunCompletionPlugin do
  @moduledoc """
  Detects when a target conversation request completes/fails and closes AgentRun.

  Runs are correlated by `request_id` + `target_conversation_id`. On completion/failure this plugin:
  1. updates AgentRun state
  2. emits `run.completed` or `run.failed` to the source conversation
  3. posts completion output back to source conversation
  4. starts the next queued run for the same target conversation
  """

  use Jido.Plugin,
    name: "agent_run_completion",
    state_key: :agent_run_completion,
    actions: [],
    description: "Marks AgentRun records complete/failed when target conversations finish",
    category: "magus",
    tags: ["orchestration", "agent-run", "lifecycle"],
    signal_patterns: [
      "ai.request.completed",
      "ai.request.failed"
    ]

  require Ash.Query
  require Logger

  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Agents.RunOrchestrator
  alias Magus.Agents.Signals
  alias Magus.Agents.Support.AiAgent

  @default_heartbeat_interval_minutes 360
  @autonomous_sources [:heartbeat, :manual_trigger, :inbox_urgent]

  @impl Jido.Plugin
  def mount(_agent, config) do
    {:ok, %{config: config}}
  end

  @impl Jido.Plugin
  def handle_signal(%{type: "ai.request.completed"} = signal, context) do
    agent = context[:agent]

    case find_active_run(agent, signal) do
      {:ok, run} ->
        result_text = extract_result_text(signal, agent)
        complete_run(run, result_text)

      :not_run ->
        :ok
    end

    {:ok, :continue}
  end

  def handle_signal(%{type: "ai.request.failed"} = signal, context) do
    agent = context[:agent]

    case find_active_run(agent, signal) do
      {:ok, run} ->
        error = (signal.data || %{})[:error] || (signal.data || %{})["error"]
        error_message = Helpers.format_error(error)
        fail_run(run, error_message)

      :not_run ->
        :ok
    end

    {:ok, :continue}
  end

  def handle_signal(_signal, _context), do: {:ok, :continue}

  defp find_active_run(agent, signal) do
    target_conversation_id = Helpers.get_conversation_id(agent)
    request_id = extract_request_id(signal)

    case Magus.Agents.running_agent_runs_by_target(target_conversation_id, authorize?: false) do
      {:ok, runs} when is_list(runs) and runs != [] ->
        pick_run(runs, request_id, target_conversation_id)

      _ ->
        :not_run
    end
  rescue
    e ->
      Logger.warning("AgentRunCompletion: error finding active run: #{Exception.message(e)}")

      :not_run
  end

  defp extract_request_id(signal) do
    data = signal.data || %{}
    data[:request_id] || data["request_id"]
  end

  defp pick_run(runs, request_id, target_conversation_id) when is_binary(request_id) do
    case Enum.find(runs, &(&1.request_id == request_id)) do
      nil ->
        Logger.warning(
          "AgentRunCompletion: no active run for target #{target_conversation_id} and request_id #{request_id}"
        )

        :not_run

      run ->
        {:ok, run}
    end
  end

  defp pick_run([run], _request_id, _target_conversation_id), do: {:ok, run}

  defp pick_run(_runs, _request_id, target_conversation_id) do
    Logger.warning(
      "AgentRunCompletion: multiple active runs for target #{target_conversation_id} but request_id missing; skipping completion correlation"
    )

    :not_run
  end

  defp complete_run(run, result_text) do
    run =
      if run.status == :pending do
        case Magus.Agents.start_agent_run(run, authorize?: false) do
          {:ok, started} -> started
          _ -> run
        end
      else
        run
      end

    case Magus.Agents.complete_agent_run(run, %{result_text: result_text}, authorize?: false) do
      {:ok, completed_run} ->
        update_spawn_output(completed_run)
        publish_completion(completed_run, result_text)
        RunOrchestrator.maybe_start_next(completed_run.target_conversation_id)
        resolve_inbox_event_for_run(completed_run)
        resolve_linked_inbox_events(completed_run)
        drain_urgent_events(completed_run)
        ensure_next_scheduled_at(completed_run)
        update_task_with_result(completed_run, result_text)
        report_to_parent_conversation(completed_run, result_text)
        Magus.Agents.SubAgent.Resumer.maybe_resume_parent(completed_run)
        Process.put(:activity_log_last_completed_run, completed_run)
        Logger.info("AgentRunCompletion: run #{completed_run.id} completed")

      {:error, reason} ->
        Logger.warning("AgentRunCompletion: failed to complete run #{run.id}: #{inspect(reason)}")
    end
  end

  @doc """
  Test entry point: drives the post-completion side effects for a run that
  has already been marked complete. Used in tests to avoid having to
  construct a full signal/agent context.
  """
  def handle_run_completed(run) do
    update_spawn_output(run)
    resolve_linked_inbox_events(run)
    drain_urgent_events(run)
    ensure_next_scheduled_at(run)
    :ok
  end

  @doc """
  Test entry point: drives the post-failure side effects for a run that
  has already been marked failed.
  """
  def handle_run_failed(run, _error_message \\ nil) do
    update_spawn_output(run)
    unlink_linked_inbox_events(run)
    drain_urgent_events(run)
    :ok
  end

  defp fail_run(run, error_message) do
    case Magus.Agents.fail_agent_run(run, %{error_message: error_message}, authorize?: false) do
      {:ok, failed_run} ->
        update_spawn_output(failed_run)
        publish_failure(failed_run, error_message)
        RunOrchestrator.maybe_start_next(failed_run.target_conversation_id)
        requeue_inbox_event_for_run(failed_run)
        unlink_linked_inbox_events(failed_run)
        drain_urgent_events(failed_run)
        Magus.Agents.SubAgent.Resumer.maybe_resume_parent(failed_run)
        Process.put(:activity_log_last_failed_run, failed_run)
        Logger.info("AgentRunCompletion: run #{failed_run.id} failed")

      {:error, reason} ->
        Logger.warning("AgentRunCompletion: failed to fail run #{run.id}: #{inspect(reason)}")
    end
  end

  # Resolves AgentInboxEvents whose `agent_run_id` points at this run, marking
  # them as :resolved with `resolved_by: :run_completed`. This is the new
  # post-run resolution path (Task 3 + Task 17), separate from the legacy
  # `resolve_inbox_event_for_run/1` which works off `run.event_id`.
  #
  # Filters to non-terminal statuses; the `:resolve_via_run` action validates
  # `status in [:pending, :waiting, :processing]`, so already-terminal events
  # would otherwise produce spurious validation failures in the rescue path.
  defp resolve_linked_inbox_events(run) do
    Magus.Agents.AgentInboxEvent
    |> Ash.Query.filter(agent_run_id == ^run.id and status in [:pending, :waiting, :processing])
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn event ->
      Magus.Agents.resolve_event_via_run(event, authorize?: false)
    end)
  rescue
    e ->
      Logger.warning(
        "AgentRunCompletion: failed to resolve linked inbox events for run #{run.id}: #{Exception.message(e)}"
      )

      :ok
  end

  # Clears `agent_run_id` on AgentInboxEvents linked to this run so they
  # become eligible for the next heartbeat to consider. Delegates to the
  # shared `Magus.Agents.AgentRunHelpers` so the timeout path
  # (CleanupStale) and the failure path stay in lockstep.
  defp unlink_linked_inbox_events(run) do
    Magus.Agents.AgentRunHelpers.unlink_linked_inbox_events(run)
  end

  # After an autonomous run reaches a terminal state, give pending urgent
  # events that arrived mid-run (their wake was rejected by the in-flight
  # gate) their follow-up run before the agent goes back to sleep. The
  # per-event idempotency key caps this at one urgent run per event ever:
  # an event whose run already happened resolves to :existing and stays
  # pending for the next heartbeat.
  defp drain_urgent_events(%{source: source, target_agent_id: agent_id} = run)
       when source in @autonomous_sources and is_binary(agent_id) do
    events =
      Magus.Agents.AgentInboxEvent
      |> Ash.Query.filter(
        agent_id == ^agent_id and
          urgency == :immediate and
          status in [:pending, :waiting] and
          is_nil(agent_run_id)
      )
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    case events do
      [event] -> enqueue_urgent_followup(event, run)
      [] -> :ok
    end
  rescue
    e ->
      Logger.warning("AgentRunCompletion: drain failed: #{Exception.message(e)}")
      :ok
  end

  defp drain_urgent_events(_run), do: :ok

  defp enqueue_urgent_followup(event, run) do
    attrs = %{
      kind: :delegate,
      source: :inbox_urgent,
      source_conversation_id: run.target_conversation_id,
      target_conversation_id: run.target_conversation_id,
      target_agent_id: run.target_agent_id,
      initiator_user_id: run.initiator_user_id,
      request_id: "inbox-urgent-#{Ash.UUID.generate()}",
      idempotency_key: "inbox:#{event.id}",
      objective: "Urgent inbox event: #{event.title}"
    }

    case RunOrchestrator.enqueue_with_outcome(attrs) do
      {:ok, :created, new_run} ->
        case Magus.Agents.link_event_to_run(event, new_run.id, authorize?: false) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "AgentRunCompletion: drain link failed for event #{event.id}: #{inspect(reason)}"
            )

            :ok
        end

      {:ok, :existing, _} ->
        :ok

      {:error, reason} ->
        Logger.info("AgentRunCompletion: drain enqueue skipped (#{inspect(reason)})")
        :ok
    end
  end

  # For :heartbeat runs, if the agent did not call `set_next_wakeup` during
  # the run (i.e. `next_scheduled_at` is nil or in the past), apply the
  # default heartbeat interval as a fallback so heartbeats keep firing.
  # Manual triggers do not advance the schedule.
  defp ensure_next_scheduled_at(%{source: source, target_agent_id: agent_id})
       when source in [:heartbeat, :inbox_urgent] and is_binary(agent_id) do
    case Ash.get(Magus.Agents.CustomAgent, agent_id, authorize?: false) do
      {:ok, agent} ->
        if needs_fallback_schedule?(agent) do
          interval =
            agent.heartbeat_default_interval_minutes || @default_heartbeat_interval_minutes

          fallback_at = DateTime.utc_now() |> DateTime.add(interval * 60, :second)

          case Magus.Agents.set_custom_agent_next_scheduled_at(agent, fallback_at,
                 authorize?: false
               ) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "AgentRunCompletion: failed to set fallback next_scheduled_at for agent #{agent_id}: #{inspect(reason)}"
              )

              :ok
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "AgentRunCompletion: ensure_next_scheduled_at failed: #{Exception.message(e)}"
      )

      :ok
  end

  defp ensure_next_scheduled_at(_run), do: :ok

  defp needs_fallback_schedule?(%{next_scheduled_at: nil}), do: true

  defp needs_fallback_schedule?(%{next_scheduled_at: %DateTime{} = at}) do
    DateTime.compare(at, DateTime.utc_now()) != :gt
  end

  defp needs_fallback_schedule?(_), do: true

  defp resolve_inbox_event_for_run(run) do
    if run.event_id do
      case Ash.get(Magus.Agents.AgentInboxEvent, run.event_id, authorize?: false) do
        {:ok, event} ->
          Magus.Agents.resolve_event(
            event,
            %{resolved_by: :agent, run_id: run.id, resolution_note: "Run completed"},
            authorize?: false
          )

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning(
        "AgentRunCompletion: failed to resolve inbox event for run #{run.id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp requeue_inbox_event_for_run(run) do
    if run.event_id do
      case Ash.get(Magus.Agents.AgentInboxEvent, run.event_id, authorize?: false) do
        {:ok, event} ->
          Magus.Agents.mark_event_waiting(event, %{}, authorize?: false)

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning(
        "AgentRunCompletion: failed to requeue inbox event for run #{run.id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp update_task_with_result(run, result_text) do
    if run.task_id && is_binary(result_text) && String.trim(result_text) != "" do
      case Ash.get(Magus.Plan.Task, run.task_id, authorize?: false) do
        {:ok, task} ->
          summary = String.slice(result_text, 0, 2000)

          Magus.Plan.update_task(task, %{status: :done, result_summary: summary},
            authorize?: false
          )

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("AgentRunCompletion: task result update failed: #{Exception.message(e)}")

      :ok
  end

  # When a delegated task completes, post the result as a message in the
  # parent conversation (where the orchestrator created the tasks).
  # This gives the orchestrator immediate visibility without going through triage.
  defp report_to_parent_conversation(run, result_text) do
    if run.task_id && is_binary(result_text) && String.trim(result_text) != "" do
      case Ash.get(Magus.Plan.Task, run.task_id, authorize?: false) do
        {:ok, task}
        when not is_nil(task.assigned_by_custom_agent_id) and
               task.assigned_by_custom_agent_id != task.assigned_to_custom_agent_id ->
          # This is a delegated task — report to the conversation where it was created
          parent_conversation_id = task.conversation_id
          agent_name = get_agent_name(task.assigned_to_custom_agent_id)
          message_id = Ash.UUID.generate()

          summary = String.slice(result_text, 0, 2000)
          text = "**Task completed: #{task.title}** (@#{agent_name})\n\n#{summary}"

          case Magus.Chat.Message
               |> Ash.Changeset.for_create(
                 :upsert_response,
                 %{
                   id: message_id,
                   conversation_id: parent_conversation_id,
                   text: text,
                   complete: true,
                   responding_agent_id: task.assigned_to_custom_agent_id
                 },
                 actor: %Magus.Agents.Support.AiAgent{}
               )
               |> Ash.create() do
            {:ok, _msg} ->
              Signals.text_complete(parent_conversation_id, message_id, text, %{},
                custom_agent_id: task.assigned_to_custom_agent_id
              )

              Signals.response_complete(parent_conversation_id, %{
                message_id: message_id,
                custom_agent_id: task.assigned_to_custom_agent_id
              })

            {:error, reason} ->
              Logger.warning("AgentRunCompletion: failed to report to parent: #{inspect(reason)}")
          end

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("AgentRunCompletion: report to parent failed: #{Exception.message(e)}")
      :ok
  end

  defp get_agent_name(agent_id) do
    case Magus.Agents.get_custom_agent(agent_id, authorize?: false) do
      {:ok, agent} -> agent.handle || agent.name
      _ -> "agent"
    end
  rescue
    _ -> "agent"
  end

  defp publish_completion(run, result_text) do
    source_conversation_id = to_string(run.source_conversation_id)

    if run.source_event_id do
      # Relay as final step on the parent's spawn_sub_agent card
      step_id = "#{run.source_event_id}-step-result"
      result_summary = truncate(result_text, 1_000) || "Done."

      Signals.relay_tool_step_complete(
        source_conversation_id,
        run.source_event_id,
        step_id,
        :complete,
        result_summary
      )

      persist_steps_to_parent_event(run)
    else
      # Legacy: no source_event_id, fall back to run.completed signal
      Signals.run_completed(source_conversation_id, %{
        run_id: to_string(run.id),
        status: "complete",
        kind: to_string(run.kind),
        objective: truncate(run.objective, 180),
        target_agent_id: run.target_agent_id,
        target_conversation_id: run.target_conversation_id,
        request_id: run.request_id,
        result_text: truncate(result_text, 1_000)
      })

      # :subtask never persists a separate response message — the spawn tool
      # card (when present) is authoritative. Other kinds keep the legacy behavior.
      if run.kind != :subtask do
        persist_source_response(run, result_text)
      end
    end
  end

  defp publish_failure(run, error_message) do
    source_conversation_id = to_string(run.source_conversation_id)

    if run.source_event_id do
      # Relay as final step with error status
      step_id = "#{run.source_event_id}-step-result"
      error_summary = "Error: #{truncate(error_message, 500)}"

      Signals.relay_tool_step_complete(
        source_conversation_id,
        run.source_event_id,
        step_id,
        :error,
        error_summary
      )

      persist_steps_to_parent_event(run)
    else
      # Legacy fallback
      Signals.run_failed(source_conversation_id, %{
        run_id: to_string(run.id),
        status: "error",
        kind: to_string(run.kind),
        objective: truncate(run.objective, 180),
        target_agent_id: run.target_agent_id,
        target_conversation_id: run.target_conversation_id,
        request_id: run.request_id,
        error: truncate(error_message, 1_000)
      })

      Magus.Chat.create_event_message(
        "Run failed: #{truncate(error_message, 200)}",
        run.source_conversation_id,
        authorize?: false
      )
    end
  end

  # Fetches the child conversation's tool event messages AND agent messages,
  # then persists them as steps on the parent's spawn_sub_agent tool card
  # so they survive page reload.
  defp persist_steps_to_parent_event(run) do
    case Magus.Chat.get_message(run.source_event_id, authorize?: false) do
      {:ok, parent_message} when is_map(parent_message.tool_call_data) ->
        child_messages = fetch_child_messages(run.target_conversation_id)
        steps = build_steps_from_messages(child_messages)
        actual_model_name = extract_child_model_name(child_messages)

        # Append artifacts step if child created files
        artifacts_step = build_artifacts_step(run.target_conversation_id)

        steps =
          if artifacts_step do
            steps ++ [artifacts_step]
          else
            steps
          end

        updated_tcd = parent_message.tool_call_data

        updated_tcd =
          if steps != [],
            do: Map.put(updated_tcd, "steps", steps),
            else: updated_tcd

        updated_tcd =
          if actual_model_name do
            existing_output = Map.get(updated_tcd, "output") || %{}
            updated_output = Map.put(existing_output, "actual_model_name", actual_model_name)
            Map.put(updated_tcd, "output", updated_output)
          else
            updated_tcd
          end

        if updated_tcd != parent_message.tool_call_data do
          Magus.Chat.upsert_event_message!(
            run.source_event_id,
            parent_message.text || "",
            run.source_conversation_id,
            updated_tcd,
            parent_message.complete || true,
            authorize?: false
          )
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("AgentRunCompletion: failed to persist steps: #{Exception.message(e)}")
      :ok
  end

  # When a :subtask run with a source_event_id completes or fails, overwrite
  # the spawn_sub_agent tool card's tool_call_data.output with the terminal
  # SpawnOutput payload so the parent's LLM sees the final result.
  defp update_spawn_output(run) do
    if run.kind == :subtask and is_binary(run.source_event_id) do
      case Magus.Chat.get_message(run.source_event_id, authorize?: false) do
        {:ok, parent_message} when is_map(parent_message.tool_call_data) ->
          new_output =
            Magus.Agents.SubAgent.SpawnOutput.build(run,
              target_conversation_id: run.target_conversation_id
            )

          existing_output = parent_message.tool_call_data["output"] || %{}

          merged_output = Map.merge(existing_output, stringify_keys(new_output))

          updated_tcd =
            parent_message.tool_call_data
            |> Map.put("output", merged_output)
            |> Map.put("status", to_string(run.status))
            |> Map.put("output_summary", build_output_summary(run))

          Magus.Chat.upsert_event_message!(
            run.source_event_id,
            parent_message.text || "",
            run.source_conversation_id,
            updated_tcd,
            parent_message.complete || true,
            authorize?: false
          )

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("AgentRunCompletion: update_spawn_output failed: #{Exception.message(e)}")
      :ok
  end

  defp build_output_summary(%{status: :complete} = run),
    do: "Sub-agent complete: #{truncate(run.result_text, 200)}"

  defp build_output_summary(%{status: :error} = run),
    do: "Sub-agent failed: #{truncate(run.error_message, 200)}"

  defp build_output_summary(%{status: :timed_out}), do: "Sub-agent timed out"
  defp build_output_summary(%{status: :cancelled}), do: "Sub-agent cancelled"
  defp build_output_summary(_), do: "Sub-agent finished"

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # Fetch both tool events and agent messages from the child conversation
  defp fetch_child_messages(conversation_id) do
    require Ash.Query

    Magus.Chat.Message
    |> Ash.Query.filter(
      conversation_id == ^conversation_id and
        ((message_type == :event and not is_nil(tool_call_data)) or
           (message_type == :message and source == :agent))
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  # Extract the actual model name from the last agent message
  defp extract_child_model_name(messages) do
    messages
    |> Enum.filter(fn msg -> msg.source == :agent and msg.message_type == :message end)
    |> List.last()
    |> case do
      nil -> nil
      msg -> msg.model_name
    end
  end

  defp build_steps_from_messages(messages) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn {msg, index} ->
      if msg.message_type == :event do
        build_tool_step(msg, index)
      else
        build_text_step(msg, index)
      end
    end)
  end

  defp build_tool_step(msg, index) do
    tcd = msg.tool_call_data || %{}
    label = tcd["display_name"] || tcd["tool_name"] || "Tool"
    content = tcd["output_summary"] || ""

    status =
      case tcd["status"] do
        "error" -> :error
        _ -> :complete
      end

    %{
      id: "persisted-step-#{index}",
      index: index,
      label: label,
      status: status,
      content: content,
      data: %{type: :tool}
    }
  end

  defp build_text_step(msg, index) do
    model = msg.model_name
    label = if model, do: "Response (#{model})", else: "Response"
    text = msg.text || ""
    content = text

    %{
      id: "persisted-step-#{index}",
      index: index,
      label: label,
      status: :complete,
      content: content,
      data: %{type: :text}
    }
  end

  @doc false
  def build_artifacts_step(conversation_id) do
    case Magus.Files.list_files_for_conversation(conversation_id,
           actor: %AiAgent{}
         ) do
      {:ok, files} when files != [] ->
        file_entries =
          Enum.map(files, fn f ->
            %{name: f.name, type: to_string(f.type), file_id: to_string(f.id)}
          end)

        file_names = Enum.map_join(files, ", ", & &1.name)

        %{
          id: "persisted-step-artifacts",
          label: "Artifacts",
          status: :complete,
          content: "Files created: #{file_names}",
          data: %{type: :artifacts, files: file_entries}
        }

      _ ->
        nil
    end
  rescue
    e ->
      Logger.warning(
        "AgentRunCompletion: failed to build artifacts step: #{Exception.message(e)}"
      )

      nil
  end

  defp persist_source_response(run, result_text) do
    text =
      if is_binary(result_text) and String.trim(result_text) != "", do: result_text, else: "Done."

    attrs = %{
      id: Ash.UUIDv7.generate(),
      conversation_id: run.source_conversation_id,
      response_to_id: run.source_message_id,
      text: text,
      complete: true,
      model_name: run.model_key || "Agent",
      mode: :chat,
      responding_agent_id: run.target_agent_id
    }

    Magus.Chat.Message
    |> Ash.Changeset.for_create(:upsert_response, attrs, actor: %AiAgent{})
    |> Ash.create()
  rescue
    e ->
      Logger.warning(
        "AgentRunCompletion: failed to persist source response: #{Exception.message(e)}"
      )

      :ok
  end

  defp extract_result_text(signal, agent) do
    strategy_state = Helpers.get_strategy_state(agent)
    data = signal.data || %{}

    Helpers.first_non_blank([
      strategy_state[:streaming_text],
      data[:result],
      data["result"],
      ""
    ])
  end

  defp truncate(text, _max) when not is_binary(text), do: ""

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "...", else: text
  end
end
