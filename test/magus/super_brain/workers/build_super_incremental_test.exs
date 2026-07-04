defmodule Magus.SuperBrain.Workers.BuildSuperIncrementalTest do
  @moduledoc """
  Tests for iter3 Task 10: `BuildSuperIncremental` worker.

  Incremental per-accessor super graph update:

    1. Acquire the same pg advisory lock used by `BuildSuperFull`
    2. Read the accessor's `super_brain_super_graphs` row
    3. Compute current read-set via `AccessibleGraphs.for_actor`
    4. Drift check: if it differs from the snapshot, enqueue `BuildSuperFull`
    5. Otherwise, process Episodes with `updated_at > super_row.last_built_at`
    6. For each new entity: KNN match into the super graph (cosine >= 0.95)
       reusing the canonical when found, otherwise creating a new one
    7. Write `:SourcePointer` + `:APPEARS_IN` edges
    8. Update `last_built_at` and exit

  Iter4 Task 5 extends this with per-episode `:RELATES_TO` aggregation
  into the super graph between canonicals whose endpoints already exist;
  edges with a missing endpoint defer to the nightly full rebuild.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  alias Magus.SuperBrain.SuperGraph
  alias Magus.SuperBrain.Workers.{BuildSuperFull, BuildSuperIncremental}

  require Ash.Query

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp ok_alpha(_, _) do
    {:ok,
     %{
       content:
         ~s({"entities":[{"name":"Alpha","type":"concept","subtype":null,"confidence":0.9}],"claims":[]}),
       usage: %Magus.SuperBrain.Usage{
         model_name: "t",
         total_tokens: 1,
         input_cost: Decimal.new("0"),
         output_cost: Decimal.new("0"),
         total_cost: Decimal.new("0")
       }
     }}
  end

  defp ok_beta(_, _) do
    # Use a distinct subtype so Beta lands in a different
    # `(type, normalized_subtype)` bucket from Alpha. Wave 2 keys the
    # canonical id on the bucket only (name is no longer in the hash), so
    # two entities of the same `(type, nil-subtype)` collapse into one
    # canonical regardless of name. The "incremental adds a new canonical"
    # intent requires distinguishable buckets.
    {:ok,
     %{
       content:
         ~s({"entities":[{"name":"Beta","type":"concept","subtype":"topic","confidence":0.85}],"claims":[]}),
       usage: %Magus.SuperBrain.Usage{
         model_name: "t",
         total_tokens: 1,
         input_cost: Decimal.new("0"),
         output_cost: Decimal.new("0"),
         total_cost: Decimal.new("0")
       }
     }}
  end

  test "adds a new entity to an existing super graph" do
    user = generate(user())
    brain = generate(brain(user_id: user.id))

    page_a =
      brain_page(brain_id: brain.id, user_id: user.id, content: "First.")

    super_graph = "super:user:#{user.id}"

    on_exit(fn ->
      Magus.Graph.drop("brain:#{brain.id}")
      Magus.Graph.drop("memories:user:#{user.id}")
      Magus.Graph.drop("files:user:#{user.id}")
      Magus.Graph.drop("drafts:user:#{user.id}")
      Magus.Graph.drop(super_graph)
    end)

    # Embed Alpha with one fingerprint.
    alpha_vec = [1.0 | List.duplicate(0.0, 1535)]

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
      {:ok, Enum.map(texts, fn _ -> alpha_vec end)}
    end)

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
      {:ok, alpha_vec}
    end)

    expect(Magus.SuperBrain.LLMMock, :complete, &ok_alpha/2)
    :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_a.id})
    Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

    # Initial full build: super graph now has Alpha
    :ok =
      perform_job(BuildSuperFull, %{
        "accessor_type" => "user",
        "user_id" => user.id,
        "workspace_id" => nil
      })

    # Add a new page producing a NEW entity (Beta). Stub embedder so Beta
    # gets a clearly different (orthogonal) embedding before the second
    # extraction so it does NOT cluster with Alpha.
    beta_vec = List.duplicate(0.0, 1535) ++ [1.0]

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
      {:ok, Enum.map(texts, fn _ -> beta_vec end)}
    end)

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
      {:ok, beta_vec}
    end)

    page_b =
      brain_page(brain_id: brain.id, user_id: user.id, content: "Second.")

    expect(Magus.SuperBrain.LLMMock, :complete, &ok_beta/2)
    :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_b.id})
    Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

    # Run incremental
    :ok =
      perform_job(BuildSuperIncremental, %{
        "accessor_type" => "user",
        "user_id" => user.id,
        "workspace_id" => nil,
        "trigger_episode_id" => nil
      })

    # Super graph now has both Alpha AND Beta
    {:ok, result} =
      Magus.Graph.query(super_graph, "MATCH (c:CanonicalEntity) RETURN c.name")

    names = result.rows |> Enum.map(&List.first/1) |> Enum.sort()
    assert "Alpha" in names
    assert "Beta" in names
  end

  describe "incremental RELATES_TO aggregation (iter4 Task 5)" do
    # First-extraction LLM stub: one Alpha entity, no edges.
    defp ok_alpha_only(_, _) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Alpha","type":"concept","subtype":null,"confidence":0.9}],"claims":[]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end

    # First-extraction LLM stub: one Beta entity, no edges. Subtype is
    # "topic" so Beta lands in a different `(type, normalized_subtype)`
    # bucket from Alpha; Wave 2's canonical id formula drops name from
    # the hash so distinguishability now comes from the bucket.
    defp ok_beta_only(_, _) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Beta","type":"concept","subtype":"topic","confidence":0.85}],"claims":[]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end

    # Second extraction reuses Alpha + Beta with a RELATES_TO edge.
    # Subtypes stay distinct so the two canonicals do not collapse.
    defp ok_alpha_beta_edge(_, _) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Alpha","type":"concept","subtype":null,"confidence":0.9},{"name":"Beta","type":"concept","subtype":"topic","confidence":0.85}],"claims":[{"subject_name":"Alpha","object_name":"Beta","predicate":"relates_to","polarity":"affirms","claim_text":"Alpha relates_to Beta.","confidence":0.8}]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end

    test "adds RELATES_TO between two existing canonicals for new episodes" do
      user = generate(user())
      # Use two separate brains so Alpha and Beta land in distinct Layer 1
      # graphs and survive the inline canonicalize step in the second
      # extraction (canonicalize is per-graph).
      brain_a = generate(brain(user_id: user.id))
      brain_b = generate(brain(user_id: user.id))

      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain_a.id}")
        Magus.Graph.drop("brain:#{brain_b.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      # Seed Alpha into brain_a.
      alpha_vec = [1.0 | List.duplicate(0.0, 1535)]

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
        {:ok, Enum.map(texts, fn _ -> alpha_vec end)}
      end)

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
        {:ok, alpha_vec}
      end)

      page_a = brain_page(brain_id: brain_a.id, user_id: user.id, content: "Alpha page.")
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_alpha_only/2)
      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_a.id})
      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      # Seed Beta into brain_b with an orthogonal embedding so it does NOT
      # cluster with Alpha at the 0.95 cosine merge threshold.
      beta_vec = List.duplicate(0.0, 1535) ++ [1.0]

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
        {:ok, Enum.map(texts, fn _ -> beta_vec end)}
      end)

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
        {:ok, beta_vec}
      end)

      page_b = brain_page(brain_id: brain_b.id, user_id: user.id, content: "Beta page.")
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_beta_only/2)
      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_b.id})
      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      # Full build to materialize the two canonicals + snapshot the read-set.
      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      # Sanity: super graph has no RELATES_TO yet (the seed extractions
      # produced no Layer 1 edges).
      {:ok, edges_before} =
        Magus.Graph.query(
          super_graph,
          "MATCH ()-[r:RELATES_TO]->() RETURN count(r)"
        )

      assert [[count_before]] = edges_before.rows
      assert "#{count_before}" == "0"

      # New episode whose Layer 1 contains Alpha-[:RELATES_TO]->Beta. Use
      # brain_b so Beta's stable_id matches the pre-seeded one (stable_id
      # is keyed on graph_name + name). Alpha is brand new in brain_b so
      # it gets its own Layer 1 entity. We bias the embedder so the new
      # Alpha vector fuses to the pre-existing Alpha canonical via KNN.
      #
      # Stub embed_one (used by the incremental KNN match path) to return
      # the right vector per name. embed_many (used at extraction time)
      # gets a sequence: episode text + 2 entity names = 3 vectors.
      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
        vecs =
          Enum.map(texts, fn text ->
            cond do
              String.contains?(text, "Alpha") -> alpha_vec
              String.contains?(text, "Beta") -> beta_vec
              true -> alpha_vec
            end
          end)

        {:ok, vecs}
      end)

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text -> {:ok, alpha_vec} end)

      page_c =
        brain_page(brain_id: brain_b.id, user_id: user.id, content: "Alpha relates to Beta.")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_alpha_beta_edge/2)
      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_c.id})
      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      # Run incremental.
      :ok =
        perform_job(BuildSuperIncremental, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil,
          "trigger_episode_id" => nil
        })

      # Super graph now has exactly one :RELATES_TO between two canonicals.
      {:ok, edges_after} =
        Magus.Graph.query(
          super_graph,
          "MATCH (a:CanonicalEntity)-[r:RELATES_TO]->(b:CanonicalEntity) RETURN a.name, b.name, r.appearance_count"
        )

      assert length(edges_after.rows) == 1
      [[from_name, to_name, ac]] = edges_after.rows
      assert from_name in ["Alpha", "Beta"]
      assert to_name in ["Alpha", "Beta"]
      assert from_name != to_name
      assert "#{ac}" in ["1"]
    end

    # First-extraction LLM stub: Alice + Aurora with a "supports" edge.
    defp ok_alice_supports_aurora(_, _) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Alice","type":"person","subtype":null,"confidence":0.9},{"name":"Aurora","type":"project","subtype":null,"confidence":0.9}],"claims":[{"subject_name":"Alice","object_name":"Aurora","predicate":"supports","polarity":"affirms","claim_text":"Alice supports Aurora.","confidence":0.85}]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end

    # Second-extraction LLM stub: Alice + Aurora with a "contradicts" edge.
    defp ok_alice_contradicts_aurora(_, _) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Alice","type":"person","subtype":null,"confidence":0.9},{"name":"Aurora","type":"project","subtype":null,"confidence":0.9}],"claims":[{"subject_name":"Alice","object_name":"Aurora","predicate":"contradicts","polarity":"affirms","claim_text":"Alice contradicts Aurora.","confidence":0.8}]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end

    test "flips contested=true when a later episode adds the opposite predicate" do
      user = generate(user())
      brain_a = generate(brain(user_id: user.id))
      brain_b = generate(brain(user_id: user.id))
      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain_a.id}")
        Magus.Graph.drop("brain:#{brain_b.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      # Use identical embeddings everywhere so Alice fuses to Alice and
      # Aurora fuses to Aurora across brains AND via KNN on incremental.
      unit_vec = [1.0 | List.duplicate(0.0, 1535)]

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
        {:ok, Enum.map(texts, fn _ -> unit_vec end)}
      end)

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
        {:ok, unit_vec}
      end)

      # Brain A: extract Alice-[supports]->Aurora.
      page_a =
        brain_page(brain_id: brain_a.id, user_id: user.id, content: "Alice supports Aurora.")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_alice_supports_aurora/2)
      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_a.id})
      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      # Initial full build: super graph has Alice + Aurora canonicals and
      # one :RELATES_TO with predicate=supports, contested=false.
      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      # Sanity: the seed edge is not contested yet.
      {:ok, seed_result} =
        Magus.Graph.query(
          super_graph,
          """
          MATCH (a:CanonicalEntity {name: 'Alice'})-[r:RELATES_TO]->(b:CanonicalEntity {name: 'Aurora'})
          RETURN r.contested, r.predicate_breakdown
          """
        )

      assert [[contested_before, breakdown_before_json]] = seed_result.rows
      refute contested_before == true or contested_before == "true"
      assert {:ok, breakdown_before} = Jason.decode(breakdown_before_json)
      assert breakdown_before == %{"supports" => 1}

      # Brain B: extract Alice-[contradicts]->Aurora (same entity names so
      # KNN matches both endpoints to the pre-existing canonicals via
      # their identical embeddings).
      page_b =
        brain_page(
          brain_id: brain_b.id,
          user_id: user.id,
          content: "Alice contradicts Aurora."
        )

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_alice_contradicts_aurora/2)
      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_b.id})
      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      :ok =
        perform_job(BuildSuperIncremental, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil,
          "trigger_episode_id" => nil
        })

      # After incremental: edge MUST be contested, breakdown MUST include
      # both predicates.
      {:ok, after_result} =
        Magus.Graph.query(
          super_graph,
          """
          MATCH (a:CanonicalEntity {name: 'Alice'})-[r:RELATES_TO]->(b:CanonicalEntity {name: 'Aurora'})
          RETURN r.contested, r.predicate_breakdown
          """
        )

      assert [[contested_after, breakdown_after_json]] = after_result.rows
      assert contested_after == true or contested_after == "true"
      assert {:ok, breakdown_after} = Jason.decode(breakdown_after_json)
      assert breakdown_after == %{"supports" => 1, "contradicts" => 1}
    end

    test "skips RELATES_TO when an endpoint canonical does not exist yet" do
      # Drive the skip branch directly: insert a Layer 1 :RELATES_TO edge
      # whose subject Entity has no corresponding SourcePointer (and so
      # no canonical) in the super graph. The aggregation must NOT create
      # the edge and must NOT crash.
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      source_graph = "brain:#{brain.id}"
      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop(source_graph)
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      alpha_vec = [1.0 | List.duplicate(0.0, 1535)]

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
        {:ok, Enum.map(texts, fn _ -> alpha_vec end)}
      end)

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text -> {:ok, alpha_vec} end)

      # Seed a baseline so the SuperGraph row exists and last_built_at is
      # set. Use BuildSuperFull with one extraction so the read_set
      # snapshot is correct and drift detection passes on incremental.
      page_a = brain_page(brain_id: brain.id, user_id: user.id, content: "Alpha page.")
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_alpha_only/2)
      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_a.id})
      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      # Drive the aggregation pass to actually have work: produce a new
      # episode in the same Layer 1 graph that emits one Layer 1 Entity
      # (Alpha, fuses to existing canonical) and a hand-crafted RELATES_TO
      # whose OTHER endpoint references a non-existent Entity id (we
      # delete it after extraction).
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_alpha_beta_edge/2)

      page_c =
        brain_page(brain_id: brain.id, user_id: user.id, content: "Alpha relates to Beta.")

      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_c.id})
      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      # Surgically delete the Beta Entity (and incident edges' endpoint
      # mismatch will be revealed by the aggregation's existence check).
      # We delete the Beta Entity node only; the :RELATES_TO edge gets
      # removed transitively via DETACH, which means the Layer 1 edge is
      # also gone. To actually exercise the skip branch we instead
      # rewrite the RELATES_TO's target id to a non-existent stable_id so
      # the canonical lookup returns nil.
      ghost_id =
        :crypto.hash(:sha256, "#{source_graph}|ghost")
        |> Base.encode16(case: :lower)
        |> binary_part(0, 32)

      # Replace the only Layer 1 RELATES_TO with one pointing to a ghost
      # target entity that has no canonical.
      _ =
        Magus.Graph.query(
          source_graph,
          """
          MATCH (a:Entity {name: 'Alpha'})-[r:RELATES_TO]->(:Entity)
          DELETE r
          """
        )

      # Insert a ghost Entity (no SourcePointer in super graph will exist).
      _ =
        Magus.Graph.query(
          source_graph,
          """
          MERGE (g:Entity {id: $gid})
          ON CREATE SET g.name = 'Ghost', g.type = 'concept',
                        g.source_id = $sid, g.extractor = 'test'
          """,
          %{gid: ghost_id, sid: page_c.id}
        )

      # Add a RELATES_TO from Alpha to Ghost tagged with this episode's
      # source_id so the aggregator picks it up.
      _ =
        Magus.Graph.query(
          source_graph,
          """
          MATCH (a:Entity {name: 'Alpha'})
          MATCH (g:Entity {id: $gid})
          MERGE (a)-[r:RELATES_TO]->(g)
          SET r.predicate = 'relates_to', r.confidence = 0.5,
              r.trust_tier = 'evidence', r.source_id = $sid
          """,
          %{gid: ghost_id, sid: page_c.id}
        )

      # Edge count before the incremental run.
      {:ok, before_result} =
        Magus.Graph.query(
          super_graph,
          "MATCH ()-[r:RELATES_TO]->() RETURN count(r)"
        )

      assert [[count_before]] = before_result.rows

      # Run incremental. Ghost has no canonical so the Alpha->Ghost edge
      # MUST be skipped; the worker MUST exit :ok without crashing.
      :ok =
        perform_job(BuildSuperIncremental, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil,
          "trigger_episode_id" => nil
        })

      {:ok, after_result} =
        Magus.Graph.query(
          super_graph,
          "MATCH (a:CanonicalEntity)-[r:RELATES_TO]->(b:CanonicalEntity) RETURN a.name, b.name"
        )

      # No edge incident to a Ghost canonical (Ghost canonical does not
      # exist). Beta canonical may or may not exist depending on whether
      # the fusion pass created it from the Beta entity already in Layer
      # 1, but since we deleted the original Alpha-Beta edge before
      # running incremental, no aggregator-driven edge can include Ghost.
      refute Enum.any?(after_result.rows, fn [from, to] ->
               from == "Ghost" or to == "Ghost"
             end)

      # And the total count must not have grown via a phantom write that
      # created Ghost on the fly.
      {:ok, ghost_check} =
        Magus.Graph.query(
          super_graph,
          "MATCH (c:CanonicalEntity {name: 'Ghost'}) RETURN count(c)"
        )

      assert [[ghost_count]] = ghost_check.rows
      assert "#{ghost_count}" == "0"

      _ = count_before
    end
  end

  describe "nil subtype sentinel (iter4 Task 9)" do
    # Mirror of the BuildSuperFull test for the same case: an incremental
    # insert of a subtype-less "Daniel/person" entity must NOT fuse onto a
    # pre-existing subtype="user" canonical. The `same_subtype?` filter in
    # `knn_match` rejects the cross-subtype KNN hit, then `create_canonical`
    # calls `canonical_id_for(super_graph, name, type, nil)` which uses the
    # `__none__` sentinel and produces a distinct id from the "user" hash.
    # If the two formulas drift (full vs incremental) the next nightly
    # `BuildSuperFull` would emit a duplicate canonical alongside the
    # incremental's row.
    defp ok_daniel_user(_, _) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Daniel","type":"person","subtype":"user","confidence":0.9}],"claims":[]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end

    defp ok_daniel_nil(_, _) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Daniel","type":"person","subtype":null,"confidence":0.85}],"claims":[]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end

    test "incremental insert of nil-subtype Daniel does not fuse with subtype=user Daniel" do
      user = generate(user())
      brain_user = generate(brain(user_id: user.id))
      brain_nil = generate(brain(user_id: user.id))
      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain_user.id}")
        Magus.Graph.drop("brain:#{brain_nil.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      # Use identical embeddings so KNN finds the existing canonical as a
      # candidate; the `same_subtype?` filter must still reject the
      # cross-subtype match.
      unit_vec = [1.0 | List.duplicate(0.0, 1535)]

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
        {:ok, Enum.map(texts, fn _ -> unit_vec end)}
      end)

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
        {:ok, unit_vec}
      end)

      # Seed brain_user with subtype="user" Daniel.
      page_user =
        brain_page(brain_id: brain_user.id, user_id: user.id, content: "Daniel the user.")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_daniel_user/2)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_user.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      # Materialize via BuildSuperFull so the super graph has the
      # subtype="user" canonical and the read-set snapshot is current.
      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      # New episode introduces a subtype=nil Daniel in a different brain.
      page_nil =
        brain_page(brain_id: brain_nil.id, user_id: user.id, content: "Untyped Daniel.")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_daniel_nil/2)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_nil.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      :ok =
        perform_job(BuildSuperIncremental, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil,
          "trigger_episode_id" => nil
        })

      # Two distinct canonical Daniels: the seed subtype="user" and the
      # incrementally-inserted subtype=nil one.
      {:ok, result} =
        Magus.Graph.query(
          super_graph,
          "MATCH (c:CanonicalEntity {name: 'Daniel'}) RETURN count(c)"
        )

      assert [[2]] = result.rows
    end
  end

  test "drift detection enqueues full rebuild and exits :ok" do
    user = generate(user())
    super_graph = "super:user:#{user.id}"

    on_exit(fn ->
      Magus.Graph.drop("memories:user:#{user.id}")
      Magus.Graph.drop("files:user:#{user.id}")
      Magus.Graph.drop("drafts:user:#{user.id}")
      Magus.Graph.drop(super_graph)
    end)

    # Pre-create a SuperGraph row and stamp a snapshot that mentions a
    # non-existent graph. The user's actual read-set will not contain it,
    # so the diff fires drift.
    {:ok, super_row} =
      Ash.create(
        SuperGraph,
        %{
          accessor_type: :user,
          user_id: user.id,
          workspace_id: nil,
          graph_name: super_graph,
          last_build_status: :pending
        },
        authorize?: false
      )

    {:ok, _} =
      Ash.update(
        super_row,
        %{
          read_set_snapshot: [
            %{"graph_name" => "brain:does-not-exist", "snapshot_at" => "2026-05-24T00:00:00Z"}
          ],
          canonical_entity_count: 0,
          canonical_edge_count: 0,
          last_build_duration_ms: 0
        },
        action: :mark_built,
        authorize?: false
      )

    result =
      perform_job(BuildSuperIncremental, %{
        "accessor_type" => "user",
        "user_id" => user.id,
        "workspace_id" => nil,
        "trigger_episode_id" => nil
      })

    # The worker translates internal :drift_detected to :ok so Oban does
    # not flag it as failure.
    assert result == :ok

    # BuildSuperFull was enqueued
    assert_enqueued(
      worker: BuildSuperFull,
      args: %{"user_id" => user.id, "accessor_type" => "user"}
    )
  end

  describe "Task 3.6: layer-1 self-edge filter (incremental)" do
    # LLM stub for an extraction whose entities all share `(type,
    # normalized_subtype)` and which emits a RELATES_TO between two of
    # them. Both endpoints resolve to the SAME canonical (CanonicalId
    # hashes only `(super_graph, type, normalized_subtype)`), so without
    # the iter5 self-edge filter the incremental aggregator would create
    # a canonical->itself loop.
    defp ok_two_aliases_with_edge_inc(_, _) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Daniel","type":"person","subtype":"user","confidence":0.9},{"name":"Dan","type":"person","subtype":"user","confidence":0.85}],"claims":[{"subject_name":"Daniel","object_name":"Dan","predicate":"relates_to","polarity":"affirms","claim_text":"Daniel relates_to Dan.","confidence":0.8}]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end

    test "RELATES_TO between two entities that fuse to one canonical does NOT create a self-loop" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))

      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      unit_vec = [1.0 | List.duplicate(0.0, 1535)]

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
        {:ok, Enum.map(texts, fn _ -> unit_vec end)}
      end)

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
        {:ok, unit_vec}
      end)

      page =
        brain_page(brain_id: brain.id, user_id: user.id, content: "Daniel also goes by Dan.")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_two_aliases_with_edge_inc/2)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      # Full build first to materialize the canonical + snapshot the read-set
      # so the subsequent incremental does not detect drift.
      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      # Add a second page that re-extracts the same aliases-with-edge shape
      # so the incremental sees a new Episode with a Layer 1 RELATES_TO
      # whose endpoints both resolve to the single existing canonical.
      page_b =
        brain_page(brain_id: brain.id, user_id: user.id, content: "Dan is just Daniel.")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_two_aliases_with_edge_inc/2)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_b.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      :ok =
        perform_job(BuildSuperIncremental, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil,
          "trigger_episode_id" => nil
        })

      # No RELATES_TO between any pair of CanonicalEntities should exist:
      # the only candidate was a self-loop and iter5 Task 3.6 drops it.
      {:ok, edge_count} =
        Magus.Graph.query(
          super_graph,
          "MATCH (a:CanonicalEntity)-[r:RELATES_TO]->(b:CanonicalEntity) RETURN count(r)"
        )

      assert [[0]] = edge_count.rows
    end
  end
end
