defmodule Magus.SuperBrain.SuperGraph do
  @moduledoc """
  Per-accessor build metadata for Layer 2 super graphs.

  One row per `(accessor_type, user_id, workspace_id)` tuple records the
  state of that accessor's super graph: when it was last built, what the
  read-set was at build time, current entity/edge counts, and the most
  recent build status. The actual canonical-entity nodes live in FalkorDB
  at `graph_name`.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.SuperBrain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "super_brain_super_graphs"
    repo Magus.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:accessor_type, :user_id, :workspace_id, :graph_name, :last_build_status]
    end

    update :mark_building do
      accept []
      require_atomic? false
      change set_attribute(:last_build_status, :building)
    end

    update :mark_built do
      accept [
        :read_set_snapshot,
        :canonical_entity_count,
        :canonical_edge_count,
        :last_build_duration_ms,
        :metrics
      ]

      require_atomic? false
      change set_attribute(:last_build_status, :ok)
      change set_attribute(:last_built_at, &DateTime.utc_now/0)
      change set_attribute(:last_error, nil)
    end

    update :mark_failed do
      accept [:last_error]
      require_atomic? false
      change set_attribute(:last_build_status, :failed)
    end

    update :update_read_set do
      accept [:read_set_snapshot]
      require_atomic? false
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :accessor_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:user, :workspace]
    end

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :workspace_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :graph_name, :string do
      allow_nil? false
      public? true
    end

    attribute :last_built_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_build_status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :building, :ok, :failed]
    end

    attribute :last_build_duration_ms, :integer do
      allow_nil? true
      public? true
    end

    attribute :last_error, :string do
      allow_nil? true
      public? true
    end

    attribute :read_set_snapshot, {:array, :map} do
      default []
      public? true
    end

    attribute :canonical_entity_count, :integer do
      default 0
      allow_nil? false
      public? true
    end

    attribute :canonical_edge_count, :integer do
      default 0
      allow_nil? false
      public? true
    end

    attribute :metrics, :map do
      default %{}
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_accessor, [:accessor_type, :user_id, :workspace_id],
      pre_check_with: Magus.SuperBrain,
      nils_distinct?: false
  end
end
