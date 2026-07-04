defmodule Magus.Eval.Subject.SuperBrainLive do
  @moduledoc """
  Live eval subject (`:e2e_live`): seeds a case's fixture into a real Layer 1
  brain graph with REAL embeddings, runs the real `BuildSuperFull` to
  materialize Layer 2, then runs `Retrieval.search` with a real query
  embedding.

  Entities are seeded directly (no LLM extraction) so the gold sets stay
  valid, but clustering/fusion, contested aggregation, importance scoring, the
  staged build + swap, and retrieval are all real. Embeddings come from
  `Magus.Files.EmbeddingModel` (the real OpenRouter path), which is
  independent of the mocked `:super_brain_embedder`. Requires
  `OPENROUTER_API_KEY`.
  """
  @behaviour Magus.Eval.Subject

  alias Magus.Eval.SuperBrain.Fixture
  alias Magus.Files.EmbeddingModel
  alias Magus.SuperBrain.Claim
  alias Magus.SuperBrain.Naming
  alias Magus.SuperBrain.Retrieval
  alias Magus.SuperBrain.Workers.BuildSuperFull

  require Ash.Query

  @impl true
  def reset(ctx) do
    super_graph = "super:user:#{ctx.user.id}"

    # Drop all brain L1 graphs the user can currently see, then the super
    # graph. This prevents prior cases' L1 graphs from leaking their entities
    # into later cases' L2 via BuildSuperFull, which pulls from ALL accessible
    # brain graphs.
    Magus.SuperBrain.AccessibleGraphs.for_actor(ctx.user, workspace_context: nil)
    |> Enum.filter(&String.starts_with?(&1, "brain:"))
    |> Enum.each(&Magus.Graph.drop/1)

    Magus.Graph.drop(super_graph)

    # Claims persist in Postgres, not FalkorDB, so dropping the graphs above
    # does not clear them. Delete this user's claim rows so a prior case
    # cannot leak into the next case's search_claims KNN (mirrors the
    # deterministic subject's reset/1).
    Claim
    |> Ash.Query.filter(source_user_id == ^ctx.user.id)
    |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: false)

    brain = Magus.Generators.generate(Magus.Generators.brain(user_id: ctx.user.id))
    {:ok, ctx |> Map.put(:brain, brain) |> Map.put(:super_graph, super_graph)}
  end

  @impl true
  def ingest(ctx, [%{role: :fixture, text: text} | _]) do
    %{"fixture" => raw} = Jason.decode!(text)
    fixture = Fixture.parse(raw)
    graph = "brain:#{ctx.brain.id}"

    Enum.each(fixture.entities, fn e ->
      {:ok, embedding} = EmbeddingModel.embed(e.name)

      Magus.Graph.upsert_node(graph, "Entity", %{
        id: e.key,
        name: e.name,
        type: e.type,
        normalized_subtype: e.normalized_subtype,
        embedding: embedding,
        confidence: e.confidence,
        trust_tier: e.trust_tier
      })
    end)

    Enum.each(fixture.edges, fn edge ->
      Magus.Graph.upsert_edge(
        graph,
        %{from_label: "Entity", from_id: edge.from, to_label: "Entity", to_id: edge.to},
        "RELATES_TO",
        %{predicate: edge.predicate, confidence: edge.confidence, trust_tier: edge.trust_tier}
      )
    end)

    seed_claims(ctx, fixture)

    :ok =
      BuildSuperFull.perform(%Oban.Job{
        args: %{"accessor_type" => "user", "user_id" => ctx.user.id, "workspace_id" => nil}
      })

    {:ok, Map.put(ctx, :claim_case, fixture.claims != [])}
  end

  # Fallback: empty list or unexpected message shape -- no-op rather than crash.
  def ingest(ctx, _), do: {:ok, Map.put(ctx, :claim_case, false)}

  @impl true
  def query(ctx, question) do
    if ctx[:claim_case] do
      query_claims(ctx, question)
    else
      query_entities(ctx, question)
    end
  end

  defp query_claims(ctx, question) do
    {:ok, embedding} = EmbeddingModel.embed(question)
    graph = "brain:#{ctx.brain.id}"

    {:ok, claims} =
      Retrieval.search_claims(ctx.user,
        query_embedding: embedding,
        accessible_graphs: [graph],
        limit: 10
      )

    {:ok, %{answer: "", meta: %{retrieved: Enum.map(claims, &claim_triple/1)}}}
  end

  defp query_entities(ctx, question) do
    {:ok, embedding} = EmbeddingModel.embed(question)

    case Retrieval.search(ctx.user,
           query: question,
           query_embedding: embedding,
           limit: 10
         ) do
      {:ok, %{entities: entities}} ->
        {:ok, %{answer: "", meta: %{retrieved: shape(entities)}}}

      {:ok, %{error: reason}} ->
        {:ok, %{answer: "", meta: %{retrieved: [], error: reason}}}

      _ ->
        {:ok, %{answer: "", meta: %{retrieved: []}}}
    end
  end

  # --- claim seeding ---

  defp seed_claims(_ctx, %{claims: []}), do: :ok

  defp seed_claims(ctx, fixture) do
    graph = "brain:#{ctx.brain.id}"
    ep = seed_episode(graph, ctx.user.id)

    Enum.each(fixture.claims, fn c ->
      {:ok, embedding} = EmbeddingModel.embed(c.claim_text)

      {:ok, _} =
        Claim
        |> Ash.Changeset.for_create(:create, %{
          graph_name: graph,
          episode_id: ep.id,
          source_user_id: ctx.user.id,
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
          embedding: embedding
        })
        |> Ash.create(authorize?: false)
    end)

    :ok
  end

  # Claim.episode_id is a hard DB foreign key (belongs_to :episode,
  # allow_nil? false), so a fabricated UUID violates the constraint on
  # insert. Create a real Episode first and use its id, matching the graph
  # name / source_user_id so the row reads coherently. Mirrors the helper in
  # the deterministic subject (see "Test setup conventions" in the
  # super-brain-claims-v1 plan).
  defp seed_episode(graph_name, user_id) do
    {:ok, ep} =
      Magus.SuperBrain.Episode
      |> Ash.Changeset.for_create(:create, %{
        resource_type: :brain_page,
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

  defp shape(entities) do
    Enum.map(entities, fn e ->
      %{name: Map.get(e, :name), type: Map.get(e, :primary_type) || Map.get(e, :type)}
    end)
  end
end
