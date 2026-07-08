defmodule Magus.SuperBrain.RetrievalClaimsTest do
  # ResourceCase (not DataCase) so `generate(user())` is available: seeding an
  # Episode below requires a real User (Episode.source_user_id is itself a hard
  # FK to users). Matches the sibling test/magus/super_brain/retrieval_test.exs
  # and the Claim.episode_id hard-FK precedent from claim_test.exs.
  use Magus.ResourceCase, async: false

  alias Magus.SuperBrain.{Claim, Retrieval}

  test "search_claims recalls a claim in an accessible graph and isolates others" do
    user = generate(user())
    graph = "memories:user:#{user.id}"

    # Episode.source_user_id is itself a hard FK to users, so the "someone
    # else" claim needs a real second user, not a fabricated UUID.
    other_user = generate(user())
    other_graph = "memories:user:#{other_user.id}"

    seed_claim(graph, user.id, "Aurora ships without the npm wrapper.", embedding: one_hot(0))
    seed_claim(other_graph, other_user.id, "Someone else fact.", embedding: one_hot(0))

    assert {:ok, [claim]} =
             Retrieval.search_claims(user,
               query_embedding: one_hot(0),
               accessible_graphs: [graph],
               limit: 5
             )

    assert claim.claim_text == "Aurora ships without the npm wrapper."
    assert %Claim{} = claim
    assert %Magus.SuperBrain.Episode{} = claim.episode
  end

  describe "temporal ranking" do
    test "returns the superseder even when the KNN query is nearest the stale claim" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      # Stale claim matches the query embedding exactly; the superseder is
      # orthogonal (the temporal xfail geometry).
      seed_claim(graph, user.id, "Aurora ships in Q3.",
        embedding: one_hot(7),
        predicate: "occurs_at",
        object: "Q3",
        asserted_at: ~U[2026-05-01 00:00:00Z]
      )

      seed_claim(graph, user.id, "Aurora now ships in Q4.",
        embedding: one_hot(9),
        predicate: "occurs_at",
        object: "Q4",
        asserted_at: ~U[2026-06-01 00:00:00Z]
      )

      assert {:ok, [claim]} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 1
               )

      assert claim.object_name == "Q4"
    end

    test "a superseder in an inaccessible graph does not supersede (accessor-relative)" do
      user = generate(user())
      graph = "memories:user:#{user.id}"
      other_user = generate(user())
      other_graph = "memories:user:#{other_user.id}"

      seed_claim(graph, user.id, "Aurora ships in Q3.",
        embedding: one_hot(7),
        predicate: "occurs_at",
        object: "Q3",
        asserted_at: ~U[2026-05-01 00:00:00Z]
      )

      seed_claim(other_graph, other_user.id, "Aurora now ships in Q4.",
        embedding: one_hot(9),
        predicate: "occurs_at",
        object: "Q4",
        asserted_at: ~U[2026-06-01 00:00:00Z]
      )

      assert {:ok, [claim]} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5
               )

      assert claim.object_name == "Q3"
    end

    test "include_historic: true returns the exact map shape with reasons" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      seed_claim(graph, user.id, "Aurora ships in Q3.",
        embedding: one_hot(7),
        predicate: "occurs_at",
        object: "Q3",
        asserted_at: ~U[2026-05-01 00:00:00Z]
      )

      seed_claim(graph, user.id, "Aurora now ships in Q4.",
        embedding: one_hot(9),
        predicate: "occurs_at",
        object: "Q4",
        asserted_at: ~U[2026-06-01 00:00:00Z]
      )

      assert {:ok, %{current: [current], historic: [historic]}} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5,
                 include_historic: true
               )

      assert current.object_name == "Q4"
      assert %{claim: %Claim{object_name: "Q3"}, reason: :superseded} = historic
    end

    test "the :now option gates validity windows deterministically" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      seed_claim(graph, user.id, "Aurora uses OldVendor.",
        embedding: one_hot(7),
        predicate: "relates_to",
        object: "OldVendor",
        asserted_at: ~U[2026-05-01 00:00:00Z],
        valid_to: ~U[2026-06-30 00:00:00Z]
      )

      # Before expiry: included.
      assert {:ok, [_]} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5,
                 now: ~U[2026-06-01 00:00:00Z]
               )

      # After expiry: excluded from current.
      assert {:ok, []} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5,
                 now: ~U[2026-07-01 00:00:00Z]
               )
    end

    test "a nil-embedding superseder still supersedes and appears in current" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      seed_claim(graph, user.id, "Aurora ships in Q3.",
        embedding: one_hot(7),
        predicate: "occurs_at",
        object: "Q3",
        asserted_at: ~U[2026-05-01 00:00:00Z]
      )

      # Embedding failure leaves nil; the completion read must still fetch it.
      seed_claim(graph, user.id, "Aurora now ships in Q4.",
        embedding: nil,
        predicate: "occurs_at",
        object: "Q4",
        asserted_at: ~U[2026-06-01 00:00:00Z]
      )

      assert {:ok, [claim]} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5
               )

      assert claim.object_name == "Q4"
    end

    test "group completion cannot introduce an unrelated group into the result" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      # Two candidates with heterogeneous subjects AND predicates, so the
      # cross-product fetch would pull (aurora, works_on) too.
      seed_claim(graph, user.id, "Aurora ships in Q3.",
        embedding: one_hot(7),
        predicate: "occurs_at",
        object: "Q3"
      )

      seed_claim(graph, user.id, "Bob works on the platform.",
        embedding: one_hot(8),
        subject: "Bob",
        predicate: "works_on",
        object: "platform"
      )

      # Cross-product group member: subject aurora x predicate works_on.
      # Orthogonal to the query so it can never be a KNN candidate itself.
      seed_claim(graph, user.id, "Aurora works on sneaky things.",
        embedding: one_hot(11),
        predicate: "works_on",
        object: "sneaky"
      )

      # limit: 2 is load-bearing: the KNN returns the nearest `limit` claims
      # regardless of distance, so a larger limit would make the sneaky claim
      # a candidate itself and defeat the point of the test. With limit 2 the
      # two 0.707-similarity claims strictly beat the orthogonal one.
      query = one_hot(7) |> List.replace_at(8, 1.0)

      assert {:ok, claims} =
               Retrieval.search_claims(user,
                 query_embedding: query,
                 accessible_graphs: [graph],
                 limit: 2
               )

      texts = claims |> Enum.map(& &1.claim_text) |> Enum.sort()
      assert texts == ["Aurora ships in Q3.", "Bob works on the platform."]
    end

    test "among current claims, fresher asserted_at ranks first at equal similarity" do
      user = generate(user())
      graph = "memories:user:#{user.id}"

      seed_claim(graph, user.id, "Aurora relates to VendorOld.",
        embedding: one_hot(7),
        predicate: "relates_to",
        object: "VendorOld",
        asserted_at: DateTime.add(DateTime.utc_now(), -200, :day)
      )

      seed_claim(graph, user.id, "Aurora relates to VendorNew.",
        embedding: one_hot(7),
        predicate: "relates_to",
        object: "VendorNew",
        asserted_at: DateTime.utc_now()
      )

      assert {:ok, [first, second]} =
               Retrieval.search_claims(user,
                 query_embedding: one_hot(7),
                 accessible_graphs: [graph],
                 limit: 5
               )

      assert first.object_name == "VendorNew"
      assert second.object_name == "VendorOld"
    end
  end

  defp one_hot(i), do: List.duplicate(0.0, 1536) |> List.replace_at(i, 1.0)

  # Claim.episode_id is a hard DB foreign key (belongs_to :episode,
  # allow_nil? false), so a fabricated UUID violates the constraint on insert.
  # Create a real Episode first and use its id (see plan's "Test setup
  # conventions" / Task 1 precedent in claim_test.exs).
  defp seed_episode(graph_name, user_id) do
    {:ok, ep} =
      Magus.SuperBrain.Episode
      |> Ash.Changeset.for_create(:create, %{
        resource_type: :memory,
        resource_id: Ash.UUID.generate(),
        graph_name: graph_name,
        raw_text: "seed",
        source_user_id: user_id,
        extractor_version: "test"
      })
      |> Ash.create(authorize?: false)

    ep
  end

  defp seed_claim(graph, uid, text, opts \\ []) do
    ep = seed_episode(graph, uid)
    subject = Keyword.get(opts, :subject, "Aurora")
    object = Keyword.get(opts, :object, "wrapper")

    Claim
    |> Ash.Changeset.for_create(:create, %{
      graph_name: graph,
      episode_id: ep.id,
      source_user_id: uid,
      subject_name: subject,
      subject_key: Magus.SuperBrain.Naming.key(subject),
      object_name: object,
      object_key: Magus.SuperBrain.Naming.key(object),
      predicate: Keyword.get(opts, :predicate, "relates_to"),
      polarity: Keyword.get(opts, :polarity, :affirms),
      claim_text: text,
      confidence: 0.8,
      trust_tier: :evidence,
      asserted_at: Keyword.get(opts, :asserted_at, DateTime.utc_now()),
      valid_from: Keyword.get(opts, :valid_from),
      valid_to: Keyword.get(opts, :valid_to),
      embedding: Keyword.get(opts, :embedding)
    })
    |> Ash.create(authorize?: false)
  end
end
