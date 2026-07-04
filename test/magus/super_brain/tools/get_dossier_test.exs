defmodule Magus.SuperBrain.Tools.GetDossierTest do
  # ResourceCase (not DataCase) so `generate(user())` is available: seeding an
  # Episode below requires a real User (Episode.source_user_id is itself a hard
  # FK to users). Matches the sibling test/magus/super_brain/retrieval_claims_test.exs
  # and the Claim.episode_id hard-FK precedent from claim_test.exs.
  use Magus.ResourceCase, async: false

  import Mox

  alias Magus.SuperBrain.Claim
  alias Magus.SuperBrain.Tools.GetDossier

  setup :verify_on_exit!

  test "returns grouped facts for an entity across accessible claims" do
    user = generate(user())

    # `get_dossier` computes its accessible-graph allow-list internally via
    # `AccessibleGraphs.for_actor/2`, which always includes
    # "memories:user:<id>" for a bare user (personal_graphs/1), so seeding
    # there (rather than a brain graph) is sufficient for the claim to be
    # visible to the tool.
    seed_claim("memories:user:#{user.id}", user.id, "Aurora targets Q3.")

    assert {:ok, %{facts: facts}} =
             GetDossier.run(%{entity_name: "Aurora"}, %{user_id: user.id})

    assert Enum.any?(facts, &("Aurora targets Q3." in &1.texts))
  end

  test "falls back to the entity view when the entity has no claims" do
    user = generate(user())

    # No claims exist for this entity, so `run/2` takes the fallback path,
    # which calls `Retrieval.search/2` and therefore the configured embedder
    # (`Magus.Embeddings.EmbedderMock` in test). Expect the call so Mox
    # doesn't raise `UnexpectedCallError`.
    expect(Magus.Embeddings.EmbedderMock, :embed, fn _text, _opts ->
      {:ok,
       %{
         embedding: List.duplicate(0.0, 1536),
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

    assert {:ok, result} = GetDossier.run(%{entity_name: "Nonexistent"}, %{user_id: user.id})
    assert Map.has_key?(result, :fallback)
  end

  # Claim.episode_id is a hard DB foreign key (belongs_to :episode,
  # allow_nil? false), so a fabricated UUID violates the constraint on insert.
  # Create a real Episode first and use its id (mirrors
  # retrieval_claims_test.exs / claim_test.exs).
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

  defp seed_claim(graph, uid, text) do
    ep = seed_episode(graph, uid)

    {:ok, claim} =
      Claim
      |> Ash.Changeset.for_create(:create, %{
        graph_name: graph,
        episode_id: ep.id,
        source_user_id: uid,
        subject_name: "Aurora",
        subject_key: "aurora",
        object_name: "Q3",
        object_key: "q3",
        predicate: "occurs_at",
        polarity: :affirms,
        claim_text: text,
        confidence: 0.8,
        trust_tier: :evidence,
        asserted_at: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    claim
  end
end
