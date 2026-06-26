defmodule Magus.Chat.Workers.ReconcileOpenRouterUsage do
  @moduledoc """
  Reconciles a `MessageUsage` row that was recorded with zero tokens (because
  OpenRouter omitted usage from the streaming response) against the authoritative
  generation endpoint:

      GET https://openrouter.ai/api/v1/generation?id=<gen-...>

  It writes back the provider's native token counts and exact cost, then deducts
  that cost to the user's PAYG period accumulator (the original zero-token row deducted
  nothing).

  Enqueued by `Magus.Agents.Persistence.UsageRecorder` ONLY for a billable
  `:response` row that carries a generation id but came back empty. Idempotent:
  only a row still in `reconciliation_status: :pending` is processed, so an
  already-reconciled, given-up, or non-empty row is never (re-)charged.

  OpenRouter's generation stats lag a little behind the request, so a 404 (or a
  row without token data yet) snoozes the job with a growing backoff rather than
  failing.
  """

  use Oban.Worker,
    queue: :usage_reconciliation,
    max_attempts: 20,
    unique: [fields: [:args], keys: [:usage_id], period: 86_400]

  require Logger
  require Ash.Query

  alias Magus.Agents.Persistence.UsageRecorder
  alias Magus.Usage.MessageUsage

  @endpoint "https://openrouter.ai/api/v1/generation"
  @initial_delay_s 5
  @max_poll_attempts 12

  @doc "Schedule reconciliation for a usage row, after a short propagation delay."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(usage_id) when is_binary(usage_id) and usage_id != "" do
    %{usage_id: usage_id}
    |> new(schedule_in: @initial_delay_s)
    |> Oban.insert()
  end

  def enqueue(_), do: {:error, :invalid_usage_id}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"usage_id" => usage_id}, attempt: attempt}) do
    case load_usage(usage_id) do
      # Gate strictly on :pending (not merely reconciled_at == nil): a :reconciled
      # row is done, an :unavailable row was given up on, and :not_required never
      # needed it. This is also what makes the deduction safe — only a pending
      # row (recorded empty) is ever deducted, so we never double-charge a row
      # that already carries usage.
      {:ok,
       %MessageUsage{reconciliation_status: :pending, provider_generation_id: gen_id} = usage}
      when is_binary(gen_id) and gen_id != "" ->
        reconcile(usage, gen_id, attempt)

      {:ok, _usage} ->
        :ok

      :not_found ->
        :ok
    end
  end

  def perform(_job), do: :ok

  # ============================================================================

  defp reconcile(usage, gen_id, attempt) do
    case api_key() do
      nil ->
        Logger.warning("ReconcileOpenRouterUsage: no OpenRouter API key; skipping #{usage.id}")
        :ok

      key ->
        case fetch_generation(gen_id, key) do
          {:ok, data} -> apply_reconciliation(usage, data)
          {:error, :not_ready} -> snooze(usage, attempt)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp load_usage(usage_id) do
    case Ash.get(MessageUsage, usage_id, authorize?: false) do
      {:ok, usage} -> {:ok, usage}
      {:error, _} -> :not_found
    end
  end

  defp fetch_generation(gen_id, key) do
    opts =
      [
        params: [id: gen_id],
        auth: {:bearer, key},
        receive_timeout: 15_000,
        retry: false
      ] ++ Application.get_env(:magus, :reconcile_usage_req_options, [])

    case Req.get(@endpoint, opts) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_map(data) ->
        if generation_ready?(data), do: {:ok, data}, else: {:error, :not_ready}

      {:ok, %{status: 404}} ->
        {:error, :not_ready}

      {:ok, %{status: status}} when status in 500..599 ->
        {:error, {:http_error, status}}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # Stats are "ready" once token counts OR the cost are populated (the row may
  # exist with null token fields for a brief window after the request completes,
  # and the cost is the field we most need for billing).
  defp generation_ready?(data) do
    is_integer(data["native_tokens_prompt"]) or is_integer(data["native_tokens_completion"]) or
      is_integer(data["tokens_prompt"]) or is_integer(data["tokens_completion"]) or
      cost_present?(to_decimal(data["total_cost"]))
  end

  defp cost_present?(%Decimal{} = cost), do: Decimal.compare(cost, 0) == :gt
  defp cost_present?(_), do: false

  defp apply_reconciliation(usage, data) do
    prompt = to_int(data["native_tokens_prompt"]) || to_int(data["tokens_prompt"]) || 0

    completion =
      to_int(data["native_tokens_completion"]) || to_int(data["tokens_completion"]) || 0

    # Round to 8dp so the column stays clean of Decimal.from_float noise; the
    # CHF conversion rounds to cents anyway.
    total_cost = (to_decimal(data["total_cost"]) || Decimal.new("0")) |> Decimal.round(8)

    attrs = %{
      prompt_tokens: prompt,
      completion_tokens: completion,
      total_tokens: prompt + completion,
      reasoning_tokens: to_int(data["native_tokens_reasoning"]),
      cached_tokens: to_int(data["native_tokens_cached"]) || 0,
      total_cost: total_cost,
      provider_cost: total_cost,
      provider: data["provider_name"]
    }

    case Ash.update(usage, attrs, action: :apply_reconciliation, authorize?: false) do
      {:ok, _updated} ->
        # The zero-token row deducted nothing; charge the reconciled cost now.
        # Ordered after the row update (which sets reconciled_at) so a crash here
        # never re-runs the deduction on retry — we prefer a rare missed charge
        # over double-charging the customer. A failed charge is surfaced (not
        # silently swallowed) so it can be recovered; see TODO below.
        # Distinct identifier from the original record: the original recorded a
        # zero-token row and deducted nothing, so this reconciled charge is its
        # own meter event (and dedupes on its own key under retry).
        case UsageRecorder.record_billable_cost(usage.user_id, total_cost,
               meter_identifier: "usage-#{usage.id}-reconcile"
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            # TODO(magus-abt): make this recoverable rather than log-only — the
            # tokens are reconciled but the usage charge was lost.
            Logger.warning(
              "ReconcileOpenRouterUsage: usage #{usage.id} reconciled but usage charge " <>
                "(#{Decimal.to_string(total_cost)} USD) failed: #{inspect(reason)}; not collected"
            )
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp snooze(usage, attempt) when attempt >= @max_poll_attempts do
    Logger.warning(
      "ReconcileOpenRouterUsage: generation stats not ready after #{attempt} attempts " <>
        "for usage #{usage.id}; marking unavailable"
    )

    Ash.update(usage, %{}, action: :mark_reconciliation_unavailable, authorize?: false)
    :ok
  end

  defp snooze(_usage, attempt), do: {:snooze, min(@initial_delay_s * attempt, 120)}

  defp api_key do
    System.get_env("OPENROUTER_API_KEY") ||
      Application.get_env(:req_llm, :openrouter_api_key)
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp to_int(_), do: nil

  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(%Decimal{} = d), do: d

  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp to_decimal(_), do: nil
end
