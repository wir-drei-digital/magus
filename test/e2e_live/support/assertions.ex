defmodule Magus.LiveE2E.Assertions do
  @moduledoc """
  Assertion helpers for live E2E tests.

  All helpers match on Phoenix.Socket.Broadcast structs from PubSub
  with generous timeouts for real LLM API calls.
  """

  import ExUnit.Assertions

  @default_timeout 60_000

  @doc """
  Assert that streaming has started (at least one text.chunk received).
  Returns the payload of the first chunk.
  """
  def assert_streaming_started(timeout \\ 30_000) do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent_signal",
                     payload: %{type: "text.chunk"} = payload
                   },
                   timeout,
                   "Expected text.chunk signal within #{timeout}ms — LLM may not be responding"

    payload
  end

  @doc """
  Assert that the agent response completed.
  Returns the payload which contains message metadata.
  """
  def assert_response_complete(timeout \\ @default_timeout) do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent_signal",
                     payload: %{type: "response.complete"} = payload
                   },
                   timeout,
                   "Expected response.complete signal within #{timeout}ms"

    payload
  end

  @doc """
  Assert that a specific tool started execution.
  Returns the payload with event_id, tool_name, display_name, inputs.
  """
  def assert_tool_started(tool_name, timeout \\ @default_timeout) do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent_signal",
                     payload: %{type: "tool.start", tool_name: ^tool_name} = payload
                   },
                   timeout,
                   "Expected tool.start for #{tool_name} within #{timeout}ms"

    payload
  end

  @doc """
  Assert that a specific tool completed execution.
  Returns the payload with event_id, tool_name, status, output_summary.
  """
  def assert_tool_completed(tool_name, timeout \\ @default_timeout) do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent_signal",
                     payload: %{type: "tool.complete", tool_name: ^tool_name} = payload
                   },
                   timeout,
                   "Expected tool.complete for #{tool_name} within #{timeout}ms"

    payload
  end

  @doc """
  Assert that the agent entered a specific state.
  Common states: :thinking, :idle
  """
  def assert_state_change(expected_state, timeout \\ @default_timeout) do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent_signal",
                     payload: %{type: "state.change", state: ^expected_state}
                   },
                   timeout,
                   "Expected state.change to #{expected_state} within #{timeout}ms"
  end

  @doc """
  Assert that an error signal was received.
  Returns the payload with error_type and error_message.
  """
  def assert_error_signal(timeout \\ @default_timeout) do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent_signal",
                     payload: %{type: "error"} = payload
                   },
                   timeout,
                   "Expected error signal within #{timeout}ms"

    payload
  end

  @doc """
  Load and validate a persisted agent message by ID.
  Asserts the message exists, has role :agent, status :complete, and non-empty text.
  Returns the message.
  """
  def assert_valid_agent_message(message_id) do
    message = Magus.Chat.get_message!(message_id, authorize?: false)
    assert message.role == :agent, "Expected agent message, got #{message.role}"
    assert message.status == :complete, "Expected complete status, got #{message.status}"
    assert is_binary(message.text) and message.text != "", "Expected non-empty message text"
    message
  end

  @doc """
  Wait for response.complete, then validate the persisted message.
  Returns the validated message or payload.
  """
  def assert_complete_response(timeout \\ @default_timeout) do
    payload = assert_response_complete(timeout)
    message_id = extract_message_id(payload)

    if message_id do
      assert_valid_agent_message(message_id)
    else
      payload
    end
  end

  @doc """
  Drain all remaining PubSub messages from the mailbox.
  Useful for cleanup between test phases.
  """
  def drain_signals(timeout \\ 100) do
    receive do
      %Phoenix.Socket.Broadcast{event: "agent_signal"} ->
        drain_signals(timeout)
    after
      timeout -> :ok
    end
  end

  @doc """
  Find the latest agent message in a conversation.
  Retries a few times to handle async persistence lag after response.complete.
  """
  def latest_agent_message(conversation_id, retries \\ 10) do
    require Ash.Query

    result =
      Magus.Chat.Message
      |> Ash.Query.filter(conversation_id == ^conversation_id and role == :agent)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> List.first()

    case {result, retries} do
      {nil, n} when n > 0 ->
        Process.sleep(200)
        latest_agent_message(conversation_id, retries - 1)

      _ ->
        result
    end
  end

  defp extract_message_id(%{message_id: id}) when is_binary(id), do: id
  defp extract_message_id(%{triggering_message_id: id}) when is_binary(id), do: id
  defp extract_message_id(_), do: nil
end
