defmodule Magus.Agents.Actions.ExtractTurnMemories do
  @moduledoc """
  Jido Action for extracting memories from a single conversation turn.

  This is a lightweight extraction that runs after each conversation turn,
  analyzing the user message and agent response to identify information
  worth persisting. Unlike the batch extraction, this focuses on:

  - Immediate facts and decisions from this turn
  - Updates to existing memories based on new information
  - Scope determination (local vs global)

  ## Usage

      {:ok, result} = ExtractTurnMemories.run(%{
        user_id: user.id,
        conversation_id: conversation.id,
        user_message: "My preferred IDE is VS Code",
        agent_response: "I'll remember that..."
      }, %{})

  ## Scope Heuristics

  - **User**: General preferences, coding style, communication preferences
  - **Local**: Project context, current task, conversation-specific notes
  """

  use Jido.Action,
    name: "extract_turn_memories",
    description: "Extracts memories from a single conversation turn",
    schema: [
      user_id: [type: :string, required: true, doc: "User ID"],
      conversation_id: [type: :string, required: true, doc: "Conversation ID"],
      user_message: [type: :string, required: true, doc: "User's message text"],
      agent_response: [type: :string, required: true, doc: "Agent's response text"],
      model: [type: {:or, [:string, nil]}, default: nil, doc: "Model key override"],
      allow_global_memories: [
        type: :boolean,
        default: true,
        doc: "Whether global memory extraction is allowed"
      ]
    ]

  require Logger

  alias Magus.Agents.Support.AiAgent
  alias Magus.Agents.Actions.PromoteMemoryCandidates
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
            "scope" => %{
              "type" => "string",
              "enum" => ["local", "user"],
              "description" => "local=this conversation, user=all conversations"
            },
            "reason" => %{
              "type" => "string",
              "description" => "Why this was extracted"
            }
          },
          "required" => ["name", "summary", "content", "scope", "reason"]
        }
      }
    },
    "required" => ["extractions"]
  }

  @impl true
  def run(params, _context) do
    # Normalize once at the boundary so the rest of the function reads a single
    # key shape instead of checking atom-or-string per field (magus-t1dx). This
    # also fixes allow_global_memories below, which previously only read the atom.
    params = normalize_keys(params)
    user_id = params["user_id"]
    conversation_id = params["conversation_id"]
    user_message = params["user_message"] || ""
    agent_response = params["agent_response"] || ""
    model = params["model"] || Config.extraction_model()

    Logger.debug(
      "ExtractTurnMemories: user_id=#{inspect(user_id)}, conv_id=#{inspect(conversation_id)}, " <>
        "msg_len=#{String.length(user_message)}, resp_len=#{String.length(agent_response)}, model=#{inspect(model)}"
    )

    # Validate required params
    cond do
      is_nil(user_id) or user_id == "" ->
        Logger.warning("ExtractTurnMemories: user_id is required")
        {:error, "user_id is required"}

      is_nil(conversation_id) or conversation_id == "" ->
        Logger.warning("ExtractTurnMemories: conversation_id is required")
        {:error, "conversation_id is required"}

      # Skip if messages are too short to contain extractable info
      String.length(user_message) < 50 or String.length(agent_response) < 100 ->
        Logger.debug("ExtractTurnMemories: Messages too short, skipping")
        {:ok, %{extractions_applied: 0, extractions_skipped: 0}}

      true ->
        allow_global = Map.get(params, "allow_global_memories", true)

        case extract_and_apply(
               user_id,
               conversation_id,
               user_message,
               agent_response,
               model,
               allow_global
             ) do
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

  defp extract_and_apply(
         user_id,
         conversation_id,
         user_message,
         agent_response,
         model,
         allow_global
       ) do
    Logger.debug("ExtractTurnMemories: Starting extraction for conversation #{conversation_id}")

    workspace_id = Magus.Memory.workspace_id_for_conversation(conversation_id)

    # Load existing memories for context (both local and global)
    local_memories = load_local_memories(conversation_id)
    user_memories = load_user_memories(user_id, workspace_id)

    Logger.debug(
      "ExtractTurnMemories: Loaded #{length(local_memories)} local, #{length(user_memories)} user memories"
    )

    prompt = build_prompt(local_memories, user_memories, user_message, agent_response)

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

        {applied, skipped} =
          apply_extractions(extractions, conversation_id, user_id, workspace_id, allow_global)

        Logger.debug(
          "ExtractTurnMemories: Applied #{applied}, skipped #{skipped} for conversation #{conversation_id}"
        )

        {:ok,
         %{extractions_applied: applied, extractions_skipped: skipped, usage: response.usage}}

      {:error, error} ->
        Logger.warning("ExtractTurnMemories: LLM extraction failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp load_local_memories(conversation_id) do
    case Memory.list_memories_for_conversation(conversation_id, actor: @actor) do
      {:ok, memories} -> Enum.take(memories, 10)
      _ -> []
    end
  end

  defp load_user_memories(user_id, workspace_id) do
    # list_user_memories uses actor(:id) for filtering, so pass a User struct
    actor = %Magus.Accounts.User{id: user_id}

    case Memory.list_user_memories(workspace_id, actor: actor) do
      {:ok, memories} -> Enum.take(memories, 10)
      _ -> []
    end
  end

  defp apply_extractions(extractions, conversation_id, user_id, workspace_id, allow_global) do
    Enum.reduce(extractions, {0, 0}, fn extraction, {applied, skipped} ->
      case apply_extraction(extraction, conversation_id, user_id, workspace_id, allow_global) do
        :applied -> {applied + 1, skipped}
        :skipped -> {applied, skipped + 1}
      end
    end)
  end

  defp apply_extraction(extraction, conversation_id, user_id, workspace_id, allow_global) do
    name = extraction["name"]
    scope = extraction["scope"]
    content = extraction["content"]
    summary = extraction["summary"]

    case scope do
      "user" when not allow_global ->
        Logger.debug(
          "ExtractTurnMemories: Downgrading user extraction '#{name}' to local (agent isolation)"
        )

        apply_local_extraction(name, content, summary, conversation_id, user_id)

      "user" ->
        apply_user_extraction(name, content, summary, user_id, workspace_id)

      _ ->
        apply_local_extraction(name, content, summary, conversation_id, user_id)
    end
  end

  defp apply_user_extraction(name, content, summary, user_id, workspace_id) do
    # Use a User struct as actor for functions that use actor(:id) for filtering
    actor = %Magus.Accounts.User{id: user_id}

    case Memory.get_user_memory_by_name(workspace_id, name, actor: actor) do
      {:ok, memory} ->
        # Merge new content into existing rather than overwriting
        merged = merge_content(memory.content, content)

        case Memory.set_memory(memory, merged, %{summary: summary}, actor: @actor) do
          {:ok, _updated} ->
            Logger.debug("ExtractTurnMemories: Updated user memory '#{name}'")
            :applied

          {:error, error} ->
            Logger.warning("ExtractTurnMemories: Failed to update user memory: #{inspect(error)}")

            :skipped
        end

      {:error, %Ash.Error.Query.NotFound{}} ->
        # Memory not found, create new one
        create_user_memory(name, content, summary, user_id, workspace_id)

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        # Check if it's a not found error wrapped in Invalid
        if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
          create_user_memory(name, content, summary, user_id, workspace_id)
        else
          Logger.warning("ExtractTurnMemories: Error looking up user memory: #{inspect(errors)}")

          :skipped
        end

      {:error, _} ->
        :skipped
    end
  end

  defp create_user_memory(name, content, summary, user_id, workspace_id) do
    # Semantic dedup: check if a similar memory already exists
    case find_similar_existing_user(summary, user_id, workspace_id) do
      {:ok, existing} ->
        # Merge new content into existing rather than overwriting
        merged = merge_content(existing.content, content)

        case Memory.set_memory(existing, merged, %{summary: summary}, actor: @actor) do
          {:ok, _} ->
            Logger.debug("ExtractTurnMemories: Deduped user memory, updated '#{existing.name}'")
            :applied

          {:error, _} ->
            :skipped
        end

      :none ->
        case Memory.create_user_memory(
               user_id,
               workspace_id,
               name,
               %{content: content, summary: summary},
               actor: @actor
             ) do
          {:ok, _memory} ->
            Logger.debug("ExtractTurnMemories: Created user memory '#{name}'")
            :applied

          {:error, error} ->
            Logger.warning("ExtractTurnMemories: Failed to create user memory: #{inspect(error)}")

            :skipped
        end
    end
  end

  defp apply_local_extraction(name, content, summary, conversation_id, user_id) do
    case Memory.get_memory_by_name(conversation_id, name, actor: @actor) do
      {:ok, memory} ->
        # Merge new content into existing rather than overwriting
        merged = merge_content(memory.content, content)

        case Memory.set_memory(memory, merged, %{summary: summary}, actor: @actor) do
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
        create_local_memory(name, content, summary, conversation_id, user_id)

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        # Check if it's a not found error wrapped in Invalid
        if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
          create_local_memory(name, content, summary, conversation_id, user_id)
        else
          Logger.warning("ExtractTurnMemories: Error looking up local memory: #{inspect(errors)}")

          :skipped
        end

      {:error, _} ->
        :skipped
    end
  end

  defp create_local_memory(name, content, summary, conversation_id, user_id) do
    # Semantic dedup: check if a similar memory already exists in this conversation
    case find_similar_existing_local(summary, conversation_id) do
      {:ok, existing} ->
        merged = merge_content(existing.content, content)

        case Memory.set_memory(existing, merged, %{summary: summary}, actor: @actor) do
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
      "scope" => to_string(extraction["scope"] || extraction[:scope] || "local"),
      "reason" => to_string(extraction["reason"] || extraction[:reason] || "")
    }
  end

  defp build_prompt(local_memories, global_memories, user_message, agent_response) do
    local_text = format_memories(local_memories, "Local")
    global_text = format_memories(global_memories, "Global")

    """
    ## Existing Memories

    ### Local (conversation-specific)
    #{local_text}

    ### Global (user preferences)
    #{global_text}

    ## Current Turn

    **User**: #{user_message}

    **Assistant**: #{agent_response}

    ## Instructions

    Extract any information worth remembering from this turn:

    1. **Facts**: Names, dates, preferences explicitly stated
    2. **Decisions**: Choices the user made or confirmed
    3. **Context**: Project details, tasks, goals mentioned

    Determine scope:
    - **user**: User preferences, coding style, communication preferences, general facts about the user
    - **local**: Project context, current task, conversation-specific details

    If information updates an existing memory, use the exact same name.
    If nothing meaningful to extract, return empty extractions list.

    Keep extractions minimal - only persist genuinely useful information.
    """
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
    information worth persisting.

    Focus on:
    - Explicit statements of fact or preference
    - Decisions and commitments
    - Important context for future conversations

    Avoid extracting:
    - Hypotheticals or questions
    - Transient/temporary information
    - Information already captured (unless updating)

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

  defp find_similar_existing_user(summary, user_id, workspace_id) do
    case EmbeddingModel.embed(summary) do
      {:ok, embedding} ->
        case Memory.search_user_memories(user_id, workspace_id, embedding, %{limit: 1},
               actor: @actor
             ) do
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
    PromoteMemoryCandidates.cosine_similarity(embedding_a, embedding_b) >
      @dedup_similarity_threshold
  end

  defp similar_enough?(_, _), do: false
end
