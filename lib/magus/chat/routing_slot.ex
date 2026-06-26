defmodule Magus.Chat.RoutingSlot do
  @moduledoc """
  Join resource mapping a model to a routing slot (specialty + tier).

  Each `{specialty, tier}` combination is unique — only one model can fill each slot.
  A model can appear in multiple slots (M2M relationship).
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "routing_slots"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:model_id, :specialty, :tier]
    end

    update :update do
      primary? true
      accept [:model_id]
    end

    read :list_all do
      description "List all routing slots with their models"
      prepare build(sort: [specialty: :asc, tier: :asc], load: [:model])
    end

    create :upsert_slot do
      accept [:model_id, :specialty, :tier]
      upsert? true
      upsert_identity :unique_slot
      upsert_fields [:model_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :specialty, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :general,
                    :coding,
                    :search,
                    :reasoning,
                    :creative,
                    :image,
                    :text_to_video,
                    :image_to_video
                  ]

      description "What this slot routes: general, coding, search, reasoning, creative, image, text_to_video, image_to_video"
    end

    attribute :tier, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:simple, :standard, :complex]
      description "Cost/capability tier: simple, standard, complex"
    end

    timestamps()
  end

  relationships do
    belongs_to :model, Magus.Chat.Model do
      allow_nil? false
    end
  end

  identities do
    identity :unique_slot, [:specialty, :tier]
  end
end
