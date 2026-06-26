defmodule Magus.SuperBrain.Iter3E2ETest do
  @moduledoc """
  End-to-end happy path for the Super Brain iter3 pipeline.

  Walks the FULL chain across all four Layer 1 source resource types:

    1. Create a brain page, user memory, file chunk, and draft.
    2. Drain the extraction queue (each resource triggers
       `ExtractBrainPage` / `ExtractMemory` / `ExtractFileChunk` /
       `ExtractDraft`, which writes into a Layer 1 graph and then
       enqueues `BuildSuperIncremental` via the fan-out in
       `ExtractBase`).
    3. Drain again so the `BuildSuperIncremental` jobs from the fan-out
       actually execute (they were enqueued during step 2).
    4. Explicitly run `BuildSuperFull` for the user's personal super
       graph to pin the final state (full rebuild aggregates the
       cross-graph `:RELATES_TO` edges that the incremental defers).

  Asserts that the user's super graph contains exactly one canonical
  `Daniel` node with `:APPEARS_IN` edges pointing at all four Layer 1
  source graph names. This is the iter3 invariant: cross-resource fusion
  collapses the four `Entity` instances (one per source graph) into a
  single `:CanonicalEntity` because they share `(type, normalized_subtype)`
  and have cosine similarity 1.0 on identical mock embeddings.

  Tagged `:integration` so callers without FalkorDB can opt out.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  @moduletag :integration

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "brain + memory + file chunk + draft fuse to one canonical in the super graph" do
    user = generate(user())
    brain = generate(brain(user_id: user.id))

    page =
      brain_page(
        brain_id: brain.id,
        user_id: user.id,
        content: "Daniel works."
      )

    memory = memory(user_id: user.id, scope: :user, summary: "Daniel is the user.")
    file = generate(file(user_id: user.id, type: :text))
    _chunk = generate(chunk(file_id: file.id, content: "Daniel uploaded this."))
    draft = draft(user_id: user.id, content: "Daniel's draft.")

    super_graph = "super:user:#{user.id}"

    on_exit(fn ->
      Magus.Graph.drop("brain:#{brain.id}")
      Magus.Graph.drop("memories:user:#{user.id}")
      Magus.Graph.drop("files:user:#{user.id}")
      Magus.Graph.drop("drafts:user:#{user.id}")
      Magus.Graph.drop(super_graph)
    end)

    # All four extractions must produce identical non-zero embeddings so
    # the Daniel entities cluster into ONE canonical at BuildSuper time
    # (cosine similarity 1.0 >= the 0.95 merge threshold). The default
    # `ResourceCase` stub returns zero-vectors, which would still cluster
    # because cosine_similarity treats zero-vectors as 0.0 similarity; we
    # use a unit vector instead so the math is unambiguous.
    unit_vec = [1.0 | List.duplicate(0.0, 1535)]

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
      {:ok, Enum.map(texts, fn _ -> unit_vec end)}
    end)

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
      {:ok, unit_vec}
    end)

    # Each Layer 1 extraction emits the SAME `Daniel` entity tuple
    # (`person` / `user`) so the four instances cluster into a single
    # canonical at BuildSuper time. `stub` (not `expect`) tolerates any
    # call count: extraction retries or fan-out churn cannot break the
    # test because of an off-by-one expectation.
    ok_daniel = fn _, _ ->
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Daniel","type":"person","subtype":"user","confidence":0.9}],"edges":[]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "test",
           prompt_tokens: 10,
           completion_tokens: 5,
           total_tokens: 15,
           input_cost: Decimal.new("0.001"),
           output_cost: Decimal.new("0.002"),
           total_cost: Decimal.new("0.003")
         }
       }}
    end

    Mox.stub(Magus.SuperBrain.LLMMock, :complete, ok_daniel)

    # First drain: extraction workers run, each writes its Layer 1 graph
    # and enqueues a `BuildSuperIncremental` via the fan-out in
    # `ExtractBase.enqueue_build_super_fan_out/1`. The fan-out enqueue
    # happens OUTSIDE the extraction's transaction, so the incremental
    # jobs become visible only after this drain returns.
    Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

    # Second drain: the `BuildSuperIncremental` jobs enqueued by the
    # first drain now execute. Any further fan-out (none expected here)
    # would also drain.
    Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

    # Explicit full build pins the final state. The incremental defers
    # cross-graph `:RELATES_TO` aggregation to the nightly full rebuild,
    # so we run it manually here for a deterministic assertion.
    assert :ok =
             perform_job(Magus.SuperBrain.Workers.BuildSuperFull, %{
               "accessor_type" => "user",
               "user_id" => user.id,
               "workspace_id" => nil
             })

    # One canonical Daniel with source_count = 4 (one per Layer 1 graph).
    {:ok, result} =
      Magus.Graph.query(
        super_graph,
        "MATCH (c:CanonicalEntity {name: 'Daniel'}) RETURN c.source_count"
      )

    assert [[source_count]] = result.rows
    # FalkorDB returns numbers as strings in verbose mode; tolerate both
    # shapes so the assertion is robust to driver-level changes.
    assert source_count in [4, "4"]

    # All four Layer 1 graph names appear via `:APPEARS_IN` edges. This
    # is the load-bearing invariant: every source resource type emitted
    # a `Daniel` entity that survived clustering and got a SourcePointer
    # in the super graph.
    {:ok, sources} =
      Magus.Graph.query(
        super_graph,
        "MATCH (c:CanonicalEntity {name: 'Daniel'})-[:APPEARS_IN]->(s:SourcePointer) RETURN s.graph_name"
      )

    graph_names = sources.rows |> List.flatten() |> Enum.uniq() |> Enum.sort()

    assert "brain:#{brain.id}" in graph_names
    assert "memories:user:#{user.id}" in graph_names
    assert "files:user:#{user.id}" in graph_names
    assert "drafts:user:#{user.id}" in graph_names

    # Silence the unused-binding warnings for the resources whose IDs we
    # don't reference after creation. The generators' side effects
    # (`ExtractMemory` / `ExtractDraft` after_action enqueue) are the
    # load-bearing observable.
    _ = page
    _ = memory
    _ = draft
  end
end
