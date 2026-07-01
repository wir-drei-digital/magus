defmodule Magus.Chat.Model do
  @moduledoc """
  A selectable LLM model (one catalog row).

  ## Two parallel "provider" notions (both load-bearing, intentionally kept)

  There are two unrelated axes that both say "provider", plus two label
  fields. A future contributor must not collapse them:

  - **`api_provider`** (atom enum, e.g. `:openrouter`) — the legacy
    **routing/region key**. Still load-bearing: `lib/magus/providers/` keys
    request routing and region selection off it. NOT dead; do not migrate or
    remove without a routing refactor.
  - **`model_provider`** (belongs_to `Magus.Models.Provider`, the FK) — the
    **credentials + endpoint source**: which configured API endpoint/base_url
    and (encrypted) `api_key` actually serve this model. This is what
    `CatalogSync` reads to build the LLMDB custom map.

  And two display/grouping labels, also distinct:

  - **`provider`** (free-text string, e.g. "Anthropic") — a **display/grouping
    label** for the UI (the model's origin/brand). Not an endpoint.
  - **`model_provider.name`** (e.g. "OpenRouter") — the **API endpoint
    provider** that actually serves the request.

  So a Claude model can have `provider: "Anthropic"` (brand),
  `model_provider.name: "OpenRouter"` (endpoint), and
  `api_provider: :openrouter` (routing key) all at once.
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshTypescript.Resource]

  # Modality strings the catalog/admin form may set. Superset of every value
  # present in Magus.Models.Catalog ("text"/"image"/"file"/"video") and a
  # subset of LLMDB's accepted modality atoms (plus "file", which the catalog
  # uses and LLMDB passes through). Bounds the admin-form path; CatalogSync
  # still drops anything LLMDB can't resolve (see modality_atom/1).
  @valid_modalities ~w(text image file video audio document pdf code embedding)
  @modality_pattern ~r/\A(#{Enum.join(@valid_modalities, "|")})\z/

  postgres do
    table "models"
    repo Magus.Repo

    migration_defaults input_modalities: "\"nil\"", output_modalities: "\"nil\""
  end

  typescript do
    type_name "Model"

    # Elixir-style `?` attribute names are invalid TypeScript identifiers.
    field_names active?: "active",
                internal?: "internal",
                supports_search?: "supportsSearch",
                supports_reasoning?: "supportsReasoning",
                supports_tools?: "supportsTools"
  end

  actions do
    defaults [:destroy]

    create :create do
      accept [
        :name,
        :key,
        :provider,
        :api_provider,
        :allowed_providers,
        :context_window,
        :input_cost,
        :output_cost,
        :input_cost_value,
        :output_cost_value,
        :input_cost_unit,
        :output_cost_unit,
        :active?,
        :settings,
        :input_modalities,
        :output_modalities,
        :supports_search?,
        :supports_reasoning?,
        :supports_tools?,
        :short_description,
        :detailed_description,
        :short_description_translations,
        :detailed_description_translations,
        :info,
        :released_at,
        :options,
        :model_provider_id,
        :llm_metadata,
        :internal?
      ]
    end

    update :update do
      primary? true

      accept [
        :name,
        :key,
        :provider,
        :api_provider,
        :allowed_providers,
        :context_window,
        :input_cost,
        :output_cost,
        :input_cost_value,
        :output_cost_value,
        :input_cost_unit,
        :output_cost_unit,
        :active?,
        :settings,
        :input_modalities,
        :output_modalities,
        :supports_search?,
        :supports_reasoning?,
        :supports_tools?,
        :short_description,
        :detailed_description,
        :short_description_translations,
        :detailed_description_translations,
        :info,
        :released_at,
        :options,
        :model_provider_id,
        :llm_metadata,
        :internal?
      ]
    end

    read :read do
      primary? true
    end

    read :by_name do
      description "Look up a model by its `name` (e.g. ReqLLM model string)."
      argument :name, :string, allow_nil?: false
      filter expr(name == ^arg(:name))
      get? true
    end

    read :by_key_with_provider do
      description "Model by key with its provider loaded (request-option resolution)"
      argument :key, :string, allow_nil?: false
      filter expr(key == ^arg(:key) and not is_nil(model_provider_id))
      prepare build(load: [:model_provider])
      get? true
    end

    read :list_active do
      description "List all active models available for selection (global + own)"

      # Scope owned models to the actor. A static `^actor(:id)` filter would make
      # Ash require an actor (ReadActionRequiresActor), but internal/actor-less
      # callers must still see global rows. A prepare lets us branch on the
      # actor: with one, global + own; without one, global only. There is no
      # authorizer on Model in 2b-1, so this filter is the visibility boundary.
      prepare fn query, %{actor: actor} ->
        require Ash.Query

        query =
          case actor do
            %{id: actor_id} when is_binary(actor_id) ->
              Ash.Query.filter(
                query,
                active? == true and internal? == false and
                  (is_nil(owner_user_id) or owner_user_id == ^actor_id)
              )

            _ ->
              Ash.Query.filter(
                query,
                active? == true and internal? == false and is_nil(owner_user_id)
              )
          end

        Ash.Query.sort(query, name: :asc)
      end
    end

    read :list_provider_linked_active do
      description "Active models linked to a provider (catalog sync input)"
      filter expr(active? == true and not is_nil(model_provider_id))
    end

    read :list_image_generation do
      description "List models that can generate images"

      filter expr(
               active? == true and internal? == false and
                 fragment("? @> ARRAY['image']::text[]", output_modalities)
             )

      prepare build(sort: [name: :asc])
    end

    read :list_video_generation do
      description "List models that can generate videos"

      filter expr(
               active? == true and internal? == false and
                 fragment("? @> ARRAY['video']::text[]", output_modalities)
             )

      prepare build(sort: [name: :asc])
    end
  end

  changes do
    change Magus.Models.Changes.SyncCatalog, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :key, :string do
      allow_nil? false
      public? false
    end

    attribute :owner_user_id, :uuid, allow_nil?: true, public?: false

    attribute :settings, :map do
      allow_nil? false
      default %{}
      description "Model-specific settings (e.g., temperature, max tokens, etc.)"
    end

    attribute :options, :map do
      allow_nil? true
      default nil
      public? true

      description "Model-specific configurable options (e.g. allowed aspect_ratios, durations, resolutions)"
    end

    attribute :active?, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :provider, :string do
      allow_nil? true
      public? true

      description """
      Free-text display/grouping label for the model's brand/origin
      (e.g. "Anthropic"). NOT the API endpoint — that's `model_provider.name`
      (e.g. "OpenRouter"). See the moduledoc.
      """
    end

    attribute :api_provider, :atom do
      allow_nil? false
      default :openrouter
      public? false
      constraints one_of: [:openrouter, :xai, :publicai, :aimlapi, :fal, :byok]

      description """
      Legacy routing/region key (consumed by lib/magus/providers/). Still
      load-bearing; distinct from the `model_provider` relationship, which is
      the credentials + endpoint source. See the moduledoc.
      """
    end

    attribute :allowed_providers, {:array, :string} do
      allow_nil? false
      default []
      public? true
      description "OpenRouter provider slugs that can serve this model. Empty = no restriction."
    end

    attribute :context_window, :integer do
      allow_nil? true
      public? true
      description "Context window size in tokens"
    end

    attribute :input_cost, :string do
      allow_nil? true
      public? true
      description "Cost per million input tokens"
    end

    attribute :output_cost, :string do
      allow_nil? true
      public? true
      description "Cost per million output tokens (legacy string format)"
    end

    # Structured cost fields for accurate billing calculations
    attribute :input_cost_value, :decimal do
      allow_nil? true
      public? true
      description "Numeric cost value for input (e.g., 2.00 for $2/M tokens)"
    end

    attribute :output_cost_value, :decimal do
      allow_nil? true
      public? true
      description "Numeric cost value for output (e.g., 12.00 for $12/M tokens)"
    end

    attribute :input_cost_unit, :atom do
      allow_nil? false
      default :per_million_tokens
      public? true

      constraints one_of: [
                    :per_million_tokens,
                    :per_image,
                    :per_second,
                    :per_video,
                    :per_megapixel
                  ]

      description "Unit for input cost calculation"
    end

    attribute :output_cost_unit, :atom do
      allow_nil? false
      default :per_million_tokens
      public? true

      constraints one_of: [
                    :per_million_tokens,
                    :per_image,
                    :per_second,
                    :per_video,
                    :per_megapixel
                  ]

      description "Unit for output cost calculation"
    end

    attribute :input_modalities, {:array, :string} do
      allow_nil? false
      default ["text"]
      public? true
      constraints items: [match: @modality_pattern]
      description "Input types the model accepts: text, image, file"
    end

    attribute :output_modalities, {:array, :string} do
      allow_nil? false
      default ["text"]
      public? true
      constraints items: [match: @modality_pattern]
      description "Output types the model can produce: text, image"
    end

    attribute :supports_search?, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether the model supports web search"
    end

    attribute :supports_reasoning?, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether the model supports reasoning mode"
    end

    attribute :supports_tools?, :boolean do
      allow_nil? false
      default true
      public? true
      description "Whether the model supports tool/function calling"
    end

    attribute :short_description, :string do
      allow_nil? true
      public? true
      description "Brief description for model selection (1-2 sentences)"
    end

    attribute :detailed_description, :string do
      allow_nil? true
      public? true
      description "Full description for the model details view"
    end

    attribute :info, :string do
      allow_nil? true
      public? true
      description "Optional info message shown above chat input when this model is selected"
    end

    attribute :released_at, :date do
      allow_nil? true
      public? true
      description "Date when the model was released"
    end

    attribute :short_description_translations, :map do
      allow_nil? false
      default %{}
      public? true
      description "Translations: %{\"en\" => \"...\", \"de\" => \"...\"}"
    end

    attribute :detailed_description_translations, :map do
      allow_nil? false
      default %{}
      public? true
      description "Translations for detailed description"
    end

    attribute :llm_metadata, :map do
      default %{}
      allow_nil? false
      public? true

      description "LLMDB metadata overrides (output_limit, cache_read/write, context, input/output_cost, skip_tools, skip_reasoning, simple_streaming, simple_capabilities, input/output_modalities)"
    end

    attribute :internal?, :boolean do
      default false
      allow_nil? false
      public? true

      description "Utility model used by internal roles/LLMDB only; hidden from user-facing pickers"
    end

    timestamps()
  end

  relationships do
    has_many :routing_slots, Magus.Chat.RoutingSlot

    # Inverse of MessageUsage.model. Drives the admin usage aggregates above.
    # FK on message_usages.model_id is indexed (migration 20260128112957).
    has_many :message_usages, Magus.Usage.MessageUsage

    # FK on-delete is intentionally left at the implicit default (no action /
    # restrict-like): deleting a Provider that still has Models should be
    # blocked, not silently cascade or nilify the link. Not declared
    # explicitly because doing so produces no behavioral change and only
    # churns the migration.
    # The credentials + endpoint source for this model (base_url + encrypted
    # api_key). This is what CatalogSync reads. Distinct from the legacy
    # `api_provider` enum, which remains the routing/region key. See moduledoc.
    belongs_to :model_provider, Magus.Models.Provider do
      attribute_writable? true
      public? true
    end
  end

  calculations do
    # Approximate CHF cost of a reference request, surfaced in the composer
    # model pickers (workbench + SPA) so users can gauge how expensive a request
    # is. nil for image/video models.
    calculate :request_cost_cents,
              :integer,
              Magus.Chat.Model.Calculations.RequestCostCents do
      public? true
      description "Approximate CHF cents for a reference request (composer model pickers)."
    end
  end

  aggregates do
    # Admin usage stats, loaded for the whole catalog in one query (replaces a
    # per-model MessageUsage scan). Counts/sums rows by the canonical `model_id`
    # FK; `record_from_response` always sets it, so only ancient pre-FK rows
    # (matched by name in the legacy path) are excluded.
    count :usage_count, :message_usages
    sum :usage_input_cost, :message_usages, :input_cost
    sum :usage_output_cost, :message_usages, :output_cost
  end

  identities do
    # `key` is the stable model-resolution identifier (request-option
    # resolution, catalog sync model_id). Duplicates would silently break
    # resolution, so enforce uniqueness at the DB level.
    identity :unique_key, [:key]
  end
end
