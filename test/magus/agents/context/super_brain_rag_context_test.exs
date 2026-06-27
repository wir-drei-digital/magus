defmodule Magus.Agents.Context.SuperBrainRagContextTest do
  @moduledoc """
  Tests for `Magus.Agents.Context.SuperBrainRagContext`.

  The module wraps two collaborators that the test environment does not
  exercise out-of-the-box:

    * `Magus.Files.EmbeddingModel.embed/1` calls OpenRouter directly and
      returns `{:error, _}` in tests without an `OPENROUTER_API_KEY`.
    * `Magus.SuperBrain.Retrieval.search/2` walks FalkorDB and only
      returns entities when a SuperGraph row + canonicals are seeded.

  We therefore stick to deterministic assertions that exercise the
  pure-logic paths (short query, nil query, empty map, embedder failure
  via the no-key path) and gate richer assertions on the optional
  `result do ... end` pattern when downstream collaborators happen to
  succeed in the test environment.
  """

  use Magus.ResourceCase, async: false

  alias Magus.Agents.Context.SuperBrainRagContext

  describe "build/1 — short-circuits" do
    test "returns nil when query is shorter than the minimum length" do
      user = generate(user())
      assert nil == SuperBrainRagContext.build(%{query: "hi", user: user})
    end

    test "returns nil when query is exactly at the boundary minus 1 char" do
      # @min_query_length is 10, so a 9-char query must short-circuit
      user = generate(user())
      assert nil == SuperBrainRagContext.build(%{query: "123456789", user: user})
    end

    test "returns nil when query is nil" do
      user = generate(user())
      assert nil == SuperBrainRagContext.build(%{query: nil, user: user})
    end

    test "returns nil for an empty map" do
      assert nil == SuperBrainRagContext.build(%{})
    end

    test "returns nil when user is missing" do
      assert nil == SuperBrainRagContext.build(%{query: "a long enough query"})
    end
  end

  describe "build/1 — embedder/retrieval failure paths" do
    test "returns nil when the embedder fails (no OPENROUTER_API_KEY in tests)" do
      # In the test environment EmbeddingModel.embed/1 hits OpenRouter and
      # returns {:error, _} when the API key is missing. The module must
      # gracefully degrade to nil rather than blow up the agent turn.
      user = generate(user())

      assert nil ==
               SuperBrainRagContext.build(%{
                 query: "What do I know about distributed systems?",
                 user: user
               })
    end

    test "returns nil for an isolated user with no graphs at all" do
      # An isolated user has no SuperGraph row and no Layer 1 graphs in
      # FalkorDB, so even if the embedder happened to succeed the
      # legacy fan-out would return {:ok, []} and we should still emit nil.
      user = generate(user())

      assert nil ==
               SuperBrainRagContext.build(%{
                 query: "irrelevant but long enough query",
                 user: user,
                 workspace_id: nil
               })
    end
  end

  describe "build/1 — happy path formatting" do
    # The happy path requires three things to align in the test env:
    #   1. A seeded SuperGraph row + a CanonicalEntity in FalkorDB.
    #   2. The OpenRouter embedder to succeed (requires OPENROUTER_API_KEY).
    #   3. FalkorDB to be reachable.
    #
    # When any of those fail we skip the strict assertions and only
    # verify that the function returns `nil | binary`. This mirrors the
    # tolerant pattern in `BrainRagContextTest`.
    test "returns nil or a <super_brain> block when a canonical is seeded" do
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

      result =
        SuperBrainRagContext.build(%{
          query: "What do I know about Daniel?",
          user: user
        })

      assert is_nil(result) or is_binary(result)

      if is_binary(result) do
        assert result =~ "<super_brain>"
        assert result =~ "</super_brain>"
        assert result =~ "Daniel"
        assert result =~ "person"
      end
    end
  end

  describe "format/1 — page-level source refs" do
    test "renders brain page + draft refs with titles, ids, and a tool hint" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      page = brain_page(brain_id: brain.id, user_id: user.id, title: "Learning Elixir")
      draft = generate(draft(user_id: user.id, title: "Rust vs Elixir"))

      entities = [
        %{
          name: "Elixir",
          primary_type: "concept",
          normalized_subtype: nil,
          sources: [
            %{
              graph_name: "brain:#{brain.id}",
              source_refs: [
                %{resource_type: "brain_page", resource_id: page.id},
                %{resource_type: "draft", resource_id: draft.id}
              ]
            }
          ]
        }
      ]

      out = SuperBrainRagContext.format(entities)

      # Actionable refs the agent can pass straight to its tools.
      assert out =~ "page \"Learning Elixir\" (page_id: #{page.id})"
      assert out =~ "brain \"#{brain.title}\" >"
      assert out =~ "draft \"Rust vs Elixir\" (draft_id: #{draft.id})"
      # Usage hint naming the read tools.
      assert out =~ "read_brain.read_page"
      assert out =~ "read_draft"
    end

    test "falls back to graph-name 'seen in' when an entity has no source refs (pre-rebuild)" do
      entities = [
        %{
          name: "Elixir",
          primary_type: "concept",
          normalized_subtype: nil,
          sources: [%{graph_name: "brain:abc", source_refs: []}]
        }
      ]

      out = SuperBrainRagContext.format(entities)
      assert out =~ "Elixir [concept]"
      assert out =~ "(seen in: brain:abc)"
    end
  end

  describe "format/1 relation signal" do
    test "renders a contested line with the predicate breakdown" do
      entities = [
        %{
          name: "Plan A",
          primary_type: "decision",
          normalized_subtype: nil,
          sources: [%{graph_name: "brain:abc", source_refs: []}],
          neighbors: [
            %{
              id: "n1",
              name: "Ship Friday",
              predicate: "supports",
              confidence: 0.9,
              contested: true,
              predicate_breakdown: %{"supports" => 2, "contradicts" => 1}
            }
          ]
        }
      ]

      out = SuperBrainRagContext.format(entities)
      assert out =~ "contested: Ship Friday"
      assert out =~ "supports 2"
      assert out =~ "contradicts 1"
    end

    test "caps relation lines and prefers contested over plain relations" do
      neighbors =
        for i <- 1..5 do
          %{
            id: "n#{i}",
            name: "Rel #{i}",
            predicate: "relates_to",
            confidence: 0.5,
            contested: false,
            predicate_breakdown: %{"relates_to" => 1}
          }
        end

      entities = [
        %{
          name: "Hub",
          primary_type: "concept",
          normalized_subtype: nil,
          sources: [%{graph_name: "brain:abc", source_refs: []}],
          neighbors: neighbors
        }
      ]

      out = SuperBrainRagContext.format(entities)
      # At most 2 relation lines (the budget cap).
      assert length(for line <- String.split(out, "\n"), String.contains?(line, "relates_to:"), do: line) <= 2
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # The read_set_snapshot must match `AccessibleGraphs.for_actor/2` for the
  # given user with no brains/files/memories. Anything else looks like
  # read-set drift and Retrieval falls back to the legacy fan-out instead of
  # the super-graph search path.
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
end
