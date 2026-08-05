defmodule MagusWeb.Cli.ChatSocket do
  @moduledoc """
  Raw WebSocket handler for `magus chat`. Authenticated at the HTTP upgrade
  (see ChatSocketController). One connection = one process = one identity:
  local tools and reverse-tunnel routing follow the AUTHENTICATED user, never
  the conversation and never anything the client sends.

  Idle contract: the upgrade sets a 60s receive timeout. Bandit answers WS
  pings automatically, so a CLI that pings (or sends) at least once a minute
  stays connected; an idle connection is closed and must reconnect with a
  fresh `hello` (using `conversation.resume` to keep its conversation).

  Frame-size contract: the upgrade caps inbound frames at 1MB; Bandit CLOSES
  the connection on an oversize frame. `mcp_result` payloads (file content)
  must therefore stay comfortably under 1MB — the CLI truncates and sets
  `result.truncated` instead of sending more.
  """

  @behaviour WebSock

  alias Magus.Agents.Tools.Remote.Catalog
  alias Magus.Cli.ConnectionRegistry

  @impl true
  def init(state) do
    # state seeded by the controller: %{user: %User{}}
    {:ok, Map.merge(%{conversation_id: nil, accepted_tools: [], pending: %{}}, state)}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "hello"} = msg} -> handle_hello(msg, state)
      {:ok, %{"type" => "chat"} = msg} -> handle_chat(msg, state)
      {:ok, %{"type" => "mcp_result"} = msg} -> handle_mcp_result(msg, state)
      {:ok, _other} -> {:ok, state}
      {:error, _} -> {:push, error_frame("bad_frame", "Could not decode frame"), state}
    end
  end

  def handle_in(_other, state), do: {:ok, state}

  # --- hello -------------------------------------------------------------

  # One hello per connection: re-initialization would leak the previous
  # conversation subscription and duplicate the registry entry.
  defp handle_hello(_msg, %{conversation_id: conv_id} = state) when is_binary(conv_id) do
    {:push, error_frame("already_initialized", "hello already completed on this connection"),
     state}
  end

  defp handle_hello(msg, state) do
    advertised = get_in(msg, ["capabilities", "local_tools"]) || []
    accepted = Enum.filter(advertised, &Catalog.known?/1)

    case resolve_conversation(msg["conversation"], state.user) do
      {:ok, conversation} ->
        # Reverse-tunnel routing identity is the AUTHENTICATED user (set by
        # the controller at the upgrade) plus the server-resolved conversation.
        # Client-supplied ids play no part.
        :ok = ConnectionRegistry.register(state.user.id, conversation.id)
        Phoenix.PubSub.subscribe(Magus.PubSub, "agents:#{conversation.id}")

        state = %{state | conversation_id: conversation.id, accepted_tools: accepted}

        frame =
          Jason.encode!(%{
            "type" => "server_hello",
            "v" => 1,
            "conversation_id" => conversation.id,
            "accepted_tools" => accepted,
            "server_version" => to_string(Application.spec(:magus, :vsn))
          })

        {:push, {:text, frame}, state}

      {:error, _reason} ->
        {:push, error_frame("forbidden", "Conversation not found or not yours"), state}
    end
  end

  defp resolve_conversation(%{"resume" => id}, user) when is_binary(id) do
    Magus.Chat.get_conversation(id, actor: user)
  end

  defp resolve_conversation(_new, user) do
    Magus.Chat.create_conversation(%{chat_mode: :chat}, actor: user)
  end

  # --- chat : drive a turn via Chat.send_user_message -------------------

  defp handle_chat(%{"text" => text}, %{conversation_id: conv_id, user: user} = state)
       when is_binary(conv_id) and is_binary(text) do
    result =
      Magus.Chat.send_user_message(
        %{
          conversation_id: conv_id,
          text: text,
          # local_tools marks this turn as CLI-driven; the reverse tunnel
          # routes by the server-side acting_user_id, so metadata carries no
          # routing identity (there is nothing to forge).
          metadata: %{"local_tools" => state.accepted_tools}
        },
        actor: user
      )

    case result do
      {:ok, _} ->
        {:ok, state}

      # A pre-persistence failure (validation/auth) fires no broadcast, so the CLI
      # would receive zero events and wedge its draining state. Surface an error
      # frame to unblock the turn. Keep the message generic — never leak internals.
      {:error, _reason} ->
        {:push, error_frame("send_failed", "Could not start the turn"), state}
    end
  end

  # Both malformed shapes get an explicit error frame — a silent drop would
  # wedge the CLI's draining state exactly like the send_failed case above.
  defp handle_chat(_msg, %{conversation_id: nil} = state),
    do: {:push, error_frame("not_ready", "Send hello before chat"), state}

  defp handle_chat(_msg, state),
    do: {:push, error_frame("bad_frame", "chat requires a text field"), state}

  # --- mcp_result : route the CLI's reply back to the waiting proxy ------

  defp handle_mcp_result(%{"call_id" => call_id} = msg, state) do
    case Map.pop(state.pending, call_id) do
      {nil, _pending} ->
        {:ok, state}

      {waiter, pending} ->
        # Normalize the untrusted wire shape at this boundary so the waiting
        # proxy tool can never crash on it (a raise would be classified as
        # retryable by the ReAct loop and re-prompt the user's machine).
        send(
          waiter,
          {:mcp_result, call_id, normalize_status(msg["status"]), normalize_result(msg["result"]),
           normalize_error(msg["error"])}
        )

        {:ok, %{state | pending: pending}}
    end
  end

  defp handle_mcp_result(_msg, state), do: {:ok, state}

  defp normalize_status(status) when status in ["ok", "denied", "error"], do: status
  defp normalize_status(_), do: "error"

  defp normalize_result(%{} = result), do: result
  defp normalize_result(_), do: %{}

  defp normalize_error(%{} = error), do: error
  defp normalize_error(error) when is_binary(error), do: %{"message" => error}
  defp normalize_error(_), do: nil

  # --- agent_signal : map PubSub broadcasts to chat_stream frames -------

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "agent_signal", payload: payload}, state) do
    case map_signal(payload) do
      nil -> {:ok, state}
      {event, data} -> {:push, {:text, chat_stream_frame(event, data)}, state}
    end
  end

  # --- mcp_call : push the reverse-tunnel request to the CLI, track waiter

  def handle_info({:mcp_call, call_id, tool_name, params, from_pid}, state) do
    # Monitor the waiter so calls whose tool timed out (the runner task dies at
    # the end of the turn) never leave dead entries in `pending` for the
    # connection's lifetime — see the :DOWN clause below.
    Process.monitor(from_pid)

    frame =
      Jason.encode!(%{
        "type" => "mcp_call",
        "v" => 1,
        "call_id" => call_id,
        "tool_name" => tool_name,
        "params" => params
      })

    {:push, {:text, frame}, %{state | pending: Map.put(state.pending, call_id, from_pid)}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    pending = state.pending |> Enum.reject(fn {_id, waiter} -> waiter == pid end) |> Map.new()
    {:ok, %{state | pending: pending}}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # --- helpers -----------------------------------------------------------

  # CAVEAT: use the BROADCAST field names below (error_message, triggering_message_id,
  # output_summary), NOT SseStreamer's payload[:message] / payload[:message_id] reads —
  # those keys do not exist on the agent's broadcasts and resolve to nil. SseStreamer
  # itself has this latent bug; do not mirror its field access, only its structure.
  defp map_signal(%{type: "text.chunk"} = p),
    do: {"text.delta", %{"delta" => p[:delta], "message_id" => p[:message_id]}}

  defp map_signal(%{type: "text.complete"} = p),
    do: {"text.done", %{"text" => p[:text], "message_id" => p[:message_id]}}

  defp map_signal(%{type: "tool.start"} = p),
    do:
      {"tool.start",
       %{"event_id" => p[:event_id], "tool_name" => p[:tool_name], "inputs" => p[:inputs]}}

  defp map_signal(%{type: "tool.complete"} = p),
    do:
      {"tool.complete",
       %{
         "event_id" => p[:event_id],
         "tool_name" => p[:tool_name],
         "status" => to_string(p[:status]),
         "summary" => p[:output_summary]
       }}

  defp map_signal(%{type: "response.complete"} = p),
    do: {"turn.done", %{"message_id" => p[:triggering_message_id]}}

  defp map_signal(%{type: "error"} = p),
    do: {"error", %{"message" => p[:error_message]}}

  defp map_signal(_), do: nil

  defp chat_stream_frame(event, data) do
    Jason.encode!(%{"type" => "chat_stream", "v" => 1, "event" => event, "data" => data})
  end

  defp error_frame(code, message) do
    {:text, Jason.encode!(%{"type" => "error", "v" => 1, "code" => code, "message" => message})}
  end
end
