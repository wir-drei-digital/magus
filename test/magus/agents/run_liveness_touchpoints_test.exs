defmodule Magus.Agents.RunLivenessTouchpointsTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.AgentRun
  alias Magus.Agents.Plugins.StreamingPlugin
  alias Magus.Agents.Plugins.ToolEventPlugin
  alias Magus.Agents.RunLiveness

  setup do
    user = generate(user())

    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    agent = generate(custom_agent(user, %{heartbeat_enabled: true, is_paused: false}))
    %{user: user, agent: agent}
  end

  defp seed_running_heartbeat_run(user, agent) do
    {:ok, home} = Magus.Agents.Support.HomeConversation.ensure(user.id, agent.id)

    {:ok, run} =
      Magus.Agents.create_agent_run(
        %{
          kind: :delegate,
          source: :heartbeat,
          source_conversation_id: home.id,
          target_agent_id: agent.id,
          target_conversation_id: home.id,
          initiator_user_id: user.id,
          request_id: "hb-#{Ash.UUID.generate()}",
          objective: "x"
        },
        authorize?: false
      )

    {:ok, started} = Magus.Agents.start_agent_run(run, authorize?: false)
    {started, home}
  end

  defp reload(run) do
    Ash.get!(AgentRun, run.id, authorize?: false)
  end

  defp build_agent_struct(conversation_id) do
    %{
      id: "conv:#{conversation_id}",
      state: %{
        conversation_id: conversation_id,
        user_id: "test-user",
        mode: :chat,
        model_keys: %{chat: "test-model"},
        __strategy__: %{active_request_id: "msg-1"}
      }
    }
  end

  defp make_signal(type, data), do: Jido.Signal.new!(type, data)

  test "StreamingPlugin.handle_signal touches liveness on ai.llm.delta", %{
    user: user,
    agent: agent
  } do
    {run, home} = seed_running_heartbeat_run(user, agent)
    RunLiveness.reset_throttle(home.id)

    original_heartbeat = reload(run).last_heartbeat_at

    Process.sleep(1100)

    plugin_agent = build_agent_struct(home.id)
    context = %{agent: plugin_agent}

    signal =
      make_signal("ai.llm.delta", %{
        call_id: "call-1",
        delta: "Hello",
        chunk_type: :content
      })

    assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

    reloaded = reload(run)
    assert DateTime.compare(reloaded.last_heartbeat_at, original_heartbeat) == :gt
  end

  test "ToolEventPlugin.handle_signal touches liveness on ai.tool.started", %{
    user: user,
    agent: agent
  } do
    {run, home} = seed_running_heartbeat_run(user, agent)
    RunLiveness.reset_throttle(home.id)

    original_heartbeat = reload(run).last_heartbeat_at

    Process.sleep(1100)

    plugin_agent = build_agent_struct(home.id)
    context = %{agent: plugin_agent}

    signal =
      make_signal("ai.tool.started", %{
        call_id: "tool-call-1",
        tool_name: "web_search",
        arguments: %{}
      })

    # Only assert it doesn't raise; the handler's return shape is an override Noop.
    ToolEventPlugin.handle_signal(signal, context)

    reloaded = reload(run)
    assert DateTime.compare(reloaded.last_heartbeat_at, original_heartbeat) == :gt
  end
end
