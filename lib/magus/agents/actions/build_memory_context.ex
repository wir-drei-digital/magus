defmodule Magus.Agents.Actions.BuildMemoryContext do
  @moduledoc """
  Builds memory context for a conversation.

  Builds a multi-layer hierarchy of memories:
  1. **Key** - Most recently updated memories (by updated_at)
  2. **Semantic** - Matched via embedding similarity to query
  3. **Associated** - 1-hop association expansion from retrieved memories

  Supports three scopes: local (conversation), agent (custom agent), and global (user).
  Co-retrieved memories are reinforced via Hebbian learning (fire-and-forget).

  ## Usage

      {:ok, context} = BuildMemoryContext.build(%{
        user_id: user.id,
        conversation_id: conversation.id,
        query_text: "What are my preferences?",
        global_enabled: true,
        custom_agent_id: agent.id
      })

      context.formatted   # => Pre-formatted string for system prompt
      context.important    # => List of key memories
      context.semantic     # => List of semantically relevant memories
      context.associated   # => List of association-expanded memories
      context.profile_document # => Distilled profile doc (string) or nil
  """

  require Logger

  alias Magus.Accounts.User
  alias Magus.Files.EmbeddingModel

  # Configuration
  @max_semantic_results 5
  @max_associated_results 3
  @max_reinforcement_pairs 10
  @min_effective_assoc_weight 0.05
  @max_preview_chars 600
  @max_block_chars 6000

  @doc """
  Builds memory context for inclusion in the system prompt.

  Returns `{:ok, context_map}` or `{:error, reason}`.
  """
  def build(params) do
    user_id = params[:user_id] || params["user_id"]
    conversation_id = params[:conversation_id] || params["conversation_id"]
    query_text = params[:query_text] || params["query_text"] || ""
    global_enabled = get_boolean(params, :global_enabled, true)
    custom_agent_id = params[:custom_agent_id] || params["custom_agent_id"]

    # Absent key => embed internally (legacy callers). Present vector => reuse
    # it (the agent context builder embeds the query once and shares it). Present
    # nil => the upstream embed failed/timed out, so skip semantic search.
    query_embedding = Map.get(params, :query_embedding, :__embed__)

    if is_nil(user_id) or user_id == "" do
      {:error, "user_id is required"}
    else
      {:ok,
       build_context(
         user_id,
         conversation_id,
         query_text,
         global_enabled,
         custom_agent_id,
         query_embedding
       )}
    end
  end

  defp get_boolean(params, key, default) do
    # Check both atom and string keys, being careful not to use || which treats false as falsy
    cond do
      Map.has_key?(params, key) -> params[key]
      Map.has_key?(params, Atom.to_string(key)) -> params[Atom.to_string(key)]
      true -> default
    end
  end

  defp build_context(
         user_id,
         conversation_id,
         query_text,
         global_enabled,
         custom_agent_id,
         query_embedding
       ) do
    # Create user actor for authorization
    actor = %User{id: user_id}
    workspace_id = Magus.Memory.workspace_id_for_conversation(conversation_id)

    # Distilled profile document (Hermes-style top layer). When present, it
    # replaces the global top-3-recency key-memory layer below.
    profile_document =
      if global_enabled and Magus.Agents.Config.profile_enabled?(to_string(user_id)) do
        load_profile_document(user_id, workspace_id)
      end

    # Layer 1: Key memories (most recently updated)
    important_local = load_important_local(conversation_id, actor)

    important_agent =
      if custom_agent_id do
        load_important_agent(custom_agent_id)
      else
        []
      end

    important_global =
      if global_enabled and is_nil(profile_document) do
        load_important_global(workspace_id, actor)
      else
        []
      end

    important = important_local ++ important_agent ++ important_global
    important_ids = MapSet.new(important, & &1.id)

    # Layer 2: Semantic search (if we have query text)
    semantic =
      if query_text != "" do
        search_semantic(
          conversation_id,
          workspace_id,
          resolve_embedding(query_embedding, query_text),
          global_enabled,
          custom_agent_id,
          important_ids,
          actor
        )
      else
        []
      end

    # Layer 3: Association expansion (1-hop from retrieved memories)
    all_retrieved = important ++ semantic
    all_retrieved_ids = MapSet.new(all_retrieved, & &1.id)

    associated =
      if all_retrieved_ids != MapSet.new() do
        expand_associations(all_retrieved_ids)
      else
        []
      end

    # Hebbian reinforcement (fire-and-forget)
    all_memory_ids = (all_retrieved ++ associated) |> Enum.map(& &1.id) |> Enum.uniq()
    reinforce_co_retrieved(all_memory_ids)

    # Build formatted context
    formatted =
      format_context(important, semantic ++ associated, global_enabled,
        profile_document: profile_document
      )

    # Whole-block budget: if full previews blow past the cap, re-render
    # summary-only. Full content stays reachable via the search_memories tool.
    formatted =
      if String.length(formatted) > @max_block_chars do
        format_context(important, semantic ++ associated, global_enabled,
          previews: false,
          profile_document: profile_document
        )
      else
        formatted
      end

    # Bump last_accessed_at only for semantically retrieved memories: they
    # were selected by relevance to the actual query, which is a real usage
    # signal. Key (recency) and associated memories are injected ambiently
    # every turn, so touching them would blur the signal even though no
    # ambient process currently reads last_accessed_at for eviction.
    touch_accessed_memories(Enum.map(semantic, & &1.id))

    %{
      important: important,
      semantic: semantic,
      associated: associated,
      formatted: formatted,
      global_enabled: global_enabled,
      profile_document: profile_document
    }
  end

  # ============================================================================
  # Layer 1: Key Memories
  # ============================================================================

  defp load_important_local(nil, _actor), do: []

  defp load_important_local(conversation_id, actor) do
    case Magus.Memory.list_top_local(conversation_id, actor: actor) do
      {:ok, memories} ->
        Enum.map(memories, &Map.put(&1, :display_scope, :local))

      _ ->
        []
    end
  end

  defp load_important_agent(custom_agent_id) do
    case Magus.Memory.list_agent_memories(custom_agent_id, authorize?: false) do
      {:ok, memories} ->
        memories
        |> Enum.take(3)
        |> Enum.map(&Map.put(&1, :display_scope, :agent))

      _ ->
        []
    end
  rescue
    e ->
      Logger.warning("Failed to load agent memories: #{Exception.message(e)}")
      []
  end

  defp load_important_global(workspace_id, actor) do
    case Magus.Memory.list_top_user(workspace_id, actor: actor) do
      {:ok, memories} ->
        Enum.map(memories, &Map.put(&1, :display_scope, :user))

      _ ->
        []
    end
  end

  # Distilled profile document (Hermes-style working memory). Returns the
  # document string when a non-empty profile exists for the bucket, nil
  # otherwise (no profile row, empty document, or lookup failure).
  defp load_profile_document(user_id, workspace_id) do
    case Magus.Memory.get_user_profile(user_id, workspace_id, authorize?: false) do
      {:ok, %{document: doc}} when is_binary(doc) and doc != "" -> doc
      _ -> nil
    end
  rescue
    e ->
      Logger.warning("Failed to load user profile: #{Exception.message(e)}")
      nil
  end

  # ============================================================================
  # Layer 2: Semantic Search
  # ============================================================================

  # Reuse a precomputed query embedding when supplied (the agent context builder
  # embeds the query once and shares it). A nil value means the upstream embed
  # failed/timed out, so skip semantic search. The `:__embed__` sentinel means
  # no embedding was supplied (legacy callers), so embed here.
  defp resolve_embedding(embedding, _query_text) when is_list(embedding), do: {:ok, embedding}
  defp resolve_embedding(:__embed__, query_text), do: EmbeddingModel.embed(query_text)
  defp resolve_embedding(_nil, _query_text), do: {:error, :no_embedding}

  defp search_semantic(
         conversation_id,
         workspace_id,
         embedding_result,
         global_enabled,
         custom_agent_id,
         exclude_ids,
         actor
       ) do
    case embedding_result do
      {:ok, embedding} ->
        local_results = search_local_semantic(conversation_id, embedding, exclude_ids, actor)

        agent_results =
          if custom_agent_id do
            search_agent_semantic(custom_agent_id, embedding, exclude_ids)
          else
            []
          end

        global_results =
          if global_enabled do
            search_global_semantic(workspace_id, embedding, exclude_ids, actor)
          else
            []
          end

        (local_results ++ agent_results ++ global_results)
        |> Enum.take(@max_semantic_results)

      {:error, reason} ->
        Logger.warning("BuildMemoryContext: Failed to generate embedding: #{inspect(reason)}")
        []
    end
  end

  defp search_local_semantic(nil, _embedding, _exclude_ids, _actor), do: []

  defp search_local_semantic(conversation_id, embedding, exclude_ids, actor) do
    case Magus.Memory.search_memories(
           conversation_id,
           embedding,
           %{limit: @max_semantic_results},
           actor: actor
         ) do
      {:ok, memories} ->
        memories
        |> Enum.reject(&MapSet.member?(exclude_ids, &1.id))
        |> Enum.map(&Map.put(&1, :display_scope, :local))

      _ ->
        []
    end
  end

  defp search_agent_semantic(custom_agent_id, embedding, exclude_ids) do
    case Magus.Memory.search_agent_memories(
           custom_agent_id,
           embedding,
           %{limit: @max_semantic_results},
           authorize?: false
         ) do
      {:ok, memories} ->
        memories
        |> Enum.reject(&MapSet.member?(exclude_ids, &1.id))
        |> Enum.map(&Map.put(&1, :display_scope, :agent))

      _ ->
        []
    end
  rescue
    e ->
      Logger.warning("Failed to search agent memories: #{Exception.message(e)}")
      []
  end

  defp search_global_semantic(workspace_id, embedding, exclude_ids, actor) do
    case Magus.Memory.search_user_memories(
           actor.id,
           workspace_id,
           embedding,
           %{limit: @max_semantic_results},
           actor: actor
         ) do
      {:ok, memories} ->
        memories
        |> Enum.reject(&MapSet.member?(exclude_ids, &1.id))
        |> Enum.map(&Map.put(&1, :display_scope, :user))

      _ ->
        []
    end
  end

  # ============================================================================
  # Layer 3: Association Expansion
  # ============================================================================

  defp expand_associations(memory_ids) do
    require Ash.Query
    memory_id_list = MapSet.to_list(memory_ids)

    # Batch query: fetch all associations where either side is in our set
    associated_ids =
      case Magus.Memory.MemoryAssociation
           |> Ash.Query.filter(memory_a_id in ^memory_id_list or memory_b_id in ^memory_id_list)
           |> Ash.read(authorize?: false) do
        {:ok, assocs} ->
          now = DateTime.utc_now()

          assocs
          |> Enum.flat_map(fn a ->
            ew = Magus.Memory.MemoryAssociation.effective_weight(a, now)

            cond do
              ew < @min_effective_assoc_weight -> []
              MapSet.member?(memory_ids, a.memory_a_id) -> [{a.memory_b_id, ew}]
              MapSet.member?(memory_ids, a.memory_b_id) -> [{a.memory_a_id, ew}]
              true -> []
            end
          end)
          |> Enum.reject(fn {id, _w} -> MapSet.member?(memory_ids, id) end)
          |> Enum.uniq_by(fn {id, _w} -> id end)
          |> Enum.sort_by(fn {_id, w} -> w end, :desc)
          |> Enum.take(@max_associated_results)
          |> Enum.map(fn {id, _w} -> id end)

        _ ->
          []
      end

    # Batch query: fetch all associated memories at once
    if associated_ids != [] do
      case Magus.Memory.Memory
           |> Ash.Query.filter(id in ^associated_ids and is_active == true)
           |> Ash.read(authorize?: false) do
        {:ok, memories} ->
          Enum.map(memories, &Map.put(&1, :display_scope, &1.scope))

        _ ->
          []
      end
    else
      []
    end
  rescue
    e ->
      Logger.warning("Failed to expand associations: #{Exception.message(e)}")
      []
  end

  # ============================================================================
  # Hebbian Reinforcement
  # ============================================================================

  defp reinforce_co_retrieved(memory_ids) when length(memory_ids) >= 2 do
    Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
      pairs = for a <- memory_ids, b <- memory_ids, a < b, do: {a, b}

      # Only reinforce a reasonable number of pairs (avoid N^2 explosion).
      # take_random instead of take: with >10 pairs, a deterministic prefix
      # systematically reinforces the same low-UUID pairs every turn.
      pairs
      |> Enum.take_random(@max_reinforcement_pairs)
      |> Enum.each(fn {a, b} ->
        case Magus.Memory.get_association_between(a, b, authorize?: false) do
          {:ok, assoc} when not is_nil(assoc) ->
            Magus.Memory.reinforce_association(assoc, authorize?: false)

          _ ->
            Magus.Memory.create_memory_association(a, b, authorize?: false)
        end
      end)
    end)
  rescue
    e -> Logger.warning("Failed to reinforce co-retrieved memories: #{Exception.message(e)}")
  end

  defp reinforce_co_retrieved(_), do: :ok

  # ============================================================================
  # Context Formatting
  # ============================================================================

  @doc false
  def format_context(important, semantic, global_enabled, opts \\ [])

  def format_context(important, semantic, global_enabled, opts) do
    previews? = Keyword.get(opts, :previews, true)
    profile_document = Keyword.get(opts, :profile_document)

    profile_section = format_profile_section(profile_document)
    important_section = format_important_section(important, previews?)
    semantic_section = format_semantic_section(semantic)

    real_sections = [profile_section, important_section, semantic_section]

    if Enum.all?(real_sections, &(&1 == "" or is_nil(&1))) do
      # No real memory content anywhere (no profile, no important memories,
      # no semantic hits). The global note is a tip/disabled-notice only, it
      # must never be the sole reason this block renders, so bail out here
      # instead of falling through to the note-only content check below.
      ""
    else
      # A profile document already tells the user global memory is active
      # and populated, so the "create/enable global memories" note would be
      # actively wrong here. Only show the note when there's no profile.
      global_note =
        if is_nil(profile_document) do
          format_global_note(global_enabled, important ++ semantic)
        else
          ""
        end

      content =
        [profile_section, important_section, semantic_section, global_note]
        |> Enum.reject(&(&1 == "" or is_nil(&1)))
        |> Enum.join("\n")

      """

      ## Your Memory

      #{content}

      You can search for more context with `search_memories`.
      """
    end
  end

  defp format_profile_section(nil), do: ""

  defp format_profile_section(document) do
    """
    ### User Profile
    #{document}
    """
  end

  defp format_important_section([], _previews?), do: ""

  defp format_important_section(memories, previews?) do
    items =
      memories
      |> Enum.map(&format_important_memory(&1, previews?))
      |> Enum.join("\n")

    """
    ### Key Memories
    #{items}
    """
  end

  defp format_important_memory(memory, previews?) do
    scope_label = scope_display(memory.display_scope)

    kind_label =
      if Map.get(memory, :kind) && memory.kind != :general, do: " [#{memory.kind}]", else: ""

    content_preview = if previews?, do: format_content_preview(memory.content), else: ""

    """
    #### #{memory.name}#{scope_label}#{kind_label}
    #{memory.summary || "(no summary)"}
    #{content_preview}
    """
  end

  defp scope_display(:user), do: " (user)"
  defp scope_display(:agent), do: " (agent)"
  defp scope_display(_), do: ""

  defp format_content_preview(content) when content == %{}, do: ""

  defp format_content_preview(content) do
    content_json = Jason.encode!(content, pretty: true)

    truncated =
      if String.length(content_json) > @max_preview_chars do
        String.slice(content_json, 0, @max_preview_chars - 100) <> "\n... (truncated)"
      else
        content_json
      end

    """
    ```json
    #{truncated}
    ```
    """
  end

  defp format_semantic_section([]), do: ""

  defp format_semantic_section(memories) do
    items =
      memories
      |> Enum.map(fn m ->
        scope = scope_display(m.display_scope)
        "- **#{m.name}**#{scope}: #{m.summary || "(no summary)"}"
      end)
      |> Enum.join("\n")

    """
    ### Relevant Context
    #{items}
    """
  end

  defp format_global_note(false, _memories) do
    "*Note: Global memory is disabled. Enable it in settings to persist preferences across conversations.*"
  end

  defp format_global_note(true, memories) do
    has_global = Enum.any?(memories, fn m -> m.display_scope == :user end)

    if has_global do
      ""
    else
      "*Tip: Create global memories with scope=\"global\" to persist preferences across all conversations.*"
    end
  end

  defp touch_accessed_memories([]), do: :ok

  defp touch_accessed_memories(ids) do
    Magus.Memory.touch_accessed(ids)
  rescue
    e -> Logger.warning("Failed to touch last_accessed_at: #{Exception.message(e)}")
  end
end
