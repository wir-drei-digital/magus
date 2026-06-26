defmodule MagusWeb.Workbench.Chat.AgentStreamHandlers do
  @moduledoc """
  Pure socket transforms that translate Jido agent PubSub payloads into
  LiveView assign/stream updates. Caller-agnostic: works for any LV that
  maintains the standard streaming assigns (`streams.messages`,
  `active_response_ids`, `streaming_thinking`, etc.).

  Originally lived at `MagusWeb.ChatLive.PubSubHandlers` — moved here so
  consumers don't have to import from a ChatLive-scoped module.
  """

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [push_event: 3, stream_insert: 4]

  alias MagusWeb.ChatLive.Helpers

  # Tools that return deferred results (fire-and-forget) stay in_progress
  # until child activity completes via tool.step signals.
  @deferred_tools ~w(spawn_sub_agent)

  # Throttle interval for re-rendering markdown during streaming (ms).
  @stream_render_interval_ms 100

  # Strip complete and in-progress ```action_cards blocks from streaming text
  # Cap step content at 100KB to prevent socket memory bloat from long-running commands.
  @action_cards_complete ~r/\n?```action_cards\s*\n.*?\n```/s
  @action_cards_partial ~r/\n?```action_cards[^`]*\z/s

  # ============================================================================
  # Text Streaming Handlers
  # ============================================================================

  def handle_text_chunk(socket, payload) do
    %{message_id: message_id, text: text} = payload

    initialized = socket.assigns[:streaming_initialized_ids] || MapSet.new()
    now = System.monotonic_time(:millisecond)

    if message_id not in initialized do
      # First chunk: create the DOM element and set streaming assigns.
      display_text = strip_action_cards_for_streaming(text)

      socket
      |> stream_insert(:messages, streaming_message(message_id, display_text, payload), at: 0)
      |> assign(:streaming_initialized_ids, MapSet.put(initialized, message_id))
      |> assign(:active_response_ids, MapSet.put(socket.assigns.active_response_ids, message_id))
      |> assign(:current_response_message_id, message_id)
      |> assign(:is_streaming, true)
      |> assign(:agent_busy?, true)
      |> assign(:waiting_for_response, false)
      |> assign(:streaming_last_render_at, now)
      |> push_event("scroll_to_bottom", %{})
    else
      # Subsequent chunks: re-render markdown at most every @stream_render_interval_ms.
      last_render = socket.assigns[:streaming_last_render_at] || 0

      if now - last_render >= @stream_render_interval_ms do
        display_text = strip_action_cards_for_streaming(text)

        socket
        |> stream_insert(:messages, streaming_message(message_id, display_text, payload), at: 0)
        |> assign(:streaming_last_render_at, now)
        |> push_event("scroll_to_bottom", %{})
      else
        socket
      end
    end
  end

  # Marks the end of one streaming iteration. Inserts the final server-rendered
  # HTML (with complete: true) so the template swaps from the streaming text
  # to fully formatted markdown. The persisted message arrives separately
  # via Ash PubSub and will replace this with the canonical version.
  def handle_text_complete(socket, payload) do
    active_ids = MapSet.delete(socket.assigns.active_response_ids, payload[:message_id])
    initialized = socket.assigns[:streaming_initialized_ids] || MapSet.new()

    display_text = strip_action_cards_for_streaming(payload[:text] || "")

    complete_message = %{
      id: payload[:message_id],
      text: display_text,
      source: :agent,
      message_type: :message,
      complete: true,
      inserted_at: DateTime.utc_now(),
      custom_agent_id: payload[:custom_agent_id],
      custom_agent_name: payload[:custom_agent_name]
    }

    socket
    |> assign(:active_response_ids, active_ids)
    |> assign(:streaming_initialized_ids, MapSet.delete(initialized, payload[:message_id]))
    |> assign(:is_streaming, MapSet.size(active_ids) > 0)
    |> assign(:current_response_message_id, nil)
    |> assign(:streaming_thinking, nil)
    |> assign(:streaming_thinking_message_id, nil)
    |> maybe_insert_complete_message(display_text, complete_message)
  end

  # A blank final answer has nothing to render. Skip the transient insert so we
  # don't paint an empty bubble — if the turn was in fact persistable, the
  # canonical row still arrives via Ash PubSub and renders normally.
  defp maybe_insert_complete_message(socket, "", _message), do: socket

  defp maybe_insert_complete_message(socket, _display_text, message) do
    stream_insert(socket, :messages, message, at: 0)
  end

  # Each chunk carries the full accumulated reasoning text, and the template
  # re-runs MDEx over the whole string per render. Throttle to the same
  # @stream_render_interval_ms as the text path so reasoning-heavy turns don't
  # re-parse + scroll on every token. The first chunk for a message (id change)
  # always renders so the thinking box appears immediately.
  def handle_thinking_chunk(socket, %{message_id: message_id, text: text}) do
    now = System.monotonic_time(:millisecond)
    new_message? = socket.assigns[:streaming_thinking_message_id] != message_id
    last_render = socket.assigns[:streaming_thinking_last_render_at] || 0

    if new_message? or now - last_render >= @stream_render_interval_ms do
      socket
      |> assign(:streaming_thinking, text)
      |> assign(:streaming_thinking_message_id, message_id)
      |> assign(:waiting_for_response, true)
      |> assign(:agent_busy?, true)
      |> assign(:streaming_thinking_last_render_at, now)
      |> push_event("scroll_to_bottom", %{})
    else
      socket
    end
  end

  # ============================================================================
  # Response Complete Handler
  # ============================================================================

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
    |> assign(:agent_busy?, true)
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
    if Map.has_key?(socket.assigns, :active_service) and socket.assigns.pane == nil do
      # Extract service name from tool event tracker inputs
      tracker = socket.assigns[:tool_event_tracker] || %{}
      tool_event = Map.get(tracker, payload.event_id)
      service_name = get_in(tool_event, [:inputs, "name"]) || "service"

      MagusWeb.ChatLive.SandboxHandlers.handle_open_service_pane(socket, name: service_name)
    else
      socket
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
  # Private Helpers
  # ============================================================================

  defp streaming_message(message_id, text, payload) do
    %{
      id: message_id,
      text: text,
      source: :agent,
      message_type: :message,
      complete: false,
      inserted_at: DateTime.utc_now(),
      custom_agent_id: payload[:custom_agent_id],
      custom_agent_name: payload[:custom_agent_name]
    }
  end

  # Resets all streaming/thinking state. The error event message is already
  # inserted via create_event_message! + Ash PubSub — we only reset UI state.
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

  # so raw JSON doesn't flash during streaming.
  # Order matters: complete blocks are stripped first, then any trailing partial block.
  defp strip_action_cards_for_streaming(text) when is_binary(text) do
    text
    |> String.replace(@action_cards_complete, "")
    |> String.replace(@action_cards_partial, "")
    |> String.trim_trailing()
  end

  defp strip_action_cards_for_streaming(text), do: text
end
