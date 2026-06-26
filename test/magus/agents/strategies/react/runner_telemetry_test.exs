defmodule Magus.Agents.Strategies.ReactStrategy.RunnerTelemetryTest do
  # async: false — attaches the GLOBAL [:magus, :agents, :llm, :call] telemetry
  # handler and toggles :empty_response_max_retries via Application env. A
  # concurrent run emitting the same event would pollute assert_receive, so this
  # module must not run alongside other agent tests.
  use ExUnit.Case, async: false

  import Mox

  alias Jido.AI.Reasoning.ReAct.Config
  alias Magus.Agents.Strategies.ReactStrategy.Runner
  alias Magus.Test.MockResponses

  @event [:magus, :agents, :llm, :call]

  setup :verify_on_exit!

  setup do
    original_client = Application.get_env(:magus, :llm_client)
    Application.put_env(:magus, :llm_client, Magus.Test.Mocks.LLMMock)

    handler_id = "runner-llm-call-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @event,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.put_env(:magus, :llm_client, original_client || Magus.Agents.Clients.LLM)
    end)

    :ok
  end

  test "emits one [:magus, :agents, :llm, :call] event for a normal final answer" do
    Magus.Test.Mocks.LLMMock
    |> expect(:stream_text, fn _model, _messages, _opts ->
      MockResponses.stream_text_response("Done")
    end)

    config =
      Config.new(%{model: "mock:test-model", tools: [], max_iterations: 5, streaming: true})

    Runner.stream("Do it", config, request_id: "req_tel", run_id: "run_tel")
    |> Enum.to_list()

    assert_receive {:telemetry, @event, measurements, %{request_id: "req_tel"} = metadata}

    assert metadata.success == true
    assert metadata.empty? == false
    assert metadata.streaming == true
    assert metadata.finish_reason == "stop"
    assert metadata.run_id == "run_tel"
    assert is_binary(metadata.model) and metadata.model != ""

    assert is_integer(measurements.duration) and measurements.duration >= 0
    # stream_text_response/1 reports input_tokens: 10 and output_tokens: byte length.
    assert measurements.prompt_tokens == 10
    assert measurements.completion_tokens == String.length("Done")
    assert measurements.total_tokens == 10 + String.length("Done")
    assert measurements.empty_retries == 0
  end

  test "flags empty? and finish_reason \"empty\" on a blank final answer" do
    # Disable re-asks so a single blank response surfaces immediately (no backoff).
    agents = Application.get_env(:magus, :agents, [])
    Application.put_env(:magus, :agents, Keyword.put(agents, :empty_response_max_retries, 0))
    on_exit(fn -> Application.put_env(:magus, :agents, agents) end)

    Magus.Test.Mocks.LLMMock
    |> expect(:stream_text, fn _model, _messages, _opts ->
      MockResponses.stream_text_response("")
    end)

    config =
      Config.new(%{model: "mock:test-model", tools: [], max_iterations: 5, streaming: true})

    Runner.stream("Say nothing", config, request_id: "req_empty", run_id: "run_empty")
    |> Enum.to_list()

    assert_receive {:telemetry, @event, measurements, %{request_id: "req_empty"} = metadata}

    assert metadata.empty? == true
    assert metadata.finish_reason == "empty"
    assert metadata.success == true
    assert measurements.empty_retries == 0
  end
end
