defmodule Magus.Memory.MemoryAssociation do
  @moduledoc """
  Hebbian weighted edges between memories.

  Associations represent co-activation patterns between memory pairs.
  Each edge has a weight (0.0–1.0) that strengthens via reinforcement
  when both memories are accessed together, following Hebbian learning
  ("neurons that fire together wire together").

  The pair is always stored with `memory_a_id < memory_b_id` to ensure
  a single canonical row per undirected edge.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Memory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  postgres do
    table "memory_associations"
    repo Magus.Repo

    custom_statements do
      statement :enforce_ordering do
        up "ALTER TABLE memory_associations ADD CONSTRAINT memory_associations_ordered CHECK (memory_a_id < memory_b_id)"

        down "ALTER TABLE memory_associations DROP CONSTRAINT IF EXISTS memory_associations_ordered"
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:weight]
      argument :memory_a_id, :uuid, allow_nil?: false
      argument :memory_b_id, :uuid, allow_nil?: false

      validate Magus.Memory.MemoryAssociation.Validations.SameWorkspace

      change fn changeset, _context ->
        a = Ash.Changeset.get_argument(changeset, :memory_a_id)
        b = Ash.Changeset.get_argument(changeset, :memory_b_id)

        # Enforce a < b ordering
        {lo, hi} = if a < b, do: {a, b}, else: {b, a}

        changeset
        |> Ash.Changeset.force_change_attribute(:memory_a_id, lo)
        |> Ash.Changeset.force_change_attribute(:memory_b_id, hi)
        |> Ash.Changeset.force_change_attribute(:last_reinforced_at, DateTime.utc_now())
      end
    end

    update :reinforce do
      accept []
      require_atomic? false

      change fn changeset, _context ->
        current = changeset.data.weight
        new_weight = min(1.0, current + 0.1)

        changeset
        |> Ash.Changeset.force_change_attribute(:weight, new_weight)
        |> Ash.Changeset.force_change_attribute(:last_reinforced_at, DateTime.utc_now())
      end
    end

    read :for_memory do
      description "Get all associations for a memory"
      argument :memory_id, :uuid, allow_nil?: false

      filter expr(memory_a_id == ^arg(:memory_id) or memory_b_id == ^arg(:memory_id))
      prepare build(sort: [weight: :desc])
    end

    read :between do
      description "Find association between two specific memories"
      argument :memory_a_id, :uuid, allow_nil?: false
      argument :memory_b_id, :uuid, allow_nil?: false
      get? true

      prepare fn query, _context ->
        require Ash.Query

        a = Ash.Query.get_argument(query, :memory_a_id)
        b = Ash.Query.get_argument(query, :memory_b_id)
        {lo, hi} = if a < b, do: {a, b}, else: {b, a}

        Ash.Query.filter(query, memory_a_id == ^lo and memory_b_id == ^hi)
      end
    end
  end

  policies do
    bypass action_type([:read, :create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if relates_to_actor_via([:memory_a, :user])
      authorize_if relates_to_actor_via([:memory_b, :user])
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if relates_to_actor_via([:memory_a, :user])
      authorize_if relates_to_actor_via([:memory_b, :user])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :weight, :float, default: 0.1, allow_nil?: false
    attribute :last_reinforced_at, :utc_datetime_usec, allow_nil?: false

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :memory_a, Magus.Memory.Memory, allow_nil?: false
    belongs_to :memory_b, Magus.Memory.Memory, allow_nil?: false
  end

  identities do
    identity :unique_pair, [:memory_a_id, :memory_b_id]
  end
end
