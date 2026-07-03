defmodule Magus.Usage.PolicyEnforcer do
  @moduledoc """
  Enforces usage limits by checking current usage against plan limits.

  All check functions return:
  - `{:ok, :allowed}` - Action is permitted
  - `{:error, %Magus.Usage.PolicyError{}}` - Action blocked due to limit

  The error carries only structured data; user-facing copy lives in the core
  renderer (`Magus.Usage.PolicyErrorMessage`).

  Exempt users (via Override) bypass all checks.
  """

  alias Magus.Usage.Calculator
  alias Magus.Usage.PolicyError

  @doc """
  Returns the user's personal subscription. Sponsored subscriptions are picked
  up by `Calculator.get_effective_limits/1` independently.
  """
  def get_subscription_for_context(user_id) do
    Magus.Usage.get_user_subscription(user_id, authorize?: false)
  end

  @doc """
  Checks if a user's plan allows the given generation mode.

  Only `:image_generation` and `:video_generation` are gated — all other modes
  (`:chat`, `:search`, `:reasoning`) are always allowed.

  ## Returns

  - `{:ok, :allowed}` - Mode is permitted
  - `{:error, %PolicyError{}}` - Mode not available on current plan
  """
  def check_mode_access(user, mode) when mode in [:image_generation, :video_generation] do
    limits = Calculator.get_effective_limits(user.id)

    cond do
      limits[:exempt] ->
        {:ok, :allowed}

      mode == :image_generation and limits[:image_generation_enabled] ->
        {:ok, :allowed}

      mode == :video_generation and limits[:video_generation_enabled] ->
        {:ok, :allowed}

      true ->
        {:error,
         %PolicyError{
           limit_type: :mode_disabled,
           upgrade_path: "/settings/subscription"
         }}
    end
  end

  def check_mode_access(_user, _mode), do: {:ok, :allowed}

  @doc """
  Checks whether the given model is allowed in the given workspace.

  If `workspace_id` is nil (personal conversation), returns `{:ok, :allowed}`.
  If the workspace has no `allowed_model_ids` (or an empty list), all models
  are allowed. Otherwise the model's id must be in the allowed list.

  ## Returns

  - `{:ok, :allowed}` - Model is permitted in this workspace (or no workspace)
  - `{:error, %PolicyError{}}` - Model is not allowed in this workspace
  """
  def check_workspace_model(nil, _model), do: {:ok, :allowed}

  def check_workspace_model(workspace_id, model) when is_binary(workspace_id) do
    case Ash.get(Magus.Workspaces.Workspace, workspace_id, authorize?: false) do
      {:ok, workspace} -> check_workspace_model(workspace, model)
      _ -> {:ok, :allowed}
    end
  end

  def check_workspace_model(%{allowed_model_ids: nil}, _model), do: {:ok, :allowed}
  def check_workspace_model(%{allowed_model_ids: []}, _model), do: {:ok, :allowed}

  def check_workspace_model(%{allowed_model_ids: allowed}, model)
      when is_list(allowed) do
    model_id = Map.get(model, :id)

    if model_id && model_id in allowed do
      {:ok, :allowed}
    else
      {:error,
       %PolicyError{
         limit_type: :workspace_model_restricted,
         upgrade_path: ""
       }}
    end
  end

  def check_workspace_model(_workspace, _model), do: {:ok, :allowed}

  @doc """
  Checks if a user can use the specified model under PAYG spend controls.

  Model access is ungated: every model is available to every plan. The only
  limit is the spend budget (monthly cap, trial cap, payment status).
  The `model` is still required to estimate the per-call cost.

  ## Parameters

  - `user` - User struct with `id` and `timezone` fields
  - `model` - Model struct (used for the pre-call cost estimate)
  - `opts` - Optional keyword list:
    - `:estimated_cost_cents` - Override pre-call cost estimate

  ## Returns

  - `{:ok, :allowed}` - Usage is permitted
  - `{:error, %PolicyError{}}` - Spend limit reached
  """
  def check_usage(user, model, opts \\ []) do
    limits = Calculator.get_effective_limits(user.id)

    if limits[:exempt] do
      {:ok, :allowed}
    else
      check_spend_budget(user, model, opts)
    end
  end

  # Money-based pay-per-use gate.
  #
  #   1. exempt is handled by the caller.
  #   2. delinquent (billable but not active/trialing, e.g. past_due) → hard-stop
  #      with `:payment_required`: no new postpaid spend during dunning. This
  #      MUST sit above the no_spend_cap / cap branches so a delinquent opt-out
  #      user can't keep spending uncollectable postpaid.
  #   3. user opted out of the cap → allow (postpaid, billed at cycle close).
  #   4. else allow while `period_usage + est ≤ effective_cap` (for free users
  #      the effective cap is the small trial allowance).
  #   5. else hard-stop with `:spend_cap` / `:trial_cap`.
  defp check_spend_budget(user, model, opts) do
    state = Calculator.get_spend_state(user.id)

    estimated =
      Keyword.get(opts, :estimated_cost_cents) || estimate_cost_cents(model)

    cond do
      state.delinquent ->
        {:error,
         %PolicyError{
           limit_type: :payment_required,
           current: state.period_usage_cents,
           limit: state.effective_cap_cents,
           upgrade_path: "/settings/subscription"
         }}

      state.no_spend_cap ->
        # Postpaid without a cap: usage is never blocked, it is billed with the
        # monthly invoice at cycle close.
        {:ok, :allowed}

      state.period_usage_cents + estimated <= state.effective_cap_cents ->
        {:ok, :allowed}

      true ->
        {:error, spend_limit_error(state)}
    end
  end

  defp spend_limit_error(state) do
    %PolicyError{
      limit_type: if(state.trial, do: :trial_cap, else: :spend_cap),
      current: state.period_usage_cents,
      limit: state.effective_cap_cents,
      upgrade_path: "/settings/subscription"
    }
  end

  @doc """
  Checks whether a user still has any remaining pay-per-use budget.

  Unlike `check_usage/3`, this does not require a model: it returns
  `{:ok, :allowed}` while the user is still under their
  effective monthly spend cap (or is exempt / opted out of the cap).

  Used by autonomy gates (e.g. `RunOrchestrator`) where a heartbeat run is
  rejected purely because the owner is out of budget, before any specific model
  has been selected.
  """
  def check_spend_budget(user) do
    state = Calculator.get_spend_state(user.id)

    cond do
      state.exempt ->
        {:ok, :allowed}

      state.delinquent ->
        {:error,
         %PolicyError{
           limit_type: :payment_required,
           current: state.period_usage_cents,
           limit: state.effective_cap_cents,
           upgrade_path: "/settings/subscription"
         }}

      state.no_spend_cap ->
        {:ok, :allowed}

      state.period_usage_cents < state.effective_cap_cents ->
        {:ok, :allowed}

      true ->
        {:error, spend_limit_error(state)}
    end
  end

  # Coarse pre-call cost estimate in integer cents (CHF). Tokens are unknown
  # before the call, so this is a deliberately rough guard to stop a single
  # expensive call from blowing far past the cap; the real cost is reconciled
  # post-call by `Account.deduct_usage`. Floored at 1 cent so the gate
  # is never a no-op.
  @assumed_input_tokens 4_000
  @assumed_output_tokens 4_000
  @media_estimate_cents 5

  # Reference request the composer model pickers price to gauge per-request
  # cost: ~16k input + ~4k output tokens (≈20k total).
  @picker_input_tokens 16_000
  @picker_output_tokens 4_000

  # Fixed CHF-cent thresholds bucketing the picker estimate into a color tier.
  @cost_cheap_max_cents 5
  @cost_moderate_max_cents 20

  @doc """
  CHF cents for the composer pickers' reference request (≈20k input + 4k output
  tokens), priced per model. `nil` for image/video models (cost is per-unit, not
  token-based). Single source for both the workbench and SPA pickers.
  """
  def picker_request_cost_cents(model),
    do: request_cost_cents(model, @picker_input_tokens, @picker_output_tokens)

  @doc """
  Buckets a per-request CHF-cents estimate into `:cheap | :moderate | :expensive`
  for color coding. `nil` passes through (no tier).
  """
  def request_cost_tier(nil), do: nil
  def request_cost_tier(cents) when cents <= @cost_cheap_max_cents, do: :cheap
  def request_cost_tier(cents) when cents <= @cost_moderate_max_cents, do: :moderate
  def request_cost_tier(_cents), do: :expensive

  @doc false
  def estimate_cost_cents(model) do
    cents =
      case Map.get(model, :output_cost_unit) do
        # Gating budgets in whole cents, so round the exact estimate up.
        :per_million_tokens -> ceil_to_cent(token_estimate_cents(model))
        nil -> ceil_to_cent(token_estimate_cents(model))
        # per_image / per_second / per_video — flat coarse guard
        _ -> @media_estimate_cents
      end

    max(1, cents)
  end

  @doc """
  CHF cents for a single token-model request of the given `input_tokens` /
  `output_tokens`, via the cached USD→CHF rate (1:1 until fetched). Returns
  `nil` for non per-million-token models (image/video), whose per-request cost
  is per-image/second rather than token-based. Returns a float with sub-cent
  precision (not floored at 1, so a free model returns 0.0) — cheap models
  would otherwise all collapse to "0.01". Used by the composer model pickers
  to show an approximate cost per request; `estimate_cost_cents/1` is the
  gating-side wrapper that rounds up to whole cents.
  """
  def request_cost_cents(model, input_tokens, output_tokens) do
    case Map.get(model, :output_cost_unit) do
      unit when unit in [:per_million_tokens, nil] ->
        token_cost_cents(model, input_tokens, output_tokens)

      _ ->
        nil
    end
  end

  defp token_estimate_cents(model),
    do: token_cost_cents(model, @assumed_input_tokens, @assumed_output_tokens)

  defp token_cost_cents(model, input_tokens, output_tokens) do
    in_per_m = cost_value(model, :input_cost_value, :input_cost)
    out_per_m = cost_value(model, :output_cost_value, :output_cost)

    # dollars = (in_per_m * in_tokens + out_per_m * out_tokens) / 1_000_000
    dollars =
      in_per_m
      |> Decimal.mult(input_tokens)
      |> Decimal.add(Decimal.mult(out_per_m, output_tokens))
      |> Decimal.div(1_000_000)

    # dollars → internal-cost-unit cents via the ExchangeRate seam (1:1 in core;
    # the billing edition supplies the live USD→CHF rate), mirroring the
    # draw-down conversion in UsageRecorder.
    dollars
    |> Decimal.mult(Magus.Usage.ExchangeRate.usd_to_chf())
    |> Decimal.mult(100)
    |> Decimal.round(3)
    |> Decimal.to_float()
  end

  defp ceil_to_cent(cents), do: cents |> :math.ceil() |> trunc()

  # Structured `*_cost_value` decimals win; legacy rows carry only display
  # strings in mixed formats ("3.43", "$3.43/M"), which must not price as free.
  defp cost_value(model, value_key, legacy_key) do
    case Map.get(model, value_key) do
      %Decimal{} = d -> d
      _ -> parse_legacy_cost(Map.get(model, legacy_key))
    end
  end

  defp parse_legacy_cost(cost) when is_binary(cost) do
    case Regex.run(~r/\d+(?:\.\d+)?/, cost) do
      [number] -> Decimal.new(number)
      _ -> Decimal.new("0")
    end
  end

  defp parse_legacy_cost(_), do: Decimal.new("0")

  @doc """
  Checks if a user can upload a batch of files.

  Validates each file individually against `max_upload_bytes`, then checks
  cumulative storage impact. Returns `{:ok, :allowed}` or `{:error, message}`
  with a human-readable error string (including filename for per-file violations).

  ## Parameters

  - `user` - User struct with `id` field
  - `files` - List of maps with `:name` and `:size` keys (bytes)

  ## Returns

  - `{:ok, :allowed}` - All uploads permitted
  - `{:error, String.t()}` - Human-readable error message
  """
  def check_file_uploads(_user, []), do: {:ok, :allowed}

  def check_file_uploads(user, files) do
    limits = Calculator.get_effective_limits(user.id)

    if limits[:exempt] do
      {:ok, :allowed}
    else
      total_size = Enum.sum(Enum.map(files, & &1.size))
      current_storage = Calculator.get_storage_used(user.id)

      cond do
        file = Enum.find(files, fn f -> f.size > limits.max_upload_bytes end) ->
          msg =
            Magus.Usage.PolicyErrorMessage.message(%PolicyError{
              limit_type: :max_upload_bytes,
              current: file.size,
              limit: limits.max_upload_bytes
            })

          {:error, "#{file.name}: #{msg}"}

        current_storage > limits.storage_bytes ->
          {:error,
           Magus.Usage.PolicyErrorMessage.message(%PolicyError{
             limit_type: :storage_overage,
             current: current_storage,
             limit: limits.storage_bytes
           })}

        current_storage + total_size > limits.storage_bytes ->
          {:error,
           Magus.Usage.PolicyErrorMessage.message(%PolicyError{
             limit_type: :storage_bytes,
             current: current_storage,
             limit: limits.storage_bytes
           })}

        true ->
          {:ok, :allowed}
      end
    end
  end

  @doc """
  Checks if a user can upload a single file of the given size.

  Returns `{:ok, :allowed}` or `{:error, %PolicyError{}}`.
  """
  def check_file_upload(user, file_size) do
    limits = Calculator.get_effective_limits(user.id)

    cond do
      limits.exempt ->
        {:ok, :allowed}

      file_size > limits.max_upload_bytes ->
        {:error,
         %PolicyError{
           limit_type: :max_upload_bytes,
           current: file_size,
           limit: limits.max_upload_bytes,
           upgrade_path: "/settings/subscription"
         }}

      true ->
        check_storage_limits(user.id, file_size, limits)
    end
  end

  defp check_storage_limits(user_id, file_size, limits) do
    current_storage = Calculator.get_storage_used(user_id)

    cond do
      # Block if already over quota (downgrade scenario)
      current_storage > limits.storage_bytes ->
        {:error,
         %PolicyError{
           limit_type: :storage_overage,
           current: current_storage,
           limit: limits.storage_bytes,
           upgrade_path: "/settings/subscription"
         }}

      # Block if this upload would exceed quota
      current_storage + file_size > limits.storage_bytes ->
        {:error,
         %PolicyError{
           limit_type: :storage_bytes,
           current: current_storage,
           limit: limits.storage_bytes,
           upgrade_path: "/settings/subscription"
         }}

      true ->
        {:ok, :allowed}
    end
  end
end
