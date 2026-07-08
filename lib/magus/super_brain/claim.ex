defmodule Magus.SuperBrain.Claim do
  @moduledoc """
  A Claim is one extracted subject-predicate-object statement plus the sentence
  that supports it, its provenance (episode), polarity, confidence, trust tier,
  and optional validity window. Claims are the propositional layer over the
  entity graph: retrieval embeds and recalls `claim_text`, and the dossier tool
  aggregates them per entity.

  Authorization boundary is `Magus.SuperBrain.AccessibleGraphs`: every read path
  filters by `graph_name in <accessible graphs>`. The resource is internal; the
  extraction pipeline and retrieval call it with `authorize?: false`.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.SuperBrain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  @max_claim_text 500

  postgres do
    table "super_brain_claims"
    repo Magus.Repo

    references do
      # Episodes are append-only and never deleted in normal operation, so no
      # cascade is load-bearing. Declare :delete for defense in depth: a claim
      # without its provenance episode is meaningless, so it goes with it.
      reference :episode, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :graph_name,
        :episode_id,
        :source_user_id,
        :subject_name,
        :subject_type,
        :subject_key,
        :object_name,
        :object_type,
        :object_key,
        :predicate,
        :polarity,
        :claim_text,
        :confidence,
        :trust_tier,
        :asserted_at,
        :valid_from,
        :valid_to,
        :embedding
      ]
    end

    create :bulk_create do
      accept [
        :graph_name,
        :episode_id,
        :source_user_id,
        :subject_name,
        :subject_type,
        :subject_key,
        :object_name,
        :object_type,
        :object_key,
        :predicate,
        :polarity,
        :claim_text,
        :confidence,
        :trust_tier,
        :asserted_at,
        :valid_from,
        :valid_to,
        :embedding
      ]
    end

    read :for_graphs do
      argument :graph_names, {:array, :string}, allow_nil?: false
      filter expr(graph_name in ^arg(:graph_names))
    end

    read :for_entity_keys do
      argument :keys, {:array, :string}, allow_nil?: false
      argument :graph_names, {:array, :string}, allow_nil?: false

      filter expr(
               graph_name in ^arg(:graph_names) and
                 (subject_key in ^arg(:keys) or object_key in ^arg(:keys))
             )
    end
  end

  policies do
    bypass action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if expr(source_user_id == ^actor(:id))
    end

    # Claims are written only by the extraction pipeline (authorize?: false).
    # Deny user-facing writes so a stray actor: caller fails loud.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :graph_name, :string, allow_nil?: false, public?: true
    attribute :episode_id, :uuid, allow_nil?: false, public?: true
    attribute :source_user_id, :uuid, allow_nil?: false, public?: true

    attribute :subject_name, :string, allow_nil?: false, public?: true
    attribute :subject_type, :string, allow_nil?: true, public?: true
    attribute :subject_key, :string, allow_nil?: false, public?: true

    attribute :object_name, :string, allow_nil?: false, public?: true
    attribute :object_type, :string, allow_nil?: true, public?: true
    attribute :object_key, :string, allow_nil?: false, public?: true

    attribute :predicate, :string, allow_nil?: false, public?: true

    attribute :polarity, :atom do
      allow_nil? false
      default :affirms
      public? true
      constraints one_of: [:affirms, :negates]
    end

    attribute :claim_text, :string do
      allow_nil? false
      public? true
      constraints max_length: @max_claim_text
    end

    attribute :confidence, :float, allow_nil?: true, public?: true

    attribute :trust_tier, :atom do
      allow_nil? false
      default :evidence
      public? true
      constraints one_of: [:instruction, :evidence, :noise]
    end

    attribute :asserted_at, :utc_datetime, allow_nil?: true, public?: true
    attribute :valid_from, :utc_datetime, allow_nil?: true, public?: true
    attribute :valid_to, :utc_datetime, allow_nil?: true, public?: true

    attribute :embedding, Magus.Files.Types.Vector, allow_nil?: true, public?: true

    timestamps()
  end

  relationships do
    belongs_to :episode, Magus.SuperBrain.Episode do
      source_attribute :episode_id
      define_attribute? false
      attribute_writable? false
    end
  end

  @doc """
  Top-`limit` claims by cosine similarity to `embedding`, restricted to
  `graph_names` and string `tiers`. Returns `{id, similarity}` pairs in
  descending-similarity order; similarity is `1 - cosine_distance`, clamped
  to [0.0, 1.0]. Nil-embedding claims cannot be KNN candidates and are
  excluded here; `group_hits_by_embedding/5` includes them so a
  not-yet-embedded superseder still participates in temporal resolution.
  """
  @spec top_hits_by_embedding([float()], [String.t()], [String.t()], integer()) ::
          [{binary(), float()}]
  def top_hits_by_embedding([], _graph_names, _tiers, _limit), do: []
  def top_hits_by_embedding(_embedding, [], _tiers, _limit), do: []
  def top_hits_by_embedding(_embedding, _graph_names, [], _limit), do: []

  def top_hits_by_embedding(embedding, graph_names, tiers, limit) do
    import Ecto.Query

    vector = Pgvector.new(embedding)

    from(c in "super_brain_claims",
      where: not is_nil(c.embedding),
      where: c.graph_name in ^graph_names,
      where: c.trust_tier in ^tiers,
      select: {c.id, fragment("1 - (? <=> ?)", c.embedding, ^vector)},
      order_by: [asc: fragment("? <=> ?", c.embedding, ^vector)],
      limit: ^limit
    )
    |> Magus.Repo.all()
    |> Enum.map(fn {id, similarity} ->
      {Ecto.UUID.load!(id), clamp_similarity(similarity)}
    end)
  end

  @doc """
  All claims in the `(subject_keys x predicates)` cross product, restricted
  to `graph_names` and string `tiers`: the group-completion read that
  surfaces superseders the KNN missed. Returns `{id, similarity}` pairs
  (unordered); nil-embedding claims are INCLUDED with similarity 0.0.
  Narrowed by the indexed graph_name and subject_key columns; predicate is
  filtered in-row.
  """
  @spec group_hits_by_embedding(
          [String.t()],
          [String.t()],
          [String.t()],
          [String.t()],
          [float()]
        ) :: [{binary(), float()}]
  def group_hits_by_embedding([], _keys, _preds, _tiers, _embedding), do: []
  def group_hits_by_embedding(_graphs, [], _preds, _tiers, _embedding), do: []
  def group_hits_by_embedding(_graphs, _keys, [], _tiers, _embedding), do: []
  def group_hits_by_embedding(_graphs, _keys, _preds, [], _embedding), do: []

  def group_hits_by_embedding(graph_names, subject_keys, predicates, tiers, embedding) do
    import Ecto.Query

    vector = Pgvector.new(embedding)

    from(c in "super_brain_claims",
      where: c.graph_name in ^graph_names,
      where: c.trust_tier in ^tiers,
      where: c.subject_key in ^subject_keys,
      where: c.predicate in ^predicates,
      select:
        {c.id,
         fragment(
           "CASE WHEN ? IS NULL THEN NULL ELSE 1 - (? <=> ?) END",
           c.embedding,
           c.embedding,
           ^vector
         )}
    )
    |> Magus.Repo.all()
    |> Enum.map(fn {id, similarity} ->
      {Ecto.UUID.load!(id), clamp_similarity(similarity)}
    end)
  end

  defp clamp_similarity(nil), do: 0.0
  defp clamp_similarity(s), do: s |> max(0.0) |> min(1.0)
end
