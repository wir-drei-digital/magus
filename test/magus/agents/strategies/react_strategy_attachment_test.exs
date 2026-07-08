# Minimal agent for lifecycle tests: the ReactStrategy with no tools and no
# plugins, so a turn exercises the parent → worker → runtime-task chain
# without touching the database.
defmodule Magus.Agents.Strategies.ReactStrategyAttachmentTest.MiniAgent do
  @moduledoc false
  use Jido.Agent,
    name: "mini_react_attachment",
    strategy: {Magus.Agents.Strategies.ReactStrategy, [tools: [], streaming: true]},
    schema: []
end

defmodule Magus.Agents.Strategies.ReactStrategyAttachmentTest do
  # async: false — global Mox mode plus a named InstanceManager.
  use ExUnit.Case, async: false

  import Mox

  alias Magus.Test.MockResponses

  @manager :react_attachment_test_manager

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    original = Application.get_env(:magus, :llm_client)
    Application.put_env(:magus, :llm_client, Magus.Test.Mocks.LLMMock)

    on_exit(fn ->
      Application.put_env(:magus, :llm_client, original || Magus.Agents.Clients.LLM)
    end)

    :ok
  end

  test "an active run holds the agent alive past idle_timeout, then the timer re-arms" do
    # The turn (600ms) deliberately outlives the idle timeout (250ms). Before
    # the run-holds-attachment fix, the idle timer was blind to activity and
    # hibernated the agent mid-turn.
    stub(Magus.Test.Mocks.LLMMock, :stream_text, fn _model, _messages, _opts ->
      Process.sleep(600)
      MockResponses.stream_text_response("done")
    end)

    start_supervised!(
      {Jido.Agent.InstanceManager,
       [
         name: @manager,
         agent: __MODULE__.MiniAgent,
         idle_timeout: 250,
         agent_opts: [jido: Magus.Jido, agent_module: __MODULE__.MiniAgent]
       ]}
    )

    {:ok, pid} = Jido.Agent.InstanceManager.get(@manager, "mini:attach:1")
    ref = Process.monitor(pid)

    signal = Jido.Signal.new!("ai.react.query", %{query: "hello", model: "mock:test-model"})
    :ok = Jido.AgentServer.cast(pid, signal)

    # Mid-turn the run's runtime task must be attached (this is what blocks
    # the idle timer) and the turn must not have failed.
    Process.sleep(150)
    server_state = :sys.get_state(pid)
    assert MapSet.size(server_state.lifecycle.attachments) == 1
    strategy_state = server_state.agent.state[:__strategy__] || %{}
    assert strategy_state[:status] == :awaiting_llm

    # The agent must survive the whole turn even though it crosses the
    # idle timeout.
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 550

    # After the turn completes the attachment drops and the idle timer
    # re-arms: the agent must still hibernate when genuinely idle.
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :idle_timeout}}, 2_500
  end
end
