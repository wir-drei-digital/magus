defmodule Magus.Library.Tag do
  @moduledoc """
  Tag resource for categorizing prompts in the public library.
  """
  use Ash.Resource,
    domain: Magus.Library,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshTypescript.Resource]

  postgres do
    table "tags"
    repo Magus.Repo
  end

  typescript do
    type_name "Tag"
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    create :create do
      accept [:name]
    end

    create :get_or_create do
      accept [:name]
      upsert? true
      upsert_identity :unique_name
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :ci_string do
      allow_nil? false
      description "The tag name (case-insensitive)"
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :prompt_tags, Magus.Library.PromptTag

    many_to_many :prompts, Magus.Library.Prompt do
      through Magus.Library.PromptTag
      source_attribute_on_join_resource :tag_id
      destination_attribute_on_join_resource :prompt_id
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
