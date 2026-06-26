defmodule Mix.Tasks.SuperBrain.Search do
  @shortdoc "Manually query the super brain for a user."

  @moduledoc """
  Run a `Magus.SuperBrain.Retrieval.search/2` query from the command line.

  Useful for poking at the super graph without spinning up a chat
  conversation, e.g. when validating that an extraction landed, that
  canonical fusion worked, or that a new query phrasing surfaces the
  expected entities.

      mix super_brain.search --user alice@example.com --query "what do I know about Daniel"

      # workspace surface instead of personal
      mix super_brain.search --user alice@example.com \\
        --workspace 5e0d... --query "Project X"

      # include noise tier and bump result count
      mix super_brain.search --user alice@example.com \\
        --query "..." --tiers instruction,evidence,noise --limit 50

      # show full payload (entity props, sources, neighborhood support)
      mix super_brain.search --user alice@example.com --query "..." --verbose

  Cold start (no super graph row yet) and read-set drift transparently
  fall back to the iter2 per-Layer-1 fan-out, matching production
  retrieval. Output labels which path served the result.
  """

  use Mix.Task

  alias Magus.Files.EmbeddingModel
  alias Magus.SuperBrain.Retrieval

  @default_limit 10
  @default_tiers "instruction,evidence"

  # Explicit string -> atom map for the trust tiers Retrieval understands.
  # We map explicitly rather than via `String.to_existing_atom/1`: this task
  # parses `--tiers` BEFORE `app.start`, so the modules that define these
  # atoms may not be loaded yet and `to_existing_atom` would raise for every
  # value (including the default and otherwise-valid tiers).
  @allowed_tiers %{
    "instruction" => :instruction,
    "evidence" => :evidence,
    "noise" => :noise
  }

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          user: :string,
          query: :string,
          workspace: :string,
          limit: :integer,
          tiers: :string,
          verbose: :boolean
        ]
      )

    email = Keyword.get(opts, :user) || Mix.raise("--user EMAIL is required")
    query = Keyword.get(opts, :query) || Mix.raise("--query TEXT is required")
    workspace = Keyword.get(opts, :workspace)
    limit = Keyword.get(opts, :limit, @default_limit)
    tiers = parse_tiers(Keyword.get(opts, :tiers, @default_tiers))
    verbose = Keyword.get(opts, :verbose, false)

    Mix.Task.run("app.start")

    actor =
      case Magus.Accounts.get_by_email(email, authorize?: false) do
        {:ok, user} -> user
        {:error, _} -> Mix.raise("No user found with email #{email}")
      end

    Mix.shell().info("Embedding query: #{inspect(query)}")

    embedding =
      case EmbeddingModel.embed(query) do
        {:ok, vec} when is_list(vec) -> vec
        {:error, reason} -> Mix.raise("Embedding failed: #{inspect(reason)}")
      end

    search_opts = [
      query: query,
      query_embedding: embedding,
      workspace_context: workspace,
      trust_tiers: tiers,
      limit: limit
    ]

    Mix.shell().info(
      "Searching as #{email} (#{actor.id})" <>
        if(workspace, do: " in workspace #{workspace}", else: " personal") <>
        ", tiers=#{Enum.join(tiers, ",")}, limit=#{limit}"
    )

    started = System.monotonic_time(:millisecond)
    result = Retrieval.search(actor, search_opts)
    elapsed = System.monotonic_time(:millisecond) - started

    Mix.shell().info("Completed in #{elapsed}ms")
    print_result(result, verbose)
  end

  defp parse_tiers(s) do
    s
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn tier ->
      Map.get(@allowed_tiers, tier) ||
        Mix.raise(
          "Unknown trust tier #{inspect(tier)} in --tiers (allowed: instruction, evidence, noise)"
        )
    end)
  end

  # Retrieval.search/2 returns one of:
  #
  #   {:ok, %{entities: [...]}}          super-graph path
  #   {:ok, [...candidates...]}          legacy fan-out path
  #   {:ok, %{error: reason}}            graph backend unavailable
  #
  defp print_result({:ok, %{entities: entities}}, verbose) do
    Mix.shell().info("Path: super-graph (#{length(entities)} hits)\n")
    Enum.with_index(entities, 1) |> Enum.each(&print_super_hit(&1, verbose))
  end

  defp print_result({:ok, list}, verbose) when is_list(list) do
    Mix.shell().info("Path: legacy fan-out (#{length(list)} hits)\n")
    Enum.with_index(list, 1) |> Enum.each(&print_legacy_hit(&1, verbose))
  end

  defp print_result({:ok, %{error: reason}}, _verbose) do
    Mix.shell().error("Search returned error: #{inspect(reason)}")
  end

  defp print_result({:error, reason}, _verbose) do
    Mix.shell().error("Search failed: #{inspect(reason)}")
  end

  defp print_super_hit({entity, idx}, verbose) do
    name = Map.get(entity, :name) || "<unnamed>"
    type = Map.get(entity, :primary_type) || Map.get(entity, :type) || "?"
    subtype = Map.get(entity, :normalized_subtype) || Map.get(entity, :subtype)
    tier = Map.get(entity, :trust_tier) || "?"
    score = Map.get(entity, :score)
    nb = Map.get(entity, :neighborhood_support)
    importance = Map.get(entity, :importance_score)
    sources = Map.get(entity, :sources, [])

    subtype_str = if subtype && subtype != "", do: "/#{subtype}", else: ""
    Mix.shell().info("#{idx}. #{name}  [#{type}#{subtype_str}, tier=#{tier}]")

    Mix.shell().info(
      "   score=#{fmt(score)}  importance=#{fmt(importance)}  nb_support=#{fmt(nb)}"
    )

    if sources != [] do
      Mix.shell().info("   sources:")

      Enum.each(sources, fn s ->
        Mix.shell().info(
          "     - #{s.graph_name}  mentions=#{s.mention_count}  weight=#{fmt(s.source_weight)}  at=#{s.latest_evidence_at}"
        )
      end)
    end

    if verbose do
      Mix.shell().info("   raw: #{inspect(entity, limit: :infinity, pretty: true)}")
    end

    Mix.shell().info("")
  end

  defp print_legacy_hit({candidate, idx}, verbose) do
    entity = candidate.entity
    name = entity.name || "<unnamed>"
    type = entity.type || "?"
    score = Map.get(candidate, :score) || Magus.SuperBrain.Retrieval.Ranker.score(candidate)

    Mix.shell().info("#{idx}. #{name}  [#{type}, tier=#{entity.trust_tier}]")

    Mix.shell().info(
      "   similarity=#{fmt(candidate.similarity)}  graph=#{candidate.graph_name}  graph_weight=#{fmt(candidate.graph_weight)}  source_weight=#{fmt(candidate.source_weight)}  nb_support=#{fmt(candidate.neighborhood_support)}  score=#{fmt(score)}"
    )

    if verbose do
      Mix.shell().info("   raw: #{inspect(candidate, limit: :infinity, pretty: true)}")
    end

    Mix.shell().info("")
  end

  defp fmt(nil), do: "-"
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt(other), do: inspect(other)
end
