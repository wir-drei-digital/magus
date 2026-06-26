defmodule Magus.SuperBrain.Workers.ExtractBaseTest do
  @moduledoc """
  Contract tests for `Magus.SuperBrain.Workers.ExtractBase`.

  Each per-resource worker (ExtractBrainPage, plus the iter2 file/memory/draft
  workers) plugs into this shared pipeline via a `load/1` callback. The tests
  here use a minimal in-test worker module so the per-resource concerns
  (block serialisation, graph routing) are kept out of scope.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  alias Magus.SuperBrain.Usage

  require Ash.Query

  setup :set_mox_from_context
  setup :verify_on_exit!

  defmodule TestWorker do
    @moduledoc false
    use Magus.SuperBrain.Workers.ExtractBase, queue: :super_brain_extraction

    @extractor_version "test_worker@1.0"

    @impl true
    def extractor_version, do: @extractor_version

    @impl true
    def load(%{"user_id" => uid, "text" => text, "graph" => graph} = args) do
      {:ok,
       %{
         user_id: uid,
         raw_text: text,
         graph_name: graph,
         resource_type: :brain_page,
         resource_id: Map.get(args, "resource_id", Ash.UUID.generate()),
         source_weight: 1.0,
         extra_node_props: %{}
       }}
    end

    def load(_), do: {:error, :unknown_args}
  end

  defp on_exit_drop_graph(graph) do
    on_exit(fn -> Magus.Graph.drop(graph) end)
  end

  defp ok_one_entity(_messages, _opts) do
    {:ok,
     %{
       content:
         ~s({"entities":[{"name":"T","type":"concept","subtype":null,"confidence":0.8}],"edges":[]}),
       usage: %Usage{
         model_name: "test-model",
         total_tokens: 10,
         prompt_tokens: 5,
         completion_tokens: 5,
         input_cost: Decimal.new("0"),
         output_cost: Decimal.new("0"),
         total_cost: Decimal.new("0")
       }
     }}
  end

  describe "run_pipeline/2" do
    test "returns :ok on the happy path and writes to graph" do
      user = generate(user())
      graph = "test:base:#{user.id}:#{System.unique_integer([:positive])}"
      on_exit_drop_graph(graph)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_one_entity/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "hello",
                 "graph" => graph
               })

      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'T'}) RETURN e.name")

      assert [["T"]] = result.rows
    end

    test "returns {:cancel, :budget_exceeded} when budget is saturated" do
      user = generate(user())
      date = Date.utc_today()

      # Pin a tiny ceiling and consume it, independent of the global default.
      Ash.create!(
        Magus.SuperBrain.ExtractionBudget,
        %{user_id: user.id, date: date, ceiling_call_count: 1},
        action: :upsert,
        authorize?: false
      )

      :ok =
        Magus.SuperBrain.ExtractionBudget.atomic_increment(user.id, date,
          calls: 1,
          cost_cents: 0
        )

      graph = "test:base:budget:#{System.unique_integer([:positive])}"
      on_exit_drop_graph(graph)

      assert {:cancel, :budget_exceeded} =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "hello",
                 "graph" => graph
               })
    end

    test "returns {:error, reason} when load fails" do
      assert {:error, :unknown_args} = perform_job(TestWorker, %{"bogus" => true})
    end
  end

  # ---------------------------------------------------------------------------
  # Iter4 Task 6: canonicalize merges must preserve edge properties
  # (predicate, confidence, trust_tier) when re-pointing RELATES_TO edges
  # from loser to winner. Pre-iter4 the do_merge step used a bare MERGE,
  # which silently dropped every loser-side edge property.
  # ---------------------------------------------------------------------------

  defp unit_vec do
    [1.0 | List.duplicate(0.0, 1535)]
  end

  defp stub_unit_embeddings do
    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
      {:ok, Enum.map(texts, fn _ -> unit_vec() end)}
    end)

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
      {:ok, unit_vec()}
    end)

    :ok
  end

  defp ensure_vector_index(graph) do
    _ =
      Magus.Graph.Vector.ensure_index(graph, "Entity", "embedding",
        dim: 1536,
        similarity: :cosine
      )

    :ok
  end

  defp seed_entity(graph, properties) do
    {:ok, _} = Magus.Graph.upsert_node(graph, "Entity", properties)
    :ok
  end

  defp seed_relates_to(graph, from_id, to_id, properties) do
    {:ok, _} =
      Magus.Graph.upsert_edge(
        graph,
        %{from_label: "Entity", from_id: from_id, to_label: "Entity", to_id: to_id},
        "RELATES_TO",
        properties
      )

    :ok
  end

  defp ok_daniel_no_edges(_messages, _opts) do
    {:ok,
     %{
       content:
         ~s({"entities":[{"name":"Daniel","type":"person","subtype":"user","confidence":0.9}],"edges":[]}),
       usage: %Usage{
         model_name: "test-model",
         total_tokens: 1,
         prompt_tokens: 1,
         completion_tokens: 0,
         input_cost: Decimal.new("0"),
         output_cost: Decimal.new("0"),
         total_cost: Decimal.new("0")
       }
     }}
  end

  describe "canonicalize merge preserves edge properties" do
    test "outbound RELATES_TO edge keeps predicate, confidence, trust_tier after merge" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      graph = "test:base:merge_props:#{user.id}:#{System.unique_integer([:positive])}"
      on_exit_drop_graph(graph)

      :ok = ensure_vector_index(graph)

      # Pre-seed two entities: a loser "Daniel" and a third party "ProjectX",
      # plus a RELATES_TO edge between them with fully populated properties.
      # The extraction below upserts a new (different id) "Daniel" via
      # stable_id; canonicalize_inline then merges the seed into it and
      # do_merge must carry the edge properties over to the surviving node.
      :ok =
        seed_entity(graph, %{
          id: "seed-daniel-loser",
          name: "Daniel",
          type: "person",
          normalized_subtype: "user",
          confidence: 0.6,
          extractor: "seed_extractor@test",
          source_id: "seed-source",
          embedding: unit_vec()
        })

      :ok =
        seed_entity(graph, %{
          id: "projectx-fixed-id",
          name: "ProjectX",
          type: "project",
          normalized_subtype: nil,
          confidence: 0.9,
          extractor: "seed_extractor@test",
          source_id: "seed-source",
          embedding: unit_vec()
        })

      :ok =
        seed_relates_to(graph, "seed-daniel-loser", "projectx-fixed-id", %{
          predicate: "works_on",
          confidence: 0.8,
          trust_tier: "provisional",
          extractor: "seed_extractor@test",
          source_id: "seed-source"
        })

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_daniel_no_edges/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "Daniel is the founder.",
                 "graph" => graph
               })

      # Only one Daniel should remain (the canonicalized winner). The
      # surviving Daniel must hold the original edge properties on its
      # RELATES_TO edge to ProjectX.
      {:ok, count_result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'Daniel'}) RETURN count(e)")

      assert [[1]] = count_result.rows

      {:ok, edge_result} =
        Magus.Graph.query(
          graph,
          """
          MATCH (e:Entity {name: 'Daniel'})-[r:RELATES_TO]->(p:Entity {name: 'ProjectX'})
          RETURN r.predicate, r.confidence, r.trust_tier
          """
        )

      assert [[predicate, confidence, trust_tier]] = edge_result.rows
      assert predicate == "works_on"
      assert_in_delta to_float(confidence), 0.8, 1.0e-6
      assert trust_tier == "provisional"
    end

    test "inbound RELATES_TO edge keeps predicate, confidence, trust_tier after merge" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      graph = "test:base:merge_props_in:#{user.id}:#{System.unique_integer([:positive])}"
      on_exit_drop_graph(graph)

      :ok = ensure_vector_index(graph)

      # Same setup but the seeded edge points INTO the loser, so do_merge
      # must re-point an incoming RELATES_TO with its properties intact.
      :ok =
        seed_entity(graph, %{
          id: "seed-daniel-loser-2",
          name: "Daniel",
          type: "person",
          normalized_subtype: "user",
          confidence: 0.6,
          extractor: "seed_extractor@test",
          source_id: "seed-source",
          embedding: unit_vec()
        })

      :ok =
        seed_entity(graph, %{
          id: "acme-fixed-id",
          name: "Acme",
          type: "organization",
          normalized_subtype: nil,
          confidence: 0.9,
          extractor: "seed_extractor@test",
          source_id: "seed-source",
          embedding: unit_vec()
        })

      :ok =
        seed_relates_to(graph, "acme-fixed-id", "seed-daniel-loser-2", %{
          predicate: "employs",
          confidence: 0.75,
          trust_tier: "high",
          extractor: "seed_extractor@test",
          source_id: "seed-source"
        })

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_daniel_no_edges/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "Daniel works at Acme.",
                 "graph" => graph
               })

      {:ok, edge_result} =
        Magus.Graph.query(
          graph,
          """
          MATCH (a:Entity {name: 'Acme'})-[r:RELATES_TO]->(d:Entity {name: 'Daniel'})
          RETURN r.predicate, r.confidence, r.trust_tier
          """
        )

      assert [[predicate, confidence, trust_tier]] = edge_result.rows
      assert predicate == "employs"
      assert_in_delta to_float(confidence), 0.75, 1.0e-6
      assert trust_tier == "high"
    end
  end

  # FalkorDB may return numerics either as floats or as strings; normalize
  # so the assertion is robust to driver-level encoding choices.
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(s) when is_binary(s), do: String.to_float(s)

  # ---------------------------------------------------------------------------
  # Wave 1 Task 1.3: supersede coverage for failed/processing/pending zombies
  # plus find_episode disambiguation by resource_type.
  # ---------------------------------------------------------------------------

  describe "supersede coverage for non-terminal zombies (Wave 1 Task 1.3)" do
    test ":failed prior episode for the same resource gets superseded by next claim" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      graph = "test:base:supersede:#{user.id}:#{System.unique_integer([:positive])}"
      resource_id = Ash.UUID.generate()
      on_exit_drop_graph(graph)

      # Seed a stale `:failed` Episode for the same (resource_type,
      # resource_id). Previously only `:extracted` priors were superseded,
      # so this row would survive forever and accumulate.
      {:ok, stale} =
        Ash.create(
          Magus.SuperBrain.Episode,
          %{
            resource_type: :brain_page,
            resource_id: resource_id,
            graph_name: graph,
            raw_text: "previous attempt",
            source_user_id: user.id
          },
          actor: user
        )

      {:ok, stale} = Ash.update(stale, %{}, action: :mark_processing, actor: user)
      {:ok, stale} = Ash.update(stale, %{last_error: "boom"}, action: :mark_failed, actor: user)
      assert stale.status == :failed

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_one_entity/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "fresh content",
                 "graph" => graph,
                 "resource_id" => resource_id
               })

      # The prior :failed row must now be :superseded.
      {:ok, reloaded_stale} = Ash.get(Magus.SuperBrain.Episode, stale.id, actor: user)
      assert reloaded_stale.status == :superseded

      # And exactly one fresh :extracted Episode for this resource exists.
      {:ok, current} =
        Magus.SuperBrain.Episode
        |> Ash.Query.filter(
          resource_id == ^resource_id and
            resource_type == :brain_page and
            status == :extracted
        )
        |> Ash.read(authorize?: false)

      assert length(current) == 1
    end

    test "embedder failure surfaces as a worker error, not silent empty-embedding writes" do
      # Wave 1 Task 1.4 regression. Previously embed_text / embed_entities
      # degraded to `{:ok, []}` on embedder errors. Entities then landed in
      # FalkorDB without vectors and became permanently invisible to KNN;
      # the fingerprint gate prevented re-extraction from healing them.
      # The fix returns `{:error, :embedder_unavailable}` so the worker
      # fails and Oban retries with backoff.
      user = generate(user())
      graph = "test:base:embedder_fail:#{user.id}:#{System.unique_integer([:positive])}"
      on_exit_drop_graph(graph)

      # Force the embedder to error. We override the default Mox stub
      # (verify_on_exit! does not flag stubs that go unused).
      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
        {:error, :timeout}
      end)

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn _texts ->
        {:error, :timeout}
      end)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_one_entity/2)

      assert {:error, :embedder_unavailable} =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "fresh content",
                 "graph" => graph
               })

      # No Entity nodes should have been written: write_to_graph short-
      # circuits via the `with` chain BEFORE any write happens.
      {:ok, result} = Magus.Graph.query(graph, "MATCH (e:Entity) RETURN count(e)")
      assert [[0]] = result.rows
    end

    test ":processing prior episode for the same resource gets superseded by next claim" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      graph = "test:base:supersede:proc:#{user.id}:#{System.unique_integer([:positive])}"
      resource_id = Ash.UUID.generate()
      on_exit_drop_graph(graph)

      {:ok, stale} =
        Ash.create(
          Magus.SuperBrain.Episode,
          %{
            resource_type: :brain_page,
            resource_id: resource_id,
            graph_name: graph,
            raw_text: "previous attempt",
            source_user_id: user.id
          },
          actor: user
        )

      {:ok, stale} = Ash.update(stale, %{}, action: :mark_processing, actor: user)
      assert stale.status == :processing

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_one_entity/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "fresh content",
                 "graph" => graph,
                 "resource_id" => resource_id
               })

      {:ok, reloaded_stale} = Ash.get(Magus.SuperBrain.Episode, stale.id, actor: user)
      assert reloaded_stale.status == :superseded
    end
  end

  # ---------------------------------------------------------------------------
  # Wave 3 Task 3.4: stable_id now includes entity type.
  #
  # Pre-iter5 the Layer 1 stable_id was a hash of (graph_name, downcase(name))
  # only, so "Apple" the organization and "apple" the food collided onto a
  # single FalkorDB node and the type property thrashed on every
  # re-extraction. The fix folds the type into the hash so semantically
  # different referents stay separate.
  # ---------------------------------------------------------------------------

  defp ok_two_apples(_messages, _opts) do
    {:ok,
     %{
       content:
         ~s({"entities":[{"name":"Apple","type":"organization","subtype":"company","confidence":0.9},{"name":"Apple","type":"concept","subtype":"food","confidence":0.8}],"edges":[]}),
       usage: %Usage{
         model_name: "test-model",
         total_tokens: 10,
         prompt_tokens: 5,
         completion_tokens: 5,
         input_cost: Decimal.new("0"),
         output_cost: Decimal.new("0"),
         total_cost: Decimal.new("0")
       }
     }}
  end

  describe "Task 3.4: stable_id is type-aware" do
    test "same name with different types in one extraction creates distinct FalkorDB nodes" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      graph = "test:base:stable_id_type:#{user.id}:#{System.unique_integer([:positive])}"
      on_exit_drop_graph(graph)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_two_apples/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "Apple the company vs apple the fruit",
                 "graph" => graph
               })

      {:ok, count_result} =
        Magus.Graph.query(graph, "MATCH (n:Entity {name: 'Apple'}) RETURN count(n)")

      assert [[2]] = count_result.rows

      {:ok, types_result} =
        Magus.Graph.query(
          graph,
          "MATCH (n:Entity {name: 'Apple'}) RETURN n.type ORDER BY n.type"
        )

      assert [["concept"], ["organization"]] = types_result.rows
    end

    test "re-extracting the same content is idempotent (stable_id is deterministic)" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      graph = "test:base:stable_id_idempotent:#{user.id}:#{System.unique_integer([:positive])}"
      resource_id = Ash.UUID.generate()
      on_exit_drop_graph(graph)

      # Two extractions of the same (resource_type, resource_id) but with
      # slightly different raw_text bytes so the fingerprint gate doesn't
      # short-circuit the second run. The deterministic stable_id keyed by
      # `(graph, type, name)` should land both runs on the same FalkorDB
      # node so the entity count stays at 1.
      Mox.expect(Magus.SuperBrain.LLMMock, :complete, 2, &ok_one_entity/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "hello",
                 "graph" => graph,
                 "resource_id" => resource_id
               })

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "hello again",
                 "graph" => graph,
                 "resource_id" => resource_id
               })

      {:ok, count_result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'T'}) RETURN count(e)")

      assert [[1]] = count_result.rows
    end

    test "RELATES_TO endpoint resolution: ambiguous edge endpoint logs telemetry and uses first occurrence" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      graph = "test:base:stable_id_amb:#{user.id}:#{System.unique_integer([:positive])}"
      on_exit_drop_graph(graph)

      # Mock LLM returns two entities with the same name "Daniel" (one
      # :person, one :concept since the test ontology may not have
      # :character) plus an edge whose subject is "Daniel". The edge alone
      # cannot disambiguate which Daniel was meant; we expect the
      # build_entity_type_lookup helper to emit a telemetry counter and
      # bind the edge to the first occurrence (:person).
      ambiguous_payload = fn _messages, _opts ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel","type":"person","subtype":"user","confidence":0.9},{"name":"Daniel","type":"concept","subtype":"character","confidence":0.7},{"name":"Project X","type":"project","subtype":null,"confidence":0.9}],"edges":[{"subject_name":"Daniel","object_name":"Project X","predicate":"supports","confidence":0.8}]}),
           usage: %Usage{
             model_name: "test-model",
             total_tokens: 10,
             prompt_tokens: 5,
             completion_tokens: 5,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end

      expect(Magus.SuperBrain.LLMMock, :complete, ambiguous_payload)

      handler_ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-ambig-edge-#{System.unique_integer([:positive])}",
        [:super_brain, :sanitizer, :ambiguous_edge_endpoint],
        fn _name, measurements, metadata, _ ->
          send(test_pid, {handler_ref, measurements, metadata})
        end,
        nil
      )

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "Daniel works on Project X",
                 "graph" => graph
               })

      assert_received {^handler_ref, %{count: 1}, %{name: "Daniel"}}

      # The edge should land on the first-occurrence Daniel (the :person).
      {:ok, edge_result} =
        Magus.Graph.query(
          graph,
          """
          MATCH (d:Entity {name: 'Daniel'})-[r:RELATES_TO]->(p:Entity {name: 'Project X'})
          RETURN d.type
          """
        )

      assert [["person"]] = edge_result.rows
    end
  end

  # ---------------------------------------------------------------------------
  # Wave 3 Task 3.6: orphan-only delete in delete_prior_extraction.
  #
  # Pre-iter5 the supersede path DETACH-DELETEd every Entity tagged with the
  # prior Episode's source_id. But Entities are MERGEd by stable_id
  # `(graph_name, type, downcase(name))`, so two resources that mention the
  # same name share ONE FalkorDB node whose source_id property gets
  # overwritten by whichever extractor wrote last. Re-extracting one
  # resource could then delete an Entity that another, still-extracted
  # resource depends on.
  #
  # The fix scopes the delete to ORPHANS: Entity nodes with no remaining
  # HAS_ENTITY edge from any other Episode.
  # ---------------------------------------------------------------------------

  describe "Task 3.6: orphan-only delete in supersede_prior" do
    test "re-extracting resource B does NOT delete entities still owned by resource A" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      graph = "test:base:orphan_delete:#{user.id}:#{System.unique_integer([:positive])}"
      on_exit_drop_graph(graph)

      resource_a = Ash.UUID.generate()
      resource_b = Ash.UUID.generate()

      # Both resources extract a single "T"/:concept entity, which collides
      # on stable_id and produces ONE shared FalkorDB Entity node referenced
      # by two distinct Episode nodes via HAS_ENTITY.
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_one_entity/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "first",
                 "graph" => graph,
                 "resource_id" => resource_a
               })

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_one_entity/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "second",
                 "graph" => graph,
                 "resource_id" => resource_b
               })

      # Confirm precondition: one shared "T" Entity referenced by two
      # Episodes via HAS_ENTITY.
      {:ok, entity_count_before} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'T'}) RETURN count(e)")

      assert [[1]] = entity_count_before.rows

      {:ok, has_entity_count_before} =
        Magus.Graph.query(
          graph,
          "MATCH (ep:Episode)-[r:HAS_ENTITY]->(e:Entity {name: 'T'}) RETURN count(r)"
        )

      assert [[2]] = has_entity_count_before.rows

      # Re-extract resource_b (different text bytes so fingerprint gate
      # does not short-circuit). supersede_prior MUST NOT delete the
      # shared "T" Entity because resource_a's Episode still references it.
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_one_entity/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "second take 2",
                 "graph" => graph,
                 "resource_id" => resource_b
               })

      {:ok, entity_count_after} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'T'}) RETURN count(e)")

      # The shared Entity must still exist (1, not 0). Pre-iter5 the
      # blanket DETACH DELETE for prior source_id matches would have
      # deleted it here.
      assert [[1]] = entity_count_after.rows

      # Both Episodes still have HAS_ENTITY edges to it.
      {:ok, has_entity_count_after} =
        Magus.Graph.query(
          graph,
          "MATCH (ep:Episode)-[r:HAS_ENTITY]->(e:Entity {name: 'T'}) RETURN count(r)"
        )

      assert [[2]] = has_entity_count_after.rows
    end
  end

  # ---------------------------------------------------------------------------
  # Wave 3 Task 3.6: sparse-edges telemetry.
  #
  # The iter4 extraction prompt asks the LLM for N/2 edges with a floor of 2
  # when N >= 3, but it is honor-system. Hub-and-spoke islands and lonely
  # entity lists slip through. Iter5 adds observability: when a batch lands
  # below the floor, emit a telemetry counter + Logger.info so we can
  # measure how often it happens in real traffic.
  # ---------------------------------------------------------------------------

  describe "Task 3.6: sparse-edges telemetry" do
    defp ok_three_entities_no_edges(_messages, _opts) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"A","type":"concept","subtype":null,"confidence":0.8},{"name":"B","type":"concept","subtype":"topic","confidence":0.8},{"name":"C","type":"concept","subtype":"area","confidence":0.8}],"edges":[]}),
         usage: %Usage{
           model_name: "test-model",
           total_tokens: 10,
           prompt_tokens: 5,
           completion_tokens: 5,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end

    test "emits [:super_brain, :extraction, :sparse_edges] when N >= 3 and edges < 2" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      graph = "test:base:sparse:#{user.id}:#{System.unique_integer([:positive])}"
      on_exit_drop_graph(graph)

      handler_ref = make_ref()
      handler_id = "test-sparse-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:super_brain, :extraction, :sparse_edges],
        fn _name, measurements, metadata, _ ->
          send(test_pid, {handler_ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_three_entities_no_edges/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "A, B, C with no connections",
                 "graph" => graph
               })

      assert_received {^handler_ref, %{count: 1}, metadata}
      assert metadata.entity_count == 3
      assert metadata.edge_count == 0
      assert metadata.user_id == user.id
    end

    test "does NOT emit sparse_edges counter when N < 3" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      graph = "test:base:not_sparse_n:#{user.id}:#{System.unique_integer([:positive])}"
      on_exit_drop_graph(graph)

      handler_ref = make_ref()
      handler_id = "test-not-sparse-n-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:super_brain, :extraction, :sparse_edges],
        fn _name, measurements, metadata, _ ->
          send(test_pid, {handler_ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Single-entity extraction (N = 1): below the N>=3 threshold, so no
      # sparse-edge signal even though edges = 0.
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_one_entity/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "single",
                 "graph" => graph
               })

      refute_received {^handler_ref, _measurements, _metadata}
    end
  end

  # ---------------------------------------------------------------------------
  # Task 3: the curated-extractor guard covers the pin and link worker prefixes.
  #
  # Pin- and link-ingested entities are user-declared and must never be merged
  # by inline canonicalize. `curated?/1` matches nodes whose extractor_version
  # starts with one of these prefixes; the pin worker stamps `brain_pin_ingest`
  # and the link worker stamps `brain_links_ingest`.
  # ---------------------------------------------------------------------------

  describe "curated_extractor_prefixes/0" do
    test "curated extractor prefixes cover the pin and link workers" do
      assert Magus.SuperBrain.Workers.ExtractBase.curated_extractor_prefixes() ==
               ["brain_pin_ingest", "brain_links_ingest"]
    end
  end
end
