defmodule Magus.Search do
  @moduledoc """
  Unified parallel search across all searchable resources.

  Searches messages, conversations, prompts, skills, and memory resources
  concurrently using PostgreSQL full-text search with trigram fuzzy matching.
  """

  require Logger

  @type result_type :: :message | :conversation | :prompt | :skill | :resource | :chunk

  @type search_result :: %{
          type: result_type(),
          id: String.t(),
          title: String.t(),
          snippet: String.t(),
          score: float(),
          metadata: map()
        }

  @type search_options :: [
          types: [result_type()],
          limit: pos_integer(),
          actor: term(),
          timeout: pos_integer()
        ]

  @default_types [:message, :conversation, :prompt, :skill, :resource, :chunk]
  @default_limit 20
  @default_timeout 5_000

  @doc """
  Search across all resource types in parallel.

  ## Options

    * `:types` - List of types to search (default: all)
    * `:limit` - Max total results (default: 20)
    * `:actor` - The actor for authorization (required for policy enforcement)
    * `:timeout` - Timeout per search in ms (default: 5000)

  ## Examples

      Magus.Search.search("hello", actor: current_user)
      Magus.Search.search("project notes", types: [:message, :prompt], limit: 10)
  """
  @spec search(String.t(), search_options()) :: {:ok, [search_result()]} | {:error, term()}
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) and byte_size(query) >= 2 do
    types = Keyword.get(opts, :types, @default_types)
    limit = Keyword.get(opts, :limit, @default_limit)
    actor = Keyword.get(opts, :actor)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Calculate per-type limit (fetch extra for better final ranking)
    per_type_limit = ceil(limit / length(types)) + 5

    results =
      types
      |> Task.async_stream(
        fn type -> search_type(type, query, per_type_limit, actor) end,
        max_concurrency: length(types),
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, results}} ->
          results

        {:ok, {:error, reason}} ->
          Logger.warning("Search failed for type: #{inspect(reason)}")
          []

        {:exit, :timeout} ->
          Logger.warning("Search timed out")
          []
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    {:ok, results}
  end

  def search(_query, _opts), do: {:ok, []}

  # ============================================
  # Type-specific search implementations
  # ============================================

  defp search_type(:message, query, limit, actor) do
    Magus.Chat.fulltext_search_message!(query, page: [limit: limit], actor: actor)
    |> extract_paginated_results()
    |> transform_results(:message, fn msg ->
      %{
        type: :message,
        id: msg.id,
        title: truncate(msg.text, 60),
        snippet: highlight_snippet(msg.text, query),
        score: calculate_score(msg.text, query),
        metadata: %{
          conversation_id: msg.conversation_id,
          created_at: msg.inserted_at
        }
      }
    end)
  rescue
    e ->
      Logger.warning("Message search failed: #{inspect(e)}")
      {:ok, []}
  end

  defp search_type(:conversation, query, limit, actor) do
    Magus.Chat.fulltext_search_conversation!(query, page: [limit: limit], actor: actor)
    |> extract_paginated_results()
    |> transform_results(:conversation, fn conv ->
      %{
        type: :conversation,
        id: conv.id,
        title: conv.title || "Untitled",
        snippet: highlight_snippet(conv.title || "", query),
        score: calculate_score(conv.title || "", query),
        metadata: %{
          created_at: conv.inserted_at
        }
      }
    end)
  rescue
    e ->
      Logger.warning("Conversation search failed: #{inspect(e)}")
      {:ok, []}
  end

  defp search_type(:prompt, query, limit, actor) do
    Magus.Library.fulltext_search_prompt!(query, page: [limit: limit], actor: actor)
    |> extract_paginated_results()
    |> transform_results(:prompt, fn prompt ->
      %{
        type: :prompt,
        id: prompt.id,
        title: prompt.name,
        snippet: highlight_snippet(prompt.content, query),
        score: calculate_score(prompt.name <> " " <> (prompt.content || ""), query),
        metadata: %{
          prompt_type: prompt.type,
          is_public: prompt.is_public,
          created_at: prompt.inserted_at
        }
      }
    end)
  rescue
    e ->
      Logger.warning("Prompt search failed: #{inspect(e)}")
      {:ok, []}
  end

  defp search_type(:skill, query, limit, actor) do
    Magus.Skills.fulltext_search_skill!(query, page: [limit: limit], actor: actor)
    |> extract_paginated_results()
    |> transform_results(:skill, fn skill ->
      text = Enum.join([skill.name, skill.display_name || "", skill.description || ""], " ")

      %{
        type: :skill,
        id: skill.id,
        title: skill.display_name || skill.name,
        snippet: highlight_snippet(skill.description || skill.body || "", query),
        score: calculate_score(text, query),
        metadata: %{
          has_executable_bundle: skill.has_executable_bundle,
          workspace_id: skill.workspace_id,
          created_at: skill.inserted_at
        }
      }
    end)
  rescue
    e ->
      Logger.warning("Skill search failed: #{inspect(e)}")
      {:ok, []}
  end

  defp search_type(:resource, query, limit, actor) do
    Magus.Files.fulltext_search_file!(query, page: [limit: limit], actor: actor)
    |> extract_paginated_results()
    |> transform_results(:resource, fn file ->
      %{
        type: :resource,
        id: file.id,
        title: file.name,
        snippet: highlight_snippet(file.name, query),
        score: calculate_score(file.name, query),
        metadata: %{
          resource_type: file.type,
          mime_type: file.mime_type,
          created_at: file.inserted_at
        }
      }
    end)
  rescue
    e ->
      Logger.warning("File search failed: #{inspect(e)}")
      {:ok, []}
  end

  defp search_type(:chunk, query, limit, actor) do
    Magus.Files.fulltext_search_chunk!(query, page: [limit: limit], actor: actor)
    |> extract_paginated_results()
    |> transform_results(:chunk, fn chunk ->
      %{
        type: :chunk,
        id: chunk.id,
        title: chunk.file.name,
        snippet: highlight_snippet(chunk.content, query),
        score: calculate_score(chunk.content, query),
        metadata: %{
          file_id: chunk.file_id,
          file_name: chunk.file.name,
          position: chunk.position
        }
      }
    end)
  rescue
    e ->
      Logger.warning("Chunk search failed: #{inspect(e)}")
      {:ok, []}
  end

  # ============================================
  # Helpers
  # ============================================

  defp extract_paginated_results(%Ash.Page.Offset{results: results}), do: results
  defp extract_paginated_results(results) when is_list(results), do: results

  defp transform_results(records, _type, mapper) when is_list(records) do
    {:ok, Enum.map(records, mapper)}
  end

  defp truncate(nil, _length), do: ""
  defp truncate(text, length) when byte_size(text) <= length, do: text
  defp truncate(text, length), do: String.slice(text, 0, length) <> "..."

  defp highlight_snippet(nil, _query), do: ""

  defp highlight_snippet(text, query) do
    text_lower = String.downcase(text)
    query_lower = String.downcase(query)

    case :binary.match(text_lower, query_lower) do
      {pos, len} ->
        # Get context around the match
        start_pos = max(0, pos - 40)
        end_pos = min(String.length(text), pos + len + 40)

        prefix = if start_pos > 0, do: "...", else: ""
        suffix = if end_pos < String.length(text), do: "...", else: ""

        # Extract and highlight - escape HTML to prevent XSS
        before = String.slice(text, start_pos, pos - start_pos) |> html_escape()
        match = String.slice(text, pos, len) |> html_escape()
        after_text = String.slice(text, pos + len, end_pos - pos - len) |> html_escape()

        "#{prefix}#{before}<mark>#{match}</mark>#{after_text}#{suffix}"

      :nomatch ->
        text |> truncate(100) |> html_escape()
    end
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  @doc """
  Calculate a simple relevance score.

  Combines exact match bonus with fuzzy similarity.
  """
  def calculate_score(nil, _query), do: 0.0

  def calculate_score(text, query) do
    text_lower = String.downcase(text)
    query_lower = String.downcase(query)

    exact_match_bonus = if String.contains?(text_lower, query_lower), do: 0.5, else: 0.0

    # Simple Jaccard-like similarity
    text_words = text_lower |> String.split(~r/\s+/) |> MapSet.new()
    query_words = query_lower |> String.split(~r/\s+/) |> MapSet.new()

    intersection = MapSet.intersection(text_words, query_words) |> MapSet.size()
    union = MapSet.union(text_words, query_words) |> MapSet.size()

    word_similarity = if union > 0, do: intersection / union, else: 0.0

    # Combine scores
    exact_match_bonus + word_similarity * 0.5
  end
end
