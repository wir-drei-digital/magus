defmodule Magus.Agents.Plugins.Support.Persistence do
  @moduledoc false
  # Builds ConversationState snapshots and delegates to MessagePersistence for
  # database writes (response messages and tool result events).

  require Logger

  alias Magus.Agents.Context.ConversationState, as: State
  alias Magus.Agents.Persistence.MessagePersistence
  alias Magus.Agents.Plugins.Support.AttachmentStash
  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Agents.Support.ActionCardExtractor
  alias Magus.Agents.Support.ToolCallText

  @doc """
  Persist the assistant's response message if there is something to persist.

  Returns `{:skipped, :empty}` when the turn carried no usable text, no tool
  calls and no attachments — the caller uses this to avoid broadcasting an
  empty `text.complete` (which paints a blank, traceless bubble in the UI) and
  to log the dropped turn. Returns `{:persisted, result}` otherwise.
  """
  def persist_response(agent, result, message_id, parent_message_id) do
    strategy_state = Helpers.get_strategy_state(agent)
    pending_tool_calls = resolve_pending_tool_calls(result, strategy_state)

    raw_text =
      response_text_from_result(result, strategy_state)
      |> ToolCallText.strip_pseudo_tool_payload()
      |> String.trim()

    {accumulated_text, action_cards} = ActionCardExtractor.extract(raw_text)
    attachments = AttachmentStash.drain()

    if accumulated_text == "" and pending_tool_calls == [] and attachments == [] do
      {:skipped, :empty}
    else
      citations = resolve_citations(result)

      conversation_state =
        build_conversation_state(
          agent,
          message_id,
          parent_message_id,
          accumulated_text,
          pending_tool_calls,
          citations,
          action_cards,
          attachments
        )

      reasoning_summary = resolve_reasoning_summary(result, strategy_state)

      {:persisted, MessagePersistence.persist_response(conversation_state, reasoning_summary)}
    end
  end

  @doc """
  Broadcast tool completion via PubSub and persist to database in one pass.

  Opts:
    * `:summary` — override for the output summary (used when the caller has
      already computed it from an unstripped result).
  """
  def broadcast_and_persist_tool_result(conversation_id, call_id, tool_name, result, opts \\ []) do
    tool_module = resolve_tool_module(tool_name)
    event_id = Helpers.tool_event_id_for_call_id(call_id)
    {status, derived_summary, error} = summarize_tool_result(tool_module, result)
    summary = Keyword.get(opts, :summary) || derived_summary

    Magus.Agents.Signals.broadcast_tool_complete(
      conversation_id,
      event_id,
      tool_name,
      status,
      summary,
      0,
      error
    )

    persist_tool_result(
      conversation_id,
      call_id,
      event_id,
      tool_name,
      tool_module,
      result,
      status,
      summary
    )
  end

  @doc "Persist a tool execution result as an event message."
  def persist_tool_result(
        conversation_id,
        call_id,
        event_id,
        tool_name,
        tool_module,
        result,
        status,
        output_summary
      ) do
    display_name = get_tool_display_name(tool_module, tool_name)
    inputs = %{}

    sanitized_result =
      case result do
        {:ok, data} -> MessagePersistence.sanitize_for_json(data)
        {:error, reason} -> MessagePersistence.sanitize_for_json(%{error: inspect(reason)})
        other -> MessagePersistence.sanitize_for_json(other)
      end

    MessagePersistence.persist_tool_result(
      event_id,
      call_id,
      tool_name,
      display_name,
      inputs,
      sanitized_result,
      status,
      output_summary,
      conversation_id
    )
  rescue
    e ->
      Logger.warning("Failed to persist tool result for #{tool_name}: #{Exception.message(e)}")
      :ok
  end

  @doc "Summarize a tool result into {status, summary, error} tuple."
  def summarize_tool_result(tool_module, {:ok, result}) when is_map(result) do
    summary = try_summarize_output(tool_module, result)
    {:success, summary, nil}
  end

  def summarize_tool_result(_tool_module, {:error, reason}) do
    {:error, nil, inspect(reason)}
  end

  def summarize_tool_result(_tool_module, result) do
    {:success, inspect(result), nil}
  end

  # --- Private ---

  defp build_conversation_state(
         agent,
         message_id,
         parent_message_id,
         accumulated_text,
         pending_tool_calls,
         citations,
         action_cards,
         attachments
       ) do
    state = agent.state || %{}
    strategy_state = Helpers.get_strategy_state(agent)
    mode = state[:mode] || :chat
    model_keys = state[:model_keys] || %{}
    model_key = effective_model_key(strategy_state, model_keys, mode)

    model_name =
      case strategy_state[:last_run_model_name] do
        nil -> model_key || "Default"
        "Default" -> model_key || "Default"
        name -> name
      end

    model = %{id: nil, key: model_key, name: model_name}

    %State{
      conversation_id: state[:conversation_id],
      # Attribute the agent reply to the member who sent the triggering message
      # (its parent), not the conversation owner (magus-k3at); owner fallback.
      user_id: Helpers.acting_user_id(agent, parent_message_id),
      mode: mode,
      model_keys: model_keys,
      model_record: model,
      current_message_id: message_id,
      parent_message_id: parent_message_id,
      accumulated_text: accumulated_text,
      accumulated_thinking: strategy_state[:streaming_thinking] || "",
      pending_tool_calls: pending_tool_calls,
      reasoning_details: [],
      citations: citations,
      custom_agent_id: state[:custom_agent_id],
      custom_agent_name: state[:custom_agent_name],
      action_cards: action_cards,
      attachments: attachments
    }
  end

  defp effective_model_key(strategy_state, model_keys, mode) do
    strategy_state[:last_run_model] || model_key_for_mode(model_keys, mode)
  end

  defp model_key_for_mode(model_keys, mode) when is_map(model_keys) do
    case mode do
      :image_generation -> model_keys[:image] || model_keys[:chat]
      :video_generation -> model_keys[:video] || model_keys[:chat]
      _ -> model_keys[:chat]
    end
  end

  defp model_key_for_mode(_, _), do: nil

  defp resolve_tool_module(tool_name) do
    Magus.Agents.Tools.ToolBuilder.skill_tool_mapping()
    |> Map.get(tool_name)
  end

  defp get_tool_display_name(nil, tool_name), do: "#{tool_name}"

  defp get_tool_display_name(module, tool_name) do
    if function_exported?(module, :display_name, 0) do
      module.display_name()
    else
      "#{tool_name}"
    end
  end

  defp try_summarize_output(module, result) do
    if module && function_exported?(module, :summarize_output, 1) do
      module.summarize_output(result)
    else
      cond do
        is_map(result) and Map.has_key?(result, :summary) -> result.summary
        is_map(result) and Map.has_key?(result, :result) -> inspect(result.result)
        true -> "Completed"
      end
    end
  end

  defp response_text_from_result(result, strategy_state) do
    case extract_result_text(result) do
      text when is_binary(text) and text != "" ->
        text

      _ ->
        strategy_state[:streaming_text] || ""
    end
  end

  defp extract_result_text({:ok, %{} = result}), do: extract_result_text(result)
  defp extract_result_text({:ok, %{} = result, _effects}), do: extract_result_text(result)

  defp extract_result_text(%{} = result) do
    Helpers.first_non_blank([
      result[:projected_text],
      result["projected_text"],
      result[:text],
      result["text"]
    ])
  end

  defp extract_result_text(result) when is_binary(result), do: result
  defp extract_result_text(_), do: nil

  defp resolve_pending_tool_calls(result, strategy_state) do
    case extract_tool_calls(result) do
      calls when is_list(calls) and calls != [] ->
        normalize_tool_calls(calls)

      _ ->
        case strategy_state[:pending_tool_calls] do
          calls when is_list(calls) -> normalize_tool_calls(calls)
          _ -> []
        end
    end
  end

  defp resolve_reasoning_summary(result, strategy_state) do
    case extract_thinking(result) do
      thinking when is_binary(thinking) and thinking != "" ->
        [thinking]

      _ ->
        case strategy_state[:streaming_thinking] do
          thinking when is_binary(thinking) and thinking != "" -> [thinking]
          _ -> []
        end
    end
  end

  defp extract_tool_calls({:ok, %{} = result}), do: extract_tool_calls(result)
  defp extract_tool_calls({:ok, %{} = result, _effects}), do: extract_tool_calls(result)

  defp extract_tool_calls(%{} = result) do
    result[:tool_calls] || result["tool_calls"] || []
  end

  defp extract_tool_calls(_), do: []

  defp extract_thinking({:ok, %{} = result}), do: extract_thinking(result)
  defp extract_thinking({:ok, %{} = result, _effects}), do: extract_thinking(result)

  defp extract_thinking(%{} = result) do
    result[:thinking_content] || result["thinking_content"]
  end

  defp extract_thinking(_), do: nil

  defp normalize_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        id: fetch_field(call, :id) || Ash.UUID.generate(),
        name: fetch_field(call, :name) || fetch_field(call, :tool_name) || "unknown_tool",
        arguments: normalize_arguments(fetch_field(call, :arguments))
      }
    end)
  end

  defp normalize_tool_calls(_), do: []

  defp fetch_field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp fetch_field(_value, _key), do: nil

  defp normalize_arguments(%{} = arguments), do: arguments
  defp normalize_arguments(_), do: %{}

  defp resolve_citations({:ok, %{} = result}), do: resolve_citations(result)
  defp resolve_citations({:ok, %{} = result, _effects}), do: resolve_citations(result)

  defp resolve_citations(%{} = result) do
    case result[:citations] || result["citations"] do
      citations when is_list(citations) -> citations
      _ -> []
    end
  end

  defp resolve_citations(_), do: []
end
