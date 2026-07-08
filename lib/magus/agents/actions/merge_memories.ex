defmodule Magus.Agents.Actions.MergeMemories do
  @moduledoc """
  Jido Action for merging small, related memories into consolidated groups.

  Uses an LLM to identify clusters of memories that can be merged by category
  (e.g., personal_info, preferences, coding_style). Merges are performed for
  both global memories and local memories per-conversation.

  ## Flow

  1. Load global memories, merge if >= min_memories_to_merge
  2. Find conversations needing consolidation (not recently consolidated)
  3. For each conversation: load local memories, merge if >= min_memories_to_merge
  4. Mark each conversation as consolidated

  ## Usage

      {:ok, result} = MergeMemories.run(%{user_id: user.id}, %{})

      result.global_merged_count   # => 2
      result.local_merged_count    # => 3
      result.conversations_processed # => 1
  """

  use Jido.Action,
    name: "merge_memories",
    description: "Merges related memories into consolidated groups by category",
    schema: [
      user_id: [type: :string, required: true, doc: "User ID to merge memories for"],
      workspace_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Workspace bucket to scope global merges to (nil = personal context)"
      ],
      model: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Model key override (defaults to extraction_model)"
      ],
      skip_local: [
        type: :boolean,
        default: false,
        doc: "If true, skip local memory merging"
      ],
      min_memories_to_merge: [
        type: :integer,
        default: 3,
        doc: "Minimum number of memories required to attempt a merge"
      ]
    ]

  require Logger
  require Ash.Query

  alias Magus.Agents.Support.AiAgent
  alias Magus.Agents.Config
  alias Magus.Agents.Persistence.UsageRecorder
  alias Magus.Agents.Clients.LLM, as: LLMClient
  alias Magus.Memory

  @actor %AiAgent{}

  # How recently a conversation must have been consolidated to skip it
  @consolidation_cooldown_days 1

  # Predefined category hints for the LLM
  @category_hints ~w(personal_info preferences coding_style project_context goals tools_and_environment)

  # JSON Schema for LLM merge output
  @merge_schema %{
    "type" => "object",
    "properties" => %{
      "merge_groups" => %{
        "type" => "array",
        "description" => "Groups of memories to merge together",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "category" => %{
              "type" => "string",
              "description" =>
                "Category for the merged memory (e.g., personal_info, preferences, coding_style, project_context, goals, tools_and_environment, or a new category)"
            },
            "memory_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "IDs of memories to merge into this group"
            },
            "merged_name" => %{
              "type" => "string",
              "description" => "Concise name for the merged memory (2-5 words)"
            },
            "merged_summary" => %{
              "type" => "string",
              "description" => "Summary of the merged memory (max 500 chars)"
            },
            "merged_content" => %{
              "type" => "object",
              "description" => "Combined data from all source memories"
            },
            "reason" => %{
              "type" => "string",
              "description" => "Why these memories should be merged"
            }
          },
          "required" => [
            "category",
            "memory_ids",
            "merged_name",
            "merged_summary",
            "merged_content",
            "reason"
          ]
        }
      },
      "reasoning" => %{
        "type" => "string",
        "description" => "Overall reasoning for the merge decisions"
      }
    },
    "required" => ["merge_groups", "reasoning"]
  }

  @impl true
  def run(params, _context) do
    user_id = params.user_id
    workspace_id = params[:workspace_id]
    model = params[:model] || Config.extraction_model()
    skip_local = params[:skip_local] || false
    min_memories = params[:min_memories_to_merge] || 3

    Logger.info("MergeMemories: starting for user #{user_id}, workspace #{inspect(workspace_id)}")

    # Step 1: Merge global memories within the workspace bucket
    global_merged_count = merge_global_memories(user_id, workspace_id, model, min_memories)

    # Step 2: Merge local memories per conversation, scoped to the workspace bucket
    {local_merged_count, conversations_processed} =
      if skip_local do
        {0, 0}
      else
        merge_local_memories(user_id, workspace_id, model, min_memories)
      end

    {:ok,
     %{
       global_merged_count: global_merged_count,
       local_merged_count: local_merged_count,
       conversations_processed: conversations_processed
     }}
  end

  # ===========================================================================
  # Global Memory Merging
  # ===========================================================================

  defp merge_global_memories(user_id, workspace_id, model, min_memories) do
    case load_active_global_memories(user_id, workspace_id) do
      memories when length(memories) >= min_memories ->
        case merge_memory_set(memories, :user, user_id, workspace_id, model) do
          {:ok, count} -> count
          {:error, _} -> 0
        end

      _ ->
        0
    end
  end

  defp load_active_global_memories(user_id, workspace_id) do
    base =
      Memory.Memory
      |> Ash.Query.filter(user_id == ^user_id and is_active == true and scope == :user)

    query =
      case workspace_id do
        nil -> Ash.Query.filter(base, is_nil(workspace_id))
        ws -> Ash.Query.filter(base, workspace_id == ^ws)
      end

    case Ash.read(query, actor: @actor) do
      {:ok, memories} -> memories
      {:error, _} -> []
    end
  end

  # ===========================================================================
  # Local Memory Merging
  # ===========================================================================

  defp merge_local_memories(user_id, workspace_id, model, min_memories) do
    conversations = find_conversations_needing_merge(user_id, workspace_id)

    Enum.reduce(conversations, {0, 0}, fn conv, {total_merged, total_convs} ->
      case load_active_local_memories(conv.id) do
        memories when length(memories) >= min_memories ->
          merged =
            case merge_memory_set(memories, :local, user_id, workspace_id, model, conv.id) do
              {:ok, count} -> count
              {:error, _} -> 0
            end

          mark_conversation_consolidated(conv)
          {total_merged + merged, total_convs + 1}

        _ ->
          mark_conversation_consolidated(conv)
          {total_merged, total_convs + 1}
      end
    end)
  end

  defp find_conversations_needing_merge(user_id, workspace_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@consolidation_cooldown_days, :day)

    base =
      Magus.Chat.Conversation
      |> Ash.Query.filter(
        user_id == ^user_id and
          (is_nil(last_memory_consolidation_at) or last_memory_consolidation_at < ^cutoff) and
          exists(memories, is_active == true and scope == :local)
      )

    query =
      case workspace_id do
        nil -> Ash.Query.filter(base, is_nil(workspace_id))
        ws -> Ash.Query.filter(base, workspace_id == ^ws)
      end

    case Ash.read(query, authorize?: false) do
      {:ok, conversations} -> conversations
      {:error, _} -> []
    end
  end

  defp load_active_local_memories(conversation_id) do
    case Memory.Memory
         |> Ash.Query.filter(
           conversation_id == ^conversation_id and is_active == true and scope == :local
         )
         |> Ash.read(actor: @actor) do
      {:ok, memories} -> memories
      {:error, _} -> []
    end
  end

  defp mark_conversation_consolidated(conv) do
    case Magus.Chat.mark_memory_consolidated(
           conv,
           %{last_memory_consolidation_at: DateTime.utc_now()},
           authorize?: false
         ) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "MergeMemories: failed to mark conversation consolidated: #{inspect(error)}"
        )
    end
  rescue
    e ->
      Logger.warning(
        "MergeMemories: failed to mark conversation consolidated: #{Exception.message(e)}"
      )
  end

  # ===========================================================================
  # Core Merge Logic
  # ===========================================================================

  defp merge_memory_set(memories, scope, user_id, workspace_id, model, conversation_id \\ nil) do
    prompt = build_merge_prompt(memories, scope, workspace_id)

    case LLMClient.llm_client().generate_object(model, prompt, @merge_schema,
           system_prompt: merge_system_prompt()
         ) do
      {:ok, response} ->
        record_usage(user_id, model, response.usage)

        merge_groups = response.object["merge_groups"] || []
        memory_map = Map.new(memories, &{to_string(&1.id), &1})

        merged_count =
          Enum.reduce(merge_groups, 0, fn group, count ->
            case execute_merge_group(
                   group,
                   memory_map,
                   scope,
                   user_id,
                   workspace_id,
                   conversation_id
                 ) do
              :ok -> count + 1
              :error -> count
            end
          end)

        {:ok, merged_count}

      {:error, error} ->
        Logger.error("MergeMemories: LLM merge failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp execute_merge_group(group, memory_map, scope, user_id, workspace_id, conversation_id) do
    memory_ids = group["memory_ids"] || []

    # Validate all memory_ids exist in the loaded set
    valid_memories =
      memory_ids
      |> Enum.map(&Map.get(memory_map, to_string(&1)))
      |> Enum.reject(&is_nil/1)

    if length(valid_memories) < 2 do
      Logger.debug("MergeMemories: skipping group with fewer than 2 valid memories")
      :error
    else
      do_merge(group, valid_memories, scope, user_id, workspace_id, conversation_id)
    end
  end

  defp do_merge(group, source_memories, scope, user_id, workspace_id, conversation_id) do
    merged_name = group["merged_name"]
    merged_summary = group["merged_summary"]
    merged_content = group["merged_content"] || %{}
    source_names = Enum.map(source_memories, & &1.name) |> Enum.join(", ")

    # Wrap in transaction to ensure atomicity: either the merge fully succeeds
    # (sources destroyed + new memory created) or nothing changes.
    # Sources are destroyed first to avoid unique name identity conflicts.
    # We pass return_notifications?: true to collect notifications and send
    # them after the transaction commits (Ash can't deliver inside a txn).
    Magus.Repo.transaction(fn ->
      notifications = []

      # Step 1: Destroy all source memories
      notifications =
        Enum.reduce(source_memories, notifications, fn memory, acc ->
          case Memory.destroy_memory(memory,
                 actor: @actor,
                 return_notifications?: true
               ) do
            {:ok, notifs} -> acc ++ notifs
            :ok -> acc
            {:error, error} -> Magus.Repo.rollback({:destroy_failed, memory.id, error})
          end
        end)

      # Step 2: Create merged memory
      {create_result, notifications} =
        case scope do
          :user ->
            case Memory.create_user_memory(
                   user_id,
                   workspace_id,
                   merged_name,
                   %{summary: merged_summary, content: merged_content},
                   actor: @actor,
                   return_notifications?: true
                 ) do
              {:ok, mem, notifs} -> {{:ok, mem}, notifications ++ notifs}
              {:ok, mem} -> {{:ok, mem}, notifications}
              {:error, _} = err -> {err, notifications}
            end

          :local ->
            case Memory.create_memory(
                   conversation_id,
                   user_id,
                   merged_name,
                   %{summary: merged_summary, content: merged_content},
                   actor: @actor,
                   return_notifications?: true
                 ) do
              {:ok, mem, notifs} -> {{:ok, mem}, notifications ++ notifs}
              {:ok, mem} -> {{:ok, mem}, notifications}
              {:error, _} = err -> {err, notifications}
            end
        end

      case create_result do
        {:ok, new_memory} ->
          {_, notifications} =
            case Memory.create_memory_version(
                   %{
                     memory_id: new_memory.id,
                     content: merged_content,
                     summary: merged_summary,
                     version: 1,
                     changed_by: :system,
                     change_description: "Merged from: #{source_names}"
                   },
                   authorize?: false,
                   return_notifications?: true
                 ) do
              {:ok, _, notifs} -> {:ok, notifications ++ notifs}
              {:ok, _} -> {:ok, notifications}
              {:error, _} -> {:ok, notifications}
            end

          notifications

        {:error, error} ->
          Magus.Repo.rollback({:create_failed, error})
      end
    end)
    |> case do
      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)

        Logger.info(
          "MergeMemories: merged #{length(source_memories)} memories into '#{merged_name}'"
        )

        :ok

      {:error, reason} ->
        Logger.warning("MergeMemories: merge failed: #{inspect(reason)}")
        :error
    end
  end

  # ===========================================================================
  # Prompt Building
  # ===========================================================================

  defp build_merge_prompt(memories, scope, workspace_id) do
    workspace_label =
      case workspace_id do
        nil -> "personal context"
        ws -> "workspace #{ws}"
      end

    scope_label =
      if scope == :user,
        do: "user-level (#{workspace_label})",
        else: "local (conversation-level)"

    memories_text =
      memories
      |> Enum.map(fn m ->
        """
        - ID: #{m.id}
          Name: #{m.name}
          Summary: #{m.summary || "(no summary)"}
          Content: #{Jason.encode!(m.content)}
        """
      end)
      |> Enum.join("\n")

    """
    ## #{scope_label |> String.capitalize()} Memories to Analyze

    The following #{scope_label} memories may contain overlapping or related information
    that could be consolidated:

    #{memories_text}

    ## Instructions

    Identify groups of memories that should be merged together. Memories should be
    merged when they:

    - Cover the same topic or category of information
    - Have overlapping or complementary content
    - Would be more useful as a single, comprehensive memory

    Category hints (use these or create new ones): #{Enum.join(@category_hints, ", ")}

    For each merge group:
    - Include at least 2 memory IDs
    - Provide a concise name (2-5 words)
    - Write a summary (max 500 chars) that captures all key information
    - Combine the content into a single structured object preserving all unique data
    - Explain why these memories should be merged

    Rules:
    - A memory can only appear in ONE merge group
    - Do NOT merge memories that are about genuinely different topics
    - If no memories should be merged, return an empty merge_groups array
    - Be conservative - only merge when information truly overlaps or is closely related
    - Preserve all unique information when merging content
    """
  end

  defp merge_system_prompt do
    """
    You are a memory consolidation assistant. Your job is to identify groups of related
    memories that can be merged into single, comprehensive memories.

    The goal is to reduce redundancy while preserving all useful information. When merging:
    1. Combine overlapping information without duplication
    2. Preserve unique details from each source memory
    3. Create clear, well-organized merged content
    4. Use descriptive names and summaries

    Be conservative - it's better to leave memories separate than to merge unrelated information.
    """
  end

  defp record_usage(user_id, model_key, usage) do
    UsageRecorder.record!(
      user_id: user_id,
      model_key: model_key,
      usage: usage,
      usage_type: :response,
      billable: false,
      action_name: "merge_memories"
    )
  end
end
