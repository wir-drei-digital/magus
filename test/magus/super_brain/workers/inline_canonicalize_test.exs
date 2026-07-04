defmodule Magus.SuperBrain.Workers.InlineCanonicalizeTest do
  @moduledoc """
  Tests for iter3 Task 7: inline canonicalize step in ExtractBase.

  After entities are upserted, ExtractBase calls
  `Magus.Graph.Vector.knn_search/5` to find near-duplicates of the same
  `(type, normalized_subtype)` above cosine 0.95 and merges them, writing
  an audit row to `super_brain_canonicalization_events`.

  ## Why these tests pre-seed entities directly

  `ExtractBase.stable_id/2` derives entity IDs from `(graph_name, name)`,
  so two extractions producing an entity named "Daniel" land on the same
  FalkorDB node via MERGE (regardless of type/subtype). To exercise the
  KNN-based canonicalize step we need DISTINCT entity IDs with similar
  embeddings, which we get by pre-seeding the graph with a synthetic
  "Daniel" node under a manual ID before the extraction runs. The
  extraction then creates the standard stable-id "Daniel" node and the
  canonicalize step fires the KNN search, finding both as candidates.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  alias Magus.SuperBrain.Workers.ExtractBrainPage

  require Ash.Query

  setup :set_mox_from_context
  setup :verify_on_exit!

  # Override the default ResourceCase stub so embeddings have unit length
  # and identical content. Cosine similarity between two identical
  # non-zero vectors is 1.0, well above the 0.95 canonicalize threshold.
  defp stub_unit_embeddings do
    dim = 1536
    unit_vec = [1.0 | List.duplicate(0.0, dim - 1)]

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
      {:ok, Enum.map(texts, fn _ -> unit_vec end)}
    end)

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
      {:ok, unit_vec}
    end)

    :ok
  end

  defp unit_vec do
    [1.0 | List.duplicate(0.0, 1535)]
  end

  # Pre-seed the FalkorDB graph with a synthetic entity that has a manual
  # id (so it does NOT collide with the extraction's stable_id-derived
  # node). The pre-seed mimics a prior extraction's output: same name,
  # configurable type+subtype, identical embedding.
  defp seed_entity(graph, opts) do
    :ok = ensure_index(graph)

    {:ok, _} =
      Magus.Graph.upsert_node(graph, "Entity", %{
        id: Keyword.fetch!(opts, :id),
        name: Keyword.get(opts, :name, "Daniel"),
        type: Keyword.get(opts, :type, "person"),
        normalized_subtype: Keyword.get(opts, :normalized_subtype),
        confidence: Keyword.get(opts, :confidence, 0.7),
        extractor: Keyword.get(opts, :extractor, "seed_extractor@test"),
        source_id: Keyword.get(opts, :source_id, "seed-source"),
        embedding: Keyword.get(opts, :embedding, unit_vec())
      })

    :ok
  end

  defp ensure_index(graph) do
    _ =
      Magus.Graph.Vector.ensure_index(graph, "Entity", "embedding",
        dim: 1536,
        similarity: :cosine
      )

    :ok
  end

  defp ok_daniel(subtype, confidence) do
    subtype_field =
      case subtype do
        nil -> "null"
        s -> ~s("#{s}")
      end

    fn _messages, _opts ->
      {:ok,
       %{
         content:
           ~s({"entities":[{"name":"Daniel","type":"person","subtype":#{subtype_field},"confidence":#{confidence}}],"claims":[]}),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end
  end

  describe "same (type, normalized_subtype) dedup" do
    test "extraction merges a pre-seeded Daniel/person/user duplicate" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain = generate(brain(user_id: user.id))
      graph = "brain:#{brain.id}"
      on_exit(fn -> Magus.Graph.drop(graph) end)

      :ok =
        seed_entity(graph,
          id: "seed-daniel-1",
          name: "Daniel",
          type: "person",
          normalized_subtype: "user",
          confidence: 0.6
        )

      page =
        brain_page(brain_id: brain.id, user_id: user.id, content: "Daniel is the founder.")

      expect(Magus.SuperBrain.LLMMock, :complete, ok_daniel("user", 0.9))
      :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # Canonicalize collapses the two Daniel/person/user nodes into one.
      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'Daniel'}) RETURN count(e)")

      assert [[1]] = result.rows
    end
  end

  describe "subtype split" do
    test "Daniel/person/user and Daniel/person/character stay separate" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain = generate(brain(user_id: user.id))
      graph = "brain:#{brain.id}"
      on_exit(fn -> Magus.Graph.drop(graph) end)

      # Seed a Daniel/person/character that the extraction's
      # Daniel/person/user must NOT merge with (different normalized_subtype).
      :ok =
        seed_entity(graph,
          id: "seed-daniel-character",
          name: "Daniel",
          type: "person",
          normalized_subtype: "character",
          confidence: 0.85
        )

      page =
        brain_page(brain_id: brain.id, user_id: user.id, content: "Daniel is me.")

      expect(Magus.SuperBrain.LLMMock, :complete, ok_daniel("user", 0.9))
      :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'Daniel'}) RETURN count(e)")

      assert [[2]] = result.rows
    end
  end

  describe "type split" do
    test "Daniel/person and Daniel/document stay separate" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain = generate(brain(user_id: user.id))
      graph = "brain:#{brain.id}"
      on_exit(fn -> Magus.Graph.drop(graph) end)

      # Seed a Daniel/document that the extraction's Daniel/person must
      # NOT merge with (different type).
      :ok =
        seed_entity(graph,
          id: "seed-daniel-doc",
          name: "Daniel",
          type: "document",
          normalized_subtype: nil
        )

      page =
        brain_page(brain_id: brain.id, user_id: user.id, content: "Daniel is a person.")

      expect(Magus.SuperBrain.LLMMock, :complete, ok_daniel(nil, 0.9))
      :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'Daniel'}) RETURN count(e)")

      assert [[2]] = result.rows
    end
  end

  describe "audit log" do
    test "writes a canonicalization event per merge" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain = generate(brain(user_id: user.id))
      graph = "brain:#{brain.id}"
      on_exit(fn -> Magus.Graph.drop(graph) end)

      :ok =
        seed_entity(graph,
          id: "seed-daniel-audit",
          name: "Daniel",
          type: "person",
          normalized_subtype: "user",
          confidence: 0.6
        )

      page =
        brain_page(brain_id: brain.id, user_id: user.id, content: "Daniel founded the company.")

      expect(Magus.SuperBrain.LLMMock, :complete, ok_daniel("user", 0.9))
      :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, %{rows: rows}} =
        Magus.Repo.query(
          "SELECT count(*) FROM super_brain_canonicalization_events WHERE graph_name = $1",
          [graph]
        )

      assert [[count]] = rows
      assert count >= 1
    end
  end

  describe "audit insert failure does not roll back the episode" do
    test "INSERT failure on super_brain_canonicalization_events leaves episode :extracted" do
      # Regression for Wave 1 / Task 1.1: previously the audit insert ran
      # via `Repo.query!` inside the pipeline's `Repo.transaction`. A
      # statement-level error would abort the entire transaction, rolling
      # back the new Episode row + budget_increment while leaving the
      # already-committed FalkorDB writes orphaned. The fix wraps the
      # insert in a SAVEPOINT so the audit failure is contained.
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain = generate(brain(user_id: user.id))
      graph = "brain:#{brain.id}"

      # Force every audit insert to fail at statement level via an
      # unsatisfiable CHECK constraint. Use a uniquely-named constraint so
      # this test does not collide with parallel runs (we're async: false,
      # but belt-and-suspenders).
      constraint_name =
        "audit_fail_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Magus.Repo.query(
          "ALTER TABLE super_brain_canonicalization_events ADD CONSTRAINT #{constraint_name} CHECK (false)"
        )

      on_exit(fn ->
        Magus.Graph.drop(graph)

        # Constraint drop runs in its own connection: the sandbox rolls
        # back data writes but DDL was committed in our test's sandbox
        # transaction. Best-effort drop.
        _ =
          Magus.Repo.query(
            "ALTER TABLE super_brain_canonicalization_events DROP CONSTRAINT IF EXISTS #{constraint_name}"
          )
      end)

      :ok =
        seed_entity(graph,
          id: "seed-daniel-audit-fail",
          name: "Daniel",
          type: "person",
          normalized_subtype: "user",
          confidence: 0.6
        )

      page =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          content: "Daniel runs the project."
        )

      expect(Magus.SuperBrain.LLMMock, :complete, ok_daniel("user", 0.9))

      # The worker MUST still return :ok despite the audit failure.
      assert :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      # And the Episode MUST be :extracted, not rolled back to nothing.
      {:ok, episodes} =
        Magus.SuperBrain.Episode
        |> Ash.Query.filter(resource_id == ^page.id)
        |> Ash.read(authorize?: false)

      assert [episode] = episodes
      assert episode.status == :extracted

      # And the merged Daniel node MUST be in the graph (one canonical
      # Daniel, since the two pre-merge nodes had identical embeddings
      # and matching (type, subtype)).
      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'Daniel'}) RETURN count(e)")

      assert [[1]] = result.rows
    end
  end

  describe "curated extractor carve-out" do
    test "extraction never merges with a pin-ingested entity" do
      :ok = stub_unit_embeddings()

      user = generate(user())
      brain = generate(brain(user_id: user.id))
      graph = "brain:#{brain.id}"
      on_exit(fn -> Magus.Graph.drop(graph) end)

      # Seed a user-curated Daniel/person/user. Even with identical
      # (type, subtype) and embedding above threshold, canonicalize must
      # leave this node alone because its extractor uses the curated
      # prefix (`brain_pin_ingest`, stamped by the pin worker).
      :ok =
        seed_entity(graph,
          id: "seed-daniel-curated",
          name: "Daniel",
          type: "person",
          normalized_subtype: "user",
          extractor: "brain_pin_ingest@2026-05-22"
        )

      page =
        brain_page(brain_id: brain.id, user_id: user.id, content: "Daniel is the founder.")

      expect(Magus.SuperBrain.LLMMock, :complete, ok_daniel("user", 0.9))
      :ok = perform_job(ExtractBrainPage, %{"resource_id" => page.id})

      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'Daniel'}) RETURN count(e)")

      assert [[2]] = result.rows
    end
  end
end
