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

  test "entity_type disambiguates between same-named entities of different types" do
    user = generate(user())
    graph = "memories:user:#{user.id}"

    # Two same-named ("Apple") subjects of DIFFERENT types in the same
    # accessible graph. entity_type should keep only the matching-type claim.
    seed_claim_attrs(graph, user.id, %{
      subject_name: "Apple",
      subject_key: "apple",
      subject_type: "organization",
      object_name: "iPhone",
      object_key: "iphone",
      predicate: "makes",
      claim_text: "Apple makes the iPhone."
    })

    seed_claim_attrs(graph, user.id, %{
      subject_name: "Apple",
      subject_key: "apple",
      subject_type: "concept",
      object_name: "fruit",
      object_key: "fruit",
      predicate: "is_a",
      claim_text: "Apple is a fruit."
    })

    assert {:ok, %{facts: facts}} =
             GetDossier.run(
               %{entity_name: "Apple", entity_type: "organization"},
               %{user_id: user.id}
             )

    texts = Enum.flat_map(facts, & &1.texts)
    assert "Apple makes the iPhone." in texts
    refute "Apple is a fruit." in texts
  end

  test "limit caps the number of returned fact groups" do
    user = generate(user())
    graph = "memories:user:#{user.id}"

    # Three fact groups for one entity: same subject, distinct object
    # endpoints (each becomes its own group in Dossier.build).
    for {obj_key, obj_name, text} <- [
          {"q1", "Q1", "Aurora targets Q1."},
          {"q2", "Q2", "Aurora targets Q2."},
          {"q3", "Q3", "Aurora targets Q3."}
        ] do
      seed_claim_attrs(graph, user.id, %{
        subject_name: "Aurora",
        subject_key: "aurora",
        object_name: obj_name,
        object_key: obj_key,
        predicate: "occurs_at",
        claim_text: text
      })
    end

    assert {:ok, %{facts: facts}} =
             GetDossier.run(%{entity_name: "Aurora", limit: 1}, %{user_id: user.id})

    assert length(facts) == 1
  end

  test "superseded and expired facts move to the history trail" do
    user = generate(user())
    graph = "memories:user:#{user.id}"

    seed_temporal_claim(graph, user.id, "Aurora ships in Q3.",
      predicate: "occurs_at",
      object: "Q3",
      asserted_at: ~U[2026-05-01 00:00:00Z]
    )

    seed_temporal_claim(graph, user.id, "Aurora now ships in Q4.",
      predicate: "occurs_at",
      object: "Q4",
      asserted_at: ~U[2026-06-01 00:00:00Z]
    )

    seed_temporal_claim(graph, user.id, "Aurora uses OldVendor.",
      predicate: "relates_to",
      object: "OldVendor",
      asserted_at: ~U[2026-05-01 00:00:00Z],
      valid_to: ~U[2026-06-01 00:00:00Z]
    )

    assert {:ok, result} = GetDossier.run(%{entity_name: "Aurora"}, %{user_id: user.id})

    fact_objects = Enum.map(result.facts, & &1.other_name)
    assert "Q4" in fact_objects
    refute "Q3" in fact_objects
    refute "OldVendor" in fact_objects

    statuses = Map.new(result.history, &{&1.object_name, &1.status})
    assert statuses["Q3"] == :superseded
    assert statuses["OldVendor"] == :expired
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
    seed_claim_attrs(graph, uid, %{claim_text: text})
  end

  # Seeds one FK-safe claim (real episode) whose subject/object/type/predicate
  # fields come from `overrides`. Defaults describe the "Aurora targets Q3"
  # claim so callers only override what a given test cares about.
  defp seed_claim_attrs(graph, uid, overrides) do
    ep = seed_episode(graph, uid)

    attrs =
      Map.merge(
        %{
          graph_name: graph,
          episode_id: ep.id,
          source_user_id: uid,
          subject_name: "Aurora",
          subject_key: "aurora",
          object_name: "Q3",
          object_key: "q3",
          predicate: "occurs_at",
          polarity: :affirms,
          claim_text: "Aurora targets Q3.",
          confidence: 0.8,
          trust_tier: :evidence,
          asserted_at: DateTime.utc_now()
        },
        overrides
      )

    {:ok, claim} =
      Claim
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create(authorize?: false)

    claim
  end

  defp seed_temporal_claim(graph, uid, text, opts) do
    ep = seed_episode(graph, uid)
    object = Keyword.fetch!(opts, :object)

    Magus.SuperBrain.Claim
    |> Ash.Changeset.for_create(:create, %{
      graph_name: graph,
      episode_id: ep.id,
      source_user_id: uid,
      subject_name: "Aurora",
      subject_key: "aurora",
      object_name: object,
      object_key: Magus.SuperBrain.Naming.key(object),
      predicate: Keyword.fetch!(opts, :predicate),
      polarity: :affirms,
      claim_text: text,
      confidence: 0.8,
      trust_tier: :evidence,
      asserted_at: Keyword.fetch!(opts, :asserted_at),
      valid_to: Keyword.get(opts, :valid_to),
      embedding: nil
    })
    |> Ash.create(authorize?: false)
  end
end
