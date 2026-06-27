defmodule Magus.Eval.Subject.SuperBrainDeterministic do
  @moduledoc """
  Offline eval subject: seeds a case's fixture straight into the Layer 2 super
  graph with authored low-dim (8) embeddings, then runs `Retrieval.search`.

  No embedder and no LLM: the authored query vector rides in via the fixture
  and is stashed on `ctx`. The `SuperGraph` row is marked built with a
  read-set snapshot that matches `AccessibleGraphs.for_actor/2`, so
  `Retrieval` takes the super-graph happy path instead of the fan-out
  fallback. Lives in test support (depends on `Magus.Generators`-style ctx).
  """
  @behaviour Magus.Eval.Subject

  alias Magus.Eval.SuperBrain.Fixture
  alias Magus.SuperBrain.AccessibleGraphs
  alias Magus.SuperBrain.EdgeAggregation
  alias Magus.SuperBrain.Retrieval
  alias Magus.SuperBrain.SuperGraph

  require Ash.Query

  @dim 8

  @impl true
  def reset(ctx) do
    super_graph = "super:user:#{ctx.user.id}"
    # Drop the FalkorDB graph if it exists from a prior ingest in this run.
    # No Postgres row exists for a fresh user, so no DB cleanup is needed.
    Magus.Graph.drop(super_graph)
    {:ok, Map.put(ctx, :super_graph, super_graph)}
  end

  @impl true
  def ingest(ctx, [%{role: :fixture, text: text} | _]) do
    %{"fixture" => raw, "query_embedding" => query_embedding} = Jason.decode!(text)
    fixture = Fixture.parse(raw)
    super_graph = ctx.super_graph

    Magus.Graph.Vector.create_index(super_graph, "CanonicalEntity", "embedding",
      dim: @dim,
      similarity: :cosine
    )

    seed_canonicals(super_graph, fixture)
    seed_edges(super_graph, fixture)
    seed_sources(super_graph, fixture)
    seed_super_row(ctx.user, super_graph)

    {:ok, Map.put(ctx, :query_embedding, query_embedding)}
  end

  @impl true
  def query(ctx, question) do
    case Retrieval.search(ctx.user,
           query: question,
           query_embedding: ctx.query_embedding,
           limit: 10
         ) do
      {:ok, %{entities: entities}} ->
        {:ok, %{answer: top_name(entities), meta: %{retrieved: retrieved(entities)}}}

      {:ok, list} when is_list(list) ->
        {:ok, %{answer: "", meta: %{retrieved: legacy_retrieved(list)}}}

      {:ok, %{error: reason}} ->
        {:ok, %{answer: "", meta: %{retrieved: [], error: reason}}}

      _ ->
        {:ok, %{answer: "", meta: %{retrieved: []}}}
    end
  end

  # --- seeding ---

  defp seed_canonicals(super_graph, fixture) do
    Enum.each(fixture.entities, fn e ->
      Magus.Graph.upsert_node(super_graph, "CanonicalEntity", %{
        id: e.key,
        name: e.name,
        primary_type: e.type,
        normalized_subtype: e.normalized_subtype,
        embedding: e.embedding,
        trust_tier: e.trust_tier,
        importance_score: 1.0,
        source_count: 1
      })
    end)
  end

  defp seed_edges(super_graph, fixture) do
    fixture.edges
    |> Enum.map(fn edge ->
      %{
        from: edge.from,
        to: edge.to,
        predicate: edge.predicate,
        confidence: edge.confidence,
        trust_tier: edge.trust_tier,
        source_graph: "fixture"
      }
    end)
    |> EdgeAggregation.aggregate()
    |> Enum.each(fn agg ->
      Magus.Graph.upsert_edge(
        super_graph,
        %{
          from_label: "CanonicalEntity",
          from_id: agg.from,
          to_label: "CanonicalEntity",
          to_id: agg.to
        },
        "RELATES_TO",
        %{
          predicate: agg.predicate,
          confidence: agg.confidence,
          trust_tier: agg.trust_tier,
          contested: agg.contested,
          predicate_breakdown: Jason.encode!(agg.predicate_breakdown),
          appearance_count: agg.appearance_count
        }
      )
    end)
  end

  defp seed_sources(super_graph, fixture) do
    Enum.each(fixture.sources, fn s ->
      pointer_id = "ptr-" <> s.entity

      Magus.Graph.upsert_node(super_graph, "SourcePointer", %{
        id: pointer_id,
        graph_name: "fixture",
        source_node_id: s.entity,
        source_refs:
          Jason.encode!([%{resource_type: s.resource_type, resource_id: s.resource_id}])
      })

      Magus.Graph.upsert_edge(
        super_graph,
        %{
          from_label: "CanonicalEntity",
          from_id: s.entity,
          to_label: "SourcePointer",
          to_id: pointer_id
        },
        "APPEARS_IN",
        %{graph_name: "fixture", mention_count: 1, source_weight: 1.0}
      )
    end)
  end

  defp seed_super_row(user, super_graph) do
    snapshot =
      user
      |> AccessibleGraphs.for_actor(workspace_context: nil)
      |> Enum.reject(&String.starts_with?(&1, "super:"))
      |> Enum.sort()
      |> Enum.map(fn name -> %{"graph_name" => name} end)

    # Fetch or create the SuperGraph row. Runner.run calls reset+ingest per
    # case, so a second case for the same user finds the row already there.
    row =
      case SuperGraph
           |> Ash.Query.filter(user_id == ^user.id and is_nil(workspace_id))
           |> Ash.read_one(authorize?: false) do
        {:ok, %SuperGraph{} = existing} ->
          existing

        _ ->
          {:ok, created} =
            SuperGraph
            |> Ash.Changeset.for_create(:create, %{
              accessor_type: :user,
              user_id: user.id,
              workspace_id: nil,
              graph_name: super_graph
            })
            |> Ash.create(authorize?: false)

          created
      end

    {:ok, _} =
      row
      |> Ash.Changeset.for_update(:mark_built, %{
        read_set_snapshot: snapshot,
        canonical_entity_count: 0,
        canonical_edge_count: 0,
        last_build_duration_ms: 1
      })
      |> Ash.update(authorize?: false)
  end

  # --- result shaping ---

  defp retrieved(entities) do
    Enum.map(entities, fn e ->
      %{
        name: Map.get(e, :name),
        type: Map.get(e, :primary_type) || Map.get(e, :type),
        score: Map.get(e, :score)
      }
    end)
  end

  defp legacy_retrieved(list) do
    Enum.map(list, fn r ->
      entity = Map.get(r, :entity) || %{}

      %{
        name: Map.get(entity, :name),
        type: Map.get(entity, :type),
        score: Map.get(r, :similarity)
      }
    end)
  end

  defp top_name([]), do: ""
  defp top_name([first | _]), do: Map.get(first, :name) || ""
end
