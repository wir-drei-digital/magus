defmodule Magus.Chat.Workers.ReconcileOpenRouterUsageTest do
  use Magus.ResourceCase, async: false

  alias Magus.Usage.MessageUsage
  alias Magus.Chat.Workers.ReconcileOpenRouterUsage

  @stub __MODULE__.Stub

  setup do
    Application.put_env(:req_llm, :openrouter_api_key, "test-key")
    Application.put_env(:magus, :reconcile_usage_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.delete_env(:magus, :reconcile_usage_req_options)
      Application.delete_env(:req_llm, :openrouter_api_key)
    end)

    :ok
  end

  defp zero_usage_row(user, gen_id) do
    {:ok, usage} =
      MessageUsage
      |> Ash.Changeset.for_create(:create, %{
        user_id: user.id,
        model_name: "Claude Sonnet 4.6",
        usage_type: :response,
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0,
        billable: true,
        provider_generation_id: gen_id,
        reconciliation_status: :pending
      })
      |> Ash.create(authorize?: false)

    usage
  end

  defp usage_job(usage_id, attempt \\ 1),
    do: %Oban.Job{args: %{"usage_id" => usage_id}, attempt: attempt}

  test "reconciles a zero-token row with native tokens + cost from the generation endpoint" do
    user = generate(user())
    usage = zero_usage_row(user, "gen-abc")

    Req.Test.stub(@stub, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "native_tokens_prompt" => 20_376,
          "native_tokens_completion" => 21,
          "native_tokens_reasoning" => 8,
          "total_cost" => 0.0612,
          "provider_name" => "anthropic"
        }
      })
    end)

    assert :ok = ReconcileOpenRouterUsage.perform(usage_job(usage.id))

    {:ok, reloaded} = Ash.get(MessageUsage, usage.id, authorize?: false)
    assert reloaded.prompt_tokens == 20_376
    assert reloaded.completion_tokens == 21
    assert reloaded.total_tokens == 20_397
    assert reloaded.reasoning_tokens == 8
    assert reloaded.provider == "anthropic"
    assert Decimal.equal?(Decimal.round(reloaded.total_cost, 4), Decimal.new("0.0612"))
    assert reloaded.reconciled_at
    assert reloaded.reconciliation_status == :reconciled
  end

  test "snoozes (does not fail) when generation stats are not ready yet (404)" do
    user = generate(user())
    usage = zero_usage_row(user, "gen-pending")

    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end)

    assert {:snooze, seconds} = ReconcileOpenRouterUsage.perform(usage_job(usage.id))
    assert is_integer(seconds) and seconds > 0

    # Still pending while it keeps retrying.
    {:ok, reloaded} = Ash.get(MessageUsage, usage.id, authorize?: false)
    assert reloaded.reconciliation_status == :pending
  end

  test "marks :unavailable after exhausting poll attempts" do
    user = generate(user())
    usage = zero_usage_row(user, "gen-gaveup")

    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end)

    assert :ok = ReconcileOpenRouterUsage.perform(usage_job(usage.id, 12))

    {:ok, reloaded} = Ash.get(MessageUsage, usage.id, authorize?: false)
    assert reloaded.reconciliation_status == :unavailable
    refute reloaded.reconciled_at
  end

  test "is idempotent: skips a row that is already reconciled (no HTTP call)" do
    user = generate(user())
    usage = zero_usage_row(user, "gen-done")

    {:ok, _} =
      Ash.update(usage, %{total_cost: Decimal.new("1")},
        action: :apply_reconciliation,
        authorize?: false
      )

    Req.Test.stub(@stub, fn _conn -> raise "generation endpoint must not be called" end)

    assert :ok = ReconcileOpenRouterUsage.perform(usage_job(usage.id))
  end
end
