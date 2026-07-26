defmodule MagusWeb.Cli.ChatSocket do
  @moduledoc """
  Raw WebSocket handler for `magus chat`. Authenticated at the HTTP upgrade
  (see ChatSocketController). One connection = one process = one identity; local
  tools and routing follow this connection, never the conversation.
  """

  @behaviour WebSock

  alias Magus.Agents.Tools.Remote.Catalog

  @registry Magus.Cli.ConnectionRegistry

  @impl true
  def init(state) do
    # state seeded by the controller: %{user: %User{}, token: %ApiToken{}}
    {:ok,
     Map.merge(%{session_id: nil, conversation_id: nil, accepted_tools: [], pending: %{}}, state)}
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

  defp handle_hello(msg, state) do
    session_id = msg["session_id"]
    advertised = get_in(msg, ["capabilities", "local_tools"]) || []
    accepted = Enum.filter(advertised, &Catalog.known?/1)

    case resolve_conversation(msg["conversation"], state.user) do
      {:ok, conversation} ->
        {:ok, _} = Registry.register(@registry, session_id, nil)
        Phoenix.PubSub.subscribe(Magus.PubSub, "agents:#{conversation.id}")

        state = %{
          state
          | session_id: session_id,
            conversation_id: conversation.id,
            accepted_tools: accepted
        }

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

  # --- chat : implemented in later tasks --------------------------------

  defp handle_chat(_msg, state), do: {:ok, state}

  # --- mcp_result : route the CLI's reply back to the waiting proxy ------

  defp handle_mcp_result(%{"call_id" => call_id} = msg, state) do
    case Map.pop(state.pending, call_id) do
      {nil, _pending} ->
        {:ok, state}

      {waiter, pending} ->
        send(waiter, {:mcp_result, call_id, msg["status"], msg["result"] || %{}, msg["error"]})
        {:ok, %{state | pending: pending}}
    end
  end

  defp handle_mcp_result(_msg, state), do: {:ok, state}

  # --- mcp_call : push the reverse-tunnel request to the CLI, track waiter

  @impl true
  def handle_info({:mcp_call, call_id, tool_name, params, from_pid}, state) do
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

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # --- helpers -----------------------------------------------------------

  defp error_frame(code, message) do
    {:text, Jason.encode!(%{"type" => "error", "v" => 1, "code" => code, "message" => message})}
  end
end
