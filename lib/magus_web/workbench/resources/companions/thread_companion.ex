defmodule MagusWeb.Workbench.Resources.Companions.ThreadCompanion do
  @moduledoc """
  LiveView wrapper around the existing `ThreadPaneComponent`. Mounted via
  `live_render` from `TabContainer` when a tab's companion is a thread.

  Receives in session:
    - `"thread_id"` — UUID of the thread conversation
    - `"conversation_id"` — parent conversation UUID
    - `"user_id"` — UUID of the current user
    - `"tab_id"` — workbench tab id (for broadcasting :close_companion back)

  Owns:
    - Thread data loading (conversation + messages)
    - Subscriptions to `"agents:\#{thread_id}"` and `"chat:messages:\#{thread_id}"`
      for real-time streaming and message broadcasts
  """
  use MagusWeb, :live_view

  alias MagusWeb.ChatLive.Components.ChatInput.ChatInputComponent
  alias MagusWeb.ChatLive.Components.Threads.ThreadPaneComponent
  alias MagusWeb.Workbench.Signals
  alias Magus.Chat

  @impl true
  def mount(_params, session, socket) do
    thread_id = session["thread_id"]
    conversation_id = session["conversation_id"]
    user_id = session["user_id"]
    tab_id = session["tab_id"]

    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    case Chat.get_conversation(thread_id,
           actor: user,
           load: [:branched_at_message, :parent_conversation, :is_collaborative]
         ) do
      {:ok, thread} ->
        messages = load_thread_messages(thread, user)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Magus.PubSub, "agents:#{thread_id}")
          Magus.Endpoint.subscribe("chat:messages:#{thread_id}")
        end

        chat_models = load_chat_models()

        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:thread, thread)
         |> assign(:branched_at_message, thread.branched_at_message)
         |> assign(:conversation_id, conversation_id)
         |> assign(:tab_id, tab_id)
         |> assign(:is_streaming, false)
         |> assign(:waiting_for_response, false)
         |> assign(:models, chat_models)
         |> assign(:selected_model_id, nil)
         |> assign(:selected_chat_model_id, nil)
         |> assign(:selected_image_model_id, nil)
         |> assign(:selected_video_model_id, nil)
         |> assign(:chat_mode, thread.chat_mode || :chat)
         |> assign(:message_form, build_message_form(thread, user))
         |> stream(:thread_messages, messages)}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:thread, nil)
         |> assign(:branched_at_message, nil)
         |> assign(:conversation_id, conversation_id)
         |> assign(:tab_id, tab_id)
         |> assign(:is_streaming, false)
         |> assign(:waiting_for_response, false)
         |> assign(:models, [])
         |> assign(:selected_model_id, nil)
         |> assign(:selected_chat_model_id, nil)
         |> assign(:selected_image_model_id, nil)
         |> assign(:selected_video_model_id, nil)
         |> assign(:chat_mode, :chat)
         |> assign(:message_form, nil)
         |> stream(:thread_messages, [])}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      data-thread-companion
      data-thread-id={if @thread, do: @thread.id, else: nil}
      class="h-full flex flex-col"
    >
      <.live_component
        :if={@thread}
        module={ThreadPaneComponent}
        id={"thread-companion-#{@thread.id}"}
        thread={@thread}
        branched_at_message={@branched_at_message}
        thread_messages={@streams.thread_messages}
        current_user={@current_user}
        models={@models}
        selected_model_id={@selected_model_id}
        selected_chat_model_id={@selected_chat_model_id}
        selected_image_model_id={@selected_image_model_id}
        selected_video_model_id={@selected_video_model_id}
        chat_mode={@chat_mode}
        message_form={@message_form}
        waiting_for_response={@waiting_for_response}
        is_streaming={@is_streaming}
      />
      <div :if={!@thread} class="flex-1 flex items-center justify-center text-wb-text-muted">
        <p>Thread not found.</p>
      </div>
    </div>
    """
  end

  # Magus.Agents.Signals.broadcast/2 wraps payloads via Magus.Endpoint.broadcast,
  # which delivers a Phoenix.Socket.Broadcast struct. Unwrap once and re-send the
  # inner payload so the per-type clauses below match.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "agents:" <> _, payload: payload},
        socket
      ) do
    send(self(), payload)
    {:noreply, socket}
  end

  def handle_info(%{type: "text.chunk"} = payload, socket) do
    %{message_id: message_id, text: text} = payload

    streaming_message = %{
      id: message_id,
      text: text,
      source: :agent,
      message_type: :message,
      complete: false,
      inserted_at: DateTime.utc_now(),
      custom_agent_id: payload[:custom_agent_id],
      custom_agent_name: payload[:custom_agent_name]
    }

    {:noreply,
     socket
     |> stream_insert(:thread_messages, streaming_message)
     |> assign(:is_streaming, true)
     |> assign(:waiting_for_response, false)}
  end

  def handle_info(%{type: "text.complete"}, socket) do
    {:noreply, assign(socket, :is_streaming, false)}
  end

  # ThreadCompanion processes a lean signal set (no turn.started/turn.completed),
  # so it derives "busy" straight from the agent state rather than via
  # Helpers.derive_thinking_state/1, which maps :running_tools/:running to "not
  # waiting" on the assumption that the turn lifecycle drives the tool
  # indicator. Here, any non-:idle state means the agent is working — including
  # :reasoning / :generating_image / :generating_video, which the previous
  # hardcoded [:thinking, :planning, :running_tools] list silently dropped, so
  # the thinking indicator vanished during reasoning and media generation.
  # `is_streaming` is owned by the text.chunk / text.complete handlers; the old
  # `state == :streaming` branch was dead (no :streaming state is ever emitted).
  def handle_info(%{type: "state.change"} = payload, socket) do
    {:noreply, assign(socket, :waiting_for_response, normalize_state(payload.state) != :idle)}
  end

  def handle_info(%{type: "response.complete"}, socket) do
    {:noreply,
     socket
     |> assign(:is_streaming, false)
     |> assign(:waiting_for_response, false)}
  end

  def handle_info(%{type: "tool.start"} = payload, socket) do
    tool_event = %{
      id: payload.event_id,
      source: :agent,
      message_type: :event,
      text: "",
      inserted_at: DateTime.utc_now(),
      tool_call_data: %{
        "tool_name" => payload.tool_name,
        "display_name" => payload[:display_name],
        "status" => "in_progress",
        "inputs" => payload[:inputs] || %{}
      }
    }

    {:noreply, stream_insert(socket, :thread_messages, tool_event)}
  end

  def handle_info(%{type: "tool.complete"} = payload, socket) do
    tool_event = %{
      id: payload.event_id,
      source: :agent,
      message_type: :event,
      text: "",
      inserted_at: DateTime.utc_now(),
      tool_call_data: %{
        "tool_name" => payload.tool_name,
        "display_name" => payload[:display_name],
        "status" => "complete",
        "output_summary" => payload[:output_summary],
        "duration_ms" => payload[:duration_ms]
      }
    }

    {:noreply, stream_insert(socket, :thread_messages, tool_event)}
  end

  def handle_info(%{type: "tool.progress"}, socket), do: {:noreply, socket}

  # `:create` and `:send_user_message` both publish to `chat:messages:<id>`
  # via Ash.Notifier.PubSub; the broadcast event name is the action name. Pick
  # up either so user messages appear in the stream without a page reload.
  def handle_info(
        %Phoenix.Socket.Broadcast{event: event, payload: %{data: message}},
        socket
      )
      when event in ["created", "create", "send_user_message"] do
    message = reload_full_message(message, socket.assigns.current_user)

    case message do
      nil -> {:noreply, socket}
      msg -> {:noreply, stream_insert(socket, :thread_messages, msg)}
    end
  end

  # Thread input → send a user message in the thread conversation.
  # ChatInputComponent runs inside ThreadPaneComponent (a LiveComponent) which
  # is hosted by this LV, so its `notify_parent` lands here. The thread variant
  # of the input fires `:send_thread_message_with_resources` (the main variant
  # fires `:send_message_with_resources`); without this clause both tuples were
  # silently swallowed by the `_unhandled` catch-all.
  def handle_info(
        {ChatInputComponent, {:send_thread_message_with_resources, params, uploaded_resources}},
        %{assigns: %{thread: %{} = thread}} = socket
      ) do
    text = params["text"] || ""

    if String.trim(text) == "" and uploaded_resources == [] do
      {:noreply, socket}
    else
      result =
        Magus.Chat.send_user_message(
          %{
            text: text,
            mode: parse_mode(params["mode"]) || thread.chat_mode || :chat,
            selected_model_id: params["selected_model_id"],
            conversation_id: thread.id,
            resources: uploaded_resources
          },
          actor: socket.assigns.current_user
        )

      case result do
        {:ok, message} ->
          full_message = reload_full_message(message, socket.assigns.current_user) || message

          {:noreply,
           socket
           |> stream_insert(:thread_messages, full_message)
           |> assign(:waiting_for_response, true)
           |> assign(:message_form, build_message_form(thread, socket.assigns.current_user))
           |> push_event("clear_message_input", %{target: "thread-chat-textarea"})
           |> push_event("scroll_to_bottom", %{force: true})}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not send message. Please try again.")}
      end
    end
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_thread_pane", _params, socket) do
    Signals.broadcast_close_companion(socket.assigns.tab_id)
    {:noreply, socket}
  end

  # Inline message-action buttons render with `phx-target={@target}`; the thread
  # renderer doesn't set `@target`, so these events bubble to this LV. Mirror
  # the behaviour of `MessageStreamComponent.handle_event/3` so the actions
  # (toggle, retry, create prompt) work the same inside a thread.

  def handle_event("toggle_message_disabled", %{"message-id" => message_id}, socket) do
    user = socket.assigns.current_user

    socket =
      with {:ok, message} <- Magus.Chat.get_message(message_id, actor: user),
           {:ok, updated} <- Magus.Chat.toggle_message_disabled(message, actor: user) do
        full = reload_full_message(updated, user) || updated
        stream_insert(socket, :thread_messages, full)
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("retry_message", %{"message-id" => message_id}, socket) do
    user = socket.assigns.current_user

    with {:ok, message} <- Magus.Chat.get_message(message_id, actor: user),
         {:ok, _} <-
           Magus.Chat.send_user_message(
             %{
               text: message.text,
               mode: message.mode,
               selected_model_id: message.selected_model_id,
               conversation_id: socket.assigns.thread.id,
               metadata: message.metadata || %{}
             },
             actor: user
           ) do
      {:noreply, assign(socket, :waiting_for_response, true)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Could not retry message.")}
    end
  end

  def handle_event("create_prompt_from_message", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :info,
       "Open this message in the main chat to create a prompt from it."
     )}
  end

  def handle_event("stop_response", _params, socket) do
    thread = socket.assigns[:thread]

    if thread do
      case Jido.Agent.InstanceManager.lookup(:conversations, "conv:#{thread.id}") do
        {:ok, pid} ->
          signal = Jido.Signal.new!("message.cancel", %{conversation_id: thread.id})
          Jido.AgentServer.cast(pid, signal)

        :error ->
          :ok
      end

      event_message =
        Magus.Chat.create_event_message!(
          gettext("Response cancelled"),
          thread.id,
          authorize?: false
        )

      {:noreply,
       socket
       |> stream_insert(:thread_messages, event_message)
       |> assign(:waiting_for_response, false)
       |> assign(:is_streaming, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(_unhandled, _params, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if thread = socket.assigns[:thread] do
      Phoenix.PubSub.unsubscribe(Magus.PubSub, "agents:#{thread.id}")
      Magus.Endpoint.unsubscribe("chat:messages:#{thread.id}")
    end

    :ok
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp load_thread_messages(thread, user) do
    # `message_history` sorts newest-first; we want chronological (oldest at
    # top, newest at bottom) for the rendered stream.
    case Chat.message_history(thread.id, actor: user, page: [limit: 50]) do
      {:ok, %{results: messages}} -> Enum.reverse(messages)
      {:ok, messages} when is_list(messages) -> Enum.reverse(messages)
      _ -> []
    end
  end

  defp load_chat_models do
    all_models = Magus.Chat.list_active_models!()
    Enum.filter(all_models, fn m -> :text in (m.output_modalities || []) end)
  end

  defp build_message_form(thread, user) do
    Magus.Chat.form_to_create_message(
      actor: user,
      params: %{"conversation_id" => thread.id}
    )
    |> to_form()
  end

  defp reload_full_message(message, user) do
    case Chat.get_message(message.id, actor: user, load: [:responding_agent]) do
      {:ok, full_message} -> full_message
      _ -> nil
    end
  end

  defp normalize_state(state) when is_atom(state), do: state

  defp normalize_state(state) when is_binary(state) do
    String.to_existing_atom(state)
  rescue
    ArgumentError -> :unknown
  end

  defp normalize_state(_), do: :unknown

  defp parse_mode("image_generation"), do: :image_generation
  defp parse_mode("video_generation"), do: :video_generation
  defp parse_mode("search"), do: :search
  defp parse_mode("reasoning"), do: :reasoning
  defp parse_mode("chat"), do: :chat
  defp parse_mode(_), do: nil
end
