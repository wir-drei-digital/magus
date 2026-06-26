defmodule MagusWeb.Api.SseStreamer do
  @moduledoc """
  Streams PubSub signals as Server-Sent Events over a chunked HTTP connection.
  Subscribes to the agent PubSub topic, filters events by verbosity,
  and formats them as SSE `data:` lines.
  """

  require Logger

  @default_timeout :timer.minutes(5)

  @doc """
  Stream agent events to the client as SSE.
  Blocks until response.complete, error, or timeout.
  """
  def stream(conn, conversation_id, opts \\ []) do
    allowed_events = Keyword.fetch!(opts, :allowed_events)
    session_id = Keyword.fetch!(opts, :session_id)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    new_session = Keyword.get(opts, :new_session, false)

    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
      |> Plug.Conn.send_chunked(200)

    conn =
      if new_session do
        send_event(conn, %{
          "event" => "session.created",
          "session_id" => session_id,
          "conversation_id" => conversation_id
        })
      else
        conn
      end

    receive_loop(conn, allowed_events, timeout)
  end

  defp receive_loop(conn, allowed_events, timeout) do
    receive do
      %Phoenix.Socket.Broadcast{payload: payload} ->
        handle_payload(conn, payload, allowed_events, timeout)

      _other ->
        receive_loop(conn, allowed_events, timeout)
    after
      timeout ->
        conn =
          send_event(conn, %{
            "event" => "error",
            "message" => "Request timed out"
          })

        send_done(conn)
    end
  end

  defp handle_payload(conn, payload, allowed_events, timeout) do
    case payload do
      %{type: "text.chunk", message_id: id, delta: delta} ->
        conn =
          maybe_send(conn, allowed_events, "text.chunk", %{
            "event" => "text.chunk",
            "message_id" => id,
            "delta" => delta
          })

        receive_loop(conn, allowed_events, timeout)

      %{type: "thinking.chunk", delta: delta} ->
        conn =
          maybe_send(conn, allowed_events, "thinking.chunk", %{
            "event" => "thinking.chunk",
            "delta" => delta
          })

        receive_loop(conn, allowed_events, timeout)

      %{type: "tool.start"} ->
        conn =
          maybe_send(conn, allowed_events, "tool.started", %{
            "event" => "tool.started",
            "name" => payload[:tool_name] || payload[:name],
            "display_name" => payload[:display_name]
          })

        receive_loop(conn, allowed_events, timeout)

      %{type: "tool.progress"} ->
        conn =
          maybe_send(conn, allowed_events, "tool.progress", %{
            "event" => "tool.progress",
            "name" => payload[:tool_name] || payload[:name],
            "status" => payload[:status] || payload[:message]
          })

        receive_loop(conn, allowed_events, timeout)

      %{type: "tool.complete"} ->
        conn =
          maybe_send(conn, allowed_events, "tool.completed", %{
            "event" => "tool.completed",
            "name" => payload[:tool_name] || payload[:name],
            "summary" => payload[:summary]
          })

        receive_loop(conn, allowed_events, timeout)

      %{type: "turn.started"} ->
        conn =
          maybe_send(conn, allowed_events, "message.started", %{
            "event" => "message.started",
            "message_id" => payload[:message_id]
          })

        receive_loop(conn, allowed_events, timeout)

      %{type: "response.complete"} ->
        conn =
          maybe_send(conn, allowed_events, "message.completed", %{
            "event" => "message.completed",
            "message_id" => payload[:message_id],
            "usage" => format_usage(payload[:usage])
          })

        send_done(conn)

      %{type: "error"} ->
        conn =
          send_event(conn, %{
            "event" => "error",
            "message" => payload[:message] || "An error occurred"
          })

        send_done(conn)

      _ ->
        receive_loop(conn, allowed_events, timeout)
    end
  end

  defp maybe_send(conn, allowed_events, event_type, data) do
    if event_type in allowed_events do
      send_event(conn, data)
    else
      conn
    end
  end

  defp send_event(conn, data) do
    chunk = "data: #{Jason.encode!(data)}\n\n"

    case Plug.Conn.chunk(conn, chunk) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp send_done(conn) do
    case Plug.Conn.chunk(conn, "data: [DONE]\n\n") do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp format_usage(nil), do: nil

  defp format_usage(usage) when is_map(usage) do
    %{
      "prompt_tokens" => usage[:prompt_tokens] || usage["prompt_tokens"],
      "completion_tokens" => usage[:completion_tokens] || usage["completion_tokens"]
    }
  end
end
