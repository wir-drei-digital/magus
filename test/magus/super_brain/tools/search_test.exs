defmodule Magus.SuperBrain.Tools.SearchTest do
  use Magus.ResourceCase, async: false

  import Mox

  alias Magus.SuperBrain.Tools.Search

  setup :verify_on_exit!

  test "returns ranked entities with provenance" do
    user = generate(user())
    brain = generate(brain(user_id: user.id))

    graph = "brain:#{brain.id}"

    Magus.Graph.upsert_node(graph, "Entity", %{
      id: "x1",
      name: "Topic X",
      type: "concept",
      embedding: [1.0, 0.0, 0.0],
      confidence: 0.8,
      trust_tier: "evidence"
    })

    Magus.Graph.Vector.create_index(graph, "Entity", "embedding",
      dim: 3,
      similarity: :cosine
    )

    on_exit(fn -> Magus.Graph.drop(graph) end)

    expect(Magus.Embeddings.EmbedderMock, :embed, fn _text, _opts ->
      {:ok,
       %{
         embedding: [1.0, 0.0, 0.0],
         usage: %Magus.SuperBrain.Usage{
           model_name: "openai/text-embedding-3-small",
           prompt_tokens: 5,
           completion_tokens: 0,
           total_tokens: 5,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end)

    {:ok, result} =
      Search.run(%{"query" => "topic x"}, %{user_id: user.id, conversation_id: nil})

    assert is_list(result.entities)
    refute Enum.empty?(result.entities)
    first = hd(result.entities)
    assert first.name == "Topic X"
    assert first.graph_name == graph
    assert first.type == "concept"
    assert first.trust_tier == :evidence
    assert is_number(first.score)
  end

  test "returns empty entities when embedder fails" do
    user = generate(user())

    expect(Magus.Embeddings.EmbedderMock, :embed, fn _text, _opts ->
      {:error, "boom"}
    end)

    {:ok, result} =
      Search.run(%{"query" => "anything"}, %{user_id: user.id, conversation_id: nil})

    assert Map.has_key?(result, :error)
  end

  test "writes a MessageUsage row for the embedding call" do
    user = generate(user())
    brain = generate(brain(user_id: user.id))

    Magus.Graph.upsert_node("brain:#{brain.id}", "Entity", %{
      id: "x1",
      name: "Topic X",
      type: "concept",
      embedding: [1.0, 0.0, 0.0],
      confidence: 0.8,
      trust_tier: "evidence"
    })

    Magus.Graph.Vector.create_index("brain:#{brain.id}", "Entity", "embedding",
      dim: 3,
      similarity: :cosine
    )

    on_exit(fn -> Magus.Graph.drop("brain:#{brain.id}") end)

    expect(Magus.Embeddings.EmbedderMock, :embed, fn _, _ ->
      {:ok,
       %{
         embedding: [1.0, 0.0, 0.0],
         usage: %Magus.SuperBrain.Usage{
           model_name: "openai/text-embedding-3-small",
           prompt_tokens: 10,
           completion_tokens: 0,
           total_tokens: 10,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end)

    {:ok, _} = Search.run(%{"query" => "topic x"}, %{user_id: user.id, conversation_id: nil})

    require Ash.Query

    {:ok, rows} =
      Magus.Usage.MessageUsage
      |> Ash.Query.filter(user_id == ^user.id and usage_type == :embedding)
      |> Ash.read(authorize?: false)

    assert length(rows) >= 1
    row = hd(rows)
    assert row.prompt_tokens == 10
  end

  # The read_set_snapshot must match `AccessibleGraphs.for_actor/2` for the
  # given user with no brains/files/memories. Anything else will look like
  # read-set drift and dispatch the legacy fan-out instead of the super-graph
  # search path.
  defp default_read_set(user_id) do
    [
      %{"graph_name" => "memories:user:#{user_id}"},
      %{"graph_name" => "files:user:#{user_id}"},
      %{"graph_name" => "drafts:user:#{user_id}"}
    ]
  end

  defp seed_super_graph_row!(user, graph_name) do
    {:ok, row} =
      Magus.SuperBrain.SuperGraph
      |> Ash.Changeset.for_create(:create, %{
        accessor_type: :user,
        user_id: user.id,
        workspace_id: nil,
        graph_name: graph_name
      })
      |> Ash.create(authorize?: false)

    {:ok, row} =
      row
      |> Ash.Changeset.for_update(:mark_built, %{
        read_set_snapshot: default_read_set(user.id),
        canonical_entity_count: 1,
        canonical_edge_count: 0,
        last_build_duration_ms: 1
      })
      |> Ash.update(authorize?: false)

    row
  end

  describe "super-graph happy path" do
    test "projects %{entities: [canonicals]} from Retrieval.search/2" do
      user = generate(user())
      super_graph = "super:user:#{user.id}"

      _row = seed_super_graph_row!(user, super_graph)

      Magus.Graph.upsert_node(super_graph, "CanonicalEntity", %{
        id: "c1",
        name: "Daniel",
        primary_type: "person",
        subtype: "user",
        normalized_subtype: "user",
        embedding: [1.0, 0.0, 0.0],
        trust_tier: "evidence",
        importance_score: 2.5,
        source_count: 2
      })

      Magus.Graph.Vector.create_index(super_graph, "CanonicalEntity", "embedding",
        dim: 3,
        similarity: :cosine
      )

      on_exit(fn -> Magus.Graph.drop(super_graph) end)

      expect(Magus.Embeddings.EmbedderMock, :embed, fn _text, _opts ->
        {:ok,
         %{
           embedding: [1.0, 0.0, 0.0],
           usage: %Magus.SuperBrain.Usage{
             model_name: "openai/text-embedding-3-small",
             prompt_tokens: 5,
             completion_tokens: 0,
             total_tokens: 5,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      assert {:ok, %{entities: entities}} =
               Search.run(%{"query" => "Daniel"}, %{user_id: user.id, conversation_id: nil})

      assert is_list(entities)
      refute Enum.empty?(entities)

      first = hd(entities)
      assert first.name == "Daniel"
      # primary_type is preferred over the older `type` key
      assert first.type == "person"
      # normalized_subtype is preferred over `subtype`
      assert first.subtype == "user"
      assert first.trust_tier == "evidence"
      assert is_number(first.score)
      assert is_list(first.sources)
    end

    test "surfaces %{error: reason} when the super graph backend errors" do
      user = generate(user())
      super_graph = "super:user:#{user.id}"

      _row = seed_super_graph_row!(user, super_graph)

      # Intentionally do NOT create the vector index on CanonicalEntity.embedding.
      # `db.idx.vector.queryNodes` against a missing index returns an error from
      # FalkorDB which surfaces here as `{:ok, %{error: _}}`.
      Magus.Graph.upsert_node(super_graph, "CanonicalEntity", %{
        id: "c1",
        name: "Daniel",
        primary_type: "person",
        normalized_subtype: "user",
        embedding: [1.0, 0.0, 0.0],
        trust_tier: "evidence",
        importance_score: 1.0,
        source_count: 1
      })

      on_exit(fn -> Magus.Graph.drop(super_graph) end)

      expect(Magus.Embeddings.EmbedderMock, :embed, fn _text, _opts ->
        {:ok,
         %{
           embedding: [1.0, 0.0, 0.0],
           usage: %Magus.SuperBrain.Usage{
             model_name: "openai/text-embedding-3-small",
             prompt_tokens: 5,
             completion_tokens: 0,
             total_tokens: 5,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      assert {:ok, %{error: _reason}} =
               Search.run(%{"query" => "Daniel"}, %{user_id: user.id, conversation_id: nil})
    end
  end

  describe "attach_claims/2" do
    test "attaches the top 2 matching claims to an entity, capped and ordered" do
      entities = [%{name: "Daniel", type: "person"}]

      claims = [
        claim("Daniel", "works_at", "Daniel works at Acme."),
        claim("Daniel", "lives_in", "Daniel lives in Berlin."),
        claim("Daniel", "likes", "Daniel likes coffee.")
      ]

      [result] = Search.attach_claims(entities, claims)

      assert result.name == "Daniel"
      assert length(result.claims) == 2

      assert result.claims == [
               %{text: "Daniel works at Acme.", predicate: "works_at"},
               %{text: "Daniel lives in Berlin.", predicate: "lives_in"}
             ]
    end

    test "entity with no matching claim gets an empty claims list" do
      entities = [%{name: "Nobody", type: "person"}]
      claims = [claim("Daniel", "works_at", "Daniel works at Acme.")]

      [result] = Search.attach_claims(entities, claims)

      assert result.claims == []
    end

    test "matches subject names case-insensitively and across whitespace, via Naming.key/1" do
      entities = [%{name: "  Daniel   Milenkovic ", type: "person"}]
      claims = [claim("daniel milenkovic", "role", "Daniel Milenkovic is an engineer.")]

      [result] = Search.attach_claims(entities, claims)

      assert result.claims == [%{text: "Daniel Milenkovic is an engineer.", predicate: "role"}]
    end

    test "returns [] unmodified when the entity list is empty" do
      assert Search.attach_claims([], [claim("Daniel", "role", "text")]) == []
    end

    defp claim(subject_name, predicate, claim_text) do
      %{subject_name: subject_name, predicate: predicate, claim_text: claim_text}
    end
  end
end
