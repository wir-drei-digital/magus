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

  # ReqLLM provider ids a user-owned provider (:create_owned) may target.
  # Config-driven per deployment; resolved at compile time.
  @user_req_llm_allowlist Application.compile_env(
                            :magus,
                            :user_provider_req_llm_allowlist,
                            ~w(anthropic openai openrouter xai google openai_compatible)
                          )

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

    create :create_owned do
      description "User-owned provider (BYOK). Server-mints the slug; validates URL and cap."
      accept [:name, :req_llm_id, :base_url, :api_key]

      validate one_of(:req_llm_id, @user_req_llm_allowlist),
        message: "is not an allowed provider"

      validate present(:base_url),
        where: [attribute_equals(:req_llm_id, "openai_compatible")],
        message: "is required for custom OpenAI-compatible providers"

      validate Magus.Models.Validations.SafeBaseUrl
      validate Magus.Models.Validations.WithinProviderCap

      change Magus.Models.Provider.Changes.SetOwnerFromActor
      change Magus.Models.Provider.Changes.GenerateUniqueSlug
      change Magus.Models.Provider.Changes.EnqueueCredentialValidation
    end

    update :update_owned do
      description "Owner edits to a user-owned provider."
      accept [:name, :base_url, :api_key, :enabled?]
      require_atomic? false
      validate Magus.Models.Validations.SafeBaseUrl
      change Magus.Models.Provider.Changes.EnqueueCredentialValidation
    end

    read :owned do
      description "Providers owned by the actor."
      filter expr(owner_user_id == ^actor(:id))
    end
  end

  policies do
    # Internal catalog plumbing (CatalogSync, request-option resolution) reads
    # without an actor via authorize?: false and bypasses these policies.
    policy action_type(:read) do
      authorize_if expr(is_nil(owner_user_id))
      authorize_if expr(owner_user_id == ^actor(:id))
      authorize_if Magus.Checks.IsAdmin
    end

    policy action(:create_owned) do
      authorize_if actor_present()
    end

    policy action(:update_owned) do
      authorize_if expr(owner_user_id == ^actor(:id))
    end

    policy action(:create) do
      authorize_if Magus.Checks.IsAdmin
    end

    policy action([:update, :destroy]) do
      authorize_if expr(not is_nil(owner_user_id) and owner_user_id == ^actor(:id))
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

    attribute :owner_user_id, :uuid, allow_nil?: true, public?: false

    attribute :validation_status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :valid, :invalid, :error]
    end

    attribute :last_validated_at, :utc_datetime, allow_nil?: true, public?: true

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
