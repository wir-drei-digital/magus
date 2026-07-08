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
      assert length(
               for line <- String.split(out, "\n"),
                   String.contains?(line, "relates_to:"),
                   do: line
             ) == 2
    end
  end

  describe "format_with_claims/2" do
    test "renders claims grouped under subjects with citations and conflicts" do
      entities = [%{name: "Aurora", primary_type: "project", sources: []}]

      claims = [
        %{
          subject_name: "Aurora",
          subject_key: "aurora",
          predicate: "occurs_at",
          object_name: "Q3",
          object_key: "q3",
          polarity: :affirms,
          claim_text: "Aurora targets Q3.",
          confidence: 0.9,
          episode: %{resource_type: :brain_page, resource_id: Ash.UUID.generate()}
        },
        %{
          subject_name: "Aurora",
          subject_key: "aurora",
          predicate: "occurs_at",
          object_name: "Q4",
          object_key: "q4",
          polarity: :affirms,
          claim_text: "Aurora moved to Q4.",
          confidence: 0.9,
          episode: %{resource_type: :draft, resource_id: Ash.UUID.generate()}
        }
      ]

      block = SuperBrainRagContext.format_with_claims(entities, claims)

      assert block =~ "<super_brain>"
      assert block =~ "Aurora targets Q3."
      assert block =~ "Aurora"
    end

    test "renders a CONFLICT line for opposite-polarity claims on the same triple" do
      entities = [%{name: "Aurora", primary_type: "project", sources: []}]

      claims = [
        %{
          subject_name: "Aurora",
          subject_key: "aurora",
          predicate: "ships_in",
          object_name: "Q3",
          object_key: "q3",
          polarity: :affirms,
          claim_text: "Aurora ships in Q3.",
          confidence: 0.9,
          episode: %{resource_type: :brain_page, resource_id: Ash.UUID.generate()}
        },
        %{
          subject_name: "Aurora",
          subject_key: "aurora",
          predicate: "ships_in",
          object_name: "Q3",
          object_key: "q3",
          polarity: :negates,
          claim_text: "Aurora does not ship in Q3.",
          confidence: 0.9,
          episode: %{resource_type: :draft, resource_id: Ash.UUID.generate()}
        }
      ]

      block = SuperBrainRagContext.format_with_claims(entities, claims)

      assert block =~ "CONFLICT"
      assert block =~ "Aurora ships in Q3."
      assert block =~ "Aurora does not ship in Q3."
    end

    test "an entity with no claims renders the name + type line" do
      block =
        SuperBrainRagContext.format_with_claims(
          [%{name: "Daniel", primary_type: "person", sources: []}],
          []
        )

      assert block =~ "Daniel"
      assert block =~ "person"
    end

    test "caps rendered claims per entity at @max_claims_per_entity" do
      entities = [%{name: "Aurora", primary_type: "project", sources: []}]

      claims =
        for i <- 1..5 do
          %{
            subject_name: "Aurora",
            subject_key: "aurora",
            predicate: "relates_to",
            object_name: "Topic #{i}",
            object_key: "topic_#{i}",
            polarity: :affirms,
            claim_text: "Aurora claim number #{i}.",
            confidence: 0.9,
            episode: %{resource_type: :brain_page, resource_id: Ash.UUID.generate()}
          }
        end

      block = SuperBrainRagContext.format_with_claims(entities, claims)

      rendered =
        for i <- 1..5, block =~ "Aurora claim number #{i}.", do: i

      assert length(rendered) == 3
    end

    test "surfaces an orphan claim (subject not among entities) under its own header" do
      # Only "Aurora" is a retrieved entity; the claim is about "Beacon", whose
      # subject_key matches no entity. It must still render under a Beacon
      # header so claim-text recall is not silently dropped.
      entities = [%{name: "Aurora", primary_type: "project", sources: []}]

      claims = [
        %{
          subject_name: "Beacon",
          subject_key: "beacon",
          subject_type: "project",
          predicate: "depends_on",
          object_name: "Aurora",
          object_key: "aurora",
          polarity: :affirms,
          claim_text: "Beacon depends on Aurora.",
          confidence: 0.9,
          episode: %{resource_type: :brain_page, resource_id: Ash.UUID.generate()}
        }
      ]

      block = SuperBrainRagContext.format_with_claims(entities, claims)

      assert block =~ "Beacon"
      assert block =~ "Beacon depends on Aurora."
    end

    test "a normalized legacy-shape entity renders its name and type, not '?'" do
      # The legacy fan-out candidate `%{entity: %{name:, type:}}` is normalized
      # by `normalize_legacy_entity/1` in `do_build/3` into this bare shape
      # BEFORE reaching the formatter; verify it renders concretely.
      normalized =
        SuperBrainRagContext.normalize_legacy_entity(%{
          entity: %{name: "Legacy Co", type: "organization"},
          graph_name: "memories:user:abc",
          similarity: 0.8
        })

      assert normalized == %{name: "Legacy Co", primary_type: "organization", sources: []}

      block = SuperBrainRagContext.format_with_claims([normalized], [])

      assert block =~ "Legacy Co"
      assert block =~ "organization"
      refute block =~ "- ? [?]"
    end
  end

  describe "superseded trailers" do
    defp temporal_claim(overrides) do
      Map.merge(
        %{
          subject_key: "aurora",
          subject_name: "Aurora",
          subject_type: "project",
          object_key: "q4",
          object_name: "Q4",
          predicate: "occurs_at",
          polarity: :affirms,
          claim_text: "Aurora now ships in Q4.",
          asserted_at: ~U[2026-06-01 00:00:00Z],
          episode: nil
        },
        Map.new(overrides)
      )
    end

    test "a superseded prior renders as a (was: X) trailer on the current line" do
      current = temporal_claim(%{})

      prior =
        temporal_claim(%{
          object_key: "q3",
          object_name: "Q3",
          claim_text: "Aurora ships in Q3.",
          asserted_at: ~U[2026-05-01 00:00:00Z]
        })

      block =
        Magus.Agents.Context.SuperBrainRagContext.format_with_claims(
          [],
          [current],
          [%{claim: prior, reason: :superseded}]
        )

      assert block =~ ~s(- "Aurora now ships in Q4.")
      assert block =~ "(was: Q3)"
    end

    test "expired and future historic claims produce no trailer and no line" do
      current = temporal_claim(%{})

      expired =
        temporal_claim(%{
          object_key: "q3",
          object_name: "Q3",
          claim_text: "Aurora ships in Q3.",
          asserted_at: ~U[2026-05-01 00:00:00Z]
        })

      block =
        Magus.Agents.Context.SuperBrainRagContext.format_with_claims(
          [],
          [current],
          [%{claim: expired, reason: :expired}]
        )

      refute block =~ "(was:"
      refute block =~ "Aurora ships in Q3."
    end

    test "a superseded re-assertion of the same object renders no trailer" do
      current = temporal_claim(%{})

      same_object_prior =
        temporal_claim(%{
          claim_text: "Aurora ships in Q4 for sure.",
          asserted_at: ~U[2026-05-01 00:00:00Z]
        })

      block =
        Magus.Agents.Context.SuperBrainRagContext.format_with_claims(
          [],
          [current],
          [%{claim: same_object_prior, reason: :superseded}]
        )

      refute block =~ "(was:"
    end

    test "format_with_claims/2 still works (historic defaults to empty)" do
      block =
        Magus.Agents.Context.SuperBrainRagContext.format_with_claims([], [temporal_claim(%{})])

      assert block =~ ~s(- "Aurora now ships in Q4.")
    end

    test "a multi-valued polarity flip does not leak a trailer onto sibling objects" do
      current_sibling =
        temporal_claim(%{
          predicate: "relates_to",
          object_key: "vendorb",
          object_name: "VendorB",
          claim_text: "Aurora relates to VendorB."
        })

      flipped_prior =
        temporal_claim(%{
          predicate: "relates_to",
          object_key: "vendora",
          object_name: "VendorA",
          claim_text: "Aurora relates to VendorA.",
          asserted_at: ~U[2026-05-01 00:00:00Z]
        })

      block =
        Magus.Agents.Context.SuperBrainRagContext.format_with_claims(
          [],
          [current_sibling],
          [%{claim: flipped_prior, reason: :superseded}]
        )

      assert block =~ ~s(- "Aurora relates to VendorB.")
      refute block =~ "(was:"
    end

    test "the trailer renders through the entity section path too" do
      entity = %{name: "Aurora", primary_type: "project", sources: []}
      current = temporal_claim(%{})

      prior =
        temporal_claim(%{
          object_key: "q3",
          object_name: "Q3",
          claim_text: "Aurora ships in Q3.",
          asserted_at: ~U[2026-05-01 00:00:00Z]
        })

      block =
        Magus.Agents.Context.SuperBrainRagContext.format_with_claims(
          [entity],
          [current],
          [%{claim: prior, reason: :superseded}]
        )

      assert block =~ "## Aurora [project]"
      assert block =~ ~s(- "Aurora now ships in Q4.")
      assert block =~ "(was: Q3)"
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
