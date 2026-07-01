defmodule Magus.Agents.Persistence.UsageRecorder do
  @moduledoc """
  Records message usage for billing and analytics.

  This module provides a unified interface for recording usage across different
  strategies and generation types (chat, image, video, etc.).

  It handles cost calculation based on:
  1. Provider cost from response (e.g., OpenRouter's usage.total_cost) - preferred
  2. Model's structured cost fields (input_cost_value, output_cost_value with units)

  ## Usage

      alias Magus.Agents.Persistence.UsageRecorder

      # Record usage after a chat response
      UsageRecorder.record(
        user_id: user_id,
        message_id: message_id,
        conversation_id: conversation_id,
        model: model_record,
        usage: usage_map,
        finish_reason: :stop,
        usage_type: :response
      )

      # Record usage for image generation
      UsageRecorder.record(
        user_id: user_id,
        message_id: message_id,
        conversation_id: conversation_id,
        model: model_record,
        usage: %{},
        usage_type: :image_generation
      )
  """

  require Logger

  @type usage_type ::
          :response | :tool_call | :search | :image_generation | :video_generation | :embedding

  @type record_opts :: [
          user_id: String.t(),
          message_id: String.t() | nil,
          conversation_id: String.t() | nil,
          model: map() | nil,
          usage: map() | nil,
          finish_reason: atom() | String.t() | nil,
          usage_type: usage_type(),
          billable: boolean(),
          action_name: String.t() | nil
        ]

  @doc """
  Records usage for a message.

  ## Options

    * `:user_id` - User ID (required)
    * `:message_id` - Message ID (optional, nil for system operations)
    * `:conversation_id` - Conversation ID (optional, nil for system operations)
    * `:model` - Model record with id and name fields (required for accurate recording)
    * `:usage` - Raw usage map from provider response
    * `:finish_reason` - Why generation stopped (atom or string)
    * `:usage_type` - Type of usage (default: :response)
    * `:billable` - Whether this counts against user limits (default: true)
    * `:action_name` - Name of the action that triggered this usage (optional)

  ## Returns

    * `{:ok, usage_record}` on success
    * `{:ok, :skipped}` if model is not available
    * `{:error, reason}` on failure
  """
  @spec record(record_opts()) :: {:ok, map()} | {:ok, :skipped} | {:error, term()}
  def record(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    message_id = Keyword.get(opts, :message_id)
    conversation_id = Keyword.get(opts, :conversation_id)
    model = Keyword.get(opts, :model)
    model_key = Keyword.get(opts, :model_key)
    usage = Keyword.get(opts, :usage, %{})
    finish_reason = Keyword.get(opts, :finish_reason)
    usage_type = Keyword.get(opts, :usage_type, :response)
    billable = Keyword.get(opts, :billable, true)
    action_name = Keyword.get(opts, :action_name)
    provider = Keyword.get(opts, :provider)
    provider_generation_id = Keyword.get(opts, :provider_generation_id)

    needs_reconciliation =
      reconciliation_needed?(billable, usage_type, provider_generation_id, usage)

    # Get model info - either from model struct or by looking up model_key
    {model_id, model_name, model_for_cost} = resolve_model(model, model_key)

    # Need at least a model_name to record
    if model_name do
      provider_cost = extract_provider_cost(usage)

      # Calculate costs (only if we have a model record)
      {input_cost, output_cost, total_cost, video_duration} =
        if model_for_cost do
          calculate_costs(usage, model_for_cost, usage_type, provider_cost)
        else
          # No model for cost calculation - just use provider cost or zero
          {Decimal.new("0"), Decimal.new("0"), provider_cost || Decimal.new("0"), nil}
        end

      result =
        Magus.Usage.record_message_usage(
          %{
            user_id: user_id,
            message_id: message_id,
            conversation_id: conversation_id,
            model_id: model_id,
            model_name: model_name,
            usage: usage || %{},
            usage_type: usage_type,
            finish_reason: normalize_finish_reason(finish_reason),
            provider_cost: provider_cost,
            input_cost: input_cost,
            output_cost: output_cost,
            total_cost: total_cost,
            video_duration: video_duration,
            billable: billable,
            action_name: action_name,
            provider: provider,
            provider_generation_id: provider_generation_id,
            reconciliation_status: if(needs_reconciliation, do: :pending, else: :not_required)
          },
          authorize?: false
        )

      # Best-effort prompt-cache-hit readout (log + telemetry). Skips cleanly
      # when there are no prompt tokens (image/video generation). Never disrupts
      # usage recording: `emit/2` rescues internally and always returns :ok.
      Magus.Agents.Persistence.CacheTelemetry.emit(usage || %{},
        conversation_id: conversation_id,
        model: model_name
      )

      # Accrue the billable cost (1:1, no markup) to the postpaid period
      # accumulator and report the full charge to the metering sink. Best-effort:
      # a failure must never break usage recording or the chat flow. The
      # MessageUsage row id is a stable, unique-per-response identifier, so a
      # meter-report retry dedupes on it.
      if billable do
        record_billable_cost(user_id, total_cost, meter_identifier: usage_record_id(result))
      end

      # When OpenRouter omitted streaming usage we recorded a zero-token row; if
      # we captured a generation id, reconcile the real tokens/cost out of band.
      if needs_reconciliation, do: enqueue_reconciliation(result)

      result
    else
      Logger.debug("Skipping usage recording: no model info available")
      {:ok, :skipped}
    end
  rescue
    e ->
      Logger.warning("Failed to record usage: #{Exception.message(e)}")
      {:error, e}
  end

  # Resolve model info from either a model struct or a model_key
  defp resolve_model(model, _model_key) when not is_nil(model) and is_map(model) do
    {Map.get(model, :id), Map.get(model, :name), model}
  end

  defp resolve_model(nil, model_key) when is_binary(model_key) do
    require Ash.Query

    case Magus.Chat.Model
         |> Ash.Query.filter(key == ^model_key)
         |> Ash.read_one(authorize?: false) do
      {:ok, model} when not is_nil(model) ->
        {model.id, model.name, model}

      _ ->
        # Model not in database - use model_key as name, no id
        {nil, model_key, nil}
    end
  end

  defp resolve_model(nil, nil), do: {nil, nil, nil}

  @doc """
  Records usage, logging but not raising on errors.

  Same as `record/1` but returns `:ok` on success and logs errors without raising.
  Useful when you don't want usage recording failures to affect the main flow.
  """
  @spec record!(record_opts()) :: :ok
  def record!(opts) do
    case record(opts) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  @doc """
  Maps a chat mode to the appropriate usage type.

  ## Examples

      iex> UsageRecorder.usage_type_for_mode(:chat)
      :response

      iex> UsageRecorder.usage_type_for_mode(:image_generation)
      :image_generation
  """
  @spec usage_type_for_mode(atom()) :: usage_type()
  def usage_type_for_mode(:chat), do: :response
  def usage_type_for_mode(:search), do: :search
  def usage_type_for_mode(:reasoning), do: :response
  def usage_type_for_mode(:image_generation), do: :image_generation
  def usage_type_for_mode(:video_generation), do: :video_generation
  def usage_type_for_mode(_), do: :response

  @doc """
  Extracts provider cost from a usage map.

  Handles various formats that providers return:
  - `usage["total_cost"]` - string key
  - `usage[:total_cost]` - atom key
  - Numeric values (float, integer)
  - String values that can be parsed as decimals
  - Decimal values

  ## Examples

      iex> UsageRecorder.extract_provider_cost(%{"total_cost" => 0.002317})
      #Decimal<0.002317>

      iex> UsageRecorder.extract_provider_cost(%{})
      nil
  """
  @spec extract_provider_cost(map() | nil) :: Decimal.t() | nil
  def extract_provider_cost(nil), do: nil

  def extract_provider_cost(usage) when is_map(usage) do
    # Prefer the reconciliation-shape `total_cost` (from the /generation stats
    # endpoint); fall back to OpenRouter's inline usage `cost` field (returned
    # for chat/completions when usage.include is set, and for video polls).
    cost = usage["total_cost"] || usage[:total_cost] || usage["cost"] || usage[:cost]

    cond do
      is_nil(cost) -> nil
      is_float(cost) -> Decimal.from_float(cost)
      is_integer(cost) -> Decimal.new(cost)
      is_binary(cost) -> parse_decimal_string(cost)
      is_struct(cost, Decimal) -> cost
      true -> nil
    end
  end

  def extract_provider_cost(_), do: nil

  # Cost Calculation

  defp calculate_costs(usage, model, usage_type, provider_cost) do
    {input_cost, output_cost, video_duration} =
      calculate_costs_by_type(usage, model, usage_type)

    # Use provider cost as total if available, otherwise sum input + output
    total_cost =
      if provider_cost do
        provider_cost
      else
        Decimal.add(input_cost, output_cost)
      end

    {input_cost, output_cost, total_cost, video_duration}
  end

  defp calculate_costs_by_type(usage, model, :video_generation) do
    calculate_video_costs(usage, model)
  end

  defp calculate_costs_by_type(usage, model, :image_generation) do
    case model && model.output_cost_unit do
      :per_million_tokens ->
        # Some image models (e.g. Gemini 3.1 Flash Image) bill per token. Fall
        # back to token-based pricing using the usage map from the provider.
        input_tokens = usage["prompt_tokens"] || usage["input_tokens"] || 0
        output_tokens = usage["completion_tokens"] || usage["output_tokens"] || 0
        {input_cost, output_cost} = calculate_token_costs(input_tokens, output_tokens, model)
        {input_cost, output_cost, nil}

      _ ->
        output_cost = get_cost_for_unit(model, :output, :per_image)
        {Decimal.new("0"), output_cost, nil}
    end
  end

  defp calculate_costs_by_type(usage, model, _usage_type) do
    # Standard token-based pricing
    input_tokens = usage["prompt_tokens"] || usage["input_tokens"] || 0
    output_tokens = usage["completion_tokens"] || usage["output_tokens"] || 0

    {input_cost, output_cost} = calculate_token_costs(input_tokens, output_tokens, model)
    {input_cost, output_cost, nil}
  end

  defp calculate_token_costs(input_tokens, output_tokens, model) do
    input_cost_per_million = get_cost_per_million(model, :input)
    output_cost_per_million = get_cost_per_million(model, :output)

    input_cost =
      Decimal.mult(
        Decimal.div(Decimal.new(input_tokens || 0), Decimal.new(1_000_000)),
        input_cost_per_million
      )

    output_cost =
      Decimal.mult(
        Decimal.div(Decimal.new(output_tokens || 0), Decimal.new(1_000_000)),
        output_cost_per_million
      )

    {input_cost, output_cost}
  end

  defp get_cost_per_million(nil, _type), do: Decimal.new("0")

  defp get_cost_per_million(model, :input) do
    if model.input_cost_value && model.input_cost_unit == :per_million_tokens do
      model.input_cost_value
    else
      Decimal.new("0")
    end
  end

  defp get_cost_per_million(model, :output) do
    if model.output_cost_value && model.output_cost_unit == :per_million_tokens do
      model.output_cost_value
    else
      Decimal.new("0")
    end
  end

  defp get_cost_for_unit(nil, _type, _unit), do: Decimal.new("0")

  defp get_cost_for_unit(model, :output, expected_unit) do
    if model.output_cost_value && model.output_cost_unit == expected_unit do
      model.output_cost_value
    else
      Decimal.new("0")
    end
  end

  defp calculate_video_costs(usage, model) do
    video_duration = get_video_duration(usage)

    {input_cost, output_cost} =
      if model && model.output_cost_value do
        case model.output_cost_unit do
          :per_second ->
            duration = video_duration || Decimal.new("5")

            if is_nil(video_duration) do
              Logger.warning(
                "Video generation recorded without duration, using default 5s for cost calculation"
              )
            end

            total_cost = Decimal.mult(model.output_cost_value, duration)
            {Decimal.new("0"), total_cost}

          :per_video ->
            {Decimal.new("0"), model.output_cost_value}

          _ ->
            {Decimal.new("0"), Decimal.new("0")}
        end
      else
        {Decimal.new("0"), Decimal.new("0")}
      end

    {input_cost, output_cost, video_duration}
  end

  defp get_video_duration(usage) when is_map(usage) do
    cond do
      duration = usage["duration"] -> parse_decimal(duration)
      duration = usage["video_duration"] -> parse_decimal(duration)
      duration = usage[:duration] -> parse_decimal(duration)
      true -> nil
    end
  end

  defp get_video_duration(_), do: nil

  # Usage accrual (pay-as-you-go)

  # Convert a USD cost (Decimal in major units) to integer CHF cents via the
  # cached Stripe FX rate (1:1 fallback until a rate is fetched), accrue it to
  # the postpaid period accumulator, and report the full charge to the metering
  # sink. No markup: the user is charged the raw provider cost.
  #
  # Best-effort: never raises — a failure must not break the chat flow.
  # Returns `:ok` or `{:error, reason}` so callers that care (the reconciliation
  # worker) can surface a lost charge; the chat flow ignores the result.
  #
  # `opts[:meter_identifier]` — a stable, unique-per-charge string used to
  # dedupe meter-event retries on both the Oban unique constraint and Stripe.
  @doc false
  # Public so ReconcileOpenRouterUsage can charge the reconciled cost later.
  @spec record_billable_cost(String.t() | nil, Decimal.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def record_billable_cost(user_id, cost, opts \\ [])

  def record_billable_cost(_user_id, nil, _opts), do: :ok

  def record_billable_cost(user_id, %Decimal{} = cost, opts) when is_binary(user_id) do
    amount_cents =
      cost
      # USD→internal-cost-unit via the ExchangeRate seam: core defaults to 1:1,
      # the billing edition supplies the live USD→CHF rate.
      |> Decimal.mult(Magus.Usage.ExchangeRate.usd_to_chf())
      |> Decimal.mult(100)
      |> Decimal.round(0)
      |> Decimal.to_integer()

    if amount_cents > 0 do
      case Magus.Usage.deduct_usage(user_id, amount_cents, authorize?: false) do
        {:ok, sub} ->
          report_charge(sub, amount_cents, opts[:meter_identifier])
          notify_usage_changed(user_id)
          :ok

        {:error, reason} ->
          Logger.debug("Usage accrual skipped for #{user_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("Usage accrual failed: #{Exception.message(e)}")
      {:error, e}
  end

  def record_billable_cost(_user_id, _cost, _opts), do: :ok

  # Hand the full charge to the metering sink seam. The configured Billing impl
  # applies the "both Stripe ids present, overflow > 0, identifier non-empty"
  # guard, so a non-billable or zero-cost charge meters nothing. The core default
  # is a no-op for an unconfigured OSS instance.
  defp report_charge(sub, amount_cents, identifier) do
    {customer_id, subscription_id} = billing_target(sub)

    Magus.Usage.MeteringSink.report_charge(%Magus.Usage.MeteringSink.Charge{
      user_id: sub.user_id,
      overflow_cents: amount_cents,
      identifier: identifier || "",
      stripe_customer_id: customer_id,
      stripe_subscription_id: subscription_id
    })
  end

  # When the account is org-sponsored, usage bills to the org's Stripe customer +
  # subscription (pooled billing), not the member's own. Reading the org's opaque
  # Stripe ids is pure core data access; in OSS they are nil and metering no-ops.
  defp billing_target(%{sponsor_org_id: org_id}) when is_binary(org_id) do
    case Magus.Organizations.get_organization(org_id, authorize?: false) do
      {:ok, org} -> {org.stripe_customer_id, org.stripe_subscription_id}
      _ -> {nil, nil}
    end
  end

  defp billing_target(sub) do
    {sub.stripe_customer_id, sub.stripe_subscription_id}
  end

  # Tell the workbench shell to refresh its pay-as-you-go usage indicator now
  # that the period accumulator has moved. Best-effort: the shell may
  # not be mounted (background worker, tests) and a broadcast failure must never
  # affect billing — so a raise here is swallowed and the deduction still
  # reports :ok. Named here so the core recorder states the intent; the topic
  # and message shape live in `MagusWeb.Workbench.Signals`.
  defp notify_usage_changed(user_id) when is_binary(user_id) do
    MagusWeb.Workbench.Signals.broadcast_usage_changed(user_id)
    :ok
  rescue
    _ -> :ok
  end

  defp notify_usage_changed(_), do: :ok

  # Reconcile out of band only when OpenRouter returned no usage for a billable
  # chat response but we captured a generation id to query after the fact. The
  # zero-token row exists for correlation; the worker fills in real tokens/cost.
  defp reconciliation_needed?(true, :response, generation_id, usage)
       when is_binary(generation_id) and generation_id != "",
       do: usage_tokens_empty?(usage)

  defp reconciliation_needed?(_billable, _usage_type, _generation_id, _usage), do: false

  defp enqueue_reconciliation({:ok, %{id: usage_id}}) when is_binary(usage_id) do
    case Magus.Chat.Workers.ReconcileOpenRouterUsage.enqueue(usage_id) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Usage reconciliation enqueue failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("Usage reconciliation enqueue crashed: #{Exception.message(e)}")
      :ok
  end

  defp enqueue_reconciliation(_result), do: :ok

  # The MessageUsage row id for this response — a stable, unique-per-response
  # meter-event identifier. nil when recording was skipped (e.g. no model row).
  # report_charge/3 still forwards the charge to the metering sink; it is
  # the sink that declines to meter (empty identifier / no Stripe ids / zero
  # overflow).
  defp usage_record_id({:ok, %{id: id}}) when is_binary(id), do: id
  defp usage_record_id(_result), do: nil

  defp usage_tokens_empty?(usage) when is_map(usage) do
    prompt = usage["prompt_tokens"] || usage[:prompt_tokens] || 0
    completion = usage["completion_tokens"] || usage[:completion_tokens] || 0
    (prompt || 0) == 0 and (completion || 0) == 0
  end

  defp usage_tokens_empty?(_usage), do: true

  # Private helpers

  defp normalize_finish_reason(nil), do: nil
  defp normalize_finish_reason(reason) when is_atom(reason), do: to_string(reason)
  defp normalize_finish_reason(reason) when is_binary(reason), do: reason
  defp normalize_finish_reason(_), do: nil

  defp parse_decimal_string(str) do
    case Decimal.parse(str) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(%Decimal{} = d), do: d
  defp parse_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp parse_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp parse_decimal(_), do: nil
end
