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

    seed_claim(graph, user.id, "Aurora ships without the npm wrapper.", one_hot(0))
    seed_claim(other_graph, other_user.id, "Someone else fact.", one_hot(0))

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

  defp seed_claim(graph, uid, text, embedding) do
    ep = seed_episode(graph, uid)

    Claim
    |> Ash.Changeset.for_create(:create, %{
      graph_name: graph,
      episode_id: ep.id,
      source_user_id: uid,
      subject_name: "Aurora",
      subject_key: "aurora",
      object_name: "wrapper",
      object_key: "wrapper",
      predicate: "relates_to",
      polarity: :affirms,
      claim_text: text,
      confidence: 0.8,
      trust_tier: :evidence,
      asserted_at: DateTime.utc_now(),
      embedding: embedding
    })
    |> Ash.create(authorize?: false)
  end
end
