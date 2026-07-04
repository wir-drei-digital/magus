defmodule Magus.SuperBrain.ClaimTest do
  # ResourceCase (not DataCase) so `generate(user())` is available: seeding an
  # Episode below requires a real User (Episode.source_user_id is itself a hard
  # FK to users), which is how every sibling super_brain test seeds one.
  use Magus.ResourceCase, async: false

  alias Magus.SuperBrain.Claim

  # Claim.episode_id is a hard DB foreign key (belongs_to :episode,
  # allow_nil? false), so a fabricated UUID violates the constraint on insert.
  # Create a real Episode first and use its id. The claim's graph_name /
  # source_user_id match the episode's so the row reads coherently.
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

  # Builds claim attrs whose graph_name / source_user_id / episode_id all refer
  # to a freshly-seeded episode (owned by a real user), so the FK is satisfied.
  # Extra overrides win.
  defp valid_attrs(overrides \\ %{}) do
    graph = Map.get(overrides, :graph_name, "brain:#{Ash.UUID.generate()}")
    uid = Map.get(overrides, :source_user_id, generate(user()).id)
    ep = seed_episode(graph, uid)

    Map.merge(
      %{
        graph_name: graph,
        episode_id: ep.id,
        source_user_id: uid,
        subject_name: "Project Aurora",
        subject_type: "project",
        subject_key: "project aurora",
        object_name: "Q3",
        object_type: "date",
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
  end

  test "creates a claim with all fields" do
    assert {:ok, claim} =
             Claim
             |> Ash.Changeset.for_create(:create, valid_attrs())
             |> Ash.create(authorize?: false)

    assert claim.polarity == :affirms
    assert claim.claim_text == "Aurora targets Q3."
  end

  test "claim_text longer than 500 chars is rejected" do
    attrs = valid_attrs(%{claim_text: String.duplicate("x", 501)})

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Claim
             |> Ash.Changeset.for_create(:create, attrs)
             |> Ash.create(authorize?: false)

    # The failure is the length validation (the point of this test), not the
    # episode FK: a real episode is seeded, so the row reaches the constraint.
    assert Enum.any?(errors, &match?(%{field: :claim_text}, &1))
  end

  test "for_graphs returns only claims whose graph_name is in the allow-list" do
    g1 = "brain:#{Ash.UUID.generate()}"
    g2 = "brain:#{Ash.UUID.generate()}"

    {:ok, _} =
      Claim
      |> Ash.Changeset.for_create(:create, valid_attrs(%{graph_name: g1}))
      |> Ash.create(authorize?: false)

    {:ok, _} =
      Claim
      |> Ash.Changeset.for_create(:create, valid_attrs(%{graph_name: g2}))
      |> Ash.create(authorize?: false)

    {:ok, rows} =
      Claim
      |> Ash.Query.for_read(:for_graphs, %{graph_names: [g1]})
      |> Ash.read(authorize?: false)

    assert Enum.all?(rows, &(&1.graph_name == g1))
    assert length(rows) >= 1
  end
end
