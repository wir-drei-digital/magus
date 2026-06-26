defmodule MagusWeb.ChatLive.PubSubHandlers do
  @moduledoc """
  Handles PubSub broadcast messages in ChatLive.

  This module processes real-time updates from PubSub broadcasts,
  keeping the main ChatLive module thin and focused on coordination.
  """

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [push_navigate: 2, push_event: 3, stream_insert: 3, stream_insert: 4, stream_delete: 3]

  alias MagusWeb.ChatLive.Helpers
  alias MagusWeb.Workbench.Chat.AgentStreamHandlers

  # Tools that return deferred results (fire-and-forget) stay in_progress
  # until child activity completes via tool.step signals.
  @deferred_tools ~w(spawn_sub_agent)

  # ============================================================================
  # Helpers
  # ============================================================================

  # Standardized conversation_id comparison helper.
  # Some PubSub topics extract conversation_id as string (from pattern match),
  # while socket.assigns.conversation.id is a UUID. This ensures consistent comparison.
  defp matches_conversation?(socket, conversation_id) do
    socket.assigns.conversation &&
      to_string(socket.assigns.conversation.id) == to_string(conversation_id)
  end

  # ============================================================================
  # Conversation Broadcasts
  # ============================================================================

  def handle_conversation_destroyed(socket, conversation) do
    socket =
      if socket.assigns.conversation && socket.assigns.conversation.id == conversation.id do
        socket
        |> assign(:conversation, nil)
        |> push_navigate(to: "/chat")
      else
        socket
      end

    unfiled =
      Enum.reject(socket.assigns.unfiled_conversations, &(&1.id == conversation.id))

    folders = Helpers.load_folders(socket.assigns.current_user, socket.assigns.expanded_folders)

    socket
    |> stream_delete(:conversations, conversation)
    |> assign(:unfiled_conversations, unfiled)
    |> assign(:folders, folders)
  end

  def handle_conversation_updated(socket, conversation) do
    # Treat soft-deleted conversations like destroyed ones
    if conversation.deleted_at do
      handle_conversation_destroyed(socket, conversation)
    else
      socket =
        if socket.assigns.conversation && socket.assigns.conversation.id == conversation.id do
          assign(socket, :conversation, conversation)
        else
          socket
        end

      unfiled =
        Enum.map(socket.assigns.unfiled_conversations, fn conv ->
          if conv.id == conversation.id, do: conversation, else: conv
        end)

      folders = Helpers.load_folders(socket.assigns.current_user, socket.assigns.expanded_folders)

      socket
      |> stream_insert(:conversations, conversation)
      |> assign(:unfiled_conversations, unfiled)
      |> assign(:folders, folders)
    end
  end

  # ============================================================================
  # Folder Broadcasts
  # ============================================================================

  def handle_folder_destroyed(socket, _folder) do
    folders = Helpers.load_folders(socket.assigns.current_user, socket.assigns.expanded_folders)
    unfiled = Magus.Chat.unfiled_conversations!(actor: socket.assigns.current_user)

    socket
    |> assign(:folders, folders)
    |> assign(:unfiled_conversations, unfiled)
  end

  def handle_folder_updated(socket, _folder) do
    folders = Helpers.load_folders(socket.assigns.current_user, socket.assigns.expanded_folders)
    unfiled = Magus.Chat.unfiled_conversations!(actor: socket.assigns.current_user)

    socket
    |> assign(:folders, folders)
    |> assign(:unfiled_conversations, unfiled)
  end

  # ============================================================================
  # Member Broadcasts
  # ============================================================================

  def handle_members_changed(socket, conversation_id) do
    if socket.assigns.conversation && socket.assigns.conversation.id == conversation_id do
      {members, is_owner} =
        Helpers.load_multiplayer_data(socket.assigns.conversation, socket.assigns.current_user)

      socket
      |> assign(:members, members)
      |> assign(:is_conversation_owner, is_owner)
    else
      socket
    end
  end

  # ============================================================================
  # Event Broadcasts
  # ============================================================================

  def handle_event_broadcast(socket, conversation_id, event) do
    if socket.assigns.conversation && socket.assigns.conversation.id == conversation_id do
      event = Ash.load!(event, [:user, :target_user], authorize?: false)
      stream_insert(socket, :messages, %{id: "event-#{event.id}", event: event}, at: 0)
    else
      socket
    end
  end

  # ============================================================================
  # Typing Broadcasts
  # ============================================================================

  def handle_thinking_broadcast(socket, conversation_id, thinking) do
    if socket.assigns.conversation && socket.assigns.conversation.id == conversation_id do
      assign(socket, :waiting_for_response, thinking)
    else
      socket
    end
  end

  def handle_user_typing(socket, conversation_id, user_id, payload, is_typing)
      when is_map(payload) do
    cond do
      not (socket.assigns.conversation &&
               socket.assigns.conversation.id == conversation_id) ->
        socket

      user_id == socket.assigns.current_user.id ->
        # Same user typing in another tab — don't render an indicator for self.
        socket

      true ->
        users_typing =
          if is_typing do
            Map.put(socket.assigns.users_typing, user_id, %{
              name: payload[:user_name] || payload["user_name"],
              avatar_path: payload[:avatar_path] || payload["avatar_path"],
              email: payload[:email] || payload["email"]
            })
          else
            Map.delete(socket.assigns.users_typing, user_id)
          end

        assign(socket, :users_typing, users_typing)
    end
  end

  # ============================================================================
  # Message Broadcasts
  # ============================================================================

  def handle_message_broadcast(socket, conversation_id, message) do
    if socket.assigns.conversation && socket.assigns.conversation.id == conversation_id do
      message =
        message
        |> maybe_load_created_by(socket)
        |> maybe_load_responding_agent()

      socket
      |> stream_insert(:messages, message, at: 0)
      |> update_streaming_state(message)
      |> maybe_clean_tracker(message)
      |> push_event("scroll_to_bottom", %{})
    else
      socket
    end
  end

  defp maybe_load_created_by(message, socket) do
    if Helpers.collaborative?(socket.assigns.conversation) do
      Helpers.ensure_created_by_loaded(message, socket.assigns.current_user)
    else
      message
    end
  end

  defp maybe_load_responding_agent(%Magus.Chat.Message{} = message) do
    if message.responding_agent_id do
      Ash.load!(message, [:responding_agent], authorize?: false)
    else
      message
    end
  end

  defp maybe_load_responding_agent(message) when is_map(message) do
    agent_id = Map.get(message, :responding_agent_id)

    if agent_id do
      case Magus.Agents.get_custom_agent(agent_id, authorize?: false) do
        {:ok, agent} -> Map.put(message, :responding_agent, agent)
        _ -> message
      end
    else
      message
    end
  end

  # Agent signals own all real-time UI state (thinking_status, is_streaming, etc.).
  # Ash PubSub messages only manage the message list — they do NOT modify thinking state.
  # The one exception is :job_trigger which comes from Ash, not agent signals.
  defp update_streaming_state(socket, message) do
    message_type = Map.get(message, :message_type, :message)

    cond do
      message_type in [:job_trigger, :draft_event] ->
        # Exception: job triggers and draft events come from Ash, not agent signals
        socket
        |> assign(:waiting_for_response, true)
        |> assign(:thinking_status, :thinking)
        |> assign(:triggering_message_id, message.id)

      message.source == :agent and message_type == :message ->
        # Only track message ID for stream targeting — agent signals own thinking state
        socket
        |> assign(:current_response_message_id, message.id)
        |> maybe_handle_message_complete(message)

      true ->
        socket
    end
  end

  defp maybe_handle_message_complete(socket, %{complete: true} = message) do
    if Helpers.has_displayable_content?(message) do
      socket
      |> assign(:is_streaming, false)
      |> assign(:current_response_message_id, nil)
    else
      socket
    end
  end

  defp maybe_handle_message_complete(socket, _message), do: socket

  # When a persisted event message arrives via Ash PubSub, remove its matching
  # tracker entry. The persisted message replaces the ephemeral stream entry
  # automatically (same ID), so we only need to clean up the tracker state.
  # Exception: deferred tools (spawn_sub_agent) that are still in_progress
  # must stay in the tracker to receive child relay events.
  defp maybe_clean_tracker(socket, %{message_type: :event, id: id}) do
    tracker = socket.assigns[:tool_event_tracker] || %{}

    case Map.get(tracker, id) do
      %{tool_name: tool_name, status: :in_progress}
      when tool_name in @deferred_tools ->
        # Keep tracker entry alive — child relay events still arriving.
        # Re-insert the ephemeral event so the live tracker state takes
        # precedence over the persisted DB message.
        stream_insert(socket, :messages, build_ephemeral_event(Map.get(tracker, id)), at: 0)

      nil ->
        socket

      _completed ->
        assign(socket, :tool_event_tracker, Map.delete(tracker, id))
    end
  end

  defp maybe_clean_tracker(socket, _message), do: socket

  # ============================================================================
  # Agent Signal Broadcasts (Jido-based)
  #
  # All signals arrive from Magus.Agents.Signals with atom keys.
  # Dispatched by type to update streaming state, tool events, and sub-steps.
  # ============================================================================

  @doc """
  Handles agent signals from the `agents:{conversation_id}` PubSub topic.

  Dispatches by signal type to the appropriate handler. All payloads use atom keys
  (produced by `Magus.Agents.Signals`).
  """
  def handle_agent_signal(socket, conversation_id, payload) when is_map(payload) do
    if matches_conversation?(socket, conversation_id) do
      case payload[:type] do
        # Turn lifecycle
        "turn.started" ->
          handle_turn_started(socket, payload)

        "turn.completed" ->
          handle_turn_completed(socket, payload)

        # Text streaming (delegated to AgentStreamHandlers)
        "text.chunk" ->
          AgentStreamHandlers.handle_text_chunk(socket, payload)

        "text.complete" ->
          AgentStreamHandlers.handle_text_complete(socket, payload)

        "thinking.chunk" ->
          AgentStreamHandlers.handle_thinking_chunk(socket, payload)

        # Agent state machine
        "state.change" ->
          handle_state_change(socket, payload.state)

        "response.complete" ->
          AgentStreamHandlers.handle_response_complete(socket, payload)

        "error" ->
          handle_error(socket, payload)

        # Context-window snapshot changed. Refetch the persisted row rather than
        # trusting the broadcast payload: the snapshot is written with string
        # keys while the signal may carry atom keys, so refetching keeps the
        # donut consistent with what message-history assembly will read.
        "context.updated" ->
          handle_context_updated(socket, conversation_id)

        # Agent run lifecycle (suppress when source_event_id is set — handled as tool steps)
        "run.started" ->
          if payload[:source_event_id], do: socket, else: handle_run_started(socket, payload)

        "run.progress" ->
          if payload[:source_event_id], do: socket, else: handle_run_progress(socket, payload)

        "run.completed" ->
          if payload[:source_event_id], do: socket, else: handle_run_completed(socket, payload)

        "run.failed" ->
          if payload[:source_event_id], do: socket, else: handle_run_failed(socket, payload)

        # Tool lifecycle (delegated to AgentStreamHandlers)
        "tool.start" ->
          AgentStreamHandlers.handle_tool_start(socket, payload)

        "tool.progress" ->
          AgentStreamHandlers.handle_tool_progress(socket, payload)

        "tool.complete" ->
          AgentStreamHandlers.handle_tool_complete(socket, payload)

        # UI hints (tool-initiated pane requests)
        #
        # Workbench LiveViews intercept "ui.open_brain_pane" before reaching
        # this canonical dispatcher (see
        # `MagusWeb.Workbench.Resources.ConversationView.handle_info/2` for
        # the broadcast-open-companion flow). The legacy `MagusWeb.ChatLive`
        # that used to call `BrainHandlers.maybe_open_brain_pane/3` here was
        # retired in Phase C5, so this branch is now a no-op fallthrough.
        "ui.open_brain_pane" ->
          socket

        # Tool sub-steps
        "tool.step.start" ->
          handle_tool_step_start(socket, payload)

        "tool.step.progress" ->
          handle_tool_step_progress(socket, payload)

        "tool.step.complete" ->
          handle_tool_step_complete(socket, payload)

        # Unknown signal — pass through
        _ ->
          socket
      end
    else
      socket
    end
  end

  def handle_agent_signal(socket, _conversation_id, _payload), do: socket

  # ============================================================================
  # Turn Lifecycle Handlers
  # ============================================================================

  defp handle_turn_started(socket, payload) do
    socket
    |> assign(:active_turn_id, payload[:turn_id])
    |> assign(:active_turn_iteration, payload[:iteration])
    |> assign(:active_turn_type, nil)
    |> assign(:waiting_for_response, true)
  end

  defp handle_turn_completed(socket, payload) do
    socket =
      socket
      |> assign(:active_turn_type, payload[:turn_type])

    if payload[:turn_type] == :tool_calls do
      socket
      |> assign(:is_streaming, false)
      |> assign(:waiting_for_response, true)
    else
      socket
    end
  end

  # ============================================================================
  # State Machine Handlers
  # ============================================================================

  defp handle_state_change(socket, state) when is_atom(state) do
    {waiting, thinking_status} = Helpers.derive_thinking_state(state)

    socket
    |> assign(:waiting_for_response, waiting)
    |> assign(:thinking_status, thinking_status)
    |> assign(:is_streaming, state == :streaming)
  end

  defp handle_state_change(socket, state) when is_binary(state) do
    handle_state_change(socket, String.to_existing_atom(state))
  rescue
    ArgumentError -> socket
  end

  defp handle_state_change(socket, _state), do: socket

  # Refetch the persisted context-window snapshot and re-assign it so the donut
  # re-renders. Passes the current user as the actor: the owner read policy
  # authorizes the conversation owner. On read failure the assign is unchanged.
  defp handle_context_updated(socket, conversation_id) do
    case Magus.Chat.get_context_window(conversation_id, actor: socket.assigns.current_user) do
      {:ok, cw} ->
        socket
        |> assign(:context_window, cw)
        |> Helpers.restream_floor_boundary()

      _ ->
        socket
    end
  end

  # Signals that the full agent response cycle is done (all iterations complete).
  def handle_response_complete(socket, _payload), do: do_response_complete(socket)

  defp do_response_complete(socket) do
    if Helpers.collaborative?(socket.assigns.conversation) do
      Helpers.broadcast_thinking_state(socket, false)
    end

    has_jobs =
      case Magus.Workflows.list_jobs_for_conversation(
             socket.assigns.conversation.id,
             actor: socket.assigns.current_user
           ) do
        {:ok, [_ | _]} -> true
        _ -> false
      end

    socket
    |> reset_streaming_state()
    |> assign(:has_jobs, has_jobs)
  end

  # Resets all streaming/thinking state. The error event message is already
  # inserted via create_event_message! + Ash PubSub — we only reset UI state.
  defp handle_error(socket, %{error_type: error_type, error_message: error_message}) do
    require Logger
    Logger.error("Agent error: #{error_type} - #{error_message}")

    socket
    |> reset_streaming_state()
    |> push_event("scroll_to_bottom", %{})
  end

  defp reset_streaming_state(socket) do
    # Preserve deferred tool events (e.g. spawn_sub_agent) that are still
    # waiting for child relay steps. Only clear completed/non-deferred entries.
    tracker = socket.assigns[:tool_event_tracker] || %{}

    surviving_tracker =
      Map.filter(tracker, fn {_id, event} ->
        event.tool_name in @deferred_tools and event.status == :in_progress
      end)

    socket
    |> assign(:waiting_for_response, false)
    |> assign(:is_streaming, false)
    |> assign(:agent_busy?, false)
    |> assign(:triggering_message_id, nil)
    |> assign(:current_response_message_id, nil)
    |> assign(:active_response_ids, MapSet.new())
    |> assign(:streaming_initialized_ids, MapSet.new())
    |> assign(:pending_mention_count, 0)
    |> assign(:tool_event_tracker, surviving_tracker)
    |> assign(:streaming_thinking, nil)
    |> assign(:streaming_thinking_message_id, nil)
    |> assign(:active_turn_id, nil)
    |> assign(:active_turn_iteration, nil)
    |> assign(:active_turn_type, nil)
  end

  # ============================================================================
  # Agent Run Handlers
  # ============================================================================

  defp handle_run_started(socket, payload) do
    run_event = %{
      id: payload[:run_id],
      tool_name: "agent_run",
      display_name: "Agent run",
      inputs: %{kind: payload[:kind], objective: payload[:objective]},
      status: :in_progress,
      progress_items: [],
      steps: [],
      started_at: DateTime.utc_now(),
      output_summary: nil,
      duration_ms: nil,
      error: nil
    }

    socket
    |> assign(:waiting_for_response, true)
    |> put_tracker(payload[:run_id], run_event)
    |> stream_insert(:messages, build_ephemeral_event(run_event), at: 0)
    |> push_event("scroll_to_bottom", %{})
  end

  defp handle_run_progress(socket, payload) do
    update_tool_event(socket, payload[:run_id], fn run_event ->
      progress_item = %{
        type: :run_progress,
        data: Map.drop(payload, [:type, :run_id]),
        timestamp: DateTime.utc_now()
      }

      %{run_event | progress_items: run_event.progress_items ++ [progress_item]}
    end)
  end

  defp handle_run_completed(socket, payload) do
    socket
    |> update_tool_event(payload[:run_id], fn run_event ->
      %{
        run_event
        | status: :complete,
          output_summary: payload[:result_text] || payload[:objective],
          error: nil
      }
    end)
    |> assign(:waiting_for_response, false)
  end

  defp handle_run_failed(socket, payload) do
    socket
    |> update_tool_event(payload[:run_id], fn run_event ->
      %{
        run_event
        | status: :error,
          output_summary: payload[:objective],
          error: payload[:error] || "Run failed"
      }
    end)
    |> assign(:waiting_for_response, false)
  end

  # ============================================================================
  # Tool Event Handlers
  #
  # Tool events render through the :messages stream (not a separate assign).
  # Each handler updates the tool_event_tracker (state accumulator), then
  # stream_inserts an ephemeral event. When the persisted Ash PubSub message
  # arrives with the same ID, stream_insert replaces the ephemeral entry
  # automatically — no custom deduplication needed.
  # ============================================================================

  def handle_tool_start(socket, payload) do
    tool_event = %{
      id: payload.event_id,
      tool_name: payload.tool_name,
      display_name: payload.display_name,
      inputs: payload[:inputs] || %{},
      status: :in_progress,
      progress_items: [],
      steps: [],
      started_at: DateTime.utc_now(),
      output_summary: nil,
      duration_ms: nil,
      error: nil
    }

    socket
    |> put_tracker(payload.event_id, tool_event)
    |> stream_insert(:messages, build_ephemeral_event(tool_event), at: 0)
    |> push_event("scroll_to_bottom", %{})
  end

  def handle_tool_progress(socket, payload) do
    progress_type = normalize_progress_type(payload.progress_type)

    update_tool_event(socket, payload.event_id, fn tool_event ->
      if progress_type == :output do
        # Accumulate streaming output chunks, capped at 100KB to prevent memory bloat
        chunk = get_in(payload, [:data, :chunk]) || ""
        existing = tool_event[:accumulated_output] || ""
        combined = existing <> chunk

        capped =
          if byte_size(combined) > 100_000 do
            "[earlier output truncated]\n" <>
              binary_part(combined, byte_size(combined) - 90_000, 90_000)
          else
            combined
          end

        Map.put(tool_event, :accumulated_output, capped)
      else
        progress_item = %{
          type: progress_type,
          data: payload[:data] || %{},
          timestamp: DateTime.utc_now()
        }

        %{tool_event | progress_items: tool_event.progress_items ++ [progress_item]}
      end
    end)
  end

  def handle_tool_complete(socket, payload) do
    socket =
      if payload.tool_name in @deferred_tools do
        # Keep card in_progress — child tool steps will accumulate on it.
        # The card completes when the final result step arrives via tool.step.complete.
        update_tool_event(socket, payload.event_id, fn tool_event ->
          %{tool_event | output_summary: payload[:output_summary]}
        end)
      else
        update_tool_event(socket, payload.event_id, fn tool_event ->
          %{
            tool_event
            | status: :complete,
              output_summary: payload[:output_summary],
              duration_ms: payload[:duration_ms],
              error: payload[:error]
          }
        end)
      end

    # Open service pane when start_service completes successfully
    if payload.tool_name == "start_service" and payload[:status] != :error do
      maybe_open_service_pane(socket, payload)
    else
      socket
    end
  end

  defp maybe_open_service_pane(socket, payload) do
    cond do
      # ConversationView doesn't have sidebar-pane assigns; Phase 3B will wire
      # companion-pane signals to handle service panes in a tab-scoped way.
      not Map.has_key?(socket.assigns, :active_service) ->
        socket

      # Don't steal focus from an already-open pane
      socket.assigns.pane != nil ->
        socket

      true ->
        # Extract service name from tool event tracker inputs
        tracker = socket.assigns[:tool_event_tracker] || %{}
        tool_event = Map.get(tracker, payload.event_id)
        service_name = get_in(tool_event, [:inputs, "name"]) || "service"

        MagusWeb.ChatLive.SandboxHandlers.handle_open_service_pane(socket, name: service_name)
    end
  end

  defp normalize_progress_type(type) when is_atom(type), do: type

  defp normalize_progress_type(type) when is_binary(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> :generic
  end

  defp normalize_progress_type(_), do: :generic

  # ============================================================================
  # Tool Sub-Step Handlers
  # ============================================================================

  defp handle_tool_step_start(socket, payload) do
    update_tool_event(socket, payload.event_id, fn tool_event ->
      step = %{
        id: payload.step_id,
        index: payload.step_index,
        label: payload.label,
        status: :in_progress,
        content: "",
        data: payload[:data] || %{},
        started_at: DateTime.utc_now()
      }

      %{tool_event | steps: tool_event.steps ++ [step]}
    end)
  end

  defp handle_tool_step_progress(socket, payload) do
    mode = payload[:mode] || :append
    content = payload[:content] || ""

    update_tool_event(socket, payload.event_id, fn tool_event ->
      updated_steps =
        Enum.map(tool_event.steps, fn step ->
          if step.id == payload.step_id do
            new_content =
              case mode do
                :replace -> content
                _append -> cap_step_content((step.content || "") <> content)
              end

            %{step | content: new_content}
          else
            step
          end
        end)

      %{tool_event | steps: updated_steps}
    end)
  end

  defp handle_tool_step_complete(socket, payload) do
    update_tool_event(socket, payload.event_id, fn tool_event ->
      step_status = payload[:status] || :complete

      updated_steps =
        Enum.map(tool_event.steps, fn step ->
          if step.id == payload.step_id do
            %{
              step
              | status: step_status,
                content: payload[:summary] || step.content
            }
          else
            step
          end
        end)

      # When the final result step arrives (from AgentRunCompletionPlugin),
      # also mark the parent card as complete.
      card_updates =
        if String.ends_with?(to_string(payload.step_id), "-step-result") do
          card_status = if step_status == :error, do: :error, else: :complete

          %{
            steps: updated_steps,
            status: card_status,
            output_summary: payload[:summary] || tool_event.output_summary
          }
        else
          %{steps: updated_steps}
        end

      Map.merge(tool_event, card_updates)
    end)
  end

  # ============================================================================
  # Tool Event Helpers
  # ============================================================================

  # Builds an ephemeral map shaped for the :messages stream.
  # Uses the same ID as the persisted event message, so stream_insert
  # replaces it automatically when the Ash PubSub message arrives.
  defp build_ephemeral_event(tool_event) do
    %{
      id: tool_event.id,
      message_type: :event,
      source: :agent,
      complete: tool_event.status == :complete,
      text: tool_event.display_name,
      inserted_at: tool_event.started_at,
      tool_call_data: tool_event
    }
  end

  # Looks up a tool event by event_id in the tracker, applies update_fn,
  # writes it back, and stream_inserts the updated ephemeral event.
  # Returns socket unchanged if the event_id is not found.
  defp update_tool_event(socket, event_id, update_fn) do
    tracker = socket.assigns[:tool_event_tracker] || %{}

    case Map.get(tracker, event_id) do
      nil ->
        socket

      tool_event ->
        updated = update_fn.(tool_event)

        socket =
          socket
          |> put_tracker(event_id, updated)
          |> stream_insert(:messages, build_ephemeral_event(updated), at: 0)

        # Deferred tools (e.g. spawn_sub_agent) have their own scrollable container
        # with AutoScrollContent, so skip main-view scroll to avoid fighting.
        if tool_event.tool_name in @deferred_tools do
          socket
        else
          push_event(socket, "scroll_to_bottom", %{})
        end
    end
  end

  defp put_tracker(socket, event_id, tool_event) do
    tracker = socket.assigns[:tool_event_tracker] || %{}
    assign(socket, :tool_event_tracker, Map.put(tracker, event_id, tool_event))
  end

  # Cap step content at 100KB to prevent socket memory bloat from long-running commands.
  @max_step_content 100_000

  defp cap_step_content(content) when byte_size(content) > @max_step_content do
    "[earlier output truncated]\n" <>
      binary_part(content, byte_size(content) - 90_000, 90_000)
  end

  defp cap_step_content(content), do: content
end
