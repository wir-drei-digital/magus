defmodule Magus.Agents.Actions.PromoteMemoryCandidates do
  @moduledoc """
  Jido Action for identifying and promoting local memories to global scope.

  This "Gardener" action analyzes a user's local memories across all conversations
  to identify patterns that should be promoted to global scope (user preferences,
  coding style, general patterns that apply everywhere).

  ## Promotion Criteria

  A memory is a candidate for promotion if:
  - Similar memories (by name or summary) exist in 2+ conversations
  - The content represents a general preference or pattern
  - It's not project-specific or conversation-bound

  ## Usage

      {:ok, result} = PromoteMemoryCandidates.run(%{
        user_id: user.id
      }, %{})

      result.promoted_count  # => 2
      result.candidates      # => list of promoted memories

  ## Concurrency Handling

  - Uses optimistic locking to handle concurrent modifications
  - Skips memories that have been modified during analysis
  """

  use Jido.Action,
    name: "promote_memory_candidates",
    description: "Identifies and promotes local memories to global scope",
    schema: [
      user_id: [type: :string, required: true, doc: "User ID to analyze memories for"],
      workspace_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Workspace bucket to scope to (nil = personal context)"
      ],
      model: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Model key override (defaults to extraction_model)"
      ],
      dry_run: [
        type: :boolean,
        default: false,
        doc: "If true, only identify candidates without promoting"
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

  # Minimum number of conversations where a similar memory must appear
  @min_conversations 2

  # JSON Schema for LLM validation output
  @validation_schema %{
    "type" => "object",
    "properties" => %{
      "candidates" => %{
        "type" => "array",
        "description" => "Memories that should be promoted to global scope",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "memory_id" => %{
              "type" => "string",
              "description" => "ID of the memory to promote"
            },
            "reason" => %{
              "type" => "string",
              "description" => "Why this memory should be global"
            },
            "suggested_name" => %{
              "type" => "string",
              "description" => "Suggested name for the global memory (optional)"
            },
            "suggested_summary" => %{
              "type" => "string",
              "description" => "Suggested summary combining insights (optional)"
            }
          },
          "required" => ["memory_id", "reason"]
        }
      },
      "reasoning" => %{
        "type" => "string",
        "description" => "Overall reasoning for the promotion decisions"
      }
    },
    "required" => ["candidates", "reasoning"]
  }

  @impl true
  def run(params, _context) do
    user_id = params.user_id
    workspace_id = params[:workspace_id]
    model = params[:model] || Config.extraction_model()
    dry_run = params[:dry_run] || false

    Logger.info(
      "PromoteMemoryCandidates: starting for user #{user_id}, workspace #{inspect(workspace_id)}"
    )

    # Get local memories scoped to the workspace bucket, grouped by conversation
    memories_by_conversation = load_local_memories_by_conversation(user_id, workspace_id)

    if map_size(memories_by_conversation) < @min_conversations do
      Logger.debug(
        "User has memories in fewer than #{@min_conversations} conversations, skipping"
      )

      {:ok, %{promoted_count: 0, candidates: [], reason: "not_enough_conversations"}}
    else
      # Find potential candidates - memories with similar names/summaries across conversations
      candidates = find_similar_memories(memories_by_conversation)

      if Enum.empty?(candidates) do
        Logger.debug("No promotion candidates found")
        {:ok, %{promoted_count: 0, candidates: [], reason: "no_candidates"}}
      else
        # Use LLM to validate which candidates are truly universal
        validate_and_promote(candidates, user_id, workspace_id, model, dry_run)
      end
    end
  end

  defp load_local_memories_by_conversation(user_id, workspace_id) do
    # Get all local memories for the user, scoped to a single workspace bucket.
    # Branches at the Elixir level so the SQL filter never compares against NULL.
    base =
      Memory.Memory
      |> Ash.Query.filter(user_id == ^user_id and is_active == true and scope == :local)

    query =
      case workspace_id do
        nil -> Ash.Query.filter(base, is_nil(workspace_id))
        ws -> Ash.Query.filter(base, workspace_id == ^ws)
      end

    case Ash.read(query, actor: @actor) do
      {:ok, memories} ->
        # Group by conversation_id
        Enum.group_by(memories, & &1.conversation_id)

      {:error, _} ->
        %{}
    end
  end

  # Similarity threshold for cross-conversation promotion
  @similarity_threshold 0.85
  # Max memories to consider per user (safety limit)
  @max_memories_to_compare 200

  defp find_similar_memories(memories_by_conversation) do
    # Flatten all memories with their conversation context
    all_memories =
      memories_by_conversation
      |> Enum.flat_map(fn {_conv_id, memories} -> memories end)
      |> Enum.filter(&(not is_nil(&1.summary_embedding)))
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.take(@max_memories_to_compare)

    # For each memory, check if a similar memory exists in a DIFFERENT conversation
    candidates =
      all_memories
      |> Enum.filter(fn memory ->
        Enum.any?(all_memories, fn other ->
          other.id != memory.id and
            other.conversation_id != memory.conversation_id and
            cosine_similarity(memory.summary_embedding, other.summary_embedding) >
              @similarity_threshold
        end)
      end)

    # Deduplicate: group similar memories, pick most recently updated from each cluster
    deduplicate_clusters(candidates)
  end

  defp deduplicate_clusters([]), do: []

  defp deduplicate_clusters(candidates) do
    # Greedily cluster by similarity
    Enum.reduce(candidates, [], fn memory, clusters ->
      already_represented =
        Enum.any?(clusters, fn representative ->
          not is_nil(memory.summary_embedding) and
            not is_nil(representative.summary_embedding) and
            cosine_similarity(memory.summary_embedding, representative.summary_embedding) >
              @similarity_threshold
        end)

      if already_represented do
        clusters
      else
        [memory | clusters]
      end
    end)
    |> Enum.reverse()
  end

  @doc false
  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if norm_a == 0.0 or norm_b == 0.0 do
      0.0
    else
      dot / (norm_a * norm_b)
    end
  end

  def cosine_similarity(_, _), do: 0.0

  defp validate_and_promote(candidates, user_id, workspace_id, model, dry_run) do
    prompt = build_validation_prompt(candidates, workspace_id)

    case LLMClient.llm_client().generate_object(model, prompt, @validation_schema,
           system_prompt: validation_system_prompt()
         ) do
      {:ok, response} ->
        # Record usage
        record_usage(user_id, model, response.usage)

        validated_candidates =
          response.object["candidates"]
          |> Enum.map(&normalize_candidate/1)

        if dry_run do
          {:ok,
           %{
             promoted_count: 0,
             candidates: validated_candidates,
             dry_run: true,
             reasoning: response.object["reasoning"]
           }}
        else
          # Actually promote the memories
          {promoted, failed} = promote_memories(validated_candidates, user_id, workspace_id)

          {:ok,
           %{
             promoted_count: promoted,
             failed_count: failed,
             candidates: validated_candidates,
             reasoning: response.object["reasoning"]
           }}
        end

      {:error, error} ->
        Logger.error("PromoteMemoryCandidates: LLM validation failed", error: inspect(error))
        {:error, error}
    end
  end

  defp promote_memories(candidates, user_id, workspace_id) do
    Enum.reduce(candidates, {0, 0}, fn candidate, {promoted, failed} ->
      case promote_single_memory(candidate, user_id, workspace_id) do
        :ok -> {promoted + 1, failed}
        :error -> {promoted, failed + 1}
      end
    end)
  end

  defp promote_single_memory(candidate, user_id, workspace_id) do
    memory_id = candidate["memory_id"]

    case Memory.get_memory(memory_id, actor: @actor) do
      {:ok, memory} ->
        # Verify it belongs to the user, is local, and matches the workspace bucket
        if memory.user_id == user_id and memory.scope == :local and
             memory.workspace_id == workspace_id do
          # Check if a user memory with this name already exists in the same workspace
          name = candidate["suggested_name"] || memory.name

          actor = %Magus.Accounts.User{id: user_id}

          case Memory.get_user_memory_by_name(workspace_id, name, actor: actor) do
            {:ok, _existing} ->
              # Global memory with this name exists, skip
              Logger.info("Global memory '#{name}' already exists, skipping promotion")
              :error

            {:error, %Ash.Error.Query.NotFound{}} ->
              # No existing global memory, safe to promote
              do_promote(memory, candidate)

            {:error, %Ash.Error.Invalid{errors: errors}} ->
              if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
                do_promote(memory, candidate)
              else
                Logger.warning(
                  "Failed to check for existing global memory '#{name}': #{inspect(errors)}"
                )

                :error
              end

            {:error, error} ->
              Logger.warning(
                "Failed to check for existing global memory '#{name}': #{inspect(error)}"
              )

              :error
          end
        else
          Logger.warning("Memory #{memory_id} not eligible for promotion")
          :error
        end

      {:error, _} ->
        Logger.warning("Memory #{memory_id} not found")
        :error
    end
  end

  defp do_promote(memory, candidate) do
    # Update name/summary if suggested
    updates =
      %{}
      |> maybe_add_field(candidate, "suggested_name", :name)
      |> maybe_add_field(candidate, "suggested_summary", :summary)

    # First apply any updates
    memory =
      if map_size(updates) > 0 do
        case Memory.set_memory(memory, memory.content, updates, actor: @actor) do
          {:ok, updated} -> updated
          {:error, _} -> memory
        end
      else
        memory
      end

    # Now promote to global
    case Memory.promote_memory_to_user(memory, actor: @actor) do
      {:ok, _promoted} ->
        Logger.info("Promoted memory '#{memory.name}' to global scope")
        :ok

      {:error, error} ->
        Logger.warning("Failed to promote memory: #{inspect(error)}")
        :error
    end
  end

  defp maybe_add_field(updates, candidate, key, field) do
    if value = candidate[key] do
      Map.put(updates, field, value)
    else
      updates
    end
  end

  defp normalize_candidate(candidate) when is_map(candidate) do
    %{
      "memory_id" => to_string(candidate["memory_id"] || candidate[:memory_id]),
      "reason" => to_string(candidate["reason"] || candidate[:reason]),
      "suggested_name" => candidate["suggested_name"] || candidate[:suggested_name],
      "suggested_summary" => candidate["suggested_summary"] || candidate[:suggested_summary]
    }
  end

  defp build_validation_prompt(candidates, workspace_id) do
    memories_text =
      candidates
      |> Enum.map(fn m ->
        """
        - ID: #{m.id}
          Name: #{m.name}
          Summary: #{m.summary || "(no summary)"}
          Content: #{Jason.encode!(m.content)}
        """
      end)
      |> Enum.join("\n")

    workspace_label =
      case workspace_id do
        nil -> "personal context"
        ws -> "workspace #{ws}"
      end

    """
    ## Candidate Memories for Global Promotion (#{workspace_label})

    The following memories appear across multiple conversations within the same
    workspace bucket (#{workspace_label}) and may be candidates for promotion to
    user scope (visible to the user across all conversations in this same bucket):

    #{memories_text}

    ## Instructions

    Evaluate each memory and determine if it should be promoted to global scope.

    A memory should be promoted if it represents:
    - User preferences (coding style, communication preferences, tool preferences)
    - General patterns that apply across all contexts
    - Personal information that's useful in any conversation

    A memory should NOT be promoted if:
    - It's project-specific or conversation-bound
    - It contains temporary or transient information
    - It would cause confusion if applied globally
    - The information is already too stale to be useful

    For each memory you recommend promoting, provide:
    - The memory_id
    - A clear reason why it should be global
    - Optionally: a better name or summary for the global version

    Be conservative - only promote memories that are truly universal.
    """
  end

  defp validation_system_prompt do
    """
    You are a memory management assistant. Your job is to evaluate memories and determine
    which ones should be promoted from conversation-level (local) to user-level (global) scope.

    Global memories are visible in ALL conversations, so only promote memories that:
    1. Represent persistent user preferences or patterns
    2. Would be useful regardless of conversation context
    3. Don't contain project-specific or temporary information

    When in doubt, don't promote. It's better to keep memories local than to pollute
    the global space with irrelevant information.
    """
  end

  defp record_usage(user_id, model_key, usage) do
    UsageRecorder.record!(
      user_id: user_id,
      model_key: model_key,
      usage: usage,
      usage_type: :response,
      billable: false,
      action_name: "promote_memory_candidates"
    )
  end
end
