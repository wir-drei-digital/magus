defmodule Magus.Agents.Actions.ExtractTurnMemories do
  @moduledoc """
  Jido Action for extracting memories from a single conversation turn.

  This is a lightweight extraction that runs after each conversation turn,
  analyzing the user message and agent response to identify information
  worth persisting. Unlike the batch extraction, this focuses on:

  - Immediate facts and decisions from this turn
  - Updates to existing memories based on new information

  Every extraction lands as a **local** (conversation-scoped) memory; a
  nightly distiller is responsible for promoting durable facts to
  user-level memories, so this action no longer decides scope.

  ## Usage

      {:ok, result} = ExtractTurnMemories.run(%{
        user_id: user.id,
        conversation_id: conversation.id,
        turns: [
          %{"user" => "My preferred IDE is VS Code", "agent" => "I'll remember that..."}
        ]
      }, %{})

  The legacy single-turn `user_message`/`agent_response` pair is still
  accepted and is converted internally into a one-element `turns` list.
  """

  use Jido.Action,
    name: "extract_turn_memories",
    description: "Extracts memories from a single conversation turn",
    schema: [
      user_id: [type: :string, required: true, doc: "User ID"],
      conversation_id: [type: :string, required: true, doc: "Conversation ID"],
      user_message: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Legacy single-turn user text (use turns instead)"
      ],
      agent_response: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Legacy single-turn agent text (use turns instead)"
      ],
      turns: [
        type: {:or, [{:list, :map}, nil]},
        default: nil,
        doc: ~s(List of turn pairs: [%{"user" => text, "agent" => text}])
      ],
      model: [type: {:or, [:string, nil]}, default: nil, doc: "Model key override"]
    ]

  require Logger

  alias Magus.Agents.Support.AiAgent
  alias Magus.Agents.Config
  alias Magus.Agents.Persistence.UsageRecorder
  alias Magus.Agents.Clients.LLM, as: LLMClient
  alias Magus.Files.EmbeddingModel
  alias Magus.Memory

  @actor %AiAgent{}

  # JSON Schema for turn extraction
  @output_schema %{
    "type" => "object",
    "properties" => %{
      "extractions" => %{
        "type" => "array",
        "description" => "List of memories to create/update from this turn",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "Memory name (short, 2-5 words)"
            },
            "summary" => %{
              "type" => "string",
              "description" => "Brief description (max 100 chars)"
            },
            "content" => %{
              "type" => "object",
              "description" => "Structured data to store"
            },
            "update_mode" => %{
              "type" => "string",
              "enum" => ["merge", "replace"],
              "description" =>
                "merge (default): add fields into the existing memory. replace: the new content supersedes the old entirely."
            },
            "reason" => %{
              "type" => "string",
              "description" => "Why this was extracted"
            }
          },
          "required" => ["name", "summary", "content", "reason"]
        }
      }
    },
    "required" => ["extractions"]
  }

  @impl true
  def run(params, _context) do
    # Normalize once at the boundary so the rest of the function reads a single
    # key shape instead of checking atom-or-string per field (magus-t1dx).
    params = normalize_keys(params)
    user_id = params["user_id"]
    conversation_id = params["conversation_id"]
    model = params["model"] || Config.extraction_model()

    turns = resolve_turns(params)

    transcript_chars =
      Enum.reduce(turns, 0, fn t, acc ->
        acc + String.length(t["user"] || "") + String.length(t["agent"] || "")
      end)

    Logger.debug(
      "ExtractTurnMemories: user_id=#{inspect(user_id)}, conv_id=#{inspect(conversation_id)}, " <>
        "turns=#{length(turns)}, transcript_chars=#{transcript_chars}, model=#{inspect(model)}"
    )

    # Validate required params
    cond do
      is_nil(user_id) or user_id == "" ->
        Logger.warning("ExtractTurnMemories: user_id is required")
        {:error, "user_id is required"}

      is_nil(conversation_id) or conversation_id == "" ->
        Logger.warning("ExtractTurnMemories: conversation_id is required")
        {:error, "conversation_id is required"}

      # Skip if there is nothing worth an LLM call
      turns == [] or transcript_chars < 80 ->
        Logger.debug("ExtractTurnMemories: Transcript too short, skipping")
        {:ok, %{extractions_applied: 0, extractions_skipped: 0}}

      true ->
        case extract_and_apply(user_id, conversation_id, turns, model) do
          {:ok, result} ->
            {:ok, result}

          {:error, _} = error ->
            error
        end
    end
  rescue
    e ->
      Logger.warning("ExtractTurnMemories: Unexpected exception: #{Exception.message(e)}")
      Logger.debug("Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}")
      {:error, "unexpected error: #{Exception.message(e)}"}
  end

  defp normalize_keys(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp resolve_turns(params) do
    case params["turns"] do
      turns when is_list(turns) and turns != [] ->
        Enum.map(turns, fn t ->
          %{
            "user" => to_string(t["user"] || t[:user] || ""),
            "agent" => to_string(t["agent"] || t[:agent] || "")
          }
        end)

      _ ->
        user_message = params["user_message"] || ""
        agent_response = params["agent_response"] || ""

        if user_message == "" and agent_response == "" do
          []
        else
          [%{"user" => user_message, "agent" => agent_response}]
        end
    end
  end

  defp extract_and_apply(user_id, conversation_id, turns, model) do
    Logger.debug("ExtractTurnMemories: Starting extraction for conversation #{conversation_id}")

    # Workspace derivation stays solely to load the user-memory listing shown
    # to the extractor as known facts to avoid re-extracting (memory-v2: the
    # nightly distiller owns user-level durability, not per-turn extraction).
    workspace_id = Magus.Memory.workspace_id_for_conversation(conversation_id)

    # Load existing memories for context (local for updates, user for dedup)
    local_memories = load_local_memories(conversation_id)
    user_memories = load_user_memories(user_id, workspace_id)

    Logger.debug(
      "ExtractTurnMemories: Loaded #{length(local_memories)} local, #{length(user_memories)} user memories"
    )

    prompt = build_prompt(local_memories, user_memories, turns)

    Logger.debug("ExtractTurnMemories: Calling LLM with model #{inspect(model)}")

    case LLMClient.llm_client().generate_object(model, prompt, @output_schema,
           system_prompt: system_prompt()
         ) do
      {:ok, response} ->
        # Record usage (non-billable system operation)
        record_usage(user_id, conversation_id, model, response.usage)

        extractions =
          (response.object["extractions"] || [])
          |> Enum.map(&normalize_extraction/1)

        {applied, skipped} = apply_extractions(extractions, conversation_id, user_id)
        evicted = enforce_conversation_cap(conversation_id)

        Logger.debug(
          "ExtractTurnMemories: Applied #{applied}, skipped #{skipped}, evicted #{evicted} " <>
            "for conversation #{conversation_id}"
        )

        {:ok,
         %{
           extractions_applied: applied,
           extractions_skipped: skipped,
           memories_evicted: evicted,
           usage: response.usage
         }}

      {:error, error} ->
        Logger.warning("ExtractTurnMemories: LLM extraction failed: #{inspect(error)}")
        {:error, error}
    end
  end

  # Deterministic growth bound: the per-conversation cap replaces time-based
  # decay. Oldest-by-update evicted first, through the real destroy action so
  # PubSub and Super Brain retraction fire.
  defp enforce_conversation_cap(conversation_id) do
    cap = Magus.Config.max_memories_per_conversation()

    case Memory.list_memories_for_conversation(conversation_id, actor: @actor) do
      {:ok, memories} when length(memories) > cap ->
        memories
        |> Enum.sort_by(& &1.updated_at, {:asc, DateTime})
        |> Enum.take(length(memories) - cap)
        |> Enum.reduce(0, fn memory, count ->
          case Memory.destroy_memory(memory, actor: @actor) do
            :ok -> count + 1
            {:error, _} -> count
          end
        end)

      _ ->
        0
    end
  end

  defp load_local_memories(conversation_id) do
    case Memory.list_memories_for_conversation(conversation_id, actor: @actor) do
      {:ok, memories} -> Enum.take(memories, 100)
      _ -> []
    end
  end

  defp load_user_memories(user_id, workspace_id) do
    # list_user_memories uses actor(:id) for filtering, so pass a User struct
    actor = %Magus.Accounts.User{id: user_id}

    case Memory.list_user_memories(workspace_id, actor: actor) do
      {:ok, memories} -> Enum.take(memories, 100)
      _ -> []
    end
  end

  defp apply_extractions(extractions, conversation_id, user_id) do
    Enum.reduce(extractions, {0, 0}, fn extraction, {applied, skipped} ->
      case apply_extraction(extraction, conversation_id, user_id) do
        :applied -> {applied + 1, skipped}
        :skipped -> {applied, skipped + 1}
      end
    end)
  end

  defp apply_extraction(extraction, conversation_id, user_id) do
    name = extraction["name"]
    content = extraction["content"]
    summary = extraction["summary"]
    update_mode = extraction["update_mode"]

    apply_local_extraction(name, content, summary, conversation_id, user_id, update_mode)
  end

  defp apply_local_extraction(name, content, summary, conversation_id, user_id, update_mode) do
    case Memory.get_memory_by_name(conversation_id, name, actor: @actor) do
      {:ok, memory} ->
        new_content = resolve_content(memory.content, content, update_mode)

        case Memory.set_memory(memory, new_content, %{summary: summary}, actor: @actor) do
          {:ok, _updated} ->
            Logger.debug("ExtractTurnMemories: Updated local memory '#{name}'")
            :applied

          {:error, error} ->
            Logger.warning(
              "ExtractTurnMemories: Failed to update local memory: #{inspect(error)}"
            )

            :skipped
        end

      {:error, %Ash.Error.Query.NotFound{}} ->
        # Memory not found, create new one
        create_local_memory(name, content, summary, conversation_id, user_id, update_mode)

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        # Check if it's a not found error wrapped in Invalid
        if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
          create_local_memory(name, content, summary, conversation_id, user_id, update_mode)
        else
          Logger.warning("ExtractTurnMemories: Error looking up local memory: #{inspect(errors)}")

          :skipped
        end

      {:error, _} ->
        :skipped
    end
  end

  defp create_local_memory(name, content, summary, conversation_id, user_id, update_mode) do
    # Semantic dedup: check if a similar memory already exists in this conversation
    case find_similar_existing_local(summary, conversation_id) do
      {:ok, existing} ->
        new_content = resolve_content(existing.content, content, update_mode)

        case Memory.set_memory(existing, new_content, %{summary: summary}, actor: @actor) do
          {:ok, _} ->
            Logger.debug("ExtractTurnMemories: Deduped local memory, updated '#{existing.name}'")
            :applied

          {:error, _} ->
            :skipped
        end

      :none ->
        case Memory.create_memory(
               conversation_id,
               user_id,
               name,
               %{content: content, summary: summary},
               actor: @actor
             ) do
          {:ok, _memory} ->
            Logger.debug("ExtractTurnMemories: Created local memory '#{name}'")
            :applied

          {:error, error} ->
            Logger.warning(
              "ExtractTurnMemories: Failed to create local memory: #{inspect(error)}"
            )

            :skipped
        end
    end
  end

  defp normalize_extraction(extraction) when is_map(extraction) do
    %{
      "name" => to_string(extraction["name"] || extraction[:name] || ""),
      "summary" => to_string(extraction["summary"] || extraction[:summary] || ""),
      "content" => extraction["content"] || extraction[:content] || %{},
      "update_mode" =>
        normalize_update_mode(extraction["update_mode"] || extraction[:update_mode]),
      "reason" => to_string(extraction["reason"] || extraction[:reason] || "")
    }
  end

  defp normalize_update_mode("replace"), do: "replace"
  defp normalize_update_mode(_), do: "merge"

  defp build_prompt(local_memories, user_memories, turns) do
    local_text = format_memories(local_memories, "Local")
    user_text = format_memories(user_memories, "User-level")

    """
    ## Existing Memories (this conversation)

    #{local_text}

    ## Known User-Level Facts (do NOT re-extract these)

    #{user_text}

    ## Current Turns

    #{format_turns(turns)}

    ## Instructions

    Extract information worth remembering for this conversation:

    1. **Facts**: Names, dates, preferences explicitly stated
    2. **Decisions**: Choices the user made or confirmed
    3. **Context**: Project details, tasks, goals mentioned

    If information updates an existing memory, use the exact same name.

    Set update_mode when updating an existing memory:
    - "merge" (default): new fields are added to the memory
    - "replace": the new content fully supersedes the old. Use this when the
      new information contradicts or reverses what the memory currently says
      (changed preference, reversed decision, corrected fact).

    If nothing meaningful to extract, return empty extractions list.

    Keep extractions minimal - only persist genuinely useful information.
    """
  end

  defp format_turns(turns) do
    Enum.map_join(turns, "\n\n---\n\n", fn t ->
      "**User**: #{t["user"]}\n\n**Assistant**: #{t["agent"]}"
    end)
  end

  defp format_memories([], _label), do: "None"

  defp format_memories(memories, _label) do
    memories
    |> Enum.map(fn m ->
      "- **#{m.name}**: #{m.summary || "(no summary)"}"
    end)
    |> Enum.join("\n")
  end

  defp system_prompt do
    """
    You are a memory extraction assistant. Analyze conversation turns and extract
    information worth persisting for THIS conversation's continuity.

    Focus on:
    - Explicit statements of fact or preference
    - Decisions and commitments
    - Project context the conversation will need later
    - Contradictions of existing memories (extract with update_mode "replace")

    Avoid extracting:
    - Hypotheticals or questions
    - Transient/temporary information
    - Information already captured (unless updating)
    - Facts already listed under known user-level facts

    Be selective - only extract genuinely useful information.
    """
  end

  defp record_usage(user_id, conversation_id, model_key, usage) do
    UsageRecorder.record!(
      user_id: user_id,
      conversation_id: conversation_id,
      model_key: model_key,
      usage: usage,
      usage_type: :response,
      billable: false,
      action_name: "extract_turn_memories"
    )
  end

  # ============================================================================
  # Content Merging
  # ============================================================================

  # Resolves how new content combines with the existing memory content based
  # on the extraction's update_mode. "replace" lets a contradiction fully
  # supersede stale content instead of deep-merging forever; anything else
  # (including nil/unrecognized values) falls back to the merge behavior.
  defp resolve_content(_old, new, "replace"), do: new
  defp resolve_content(old, new, _merge), do: merge_content(old, new)

  # Deep-merges new content into existing content. New keys are added,
  # existing map values are recursively merged, and scalar values are
  # overwritten by the new extraction (most recent wins).
  defp merge_content(old, new) when is_map(old) and is_map(new) do
    Map.merge(old, new, fn
      _key, old_val, new_val when is_map(old_val) and is_map(new_val) ->
        merge_content(old_val, new_val)

      _key, _old_val, new_val ->
        new_val
    end)
  end

  defp merge_content(_old, new), do: new

  # ============================================================================
  # Semantic Dedup Helpers
  # ============================================================================

  @dedup_similarity_threshold 0.9

  defp find_similar_existing_local(summary, conversation_id) do
    case EmbeddingModel.embed(summary) do
      {:ok, embedding} ->
        case Memory.search_memories(conversation_id, embedding, %{limit: 1}, actor: @actor) do
          {:ok, [match | _]} ->
            if similar_enough?(match.summary_embedding, embedding) do
              {:ok, match}
            else
              :none
            end

          _ ->
            :none
        end

      {:error, _} ->
        :none
    end
  rescue
    _ -> :none
  end

  defp similar_enough?(embedding_a, embedding_b)
       when is_list(embedding_a) and is_list(embedding_b) do
    cosine_similarity(embedding_a, embedding_b) > @dedup_similarity_threshold
  end

  defp similar_enough?(_, _), do: false

  defp cosine_similarity(a, b) when is_list(a) and is_list(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if norm_a == 0.0 or norm_b == 0.0 do
      0.0
    else
      dot / (norm_a * norm_b)
    end
  end
end
