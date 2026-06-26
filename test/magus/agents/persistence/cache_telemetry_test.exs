defmodule Magus.Agents.Persistence.CacheTelemetryTest do
  @moduledoc """
  DB-free tests for the pure prompt-cache-hit helpers and the best-effort emit.
  """
  # async: false — the `emit/2` describe block uses `refute_receive` on the
  # GLOBAL telemetry event `[:magus, :agents, :prompt_cache]`. Telemetry handlers
  # fire in the emitting process and `send` to the attaching test pid, so a
  # concurrent test that emits this event would deliver a message here and fail
  # the refute. The handler/event name is fixed by app code and cannot be
  # uniquely scoped, so serializing the module is the correct isolation.
  use ExUnit.Case, async: false

  alias Magus.Agents.Persistence.CacheTelemetry

  describe "cache_hit_ratio/2" do
    test "is cached / prompt" do
      assert CacheTelemetry.cache_hit_ratio(50, 100) == 0.5
      assert CacheTelemetry.cache_hit_ratio(25, 100) == 0.25
    end

    test "is 0.0 when prompt is 0" do
      assert CacheTelemetry.cache_hit_ratio(10, 0) == 0.0
    end

    test "is 0.0 when prompt is nil (no division by zero)" do
      assert CacheTelemetry.cache_hit_ratio(10, nil) == 0.0
    end

    test "is 0.0 when cached is 0" do
      assert CacheTelemetry.cache_hit_ratio(0, 100) == 0.0
    end

    test "is 0.0 when cached is nil" do
      assert CacheTelemetry.cache_hit_ratio(nil, 100) == 0.0
    end

    test "is 1.0 when cached == prompt (full hit)" do
      assert CacheTelemetry.cache_hit_ratio(100, 100) == 1.0
    end

    test "clamps to 1.0 if cached somehow exceeds prompt" do
      assert CacheTelemetry.cache_hit_ratio(150, 100) == 1.0
    end
  end

  describe "prompt_tokens/1" do
    test "mirrors ExtractTokens precedence across key shapes" do
      assert CacheTelemetry.prompt_tokens(%{input_tokens: 42}) == 42
      assert CacheTelemetry.prompt_tokens(%{prompt_tokens: 17}) == 17
      assert CacheTelemetry.prompt_tokens(%{"prompt_tokens" => 99}) == 99
      assert CacheTelemetry.prompt_tokens(%{"input_tokens" => 7}) == 7
    end

    test "is 0 when absent or not a map" do
      assert CacheTelemetry.prompt_tokens(%{}) == 0
      assert CacheTelemetry.prompt_tokens(nil) == 0
    end
  end

  describe "cached_tokens/1" do
    test "reads top-level ReqLLM-normalized keys" do
      assert CacheTelemetry.cached_tokens(%{cached_input: 30}) == 30
      assert CacheTelemetry.cached_tokens(%{cached_tokens: 12}) == 12
    end

    test "reads nested prompt_tokens_details" do
      assert CacheTelemetry.cached_tokens(%{"prompt_tokens_details" => %{"cached_tokens" => 64}}) ==
               64

      assert CacheTelemetry.cached_tokens(%{prompt_tokens_details: %{cached_tokens: 8}}) == 8
    end

    test "is 0 when absent or not a map" do
      assert CacheTelemetry.cached_tokens(%{}) == 0
      assert CacheTelemetry.cached_tokens(nil) == 0
    end
  end

  describe "emit/2 (DB-free, telemetry handler)" do
    setup do
      handler_id = "cache-telemetry-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:magus, :agents, :prompt_cache],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "fires telemetry for normal text generation with prompt tokens" do
      assert :ok =
               CacheTelemetry.emit(
                 %{"prompt_tokens" => 200, "prompt_tokens_details" => %{"cached_tokens" => 50}},
                 conversation_id: "conv-1",
                 model: "x-ai/grok-4.1-fast"
               )

      assert_receive {:telemetry, [:magus, :agents, :prompt_cache], measurements, metadata}
      assert measurements.prompt_tokens == 200
      assert measurements.cached_tokens == 50
      assert measurements.ratio == 0.25
      assert metadata.conversation_id == "conv-1"
      assert metadata.model == "x-ai/grok-4.1-fast"
    end

    test "skips cleanly when there are no prompt tokens (image/video gen)" do
      assert :ok = CacheTelemetry.emit(%{}, conversation_id: "conv-2")
      refute_receive {:telemetry, [:magus, :agents, :prompt_cache], _, _}
    end
  end
end
