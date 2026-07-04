defmodule Magus.SuperBrain.E2ETest do
  @moduledoc """
  End-to-end happy path for the Super Brain iter2 pipeline.

  Walks the full chain from a brain page create through the AshOban trigger,
  the `ExtractBrainPage` worker, FalkorDB writes, and the
  `MessageUsage` row produced by `ExtractBase`.

  Tagged `:integration` so callers can opt out when FalkorDB is not
  reachable on the host running the suite. `test_helper.exs` does NOT
  exclude this tag by default; readers can pass `--exclude integration`.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  require Ash.Query

  alias Magus.SuperBrain.Episode

  @moduletag :integration

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "brain page edit triggers extraction, populates FalkorDB, records usage" do
    user = generate(user())
    brain = generate(brain(user_id: user.id))

    # Creating the page enqueues the extraction worker via the page's
    # `after_action` hook in `lib/magus/brain/page.ex`.
    page =
      brain_page(
        brain_id: brain.id,
        user_id: user.id,
        content: "Daniel works on Project X"
      )

    graph = "brain:#{brain.id}"
    on_exit(fn -> Magus.Graph.drop(graph) end)

    expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Daniel","type":"person","subtype":null,"confidence":0.9},{"name":"Project X","type":"project","subtype":null,"confidence":0.8}],"claims":[{"subject_name":"Daniel","object_name":"Project X","predicate":"works_on","polarity":"affirms","claim_text":"Daniel works on Project X.","confidence":0.85}]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "test",
           prompt_tokens: 100,
           completion_tokens: 50,
           total_tokens: 150,
           input_cost: Decimal.new("0.001"),
           output_cost: Decimal.new("0.002"),
           total_cost: Decimal.new("0.003")
         }
       }}
    end)

    # The trigger (Task 17) enqueued the worker when the brain_page
    # generator created the page above.
    assert_enqueued(
      worker: Magus.SuperBrain.Workers.ExtractBrainPage,
      args: %{"resource_id" => page.id},
      queue: :super_brain_extraction
    )

    # Drain the queue so the worker actually runs in-process.
    %{success: success_count, failure: failure_count} =
      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

    assert failure_count == 0, "expected no worker failures, drained: #{success_count} ok"
    assert success_count >= 1

    # 1) Episode is :extracted.
    {:ok, episode} =
      Episode
      |> Ash.Query.filter(resource_type == :brain_page and resource_id == ^page.id)
      |> Ash.read_one(authorize?: false)

    assert episode.status == :extracted

    # 2) FalkorDB has the entity node.
    {:ok, entity_result} =
      Magus.Graph.query(graph, "MATCH (e:Entity {name: 'Daniel'}) RETURN e.name")

    assert [["Daniel"]] = entity_result.rows

    # 2a) Spec schema (closes D1): an Episode node was written and
    # linked to each Entity via HAS_ENTITY. The default
    # `Magus.Embeddings.BatchEmbedderMock` stub in `Magus.ResourceCase`
    # provides zero-vectors so the embedding properties land too.
    {:ok, episode_result} =
      Magus.Graph.query(graph, "MATCH (ep:Episode) RETURN ep.resource_type")

    assert [["brain_page"]] = episode_result.rows

    {:ok, has_entity_result} =
      Magus.Graph.query(
        graph,
        "MATCH (ep:Episode)-[:HAS_ENTITY]->(e:Entity {name: 'Daniel'}) RETURN e.name"
      )

    assert [["Daniel"]] = has_entity_result.rows

    # 3) FalkorDB has the RELATES_TO edge between the two entities.
    # The atom-safe sanitiser routes the mocked predicate "works_on" through
    # `String.to_existing_atom/1`: when the atom is already loaded (e.g. by
    # `sanitizer_test.exs` earlier in the same VM), it survives as
    # `:works_on`; otherwise the sanitiser falls back to the canonical
    # `:relates_to`. The load-bearing assertion is that the edge was
    # materialised at all, which proves entity- and edge-endpoint IDs hash
    # consistently. Accept either predicate.
    {:ok, edge_result} =
      Magus.Graph.query(
        graph,
        "MATCH (a:Entity {name: 'Daniel'})-[r:RELATES_TO]->(b:Entity {name: 'Project X'}) RETURN r.predicate"
      )

    assert [[predicate]] = edge_result.rows
    assert predicate in ["relates_to", "works_on"]

    # 4) MessageUsage row was written for the extraction call.
    {:ok, usage_rows} =
      Magus.Usage.MessageUsage
      |> Ash.Query.filter(user_id == ^user.id and usage_type == :super_brain_extraction)
      |> Ash.read(authorize?: false)

    assert length(usage_rows) >= 1
    row = hd(usage_rows)
    assert row.prompt_tokens == 100
    assert row.completion_tokens == 50
    assert Decimal.equal?(row.total_cost, Decimal.new("0.003"))
  end
end
