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
  alias Magus.SuperBrain.Workers.BuildSuperFull

  @impl true
  def reset(ctx) do
    brain = Magus.Generators.generate(Magus.Generators.brain(user_id: ctx.user.id))
    super_graph = "super:user:#{ctx.user.id}"
    Magus.Graph.drop("brain:#{brain.id}")
    Magus.Graph.drop(super_graph)
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

    :ok =
      BuildSuperFull.perform(%Oban.Job{
        args: %{"accessor_type" => "user", "user_id" => ctx.user.id, "workspace_id" => nil}
      })

    {:ok, ctx}
  end

  @impl true
  def query(ctx, question) do
    {:ok, embedding} = EmbeddingModel.embed(question)

    case Magus.SuperBrain.Retrieval.search(ctx.user,
           query: question,
           query_embedding: embedding,
           limit: 10
         ) do
      {:ok, %{entities: entities}} ->
        {:ok, %{answer: "", meta: %{retrieved: shape(entities)}}}

      _ ->
        {:ok, %{answer: "", meta: %{retrieved: []}}}
    end
  end

  defp shape(entities) do
    Enum.map(entities, fn e ->
      %{name: Map.get(e, :name), type: Map.get(e, :primary_type) || Map.get(e, :type)}
    end)
  end
end
