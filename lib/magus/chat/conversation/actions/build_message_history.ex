defmodule Magus.Chat.Conversation.Actions.BuildMessageHistory do
  @moduledoc """
  Loads conversation message history for LLM context.

  Returns a flat list of ReqLLM.Message structs (no system prompt, no wrapping).
  Tool events from completed turns are excluded — the assistant's final text
  already captures results. If the last turn was interrupted (error/cancellation),
  tool activity is appended as plain text to the last assistant message.

  ## Pointer-aware windowing

  The read is bounded by the conversation's `ContextWindow`:

  - `window_start_at` (the floor) excludes everything inserted before the pointer.
  - `message_count_backstop` caps how many recent rows are loaded.
  - For the `:rolling` strategy the loaded rows are further trimmed at read time
    so the cumulative approximate token count of their text stays under
    `rolling_target_fraction * max_context`, while always keeping at least
    `compaction_tail` of the most recent messages.
  - If a compaction `summary` is present it is prepended as a leading user
    message so the model retains context from before the floor.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Magus.Agents.Context.ContextReport
  alias Magus.Chat.ContextWindow
  alias Magus.Chat.Message.ToolCallHelpers

  @default_max_context 128_000

  @impl true
  def run(input, _opts, _context) do
    conversation_id = input.arguments.conversation_id
    current_message_id = input.arguments[:current_message_id]
    is_multiplayer = input.arguments[:is_multiplayer] || false
    ai_actor = %Magus.Agents.Support.AiAgent{}

    context_window = load_context_window(conversation_id, ai_actor)
    user_default = ContextWindow.user_default_strategy(conversation_id)

    strategy =
      ContextWindow.resolve_strategy(%{
        strategy: context_window && context_window.strategy,
        user_default: user_default
      })

    # Read the rolling window: bounded below by the pointer (window_start_at) and
    # capped above by the message-count backstop. recent_limit sorts desc + limits
    # at the DB level; we reverse back to chronological order.
    messages =
      Magus.Chat.Message
      |> Ash.Query.for_read(:for_llm_context, %{
        conversation_id: conversation_id,
        exclude_id: current_message_id,
        since_at: context_window && context_window.window_start_at,
        recent_limit: ContextWindow.config(:message_count_backstop)
      })
      |> Ash.Query.load(as_llm_message: [is_multiplayer: is_multiplayer])
      |> Ash.read!(actor: ai_actor)
      |> Enum.reverse()
      |> trim_for_strategy(strategy, context_window)

    llm_messages =
      messages
      |> build_llm_messages(conversation_id)
      |> prepend_summary(context_window)

    {:ok, llm_messages}
  end

  # ---------------------------------------------------------------------------
  # Context-window + strategy resolution
  # ---------------------------------------------------------------------------

  defp load_context_window(conversation_id, actor) do
    ContextWindow
    |> Ash.Query.for_read(:get_for_conversation, %{conversation_id: conversation_id})
    |> Ash.read_one!(actor: actor)
  end

  # ---------------------------------------------------------------------------
  # Rolling read-time trim
  # ---------------------------------------------------------------------------

  # :compact never trims here — the window floor already bounds the read.
  defp trim_for_strategy(messages, :compact, _context_window), do: messages

  defp trim_for_strategy(messages, _strategy, context_window) do
    max_context = (context_window && context_window.last_max_context) || @default_max_context
    budget = round(ContextWindow.config(:rolling_target_fraction) * max_context)
    tail = ContextWindow.config(:compaction_tail)

    tokens = Enum.map(messages, &message_tokens/1)
    drop_oldest_until_under_budget(messages, tokens, Enum.sum(tokens), budget, tail)
  end

  # Drop oldest messages (front of the chronological list) until cumulative tokens
  # fit the budget, but never drop below the last `tail` messages.
  defp drop_oldest_until_under_budget(messages, tokens, running, budget, tail) do
    cond do
      running <= budget ->
        messages

      length(messages) <= tail ->
        messages

      true ->
        drop_oldest_until_under_budget(
          tl(messages),
          tl(tokens),
          running - hd(tokens),
          budget,
          tail
        )
    end
  end

  defp message_tokens(%{text: text}) when is_binary(text), do: ContextReport.approx_tokens(text)
  defp message_tokens(_), do: 0

  # ---------------------------------------------------------------------------
  # Summary prepend
  # ---------------------------------------------------------------------------

  defp prepend_summary(llm_messages, %{summary: summary})
       when is_binary(summary) and summary != "" do
    summary_text = "[Summary of earlier conversation]\n" <> summary

    [
      %ReqLLM.Message{
        role: :user,
        content: [ReqLLM.Message.ContentPart.text(summary_text)]
      }
      | llm_messages
    ]
  end

  defp prepend_summary(llm_messages, _context_window), do: llm_messages

  # ---------------------------------------------------------------------------
  # LLM message building with recovery for incomplete turns
  # ---------------------------------------------------------------------------

  defp build_llm_messages(messages, conversation_id) do
    base_messages =
      messages
      |> Enum.map(& &1.as_llm_message)
      |> Enum.reject(&is_nil/1)

    last_agent =
      messages
      |> Enum.filter(&(&1.source == :agent and &1.message_type == :message))
      |> List.last()

    last_user =
      messages
      |> Enum.filter(&(&1.source == :user))
      |> List.last()

    case find_recovery_tool_calls(last_agent, last_user, conversation_id) do
      [] -> base_messages
      tool_calls -> recover_as_text(base_messages, tool_calls, last_user, conversation_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Recovery: append interrupted tool activity as plain text
  # ---------------------------------------------------------------------------

  # Returns tool_calls list if the last turn was interrupted, [] otherwise.
  # Two paths:
  # 1. Visible agent message has tool_call_data (normal case)
  # 2. Agent message was excluded by text filter (tool-only response) — DB fallback
  defp find_recovery_tool_calls(nil, nil, _conversation_id), do: []

  defp find_recovery_tool_calls(last_agent, last_user, conversation_id) do
    cond do
      is_nil(last_agent) ->
        find_hidden_tool_calls(conversation_id, last_user)

      last_agent.status in [:error, :streaming] or
          (last_agent.status == :complete and not is_nil(last_agent.tool_call_data)) ->
        case extract_tool_calls(last_agent) do
          [] -> find_hidden_tool_calls(conversation_id, last_user)
          calls -> calls
        end

      true ->
        []
    end
  end

  defp extract_tool_calls(msg),
    do: ToolCallHelpers.extract_tool_calls(msg.tool_call_data)

  defp find_hidden_tool_calls(conversation_id, last_user) do
    lower = if last_user, do: last_user.inserted_at, else: ~U[1970-01-01 00:00:00Z]

    case Magus.Chat.Message
         |> Ash.Query.filter(
           conversation_id == ^conversation_id and
             source == :agent and
             message_type == :message and
             not is_nil(tool_call_data) and
             disabled != true and
             inserted_at >= ^lower
         )
         |> Ash.Query.sort(inserted_at: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read!(actor: %Magus.Agents.Support.AiAgent{}) do
      [msg] -> extract_tool_calls(msg)
      [] -> []
    end
  end

  defp recover_as_text(llm_messages, tool_calls, last_user, conversation_id) do
    tool_events = load_tool_events(conversation_id, last_user)

    tool_names = Enum.map_join(tool_calls, ", ", & &1.name)

    result_lines =
      Enum.map(tool_calls, fn tc ->
        event = Enum.find(tool_events, &tool_event_matches?(&1, tc.id))

        summary =
          if event do
            ToolCallHelpers.fetch(event.tool_call_data, :output_summary) || "Completed"
          else
            "interrupted"
          end

        "[#{tc.name} result: #{String.slice(to_string(summary), 0, 500)}]"
      end)

    suffix =
      "\n\n[Previous turn called: #{tool_names}]\n" <> Enum.join(result_lines, "\n")

    append_to_last_assistant(llm_messages, suffix)
  end

  defp tool_event_matches?(event, tool_call_id) do
    ToolCallHelpers.fetch(event.tool_call_data, :tool_use_id) == tool_call_id
  end

  defp load_tool_events(conversation_id, last_user) do
    lower = if last_user, do: last_user.inserted_at, else: ~U[1970-01-01 00:00:00Z]

    Magus.Chat.Message
    |> Ash.Query.filter(
      conversation_id == ^conversation_id and
        message_type == :event and
        not is_nil(tool_call_data) and
        disabled != true and
        inserted_at >= ^lower
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.select([:tool_call_data])
    |> Ash.read!(actor: %Magus.Agents.Support.AiAgent{})
  end

  defp append_to_last_assistant(messages, suffix) do
    messages
    |> Enum.reverse()
    |> do_append_to_assistant(suffix)
    |> Enum.reverse()
  end

  defp do_append_to_assistant([%{role: :assistant} = msg | rest], suffix) do
    updated =
      case msg.content do
        parts when is_list(parts) ->
          %{msg | content: parts ++ [ReqLLM.Message.ContentPart.text(suffix)]}

        text when is_binary(text) ->
          %{msg | content: text <> suffix}

        _ ->
          %{msg | content: [ReqLLM.Message.ContentPart.text(suffix)]}
      end

    [updated | rest]
  end

  defp do_append_to_assistant([msg | rest], suffix),
    do: [msg | do_append_to_assistant(rest, suffix)]

  defp do_append_to_assistant([], _suffix), do: []
end
