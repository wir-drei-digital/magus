defmodule Magus.SuperBrain.Tools.Search do
  @moduledoc """
  Jido tool that searches the user's super brain across every accessible
  source graph (memories, files, drafts, brains) and returns ranked
  entities with provenance.

  Flow:

    1. Embed the natural language query via the configured embedder
       (production: `Magus.Embeddings.OpenAIEmbedder`, tests: a Mox mock).
    2. Resolve the calling user as an Ash actor so `AccessibleGraphs`
       authorizes brain reads correctly.
    3. Fan out via `Magus.SuperBrain.Retrieval.search/2`, which performs
       per-graph vector recall + 1-hop graph verification and ranks
       candidates with the composite ranker.
    4. Project each candidate to a flat payload suitable for the LLM.
  """

  use Jido.Action,
    name: "super_brain_search",
    description: """
    Search your accumulated knowledge for distilled cross-source facts
    (claims) and entities, with citations. Prefer get_dossier for one
    specific entity.
    """,
    schema: [
      query: [
        type: :string,
        required: true,
        doc: "Natural language search query"
      ],
      limit: [
        type: :integer,
        required: false,
        default: 10,
        doc: "Maximum number of entities to return"
      ]
    ]

  require Logger

  alias Magus.SuperBrain.Naming
  alias Magus.SuperBrain.Retrieval
  alias Magus.SuperBrain.Retrieval.Ranker

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_param: 3]

  @doc "User-facing display name shown in the UI while this tool is executing."
  def display_name, do: "Searching super brain..."

  @doc "Human-readable output summary for UI display."
  def summarize_output(%{entities: entities}) when is_list(entities) do
    source_count =
      entities
      |> Enum.flat_map(fn e -> Map.get(e, :sources, []) end)
      |> length()

    case length(entities) do
      0 -> "No matches"
      n -> "Found #{n} entities across #{source_count} sources"
    end
  end

  def summarize_output(%{error: :all_graphs_unavailable}) do
    "Super brain is temporarily unavailable; try again shortly"
  end

  def summarize_output(%{error: e}), do: "Error: #{inspect(e)}"
  def summarize_output(_), do: "No results"

  @impl true
  def run(params, context) do
    query = get_param(params, :query)
    limit = get_param(params, :limit, 10)
    user_id = Map.get(context, :user_id)

    cond do
      is_nil(user_id) ->
        {:ok, %{error: "Missing user_id in context"}}

      is_nil(query) or query == "" ->
        {:ok, %{error: "Missing query"}}

      true ->
        do_search(query, limit, user_id, context)
    end
  end

  defp do_search(query, limit, user_id, context) do
    with {:ok, actor} <- fetch_actor(user_id),
         {:ok, %{embedding: embedding, usage: usage}} <- embed(query) do
      # Record the embedding usage (best effort; failures are logged but not
      # propagated, so a usage write hiccup never breaks user search).
      _ = Magus.SuperBrain.Usage.write_message_usage(usage, user_id, :embedding)

      case Retrieval.search(actor,
             query: query,
             query_embedding: embedding,
             workspace_context: Map.get(context, :workspace_id),
             limit: limit
           ) do
        # Super-graph happy path: Layer 2 canonicals wrapped in a map.
        {:ok, %{entities: entities}} when is_list(entities) ->
          projected = project_super_graph_entities(entities)
          {:ok, claims} = Retrieval.search_claims(actor, query_embedding: embedding, limit: 10)
          {:ok, %{entities: attach_claims(projected, claims)}}

        # Super-graph backend errors (e.g. :all_graphs_unavailable or any
        # FalkorDB error surfaced as %{error: reason}). Surface a fixed
        # user-safe string to the LLM instead of `inspect(reason)`, which
        # would leak Redix struct internals and other backend details.
        {:ok, %{error: reason}} ->
          Logger.warning("super_brain_search backend error: #{inspect(reason)}")
          {:ok, %{error: "Super brain temporarily unavailable. Try again shortly."}}

        # Legacy fan-out path (cold-start + read-set drift fallback):
        # a flat list of ranked candidate maps with `entity`/`graph_name`.
        {:ok, results} when is_list(results) ->
          {:ok, %{entities: project_legacy_candidates(results)}}

        {:error, reason} ->
          Logger.warning("super_brain_search failed: #{inspect(reason)}")
          {:ok, %{error: "Super brain temporarily unavailable. Try again shortly."}}
      end
    else
      {:error, reason} ->
        Logger.warning("super_brain_search failed: #{inspect(reason)}")
        {:ok, %{error: "Super brain temporarily unavailable. Try again shortly."}}
    end
  end

  # Super-graph happy path: `Retrieval.search/2` returns canonical entity maps
  # with `primary_type` / `normalized_subtype` plus a `sources` list attached
  # by the provenance walk. Project to a flat payload the LLM can consume,
  # preferring the canonical-layer field names when present and falling back
  # to the legacy `type` / `subtype` keys if a Layer 1 hit ever leaks through.
  defp project_super_graph_entities(entities) do
    Enum.map(entities, fn e ->
      %{
        name: Map.get(e, :name),
        type: Map.get(e, :primary_type) || Map.get(e, :type),
        subtype: Map.get(e, :normalized_subtype) || Map.get(e, :subtype),
        trust_tier: Map.get(e, :trust_tier),
        score: Map.get(e, :score),
        sources: Map.get(e, :sources, [])
      }
    end)
  end

  # Legacy fan-out path: a flat list of candidate maps shaped as
  # `%{entity: %{name, type, trust_tier, ...}, graph_name: g, ...}` produced
  # by `Retrieval.search_one_graph/4`. The composite score is computed via
  # the iter2 ranker since these candidates carry per-graph weights and
  # similarity rather than a pre-computed canonical score.
  defp project_legacy_candidates(results) do
    Enum.map(results, fn candidate ->
      %{
        name: candidate.entity.name,
        type: candidate.entity.type,
        trust_tier: candidate.entity.trust_tier,
        graph_name: candidate.graph_name,
        score: Ranker.score(candidate)
      }
    end)
  end

  # Pure grouping step: attaches the top 2 claims (by list order, i.e. recall
  # rank from `Retrieval.search_claims/2`) to each entity whose `:name` matches
  # a claim's `subject_name` under `Naming.key/1`. No I/O, so it is
  # unit-testable with hand-built entities and claims (no DB, no seeding).
  # Entities with no matching claim get `claims: []`.
  @doc false
  def attach_claims(entities, claims) do
    by_subject = Enum.group_by(claims, &Naming.key(&1.subject_name))

    Enum.map(entities, fn e ->
      key = Naming.key(Map.get(e, :name))

      tops =
        by_subject
        |> Map.get(key, [])
        |> Enum.take(2)
        |> Enum.map(&%{text: &1.claim_text, predicate: &1.predicate})

      Map.put(e, :claims, tops)
    end)
  end

  defp fetch_actor(user_id) do
    case Magus.Accounts.get_user(user_id, authorize?: false) do
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  defp embed(text) do
    Magus.SuperBrain.EmbeddingConfig.embedder().embed(text, [])
  end
end
