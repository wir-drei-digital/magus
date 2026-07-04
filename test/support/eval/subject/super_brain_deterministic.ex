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
  alias Magus.SuperBrain.Claim
  alias Magus.SuperBrain.EdgeAggregation
  alias Magus.SuperBrain.Naming
  alias Magus.SuperBrain.Retrieval
  alias Magus.SuperBrain.SuperGraph

  require Ash.Query

  @dim 8

  @impl true
  def reset(ctx) do
    super_graph = "super:user:#{ctx.user.id}"
    # Drop the FalkorDB graph if it exists from a prior ingest in this run.
    Magus.Graph.drop(super_graph)

    # Claims persist in Postgres; drop this user's claim rows so a prior case
    # cannot leak into the next case's search_claims KNN (the FalkorDB super
    # graph is already dropped above; this restores the same per-case isolation
    # for the claim layer). No other Postgres cleanup is needed: a fresh user
    # has no SuperGraph row, and seed_super_row/2 upserts the one it needs.
    Claim
    |> Ash.Query.filter(source_user_id == ^ctx.user.id)
    |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: false)

    {:ok, Map.put(ctx, :super_graph, super_graph)}
  end

  @impl true
  def ingest(ctx, [%{role: :fixture, text: text} | _]) do
    decoded = Jason.decode!(text)
    %{"fixture" => raw, "query_embedding" => query_embedding} = decoded
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
    seed_claims(ctx.user, fixture)

    {:ok,
     ctx
     |> Map.put(:query_embedding, query_embedding)
     |> Map.put(:claim_query_embedding, expand(Map.get(decoded, "claim_query_embedding")))}
  end

  @impl true
  def query(ctx, question) do
    if ctx[:claim_query_embedding] do
      {:ok, claims} =
        Retrieval.search_claims(ctx.user,
          query_embedding: ctx.claim_query_embedding,
          accessible_graphs: ["memories:user:#{ctx.user.id}"],
          limit: 10
        )

      {:ok, %{answer: "", meta: %{retrieved: Enum.map(claims, &claim_triple/1)}}}
    else
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

  defp expand(nil), do: nil
  defp expand(%{"hot" => _} = basis), do: Fixture.expand_basis(basis)

  # Seeds `fixture.claims` into `memories:user:<id>` under one real Episode per
  # case: `Claim.episode_id` is a hard DB foreign key, so a fabricated UUID
  # would violate the constraint on insert. A no-op when the fixture carries
  # no claims (entity-only cases behave exactly as before).
  defp seed_claims(_user, %{claims: []}), do: :ok

  defp seed_claims(user, fixture) do
    graph = "memories:user:#{user.id}"
    ep = seed_episode(graph, user.id)

    Enum.each(fixture.claims, fn c ->
      {:ok, _} =
        Claim
        |> Ash.Changeset.for_create(:create, %{
          graph_name: graph,
          episode_id: ep.id,
          source_user_id: user.id,
          subject_name: c.subject,
          subject_key: Naming.key(c.subject),
          object_name: c.object,
          object_key: Naming.key(c.object),
          predicate: c.predicate,
          polarity: String.to_existing_atom(c.polarity),
          claim_text: c.claim_text,
          confidence: c.confidence,
          trust_tier: :evidence,
          asserted_at: DateTime.utc_now(),
          embedding: c.embedding && Fixture.expand_basis(c.embedding)
        })
        |> Ash.create(authorize?: false)
    end)

    :ok
  end

  # Claim.episode_id is a hard DB foreign key (belongs_to :episode,
  # allow_nil? false), so a fabricated UUID violates the constraint on
  # insert. Create a real Episode first and use its id, matching the
  # graph_name / source_user_id so the row reads coherently. Mirrors the
  # helper copied verbatim across the Claim test suite (see "Test setup
  # conventions" in the super-brain-claims-v1 plan).
  defp seed_episode(graph_name, user_id) do
    {:ok, ep} =
      Magus.SuperBrain.Episode
      |> Ash.Changeset.for_create(:create, %{
        resource_type: :memory,
        resource_id: Ash.UUID.generate(),
        graph_name: graph_name,
        raw_text: "seed",
        source_user_id: user_id,
        extractor_version: "test"
      })
      |> Ash.create(authorize?: false)

    ep
  end

  defp claim_triple(c),
    do: %{subject: c.subject_name, predicate: c.predicate, object: c.object_name}

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
