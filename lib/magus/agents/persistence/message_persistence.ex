defmodule Magus.Agents.Persistence.MessagePersistence do
  @moduledoc """
  Handles message and tool result persistence for the LLM strategy.

  Responsible for:
  - Persisting assistant responses
  - Persisting media generation responses (images/videos)
  - Persisting tool execution results as event messages
  """

  require Logger

  alias Magus.Agents.Context.ConversationState, as: State

  @doc """
  Persists a text response message.
  Takes a pre-computed reasoning_summary to avoid circular dependency.
  """
  def persist_response(%State{} = state, reasoning_summary) do
    # Store tool_calls on assistant message so cross-turn context can pair
    # tool_use blocks with their tool_result messages
    tool_call_data =
      if state.pending_tool_calls != [] do
        %{
          tool_calls:
            Enum.map(state.pending_tool_calls, fn tc ->
              %{id: tc.id, name: tc.name, arguments: tc.arguments}
            end)
        }
      else
        nil
      end

    metadata =
      if state.action_cards do
        %{"action_cards" => state.action_cards}
      else
        %{}
      end

    attrs = %{
      id: state.current_message_id,
      conversation_id: state.conversation_id,
      response_to_id: sanitize_uuid(state.parent_message_id),
      text: state.accumulated_text,
      complete: true,
      model_name: state.model_record.name,
      mode: state.mode,
      citations: state.citations || [],
      reasoning_summary: reasoning_summary,
      reasoning_details: state.reasoning_details || [],
      tool_call_data: tool_call_data,
      responding_agent_id: state.custom_agent_id,
      metadata: metadata,
      attachments: state.attachments || []
    }

    case Magus.Chat.Message
         |> Ash.Changeset.for_create(:upsert_response, attrs,
           actor: %Magus.Agents.Support.AiAgent{}
         )
         |> Ash.create() do
      {:ok, _message} ->
        Logger.debug("Response persisted: #{state.current_message_id}")

      {:error, error} ->
        Logger.error("Failed to persist response: #{inspect(error)}")
    end
  end

  @doc """
  Persists a media (image/video) response message with attachments.
  """
  def persist_media_response(%State{} = state, attachments) do
    attrs = %{
      id: state.current_message_id,
      conversation_id: state.conversation_id,
      response_to_id: sanitize_uuid(state.parent_message_id),
      text: state.accumulated_text,
      complete: true,
      model_name: state.model_record.name,
      mode: state.mode,
      attachments: attachments
    }

    case Magus.Chat.Message
         |> Ash.Changeset.for_create(:upsert_response, attrs,
           actor: %Magus.Agents.Support.AiAgent{}
         )
         |> Ash.create() do
      {:ok, _message} ->
        Logger.debug("Media response persisted: #{state.current_message_id}")

      {:error, error} ->
        Logger.error("Failed to persist media response: #{inspect(error)}")
    end
  end

  @doc """
  Persists a tool result as an event message.
  Takes a pre-computed output_summary to avoid circular dependency.
  """
  def persist_tool_result(
        event_id,
        tool_use_id,
        tool_name,
        display_name,
        inputs,
        result,
        status,
        output_summary,
        conversation_id
      ) do
    text =
      case status do
        :success -> "#{display_name} completed"
        :error -> "#{display_name} failed"
        :cancelled -> "#{display_name} cancelled"
      end

    tool_call_data = %{
      id: event_id,
      tool_use_id: tool_use_id,
      status: status,
      tool_name: tool_name,
      display_name: display_name,
      inputs: inputs,
      output: result,
      output_summary: output_summary
    }

    Magus.Chat.upsert_event_message!(
      event_id,
      text,
      conversation_id,
      tool_call_data,
      true,
      authorize?: false
    )
  end

  @doc """
  Recursively sanitize values to ensure valid UTF-8 for JSON encoding.
  Tool output (e.g. pdfTeX, sandbox stdout) may contain Latin-1 or other
  non-UTF-8 bytes that cause Jason.EncodeError. Also strips null bytes
  which PostgreSQL JSONB does not allow in string values.
  """
  def sanitize_for_json(value) when is_binary(value) do
    value
    |> String.replace(<<0>>, "")
    |> ensure_valid_utf8()
  end

  def sanitize_for_json(%_{} = struct) do
    to_string(struct)
  end

  def sanitize_for_json(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, sanitize_for_json(v)} end)
  end

  def sanitize_for_json(value) when is_list(value) do
    Enum.map(value, &sanitize_for_json/1)
  end

  def sanitize_for_json(value), do: value

  # Returns the value unchanged if it's a valid UUID, otherwise nil.
  # Prevents non-UUID strings (e.g. "subtask:...") from being set as response_to_id.
  defp sanitize_uuid(nil), do: nil

  defp sanitize_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> value
      :error -> nil
    end
  end

  defp sanitize_uuid(_), do: nil

  defp ensure_valid_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      case :unicode.characters_to_binary(binary, :latin1) do
        result when is_binary(result) ->
          result

        _ ->
          # Strip non-ASCII bytes as last resort (no /u flag — binary isn't valid UTF-8)
          for <<byte <- binary>>, byte < 128, into: "", do: <<byte>>
      end
    end
  end
end
