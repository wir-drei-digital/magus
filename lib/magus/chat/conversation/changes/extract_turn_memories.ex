defmodule Magus.Chat.Conversation.Changes.ExtractTurnMemories do
  @moduledoc """
  Ash change module that triggers turn-level memory extraction.

  Triggered by AshOban when `extraction_due_at` has passed. Clears the
  `extraction_due_at` field, then runs extraction inline in an
  `after_transaction` hook: outside the DB transaction (LLM calls must not
  hold a connection) but inside the Oban job, so an LLM failure fails the
  job and Oban retries it. The previous version spawned a fire-and-forget
  Task here, which permanently lost the turn on any LLM error.
  """

  use Ash.Resource.Change
  require Logger

  alias Magus.Agents.Actions.ExtractTurnMemories, as: ExtractAction

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:extraction_due_at, nil)
    |> Ash.Changeset.after_transaction(fn
      _changeset, {:ok, conversation} ->
        case run_extraction(conversation) do
          :ok -> {:ok, conversation}
          {:error, reason} -> {:error, reason}
        end

      _changeset, error ->
        error
    end)
  end

  # First extraction on a conversation with no watermark: cap the bootstrap
  # window so we do not extract an entire long history in one call.
  @max_bootstrap_messages 20
  # Below this many characters across all pending turns there is nothing
  # worth an LLM call; advance the watermark and move on.
  @min_transcript_chars 80

  defp run_extraction(conversation) do
    turns = load_turns_since(conversation)

    transcript_chars =
      Enum.reduce(turns, 0, fn t, acc ->
        acc + String.length(t.user) + String.length(t.agent)
      end)

    cond do
      turns == [] ->
        :ok

      transcript_chars < @min_transcript_chars ->
        advance_watermark(conversation, turns)

      true ->
        allow_global = agent_allows_global_writes?(conversation)

        case ExtractAction.run(
               %{
                 user_id: to_string(conversation.user_id),
                 conversation_id: to_string(conversation.id),
                 turns: Enum.map(turns, fn t -> %{"user" => t.user, "agent" => t.agent} end),
                 allow_global_memories: allow_global
               },
               %{}
             ) do
          {:ok, _result} -> advance_watermark(conversation, turns)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp advance_watermark(conversation, turns) do
    last = turns |> List.last() |> Map.fetch!(:last_inserted_at)

    case Magus.Chat.mark_conversation_extracted(
           conversation,
           %{last_extracted_message_at: last},
           authorize?: false
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Oban triggers provide bare conversations without preloads, so we
  # explicitly load the custom_agent association here.
  defp agent_allows_global_writes?(conversation) do
    case Ash.load(conversation, [:custom_agent], authorize?: false) do
      {:ok, %{custom_agent: %{can_write_global_memories: false}}} -> false
      _ -> true
    end
  end

  defp load_turns_since(conversation) do
    require Ash.Query

    query =
      Magus.Chat.Message
      |> Ash.Query.filter(conversation_id == ^conversation.id and role in [:user, :agent])
      |> Ash.Query.sort(inserted_at: :asc)

    query =
      case conversation.last_extracted_message_at do
        nil -> query
        watermark -> Ash.Query.filter(query, inserted_at > ^watermark)
      end

    case Ash.read(query, authorize?: false) do
      {:ok, messages} ->
        messages
        |> bootstrap_cap(conversation.last_extracted_message_at)
        |> Enum.map(&%{role: &1.role, text: &1.text || "", inserted_at: &1.inserted_at})
        |> pair_turns()

      {:error, _} ->
        []
    end
  end

  defp bootstrap_cap(messages, nil), do: Enum.take(messages, -@max_bootstrap_messages)
  defp bootstrap_cap(messages, _watermark), do: messages

  @doc """
  Pairs each user message with the next non-empty agent message. Input must
  be sorted ascending by inserted_at. Returns complete pairs only: a trailing
  user message without a response stays before the watermark and is picked up
  by the next run. Public for unit testing.
  """
  def pair_turns(messages), do: do_pair(messages, [])

  defp do_pair([], acc), do: Enum.reverse(acc)

  defp do_pair([%{role: :user, text: user_text} | rest], acc) when user_text != "" do
    case Enum.split_while(rest, fn m -> m.role != :agent or m.text == "" end) do
      {_skipped, [%{role: :agent, text: agent_text, inserted_at: at} | tail]} ->
        do_pair(tail, [%{user: user_text, agent: agent_text, last_inserted_at: at} | acc])

      {_skipped, []} ->
        Enum.reverse(acc)
    end
  end

  defp do_pair([_other | rest], acc), do: do_pair(rest, acc)
end
