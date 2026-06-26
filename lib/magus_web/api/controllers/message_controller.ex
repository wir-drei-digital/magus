defmodule MagusWeb.Api.MessageController do
  use MagusWeb, :controller

  require Logger

  alias Magus.Integrations
  alias Magus.Chat
  alias Magus.Integrations.Providers.Api, as: ApiProvider
  alias MagusWeb.Api.SseStreamer

  @non_streaming_timeout :timer.minutes(5)

  def create(conn, params) do
    integration = conn.assigns.api_integration
    user = conn.assigns.current_user

    with {:ok, parsed} <- ApiProvider.parse_request(params, []),
         {:ok, conversation_id, session_id, new_session} <-
           resolve_conversation(integration, user, parsed),
         :ok <- subscribe_to_agent(conversation_id),
         {:ok, input_message} <- create_input_message(integration, user, parsed) do
      # Dispatch the message to the agent asynchronously so that the response
      # loop (receive/SSE) is active before the first streaming chunk arrives.
      dispatch_message_async(input_message, conversation_id, parsed, user)

      if parsed["stream"] do
        stream_response(conn, conversation_id, session_id, new_session, parsed["verbosity"])
      else
        await_response(conn, conversation_id, session_id)
      end
    else
      {:error, :content_required} ->
        send_error(conn, 400, "invalid_request", "content is required")

      {:error, :usage_limit_exceeded} ->
        send_error(conn, 403, "usage_limit_exceeded", "PAYG spend limit reached")

      {:error, reason} ->
        Logger.error("API message error: #{inspect(reason)}")
        send_error(conn, 500, "internal_error", "An unexpected error occurred")
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Resolve or create a conversation from the session_id embedded in parsed.
  # Uses IntegrationConversation mappings to support multi-session (one per sender_id).
  defp resolve_conversation(integration, user, parsed) do
    session_id = parsed["sender_id"]

    case Integrations.get_integration_conversation_by_identifier(
           integration.id,
           session_id,
           actor: user
         ) do
      {:ok, ic} ->
        {:ok, ic.conversation_id, session_id, false}

      {:error, _} ->
        with {:ok, conversation} <- create_conversation(integration, user),
             {:ok, _ic} <-
               Integrations.create_integration_conversation(
                 %{
                   user_integration_id: integration.id,
                   conversation_id: conversation.id,
                   external_identifier: session_id
                 },
                 actor: user
               ) do
          {:ok, conversation.id, session_id, true}
        end
    end
  end

  defp create_conversation(integration, user) do
    Chat.create_conversation(
      %{chat_mode: :chat, custom_agent_id: integration.custom_agent_id},
      actor: user
    )
  end

  defp subscribe_to_agent(conversation_id) do
    Phoenix.PubSub.subscribe(Magus.PubSub, "agents:#{conversation_id}")
    :ok
  end

  # Create an InputMessage record (does NOT trigger the agent).
  defp create_input_message(integration, user, parsed) do
    Integrations.create_input_message(
      %{
        user_id: user.id,
        user_integration_id: integration.id,
        provider_key: :api,
        message_type: :text,
        payload: parsed,
        raw_payload: parsed,
        dispatched: true
      },
      actor: user
    )
  end

  # Send the user message and mark the input as processed in a Task so that
  # the response loop (receive/SSE) is already active before the agent emits
  # its first streaming chunk. We skip DispatchInput because it re-resolves
  # the conversation independently and may route to a different one.
  defp dispatch_message_async(input_message, conversation_id, parsed, user) do
    topic = "agents:#{conversation_id}"

    Task.start(fn ->
      with {:ok, _message} <-
             Chat.send_user_message(
               %{
                 conversation_id: conversation_id,
                 text: parsed["text"],
                 metadata: %{
                   "source" => "integration",
                   "provider_key" => "api",
                   "input_message_id" => input_message.id
                 }
               },
               actor: user
             ),
           _ <- Integrations.mark_input_processed(input_message, actor: user) do
        :ok
      else
        {:error, reason} ->
          Logger.error("API dispatch failed: #{inspect(reason)}")

          Magus.Endpoint.broadcast(topic, "agent_signal", %{
            type: "error",
            message: "Failed to dispatch message"
          })
      end
    end)
  end

  defp stream_response(conn, conversation_id, session_id, new_session, verbosity) do
    allowed_events = ApiProvider.stream_event_types(verbosity)

    conn =
      SseStreamer.stream(conn, conversation_id,
        allowed_events: allowed_events,
        session_id: session_id,
        new_session: new_session
      )

    Phoenix.PubSub.unsubscribe(Magus.PubSub, "agents:#{conversation_id}")
    conn
  end

  defp await_response(conn, conversation_id, session_id) do
    result = accumulate_response(@non_streaming_timeout)
    Phoenix.PubSub.unsubscribe(Magus.PubSub, "agents:#{conversation_id}")

    case result do
      {:ok, content, message_id, usage} ->
        json(conn, %{
          "id" => message_id,
          "session_id" => session_id,
          "conversation_id" => conversation_id,
          "content" => content,
          # v1: tool_calls, citations, and attachments not yet populated from PubSub signals
          "citations" => [],
          "tool_calls" => [],
          "attachments" => [],
          "usage" => usage,
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:error, :timeout, message} ->
        send_error(conn, 504, "timeout", message)

      {:error, :agent_error, message} ->
        send_error(conn, 502, "agent_error", message)
    end
  end

  defp accumulate_response(timeout), do: accumulate_response("", nil, nil, timeout)

  defp accumulate_response(content, message_id, usage, timeout) do
    receive do
      %Phoenix.Socket.Broadcast{payload: payload} ->
        case payload do
          %{type: "text.chunk", message_id: id, delta: delta} ->
            accumulate_response(content <> delta, id || message_id, usage, timeout)

          # text.complete carries the full persisted text and usage — use it as
          # the authoritative source since early streaming chunks may be missed.
          %{type: "text.complete", message_id: id, text: full_text, usage: msg_usage} ->
            accumulate_response(full_text, id, msg_usage, timeout)

          %{type: "response.complete"} ->
            {:ok, content, message_id, format_usage(usage)}

          %{type: "error"} ->
            {:error, :agent_error, payload[:message] || "An error occurred"}

          _ ->
            accumulate_response(content, message_id, usage, timeout)
        end

      _other ->
        accumulate_response(content, message_id, usage, timeout)
    after
      timeout ->
        {:error, :timeout, "Request timed out"}
    end
  end

  defp format_usage(nil), do: nil

  defp format_usage(usage) when is_map(usage) do
    %{
      "prompt_tokens" =>
        usage[:prompt_tokens] || usage["prompt_tokens"] ||
          usage[:input_tokens] || usage["input_tokens"],
      "completion_tokens" =>
        usage[:completion_tokens] || usage["completion_tokens"] ||
          usage[:output_tokens] || usage["output_tokens"]
    }
  end

  defp send_error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => %{"code" => code, "message" => message}})
  end
end
