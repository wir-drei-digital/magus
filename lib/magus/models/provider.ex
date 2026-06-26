defmodule Magus.Models.Provider do
  @moduledoc """
  An LLM API provider configured for this instance.

  - Built-in providers reference a ReqLLM provider module by id
    (`req_llm_id`, e.g. "openrouter", "anthropic", "xai"); `slug` equals
    `req_llm_id` for those.
  - Custom OpenAI-compatible endpoints use `req_llm_id: "openai_compatible"`
    with a distinct `slug` and a required `base_url`.

  `api_key` is encrypted at rest (Cloak). When nil, ReqLLM's own env-var
  convention for the provider applies (e.g. OPENROUTER_API_KEY), which
  preserves current hosted behavior.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Models,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "model_providers"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :slug, :req_llm_id, :base_url, :api_key, :enabled?]
    end

    update :update do
      primary? true
      accept [:name, :base_url, :api_key, :enabled?]
    end

    read :enabled do
      filter expr(enabled? == true)
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug))
      get? true
    end
  end

  policies do
    # Internal catalog plumbing (CatalogSync, request-option resolution)
    # reads providers without an actor; api_key is sensitive?/non-public
    # and never serialized through public APIs.
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAdmin
    end
  end

  changes do
    change Magus.Models.Changes.SyncCatalog, on: [:create, :update, :destroy]
  end

  validations do
    validate present(:base_url),
      where: attribute_equals(:req_llm_id, "openai_compatible"),
      message: "is required for custom OpenAI-compatible providers"

    # The slug is turned into an atom (slug_to_atom in CatalogSync) and keys
    # custom LLMDB providers. Constraining it to a small lowercase character
    # set with a bounded length keeps the minted-atom space from growing
    # unbounded and is sane hygiene for the open-source/admin-form story.
    # All existing slugs (openrouter, openrouter_citations, publicai, xai,
    # fal, aimlapi) match. Only `:create` accepts `:slug` (it's immutable
    # afterward), so the validations run there and stay out of the atomic
    # update pipeline.
    validate match(:slug, ~r/\A[a-z0-9_]+\z/),
      on: [:create],
      message: "must contain only lowercase letters, digits, and underscores"

    validate string_length(:slug, max: 64),
      on: [:create],
      message: "must be at most 64 characters"
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :req_llm_id, :string, allow_nil?: false, public?: true
    attribute :base_url, :string, public?: true

    attribute :api_key, Magus.Agents.AgentSecret.EncryptedString do
      sensitive? true
    end

    attribute :enabled?, :boolean do
      default true
      allow_nil? false
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
