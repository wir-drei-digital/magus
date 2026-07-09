defmodule Magus.Usage.MessageUsage do
  @moduledoc """
  Tracks detailed token usage per message for billing and analytics.

  This resource is never deleted - when messages, conversations, or users
  are deleted, the foreign keys are set to NULL but the usage record
  persists for aggregate billing/statistics.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Usage,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "message_usages"
    repo Magus.Repo

    references do
      reference :user, on_delete: :nilify
      reference :message, on_delete: :nilify
      reference :conversation, on_delete: :nilify
      reference :model, on_delete: :nilify
    end
  end

  typescript do
    type_name "MessageUsage"
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :user_id,
        :message_id,
        :conversation_id,
        :model_id,
        :model_name,
        :usage_type,
        :prompt_tokens,
        :completion_tokens,
        :total_tokens,
        :reasoning_tokens,
        :audio_tokens,
        :accepted_prediction_tokens,
        :rejected_prediction_tokens,
        :cached_tokens,
        :cache_write_tokens,
        :prompt_audio_tokens,
        :video_tokens,
        :video_duration,
        :input_cost,
        :output_cost,
        :total_cost,
        :provider_cost,
        :finish_reason,
        :billable,
        :action_name,
        :provider_generation_id,
        :reconciliation_status
      ]
    end

    @doc """
    Records usage from an LLM response.

    Costs should be pre-calculated by the caller (e.g., UsageRecorder).

    ## Arguments

    - `:user_id` - User ID (required)
    - `:message_id` - Message ID (required)
    - `:conversation_id` - Conversation ID (required)
    - `:model_id` - Model ID (required)
    - `:model_name` - Model display name (required)
    - `:usage` - Raw usage map from LLM response (tokens extracted automatically)
    - `:usage_type` - Type of usage (:response, :search, :image_generation, :video_generation)
    - `:finish_reason` - Why generation stopped (stop, tool_calls, length, etc.)
    - `:provider_cost` - Direct cost from provider response
    - `:input_cost` - Calculated input cost
    - `:output_cost` - Calculated output cost
    - `:total_cost` - Total cost (provider_cost or input + output)
    - `:video_duration` - Video duration in seconds (for video generation)
    """
    create :record_from_response do
      accept [
        :user_id,
        :message_id,
        :conversation_id,
        :model_id,
        :model_name,
        :provider,
        :provider_generation_id,
        :reconciliation_status
      ]

      argument :usage, :map, default: %{}
      argument :usage_type, :atom, default: :response
      argument :finish_reason, :string
      argument :provider_cost, :decimal
      argument :input_cost, :decimal
      argument :output_cost, :decimal
      argument :total_cost, :decimal
      argument :video_duration, :decimal
      argument :billable, :boolean, default: true
      argument :action_name, :string

      change set_attribute(:usage_type, arg(:usage_type))
      change set_attribute(:finish_reason, arg(:finish_reason))
      change set_attribute(:provider_cost, arg(:provider_cost))
      change set_attribute(:input_cost, arg(:input_cost))
      change set_attribute(:output_cost, arg(:output_cost))
      change set_attribute(:total_cost, arg(:total_cost))
      change set_attribute(:video_duration, arg(:video_duration))
      change set_attribute(:billable, arg(:billable))
      change set_attribute(:action_name, arg(:action_name))
      change Magus.Usage.MessageUsage.Changes.ExtractTokens
    end

    # Reconciles an existing usage row with authoritative token/cost figures
    # fetched from the provider's generation endpoint (OpenRouter GET
    # /api/v1/generation). Written exclusively by the ReconcileOpenRouterUsage
    # worker via authorize?: false; the create/update policy forbids user writes.
    update :apply_reconciliation do
      # OpenRouter's generation endpoint gives an authoritative total_cost but no
      # input/output split, so those columns intentionally stay at their (zero)
      # create-time values on reconciled rows. total_cost is the source of truth.
      accept [
        :prompt_tokens,
        :completion_tokens,
        :total_tokens,
        :reasoning_tokens,
        :cached_tokens,
        :total_cost,
        :provider_cost,
        :provider
      ]

      change set_attribute(:reconciled_at, &DateTime.utc_now/0)
      change set_attribute(:reconciliation_status, :reconciled)
    end

    # Marks a row whose usage could not be reconciled (OpenRouter never returned
    # generation stats). Written by the worker via authorize?: false.
    update :mark_reconciliation_unavailable do
      accept []
      change set_attribute(:reconciliation_status, :unavailable)
    end

    action :usage_log, :map do
      description "Paged, filterable log of the caller's billable usage rows (settings Usage page)."

      argument :range, :string, default: "current_period"
      argument :model_name, :string, allow_nil?: true
      argument :workspace, :string, allow_nil?: true
      argument :page, :integer, default: 1

      run fn input, context ->
        {:ok, Magus.Chat.MessageUsageLog.rpc_payload(context.actor, input.arguments)}
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if Magus.Checks.IsAdmin
    end

    # The log payload re-reads MessageUsage with `actor:`, so the read policy
    # above scopes the rows; the action itself only needs a signed-in caller.
    policy action(:usage_log) do
      authorize_if actor_present()
    end

    # Usage rows are written exclusively by server-side recorders via
    # `authorize?: false`. Deny all user-facing writes so any accidental
    # `actor:` caller fails loud instead of silently succeeding.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    # Model & Type
    attribute :model_name, :string do
      allow_nil? false
      public? true
      source :model
      description "Model name (denormalized for display, kept for backwards compatibility)"
    end

    attribute :provider, :string do
      allow_nil? true
      public? true
      description "OpenRouter provider slug that served this request"
    end

    attribute :usage_type, :atom do
      constraints one_of: [
                    :response,
                    :tool_call,
                    :search,
                    :image_generation,
                    :video_generation,
                    :embedding,
                    :super_brain_extraction
                  ]

      default :response
      public? true
    end

    # Core Tokens (OpenRouter schema)
    attribute :prompt_tokens, :integer, default: 0, public?: true
    attribute :completion_tokens, :integer, default: 0, public?: true
    attribute :total_tokens, :integer, default: 0, public?: true

    # Completion Token Details
    attribute :reasoning_tokens, :integer, public?: true
    attribute :audio_tokens, :integer, public?: true
    attribute :accepted_prediction_tokens, :integer, public?: true
    attribute :rejected_prediction_tokens, :integer, public?: true

    # Prompt Token Details
    attribute :cached_tokens, :integer, default: 0, public?: true
    attribute :cache_write_tokens, :integer, default: 0, public?: true
    attribute :prompt_audio_tokens, :integer, public?: true
    attribute :video_tokens, :integer, public?: true

    # Video generation details (for per-second billing)
    attribute :video_duration, :decimal do
      allow_nil? true
      public? true
      description "Video duration in seconds (for per-second billing of video generation)"
    end

    # Costs (calculated at creation time)
    attribute :input_cost, :decimal, default: Decimal.new("0"), public?: true
    attribute :output_cost, :decimal, default: Decimal.new("0"), public?: true

    # Total cost - stored instead of calculated for efficiency
    attribute :total_cost, :decimal, default: Decimal.new("0"), public?: true

    # Provider cost - direct cost from provider response (e.g., OpenRouter's usage.total_cost)
    attribute :provider_cost, :decimal do
      allow_nil? true
      public? true
      description "Direct cost from provider response when available"
    end

    # Finish reason from LLM response
    attribute :finish_reason, :string do
      allow_nil? true
      public? true
      description "Why generation stopped: stop, tool_calls, length, content_filter, etc."
    end

    # Billable flag - system operations don't count against user limits
    attribute :billable, :boolean do
      default true
      public? true
      description "Whether this usage counts against user limits (false for system operations)"
    end

    # Action name - identifies what action/operation triggered this usage
    attribute :action_name, :string do
      allow_nil? true
      public? true

      description "Name of the action that triggered this usage (e.g., generate_title, extract_memories)"
    end

    # Provider's generation id (e.g. OpenRouter "gen-..."), captured so we can
    # reconcile authoritative tokens/cost from GET /api/v1/generation when the
    # streaming response omitted usage. See ReconcileOpenRouterUsage worker.
    attribute :provider_generation_id, :string do
      allow_nil? true
      public? true
      description "Provider generation id used to reconcile usage/cost after the fact"
    end

    attribute :reconciled_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When tokens/cost were reconciled against the provider's generation endpoint"
    end

    # Makes "which rows needed a usage update" directly queryable:
    #   :not_required - usage arrived with the response (the normal case)
    #   :pending      - recorded empty; reconciliation enqueued, not yet applied
    #   :reconciled   - was empty, then filled from the generation endpoint
    #   :unavailable  - was empty and OpenRouter never returned stats (gave up)
    attribute :reconciliation_status, :atom do
      constraints one_of: [:not_required, :pending, :reconciled, :unavailable]
      default :not_required
      allow_nil? false
      public? true
      description "Whether this row needed usage reconciliation and its outcome"
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? true
      public? true
    end

    belongs_to :message, Magus.Chat.Message do
      allow_nil? true
      public? true
    end

    belongs_to :conversation, Magus.Chat.Conversation do
      allow_nil? true
      public? true
    end

    belongs_to :model, Magus.Chat.Model do
      allow_nil? true
      public? true
      description "Reference to the model used for this usage (for accurate cost calculation)"
    end
  end
end
