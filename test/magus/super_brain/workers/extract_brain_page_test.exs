defmodule Magus.SuperBrain.Workers.ExtractBrainPageTest do
  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  require Ash.Query

  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.ExtractionBudget
  alias Magus.SuperBrain.Usage
  alias Magus.SuperBrain.Workers.ExtractBrainPage

  setup :set_mox_from_context
  setup :verify_on_exit!

  # Drop the test graph for each brain we touch, so re-runs don't leak
  # nodes between tests against the same FalkorDB instance.
  defp on_exit_drop_graph(brain_id) do
    on_exit(fn ->
      Magus.Graph.drop("brain:#{brain_id}")
    end)
  end

  defp zero_usage do
    %Usage{
      model_name: "test-model",
      total_tokens: 10,
      prompt_tokens: 5,
      completion_tokens: 5,
      input_cost: Decimal.new("0"),
      output_cost: Decimal.new("0"),
      total_cost: Decimal.new("0")
    }
  end

  defp ok_extract_x(_messages, _opts) do
    {:ok,
     %{
       content: """
       {"entities": [
          {"name": "X", "type": "person", "subtype": null, "confidence": 0.8}
        ],
        "claims":[]}
       """,
       usage: zero_usage()
     }}
  end

  describe "perform/1" do
    test "extracts entities and writes them to the brain graph" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "Daniel works on X"
        )

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_x/2)

      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :brain_page and resource_id == ^page.id)
        |> Ash.read_one(authorize?: false)

      assert episode.status == :extracted
      assert episode.extractor_version == "brain_extract_worker@2026-05-21"

      {:ok, result} =
        Magus.Graph.query(
          "brain:#{brain.id}",
          "MATCH (e:Entity {name: 'X'}) RETURN e.name"
        )

      assert [["X"]] = result.rows
    end

    test "still accepts the legacy 'page_id' arg key" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "legacy arg"
        )

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"L","type":"concept","subtype":null,"confidence":0.8}],"claims":[]}),
           usage: zero_usage()
         }}
      end)

      assert :ok = perform_job(ExtractBrainPage, %{"page_id" => page.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :brain_page and resource_id == ^page.id)
        |> Ash.read_one(authorize?: false)

      assert episode.status == :extracted
    end

    test "skips re-extraction when content fingerprint is unchanged" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "same content"
        )

      # First run: LLM is invoked once and the Episode is marked :extracted.
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_x/2)
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # Confirm the first expectation was consumed; no pending calls remain.
      verify!(Magus.SuperBrain.LLMMock)

      # Second run with unchanged content: must NOT call the LLM. Mox is in
      # global mode (set_mox_from_context for non-async test), so any
      # unexpected call would raise Mox.UnexpectedCallError and fail the test.
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})
    end

    test "respects per-user daily budget ceiling" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "anything"
        )

      # Saturate the budget so the next call would reach the ceiling. Pin a
      # tiny explicit ceiling so this is independent of the global default.
      date = Date.utc_today()

      Ash.create!(ExtractionBudget, %{user_id: user.id, date: date, ceiling_call_count: 1},
        action: :upsert,
        authorize?: false
      )

      :ok = ExtractionBudget.atomic_increment(user.id, date, calls: 1, cost_cents: 0)

      assert {:cancel, :budget_exceeded} =
               perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # Nothing should have hit the LLM; nothing should have been written
      # to the Episode lifecycle either.
      assert {:ok, nil} =
               Episode
               |> Ash.Query.filter(resource_type == :brain_page and resource_id == ^page.id)
               |> Ash.read_one(authorize?: false)
    end

    test "propagates LLM errors and persists no episode" do
      # The LLM call runs before the persistence transaction (so no DB
      # connection is held across it), so an LLM failure happens before any
      # Episode row is created. The error propagates so Oban retries the job;
      # no `:extracted` (or `:failed`) Episode is left behind, and the prior
      # extraction, if any, is untouched.
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "anything"
        )

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ -> {:error, :rate_limited} end)

      assert {:error, :rate_limited} =
               perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :brain_page and resource_id == ^page.id)
        |> Ash.read_one(authorize?: false)

      assert is_nil(episode)
    end

    test "source-scoped re-extraction preserves manually-curated entities" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      graph = "brain:#{brain.id}"

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "v1 content about X"
        )

      # Seed a human-curated node that must survive any re-extraction.
      {:ok, _} =
        Magus.Graph.upsert_node(graph, "Entity", %{
          id: "manual-1",
          name: "ManualNode",
          extractor: "human"
        })

      # First extraction.
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_x/2)
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # Replace the page's blocks so its rendered markdown changes. This
      # mirrors what would happen when a user edits a page in the UI; the
      # plan's `Ash.update(page, %{content: "v2"})` is not possible because
      # the Page resource has no :content attribute - text lives in blocks.
      {:ok, owner} = Magus.Accounts.get_user(user.id, authorize?: false)
      page = replace_page_body(page, "v2 content about Y", owner)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_x/2)
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # The hand-curated node is still present.
      {:ok, manual_result} =
        Magus.Graph.query(
          graph,
          "MATCH (e:Entity {id: 'manual-1'}) RETURN e.name"
        )

      assert [["ManualNode"]] = manual_result.rows

      # And the extractor-tagged node was rewritten (so only one copy
      # exists, not duplicated).
      {:ok, extracted_result} =
        Magus.Graph.query(
          graph,
          "MATCH (e:Entity {name: 'X', extractor: 'brain_extract_worker@2026-05-21'}) RETURN e.name"
        )

      assert length(extracted_result.rows) == 1
    end

    test "re-extracting page A preserves page B's entities in the same brain" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      graph = "brain:#{brain.id}"
      {:ok, owner} = Magus.Accounts.get_user(user.id, authorize?: false)

      page_a =
        brain_page(brain_id: brain.id, user_id: user.id, content: "A1 content about EntityA")

      page_b =
        brain_page(brain_id: brain.id, user_id: user.id, content: "B1 content about EntityB")

      entity_a_response = fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities": [{"name": "EntityA", "type": "concept", "subtype": null, "confidence": 0.8}], "claims":[]}),
           usage: zero_usage()
         }}
      end

      entity_b_response = fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities": [{"name": "EntityB", "type": "concept", "subtype": null, "confidence": 0.8}], "claims":[]}),
           usage: zero_usage()
         }}
      end

      # Extract both pages so EntityA and EntityB both exist in the brain graph.
      expect(Magus.SuperBrain.LLMMock, :complete, entity_a_response)
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page_a.id})

      expect(Magus.SuperBrain.LLMMock, :complete, entity_b_response)
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page_b.id})

      # Modify page A so its fingerprint changes, then re-extract it. With
      # the source-scoped DELETE filtering by source_id (the Episode id),
      # only EntityA's old node should be removed; EntityB must survive.
      page_a = replace_page_body(page_a, "A2 different content", owner)

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities": [{"name": "EntityA2", "type": "concept", "subtype": null, "confidence": 0.8}], "claims":[]}),
           usage: zero_usage()
         }}
      end)

      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page_a.id})

      # EntityB (from page B, not touched) must still exist.
      {:ok, result_b} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'EntityB'}) RETURN e.name")

      assert [["EntityB"]] = result_b.rows
    end

    test "writes an Episode node linked via HAS_ENTITY to each Entity, with embeddings" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "Daniel works on Project X"
        )

      graph = "brain:#{brain.id}"

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel","type":"person","subtype":null,"confidence":0.9}],"claims":[]}),
           usage: zero_usage()
         }}
      end)

      # The default `Magus.Embeddings.BatchEmbedderMock` stub in
      # `Magus.ResourceCase` returns 1536-dim zero-vectors for both
      # `embed_one/1` (Episode raw_text) and `embed_many/1` (entity names),
      # so the full spec schema lands in FalkorDB without the test needing
      # to manage embedder expectations.
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # 1) Episode node exists with the right resource_type.
      {:ok, ep_result} =
        Magus.Graph.query(
          graph,
          "MATCH (e:Episode) RETURN e.resource_type"
        )

      assert [["brain_page"]] = ep_result.rows

      # 2) HAS_ENTITY edge from Episode to Entity, with confidence.
      {:ok, link_result} =
        Magus.Graph.query(
          graph,
          "MATCH (ep:Episode)-[r:HAS_ENTITY]->(e:Entity {name: 'Daniel'}) RETURN r.confidence"
        )

      assert [[conf]] = link_result.rows
      # FalkorDB scalar decoding may return numerics as strings or floats;
      # accept either as long as something non-nil came back on the edge.
      refute is_nil(conf)

      # 3) Entity node carries an embedding (FalkorDB returns vecf32 as a
      #    string-like representation; non-empty rows confirm presence).
      {:ok, entity_embedding_result} =
        Magus.Graph.query(
          graph,
          "MATCH (e:Entity {name: 'Daniel'}) RETURN e.embedding"
        )

      assert [[embedding_value]] = entity_embedding_result.rows
      refute is_nil(embedding_value)

      # 4) Episode also carries an embedding.
      {:ok, ep_embedding_result} =
        Magus.Graph.query(
          graph,
          "MATCH (e:Episode) RETURN e.embedding"
        )

      assert [[ep_embedding_value]] = ep_embedding_result.rows
      refute is_nil(ep_embedding_value)
    end

    test "re-extraction removes the prior Episode node for this source" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      graph = "brain:#{brain.id}"
      {:ok, owner} = Magus.Accounts.get_user(user.id, authorize?: false)

      page =
        brain_page(brain_id: brain.id, user_id: user.id, content: "v1 about X")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_x/2)
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # Confirm exactly one Episode for this source before re-extraction.
      {:ok, before_result} =
        Magus.Graph.query(graph, "MATCH (e:Episode) RETURN count(e)")

      assert [[1]] = before_result.rows

      # Change the page content to force re-extraction, then run it again.
      page = replace_page_body(page, "v2 about Y", owner)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_x/2)
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # Still exactly one Episode (the prior one was DETACH DELETEd).
      {:ok, after_result} =
        Magus.Graph.query(graph, "MATCH (e:Episode) RETURN count(e)")

      assert [[1]] = after_result.rows
    end

    test "re-extraction supersedes prior Episode instead of overwriting (D7)" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      {:ok, owner} = Magus.Accounts.get_user(user.id, authorize?: false)

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "v1 content about X"
        )

      # First extraction.
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_x/2)
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # Change content so the fingerprint differs, then re-extract.
      page = replace_page_body(page, "v2 content about Y", owner)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_x/2)
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, episodes} =
        Episode
        |> Ash.Query.filter(resource_type == :brain_page and resource_id == ^page.id)
        |> Ash.read(authorize?: false)

      # Provenance preserved: both rows exist (one extracted, one superseded).
      assert length(episodes) == 2

      statuses = episodes |> Enum.map(& &1.status) |> Enum.sort()
      assert statuses == [:extracted, :superseded]

      extracted = Enum.find(episodes, &(&1.status == :extracted))
      superseded = Enum.find(episodes, &(&1.status == :superseded))

      # The most recently inserted row is the live `:extracted` one.
      assert DateTime.compare(extracted.inserted_at, superseded.inserted_at) == :gt

      # Partial unique index still enforces "at most one :extracted" per
      # (resource_type, resource_id).
      {:ok, extracted_only} =
        Episode
        |> Ash.Query.filter(
          resource_type == :brain_page and
            resource_id == ^page.id and
            status == :extracted
        )
        |> Ash.read(authorize?: false)

      assert length(extracted_only) == 1
    end

    test "records the extraction_model from the Usage struct on the Episode" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "Daniel works on X"
        )

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content: ~s({"entities":[],"claims":[]}),
           usage: %Usage{
             model_name: "anthropic:claude-haiku-4-5",
             total_tokens: 5,
             prompt_tokens: 3,
             completion_tokens: 2,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(
          resource_type == :brain_page and resource_id == ^page.id and status == :extracted
        )
        |> Ash.read_one(authorize?: false)

      assert episode.extraction_model == "anthropic:claude-haiku-4-5"
    end

    test "writes normalized_subtype to Entity nodes (iter3 Task 8)" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      graph = "brain:#{brain.id}"

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "Daniel is my colleague"
        )

      # Mock an LLM response with a subtype that collides with the
      # SubtypeNormalizer map: "colleague" should collapse to "coworker".
      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel","type":"person","subtype":"colleague","confidence":0.9}],"claims":[]}),
           usage: zero_usage()
         }}
      end)

      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, result} =
        Magus.Graph.query(
          graph,
          "MATCH (e:Entity {name: 'Daniel'}) RETURN e.subtype, e.normalized_subtype"
        )

      assert [[raw, normalized]] = result.rows
      assert raw == "colleague"
      # SubtypeNormalizer collapses "colleague" -> "coworker".
      assert normalized == "coworker"
    end

    test "writes nil normalized_subtype when entity has no subtype (iter3 Task 8)" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      graph = "brain:#{brain.id}"

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "X is unique"
        )

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_x/2)
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, result} =
        Magus.Graph.query(
          graph,
          "MATCH (e:Entity {name: 'X'}) RETURN e.normalized_subtype"
        )

      assert [[normalized]] = result.rows
      assert is_nil(normalized)
    end

    test "writes a MessageUsage row for the LLM call" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "Daniel works on X"
        )

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"X","type":"person","subtype":null,"confidence":0.8}],"claims":[]}),
           usage: %Usage{
             model_name: "test-model",
             prompt_tokens: 42,
             completion_tokens: 7,
             total_tokens: 49,
             input_cost: Decimal.new("0.001"),
             output_cost: Decimal.new("0.002"),
             total_cost: Decimal.new("0.003")
           }
         }}
      end)

      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # MessageUsage row was written with usage_type :super_brain_extraction.
      require Ash.Query

      {:ok, [row]} =
        Magus.Usage.MessageUsage
        |> Ash.Query.filter(user_id == ^user.id and usage_type == :super_brain_extraction)
        |> Ash.read(authorize?: false)

      assert row.prompt_tokens == 42
      assert row.completion_tokens == 7
      assert row.total_tokens == 49
    end
  end

  describe "iter4 Task 4: :instruction trust tier routing" do
    test "insight callout in body routes through :user_curated and reaches :instruction tier" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      body = """
      # Notes

      ```callout
      variant: insight
      text: Daniel's wife is named Lisa
      ```
      """

      page = brain_page(brain_id: brain.id, user_id: user.id, content: body)

      # High-confidence entity so it CAN reach :instruction tier
      # (Ontology.compute_trust_tier requires confidence >= 0.9 + an
      # instruction-class source).
      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel","type":"person","subtype":null,"confidence":0.95}],"claims":[]}),
           usage: zero_usage()
         }}
      end)

      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, result} =
        Magus.Graph.query(
          "brain:#{brain.id}",
          "MATCH (e:Entity {name: 'Daniel'}) RETURN e.trust_tier"
        )

      assert [["instruction"]] = result.rows
    end

    test "pages without an insight callout still route through :llm_extract (:evidence tier)" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      # Plain paragraph: no callout, no instruction routing.
      page = brain_page(brain_id: brain.id, user_id: user.id, content: "Daniel works on X")

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Daniel","type":"person","subtype":null,"confidence":0.95}],"claims":[]}),
           usage: zero_usage()
         }}
      end)

      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, result} =
        Magus.Graph.query(
          "brain:#{brain.id}",
          "MATCH (e:Entity {name: 'Daniel'}) RETURN e.trust_tier"
        )

      # Even at confidence 0.95, without an instruction-class source the
      # entity stays at :evidence.
      assert [["evidence"]] = result.rows
    end
  end

  describe "iter3 fan-out: BuildSuperIncremental enqueue" do
    test "successful extraction fans out BuildSuperIncremental for the source graph's accessors" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "x"
        )

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content: ~s({"entities":[],"claims":[]}),
           usage: %Magus.SuperBrain.Usage{
             model_name: "t",
             total_tokens: 1,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # Personal brain - the user is the only accessor.
      assert_enqueued(
        worker: Magus.SuperBrain.Workers.BuildSuperIncremental,
        args: %{"user_id" => user.id, "accessor_type" => "user", "workspace_id" => nil}
      )
    end
  end
end
