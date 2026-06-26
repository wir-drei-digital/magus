defmodule Magus.SuperBrain.Workers.BuildSuperFullTest do
  @moduledoc """
  Tests for iter3 Task 9: `BuildSuperFull` worker.

  Builds the Layer 2 super graph for a single accessor by:

    1. Computing the read-set via `AccessibleGraphs.for_actor`
    2. Dropping the super graph
    3. Pulling all Layer 1 entities from each readable graph
    4. Clustering by `(type, normalized_subtype)` at cosine 0.95
    5. Writing `:CanonicalEntity` + `:SourcePointer` + `:APPEARS_IN` + `:RELATES_TO`
    6. Updating the `super_brain_super_graphs` metadata row
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  alias Magus.SuperBrain.SuperGraph
  alias Magus.SuperBrain.Workers.BuildSuperFull

  require Ash.Query

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp ok_daniel(_, _) do
    {:ok,
     %{
       content:
         ~s({"entities":[{"name":"Daniel","type":"person","subtype":"user","confidence":0.9}],"edges":[]}),
       usage: %Magus.SuperBrain.Usage{
         model_name: "t",
         total_tokens: 1,
         input_cost: Decimal.new("0"),
         output_cost: Decimal.new("0"),
         total_cost: Decimal.new("0")
       }
     }}
  end

  # Override the default ResourceCase embedder stub so two extractions
  # produce identical (non-zero) embeddings that cluster cleanly at
  # cosine similarity 1.0 (well above the 0.95 merge threshold).
  defp stub_unit_embeddings do
    unit_vec = [1.0 | List.duplicate(0.0, 1535)]

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
      {:ok, Enum.map(texts, fn _ -> unit_vec end)}
    end)

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
      {:ok, unit_vec}
    end)

    :ok
  end

  describe "personal super graph" do
    test "fuses entities across multiple Layer 1 graphs into one canonical" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain = generate(brain(user_id: user.id))

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "Daniel works on Aurora."
        )

      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      # Drive an extraction into the brain graph.
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_daniel/2)
      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page.id})

      # Drive an extraction into the user memories graph.
      mem = generate(memory(user_id: user.id, scope: :user, summary: "Daniel is the user."))
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_daniel/2)
      :ok = perform_job(Magus.SuperBrain.Workers.ExtractMemory, %{"resource_id" => mem.id})

      # Drain any pending extraction workers (e.g. fan-out).
      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      assert :ok =
               perform_job(BuildSuperFull, %{
                 "accessor_type" => "user",
                 "user_id" => user.id,
                 "workspace_id" => nil
               })

      {:ok, result} =
        Magus.Graph.query(
          super_graph,
          "MATCH (c:CanonicalEntity {name: 'Daniel'}) RETURN c.source_count"
        )

      assert [[count]] = result.rows
      # FalkorDB returns numeric scalars as strings in verbose mode; coerce
      # to a string before checking.
      assert "#{count}" in ["2"]

      {:ok, [meta]} =
        SuperGraph
        |> Ash.Query.filter(user_id == ^user.id and accessor_type == :user)
        |> Ash.read(authorize?: false)

      assert meta.last_build_status == :ok
      assert meta.last_built_at != nil
    end

    test "nil subtype canonicals do not fuse with subtyped canonicals of the same name+type" do
      # Iter4 Task 9: nil normalized_subtype must hash distinctly from any
      # real subtype value so a subtype-less "Daniel" never silently
      # collides with a subtype="user" "Daniel" canonical. Pre-iter4 both
      # collapsed into one node because the hash used the empty string
      # for the nil case, which would compare equal to any future
      # normalized_subtype = "" entity.
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain_user = generate(brain(user_id: user.id))
      brain_nil = generate(brain(user_id: user.id))

      page_user =
        brain_page(brain_id: brain_user.id, user_id: user.id, content: "User Daniel.")

      page_nil =
        brain_page(brain_id: brain_nil.id, user_id: user.id, content: "Untyped Daniel.")

      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain_user.id}")
        Magus.Graph.drop("brain:#{brain_nil.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel","type":"person","subtype":"user","confidence":0.9}],"edges":[]}),
           usage: %Magus.SuperBrain.Usage{
             model_name: "t",
             total_tokens: 1,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_user.id})

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel","type":"person","subtype":null,"confidence":0.85}],"edges":[]}),
           usage: %Magus.SuperBrain.Usage{
             model_name: "t",
             total_tokens: 1,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_nil.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      {:ok, result} =
        Magus.Graph.query(
          super_graph,
          "MATCH (c:CanonicalEntity {name: 'Daniel'}) RETURN count(c)"
        )

      assert [[2]] = result.rows
    end

    test "two nil-subtype canonicals of the same name+type still fuse with each other" do
      # Regression guard for iter4 Task 9: the `__none__` sentinel keeps
      # nil-subtype entities distinct from any real subtype value, but two
      # entities that are BOTH subtype-less must still collide on the
      # `__none__` bucket so they continue to fuse. This is the
      # "known-unknown" semantic: we don't know what subtype they are,
      # but they share that unknown.
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain_a = generate(brain(user_id: user.id))
      brain_b = generate(brain(user_id: user.id))

      page_a =
        brain_page(brain_id: brain_a.id, user_id: user.id, content: "Daniel A.")

      page_b =
        brain_page(brain_id: brain_b.id, user_id: user.id, content: "Daniel B.")

      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain_a.id}")
        Magus.Graph.drop("brain:#{brain_b.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      expect(Magus.SuperBrain.LLMMock, :complete, 2, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel","type":"person","subtype":null,"confidence":0.9}],"edges":[]}),
           usage: %Magus.SuperBrain.Usage{
             model_name: "t",
             total_tokens: 1,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_a.id})

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_b.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      {:ok, result} =
        Magus.Graph.query(
          super_graph,
          "MATCH (c:CanonicalEntity {name: 'Daniel'}) RETURN count(c)"
        )

      assert [[1]] = result.rows
    end

    test "different normalized_subtype keeps canonicals separate" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      # Two separate Layer 1 graphs (different brains) so the same name
      # produces two distinct entities; otherwise ExtractBase.stable_id/2
      # would collapse them at MERGE time before clustering ever sees them.
      brain_user = generate(brain(user_id: user.id))
      brain_char = generate(brain(user_id: user.id))

      page_user =
        brain_page(brain_id: brain_user.id, user_id: user.id, content: "Real Daniel.")

      page_char =
        brain_page(brain_id: brain_char.id, user_id: user.id, content: "Fictional Daniel.")

      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain_user.id}")
        Magus.Graph.drop("brain:#{brain_char.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel","type":"person","subtype":"user","confidence":0.9}],"edges":[]}),
           usage: %Magus.SuperBrain.Usage{
             model_name: "t",
             total_tokens: 1,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_user.id})

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel","type":"person","subtype":"character","confidence":0.85}],"edges":[]}),
           usage: %Magus.SuperBrain.Usage{
             model_name: "t",
             total_tokens: 1,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_char.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      {:ok, result} =
        Magus.Graph.query(
          super_graph,
          "MATCH (c:CanonicalEntity {name: 'Daniel'}) RETURN count(c)"
        )

      assert [[2]] = result.rows
    end
  end

  describe "contested RELATES_TO (iter4 Task 7)" do
    # supports + contradicts between the same canonical pair must light up
    # `contested = true` and produce a per-predicate breakdown so retrieval
    # can show the LLM that the modal predicate is not the whole story.
    defp ok_alice_supports_aurora(_, _) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Alice","type":"person","subtype":null,"confidence":0.9},{"name":"Aurora","type":"project","subtype":null,"confidence":0.9}],"edges":[{"subject_name":"Alice","object_name":"Aurora","predicate":"supports","confidence":0.85}]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end

    defp ok_alice_contradicts_aurora(_, _) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Alice","type":"person","subtype":null,"confidence":0.9},{"name":"Aurora","type":"project","subtype":null,"confidence":0.9}],"edges":[{"subject_name":"Alice","object_name":"Aurora","predicate":"contradicts","confidence":0.85}]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end

    test "marks edges as contested when supports + contradicts appear for the same pair" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain_supports = generate(brain(user_id: user.id))
      brain_contradicts = generate(brain(user_id: user.id))

      page_supports =
        brain_page(
          brain_id: brain_supports.id,
          user_id: user.id,
          content: "Alice supports Aurora."
        )

      page_contradicts =
        brain_page(
          brain_id: brain_contradicts.id,
          user_id: user.id,
          content: "Alice contradicts Aurora."
        )

      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain_supports.id}")
        Magus.Graph.drop("brain:#{brain_contradicts.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_alice_supports_aurora/2)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{
          "resource_id" => page_supports.id
        })

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_alice_contradicts_aurora/2)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{
          "resource_id" => page_contradicts.id
        })

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      {:ok, result} =
        Magus.Graph.query(
          super_graph,
          """
          MATCH (a:CanonicalEntity {name: 'Alice'})-[r:RELATES_TO]->(b:CanonicalEntity {name: 'Aurora'})
          RETURN r.predicate, r.contested, r.predicate_breakdown
          """
        )

      assert [[predicate, contested, breakdown_json]] = result.rows
      assert predicate in ["supports", "contradicts"]
      # FalkorDB's verbose protocol may surface booleans as the literal
      # string "true" or as the boolean. Accept either; what we care
      # about is that the contradiction was NOT collapsed.
      assert contested == true or contested == "true"

      assert {:ok, breakdown} = Jason.decode(breakdown_json)
      assert breakdown == %{"supports" => 1, "contradicts" => 1}
    end
  end

  describe "auth boundary" do
    test "user A's super graph contains only entities from graphs A can read" do
      :ok = stub_unit_embeddings()

      user_a = generate(user())
      user_b = generate(user())
      ws = generate(workspace(actor: user_a))
      _ = workspace_member(user_id: user_b.id, workspace_id: ws.id, role: :member)

      brain_a = generate(brain(user_id: user_a.id, workspace_id: ws.id))

      page_a =
        brain_page(brain_id: brain_a.id, user_id: user_a.id, content: "Confidential.")

      brain_b = generate(brain(user_id: user_b.id, workspace_id: ws.id))

      page_b =
        brain_page(brain_id: brain_b.id, user_id: user_b.id, content: "Also confidential.")

      super_graph_a = "super:workspace:#{ws.id}:#{user_a.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain_a.id}")
        Magus.Graph.drop("brain:#{brain_b.id}")
        Magus.Graph.drop("memories:user:#{user_a.id}")
        Magus.Graph.drop("files:user:#{user_a.id}")
        Magus.Graph.drop("drafts:user:#{user_a.id}")
        Magus.Graph.drop("memories:workspace:#{ws.id}")
        Magus.Graph.drop("files:workspace:#{ws.id}")
        Magus.Graph.drop(super_graph_a)
      end)

      expect(Magus.SuperBrain.LLMMock, :complete, 2, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Secret","type":"concept","subtype":null,"confidence":0.9}],"edges":[]}),
           usage: %Magus.SuperBrain.Usage{
             model_name: "t",
             total_tokens: 1,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_a.id})

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_b.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "workspace",
          "user_id" => user_a.id,
          "workspace_id" => ws.id
        })

      {:ok, result} =
        Magus.Graph.query(
          super_graph_a,
          "MATCH (c:CanonicalEntity)-[r:APPEARS_IN]->(s:SourcePointer) RETURN s.graph_name"
        )

      source_graphs = result.rows |> List.flatten() |> Enum.uniq()

      assert "brain:#{brain_a.id}" in source_graphs
      refute "brain:#{brain_b.id}" in source_graphs
    end
  end

  describe "determinism (Wave 2 Task 2.2)" do
    test "two BuildSuperFull runs over the same Layer 1 produce identical canonicals" do
      # The read-set sort + ORDER BY e.id pull + longest-name-lowest-id
      # canonical-name picker together guarantee that two builds over
      # the same Layer 1 input write the same `(id, name, source_count,
      # primary_type, normalized_subtype, trust_tier)` for every
      # canonical. Pre-Wave-2 the name occasionally flipped because the
      # max_by used confidence as the tie-break, and clusters arrived
      # in storage order.
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain_a = generate(brain(user_id: user.id))
      brain_b = generate(brain(user_id: user.id))

      page_a =
        brain_page(brain_id: brain_a.id, user_id: user.id, content: "Daniel works.")

      page_b =
        brain_page(brain_id: brain_b.id, user_id: user.id, content: "Daniel Smith works.")

      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain_a.id}")
        Magus.Graph.drop("brain:#{brain_b.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel","type":"person","subtype":"user","confidence":0.9}],"edges":[]}),
           usage: %Magus.SuperBrain.Usage{
             model_name: "t",
             total_tokens: 1,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_a.id})

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel Smith","type":"person","subtype":"user","confidence":0.85}],"edges":[]}),
           usage: %Magus.SuperBrain.Usage{
             model_name: "t",
             total_tokens: 1,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_b.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      {:ok, snapshot1} =
        Magus.Graph.query(
          super_graph,
          """
          MATCH (c:CanonicalEntity)
          RETURN c.id, c.name, c.primary_type, c.normalized_subtype, c.source_count
          ORDER BY c.id ASC
          """
        )

      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      {:ok, snapshot2} =
        Magus.Graph.query(
          super_graph,
          """
          MATCH (c:CanonicalEntity)
          RETURN c.id, c.name, c.primary_type, c.normalized_subtype, c.source_count
          ORDER BY c.id ASC
          """
        )

      assert snapshot1.rows == snapshot2.rows
      # And the longest-name winner ("Daniel Smith") was picked
      # deterministically: pre-Wave-2 the confidence tie-break could flip
      # this to "Daniel" depending on cluster arrival order.
      assert Enum.any?(snapshot1.rows, fn [_id, name | _] -> name == "Daniel Smith" end)
    end
  end

  describe "Task 3.6: layer-1 self-edge filter" do
    # Two entities of the same `(type, normalized_subtype)` in the same
    # Layer 1 graph cluster into one canonical at BuildSuperFull time
    # (CanonicalId is keyed on `(super_graph, type, normalized_subtype)`).
    # A Layer 1 RELATES_TO between them would otherwise materialize as a
    # canonical->itself loop in the super graph; iter5 Task 3.6 drops
    # such self-edges in `aggregate_relates_to/3`.
    defp ok_two_aliases_with_edge(_, _) do
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Daniel","type":"person","subtype":"user","confidence":0.9},{"name":"Dan","type":"person","subtype":"user","confidence":0.85}],"edges":[{"subject_name":"Daniel","object_name":"Dan","predicate":"relates_to","confidence":0.8}]}),
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
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain = generate(brain(user_id: user.id))

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "Daniel also goes by Dan."
        )

      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
      end)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_two_aliases_with_edge/2)

      :ok =
        perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      :ok =
        perform_job(BuildSuperFull, %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        })

      # Both aliases fuse into one canonical (same `(type, normalized_subtype)`).
      {:ok, canonical_count} =
        Magus.Graph.query(super_graph, "MATCH (c:CanonicalEntity) RETURN count(c)")

      assert [[1]] = canonical_count.rows

      # The Layer 1 RELATES_TO endpoints both resolve to the SAME canonical;
      # without the iter5 self-edge filter this would be a (c)-[:RELATES_TO]->(c)
      # loop. With the filter, zero RELATES_TO edges exist between
      # CanonicalEntities.
      {:ok, edge_count} =
        Magus.Graph.query(
          super_graph,
          "MATCH (a:CanonicalEntity)-[r:RELATES_TO]->(b:CanonicalEntity) RETURN count(r)"
        )

      assert [[0]] = edge_count.rows
    end
  end

  describe "staged build (iter5 Task 3.1)" do
    # Pre-iter5 the worker dropped the live super graph BEFORE building.
    # Any failure between the drop and `mark_built` left users with an
    # empty graph until SuperGraphMaintenance reran hours later. The
    # staged-build pattern builds into `<live>:building` and only swaps
    # into live after the writes succeed, so a mid-build failure leaves
    # the live graph untouched.
    setup do
      on_exit(fn ->
        Application.delete_env(:magus, BuildSuperFull)
      end)

      :ok
    end

    test "mid-build crash leaves the live super graph intact" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain = generate(brain(user_id: user.id))

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "Daniel works on Aurora."
        )

      super_graph = "super:user:#{user.id}"
      staging_graph = BuildSuperFull.building_graph_name(super_graph)

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
        Magus.Graph.drop(staging_graph)
      end)

      # Pre-seed the LIVE super graph with a survivor entity. This
      # entity is what the pre-iter5 design would have wiped during
      # `drop_super_graph` before the failure manifested.
      {:ok, _} =
        Magus.Graph.upsert_node(super_graph, "CanonicalEntity", %{
          id: "survivor-id",
          name: "Survivor",
          primary_type: "person"
        })

      # Drive an extraction so Layer 1 has data to feed the build.
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_daniel/2)
      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      # Force the build to fail AFTER the staging writes complete but
      # BEFORE the swap into live. The test-only injection hook makes
      # `stage_build/3` return `{:error, {:test_injected, ...}}` from a
      # late stage.
      Application.put_env(
        :magus,
        BuildSuperFull,
        test_inject_failure_at: :after_staging_writes
      )

      assert {:error, {:test_injected, :after_staging_writes}} =
               perform_job(BuildSuperFull, %{
                 "accessor_type" => "user",
                 "user_id" => user.id,
                 "workspace_id" => nil
               })

      # The live graph still contains "Survivor": staged-build pattern
      # never touched it.
      {:ok, result} =
        Magus.Graph.query(
          super_graph,
          "MATCH (c:CanonicalEntity {name: 'Survivor'}) RETURN count(c)"
        )

      assert [[1]] = result.rows

      # The staging graph was dropped on the failure path. FalkorDB
      # lazily recreates a graph on any query so we cannot probe for
      # "missing key" directly; instead we assert it is empty (no
      # CanonicalEntity nodes from the aborted staging writes).
      {:ok, staging_check} =
        Magus.Graph.query(
          staging_graph,
          "MATCH (n:CanonicalEntity) RETURN count(n)"
        )

      assert [[0]] = staging_check.rows

      # And the SuperGraph row is marked :failed (Wave 1 Task 1.2 fix
      # survives the new flow).
      {:ok, [row]} =
        SuperGraph
        |> Ash.Query.filter(user_id == ^user.id and accessor_type == :user)
        |> Ash.read(authorize?: false)

      assert row.last_build_status == :failed
      assert is_binary(row.last_error)
    end

    test "successful build swaps staging into live atomically" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain = generate(brain(user_id: user.id))

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "Daniel works on Aurora."
        )

      super_graph = "super:user:#{user.id}"
      staging_graph = BuildSuperFull.building_graph_name(super_graph)

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
        Magus.Graph.drop(staging_graph)
      end)

      # Pre-seed live with a stale canonical that should NOT survive
      # the swap (it represents an entity that no longer exists in
      # Layer 1).
      {:ok, _} =
        Magus.Graph.upsert_node(super_graph, "CanonicalEntity", %{
          id: "stale-id",
          name: "OldNode",
          primary_type: "person"
        })

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_daniel/2)
      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      assert :ok =
               perform_job(BuildSuperFull, %{
                 "accessor_type" => "user",
                 "user_id" => user.id,
                 "workspace_id" => nil
               })

      # Live contains the freshly built canonical ("Daniel") and NOT
      # the stale pre-seeded canonical ("OldNode"); the swap replaced
      # the live contents wholesale.
      {:ok, daniel_result} =
        Magus.Graph.query(
          super_graph,
          "MATCH (c:CanonicalEntity {name: 'Daniel'}) RETURN count(c)"
        )

      assert [[1]] = daniel_result.rows

      {:ok, old_result} =
        Magus.Graph.query(
          super_graph,
          "MATCH (c:CanonicalEntity {name: 'OldNode'}) RETURN count(c)"
        )

      assert [[0]] = old_result.rows

      # Staging graph cleaned up after the swap: no CanonicalEntity
      # nodes remain. (Querying lazily recreates the graph, so we
      # cannot probe for a missing key directly.)
      {:ok, staging_check} =
        Magus.Graph.query(
          staging_graph,
          "MATCH (n:CanonicalEntity) RETURN count(n)"
        )

      assert [[0]] = staging_check.rows

      # Row marked :ok.
      {:ok, [row]} =
        SuperGraph
        |> Ash.Query.filter(user_id == ^user.id and accessor_type == :user)
        |> Ash.read(authorize?: false)

      assert row.last_build_status == :ok
    end

    test "write-error threshold rejects the swap; live graph unchanged" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain = generate(brain(user_id: user.id))

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "Daniel works on Aurora."
        )

      super_graph = "super:user:#{user.id}"
      staging_graph = BuildSuperFull.building_graph_name(super_graph)

      on_exit(fn ->
        Magus.Graph.drop("brain:#{brain.id}")
        Magus.Graph.drop("memories:user:#{user.id}")
        Magus.Graph.drop("files:user:#{user.id}")
        Magus.Graph.drop("drafts:user:#{user.id}")
        Magus.Graph.drop(super_graph)
        Magus.Graph.drop(staging_graph)
      end)

      # Pre-seed live with the survivor we expect to NOT be touched
      # when the build aborts because of the write-error threshold.
      {:ok, _} =
        Magus.Graph.upsert_node(super_graph, "CanonicalEntity", %{
          id: "survivor-id",
          name: "Survivor",
          primary_type: "person"
        })

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_daniel/2)
      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page.id})

      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      # Force the write-error rate above the 5% threshold (10/100 = 10%).
      Application.put_env(
        :magus,
        BuildSuperFull,
        test_force_write_stats: %{total: 100, errors: 10}
      )

      assert {:error, {:too_many_write_errors, _}} =
               perform_job(BuildSuperFull, %{
                 "accessor_type" => "user",
                 "user_id" => user.id,
                 "workspace_id" => nil
               })

      # Live graph still has the survivor: the swap was rejected
      # before it ran.
      {:ok, result} =
        Magus.Graph.query(
          super_graph,
          "MATCH (c:CanonicalEntity {name: 'Survivor'}) RETURN count(c)"
        )

      assert [[1]] = result.rows

      # Staging dropped: no CanonicalEntity nodes from the aborted
      # staging writes remain.
      {:ok, staging_check} =
        Magus.Graph.query(
          staging_graph,
          "MATCH (n:CanonicalEntity) RETURN count(n)"
        )

      assert [[0]] = staging_check.rows

      # Row marked :failed.
      {:ok, [row]} =
        SuperGraph
        |> Ash.Query.filter(user_id == ^user.id and accessor_type == :user)
        |> Ash.read(authorize?: false)

      assert row.last_build_status == :failed
    end
  end

  describe "mark_failed_safe survives transaction rollback (Wave 1 Task 1.2)" do
    test "a failing build leaves the SuperGraph row at :failed, not :building" do
      # Pre-iter5: `mark_failed_safe` was called from the `else` arm of the
      # `with`-chain INSIDE `Repo.transaction`. The wrapping txn rolled back
      # on `{:error, _}` from the inner pipeline, taking the failure-status
      # update with it. The SuperGraph row stayed stuck at `:building`
      # forever. The fix captures the inner result, runs `mark_failed_safe`
      # OUTSIDE the transaction, so the failure status survives.
      :ok = stub_unit_embeddings()

      # Use a synthetic user_id that does not exist in accounts.users. The
      # SuperGraph resource only declares `user_id` as a `:uuid` attribute
      # (no `references`), so we can create a row with a phantom user_id.
      # `load_user` then fails with `Ash.Error.Query.NotFound`, which surfaces
      # as the inner `{:error, _}` branch of the pipeline `with` chain.
      phantom_user_id = Ash.UUID.generate()
      super_graph_name = "super:user:#{phantom_user_id}"

      {:ok, _} =
        Ash.create(
          Magus.SuperBrain.SuperGraph,
          %{
            accessor_type: :user,
            user_id: phantom_user_id,
            workspace_id: nil,
            graph_name: super_graph_name,
            last_build_status: :ok
          },
          authorize?: false
        )

      on_exit(fn ->
        Magus.Graph.drop(super_graph_name)
      end)

      assert {:error, _} =
               perform_job(BuildSuperFull, %{
                 "accessor_type" => "user",
                 "user_id" => phantom_user_id,
                 "workspace_id" => nil
               })

      {:ok, [row]} =
        SuperGraph
        |> Ash.Query.filter(user_id == ^phantom_user_id and accessor_type == :user)
        |> Ash.read(authorize?: false)

      assert row.last_build_status == :failed,
             "expected :failed, got #{inspect(row.last_build_status)}; mark_failed_safe got rolled back"

      assert is_binary(row.last_error)
    end
  end
end
