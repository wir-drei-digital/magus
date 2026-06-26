defmodule Magus.Library.PromptTag do
  @moduledoc """
  Join resource between prompts and tags.
  """
  use Ash.Resource,
    domain: Magus.Library,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "prompt_tags"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy, :update]

    create :create do
      primary? true
      accept [:prompt_id, :tag_id]
    end
  end

  attributes do
    uuid_primary_key :id

    timestamps()
  end

  relationships do
    belongs_to :prompt, Magus.Library.Prompt do
      allow_nil? false
    end

    belongs_to :tag, Magus.Library.Tag do
      allow_nil? false
    end
  end

  identities do
    identity :unique_prompt_tag, [:prompt_id, :tag_id]
  end
end
