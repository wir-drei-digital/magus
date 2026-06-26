# test/magus/agents/plugins/activity_log_plugin_test.exs
defmodule Magus.Agents.Plugins.ActivityLogPluginTest do
  use Magus.DataCase, async: false

  alias Magus.Agents.Plugins.ActivityLogPlugin

  import Magus.Generators

  # Process dictionary state is per-process and each test runs in its own
  # process, so no explicit cleanup is needed between tests.

  # Helper to build agent map with a real conversation
  defp build_agent_state(user, opts \\ []) do
    conv = generate(conversation(actor: user))

    state =
      %{user_id: user.id, conversation_id: conv.id}
      |> then(fn s ->
        case Keyword.get(opts, :custom_agent_id) do
          nil -> s
          id -> Map.put(s, :custom_agent_id, id)
        end
      end)

    {%{state: state}, conv}
  end

  describe "handle_signal/2 - ai.request.completed" do
    test "creates :response_sent activity log entry" do
      user = generate(user())
      custom_agent = custom_agent(user)

      {agent, _conv} = build_agent_state(user, custom_agent_id: custom_agent.id)

      signal = %{type: "ai.request.completed", data: %{}}
      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      assert [log] =
               Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)

      assert log.activity_type == :response_sent
      assert log.agent_id == custom_agent.id
      assert log.user_id == user.id
    end

    test "enriches :response_sent with accumulated model/tokens from ai.usage" do
      user = generate(user())
      custom_agent = custom_agent(user)
      {agent, _conv} = build_agent_state(user, custom_agent_id: custom_agent.id)
      context = %{agent: agent}

      # Two usage turns accumulate before the request completes.
      assert {:ok, :continue} =
               ActivityLogPlugin.handle_signal(
                 %{
                   type: "ai.usage",
                   data: %{model: "openrouter:test-model", input_tokens: 100, output_tokens: 40}
                 },
                 context
               )

      assert {:ok, :continue} =
               ActivityLogPlugin.handle_signal(
                 %{
                   type: "ai.usage",
                   data: %{model: "openrouter:test-model", input_tokens: 10, output_tokens: 5}
                 },
                 context
               )

      assert {:ok, :continue} =
               ActivityLogPlugin.handle_signal(
                 %{type: "ai.request.completed", data: %{result: "All done."}},
                 context
               )

      assert [log] = Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)
      assert log.activity_type == :response_sent
      assert log.model_used == "openrouter:test-model"
      assert log.tokens_used == 155
      assert log.details["finish_reason"] == "stop"
      assert log.details["empty?"] == false

      # Accumulator is consumed/cleared on the terminal signal.
      assert Process.get(:activity_log_usage_acc) == nil
    end

    test "flags empty? and finish_reason \"empty\" when the final result is blank" do
      user = generate(user())
      custom_agent = custom_agent(user)
      {agent, _conv} = build_agent_state(user, custom_agent_id: custom_agent.id)
      context = %{agent: agent}

      assert {:ok, :continue} =
               ActivityLogPlugin.handle_signal(
                 %{type: "ai.request.completed", data: %{result: "   "}},
                 context
               )

      assert [log] = Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)
      assert log.activity_type == :response_sent
      assert log.details["empty?"] == true
      assert log.details["finish_reason"] == "empty"
    end
  end

  describe "handle_signal/2 - default agent resolution" do
    test "resolves default agent when custom_agent_id is nil" do
      user = generate(user())
      default_agent = Magus.Agents.create_default_agent!(%{name: "Default Agent"}, actor: user)

      {agent, _conv} = build_agent_state(user)

      signal = %{type: "ai.request.completed", data: %{}}
      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      assert [log] =
               Magus.Agents.list_agent_activity!(default_agent.id, authorize?: false)

      assert log.activity_type == :response_sent
      assert log.agent_id == default_agent.id
    end

    test "skips logging when no custom_agent_id and no default agent" do
      user = generate(user())

      {agent, _conv} = build_agent_state(user)

      signal = %{type: "ai.request.completed", data: %{}}
      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      assert [] = Magus.Agents.list_user_activity!(actor: user, authorize?: false)
    end
  end

  describe "handle_signal/2 - ai.request.failed" do
    test "creates :error activity log entry with error message" do
      user = generate(user())
      custom_agent = custom_agent(user)

      {agent, _conv} = build_agent_state(user, custom_agent_id: custom_agent.id)

      signal = %{type: "ai.request.failed", data: %{error: "LLM timeout after 30s"}}
      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      assert [log] =
               Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)

      assert log.activity_type == :error
      assert log.summary == "Error: LLM timeout after 30s"
      assert log.details["error"] == "LLM timeout after 30s"
    end
  end

  describe "handle_signal/2 - ai.tool.result" do
    test "creates :run_spawned for spawn_sub_agent tool" do
      user = generate(user())
      custom_agent = custom_agent(user)
      run_id = Ash.UUID.generate()

      {agent, _conv} = build_agent_state(user, custom_agent_id: custom_agent.id)

      signal = %{
        type: "ai.tool.result",
        data: %{
          tool_name: "spawn_sub_agent",
          params: %{"objective" => "Research Elixir best practices"},
          result: %{run_id: run_id}
        }
      }

      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      assert [log] =
               Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)

      assert log.activity_type == :run_spawned
      assert log.summary == "Sub-agent spawned: Research Elixir best practices"
      assert log.run_id == run_id
      assert log.details["objective"] == "Research Elixir best practices"
    end

    test "creates :memory_updated for create_memory tool" do
      user = generate(user())
      custom_agent = custom_agent(user)

      {agent, _conv} = build_agent_state(user, custom_agent_id: custom_agent.id)

      signal = %{
        type: "ai.tool.result",
        data: %{
          tool_name: "create_memory"
        }
      }

      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      assert [log] =
               Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)

      assert log.activity_type == :memory_updated
      assert log.summary == "Memory create_memory"
      assert log.details["tool"] == "create_memory"
    end

    test "ignores read-only memory tools like search_memories" do
      user = generate(user())
      custom_agent = custom_agent(user)

      {agent, _conv} = build_agent_state(user, custom_agent_id: custom_agent.id)

      signal = %{
        type: "ai.tool.result",
        data: %{
          tool_name: "search_memories"
        }
      }

      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      assert [] = Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)
    end
  end

  describe "handle_signal/2 - integration reply from process dict" do
    test "creates :response_sent with integration details from process dict" do
      user = generate(user())
      custom_agent = custom_agent(user)

      {agent, conv} = build_agent_state(user, custom_agent_id: custom_agent.id)
      conv_id = conv.id

      # Simulate IntegrationReplyPlugin setting the process dict
      Process.put(:activity_log_integration_reply, %{
        provider: "telegram",
        conversation_id: conv_id
      })

      signal = %{type: "ai.request.completed", data: %{}}
      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      logs = Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)
      assert length(logs) == 2

      regular = Enum.find(logs, &(&1.summary == "Response completed"))
      assert regular.activity_type == :response_sent

      integration = Enum.find(logs, &(&1.summary =~ "telegram"))
      assert integration.activity_type == :response_sent
      assert integration.summary == "Integration reply sent via telegram"
      assert integration.details["provider"] == "telegram"
      assert integration.details["conversation_id"] == conv_id

      # Process dict should be cleaned up
      assert Process.get(:activity_log_integration_reply) == nil
    end
  end

  describe "handle_signal/2 - completed run from process dict" do
    test "creates :run_completed when process dict has last_completed_run" do
      user = generate(user())
      custom_agent = custom_agent(user)
      run_id = Ash.UUID.generate()

      {agent, _conv} = build_agent_state(user, custom_agent_id: custom_agent.id)

      # Simulate AgentRunCompletionPlugin setting the process dict
      Process.put(:activity_log_last_completed_run, %{
        id: run_id,
        objective: "Research Elixir concurrency patterns",
        event_id: nil,
        task_id: nil,
        duration_ms: 1500,
        model_key: "openrouter:test-model",
        status: :complete,
        result_text: "Found three patterns."
      })

      signal = %{type: "ai.request.completed", data: %{}}
      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      logs = Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)
      assert length(logs) == 2

      regular = Enum.find(logs, &(&1.activity_type == :response_sent))
      assert regular != nil

      run_log = Enum.find(logs, &(&1.activity_type == :run_completed))
      assert run_log.summary == "Run completed: Research Elixir concurrency patterns"
      assert run_log.run_id == run_id
      assert run_log.duration_ms == 1500
      assert run_log.model_used == "openrouter:test-model"
      assert run_log.details["objective"] == "Research Elixir concurrency patterns"
      assert run_log.details["run_id"] == run_id
      assert run_log.details["finish_reason"] == "stop"
      assert run_log.details["empty?"] == false

      # Process dict should be cleaned up
      assert Process.get(:activity_log_last_completed_run) == nil
    end
  end

  describe "handle_signal/2 - failed run from process dict" do
    test "creates :run_failed when process dict has last_failed_run" do
      user = generate(user())
      custom_agent = custom_agent(user)
      run_id = Ash.UUID.generate()

      {agent, _conv} = build_agent_state(user, custom_agent_id: custom_agent.id)

      # Simulate AgentRunCompletionPlugin setting the process dict
      Process.put(:activity_log_last_failed_run, %{
        id: run_id,
        objective: "Deploy to production",
        event_id: nil,
        task_id: nil,
        duration_ms: 500,
        model_key: "openrouter:test-model",
        status: :error,
        result_text: nil
      })

      signal = %{type: "ai.request.failed", data: %{error: "LLM timeout"}}
      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      logs = Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)
      assert length(logs) == 2

      error_log = Enum.find(logs, &(&1.activity_type == :error))
      assert error_log != nil

      run_log = Enum.find(logs, &(&1.activity_type == :run_failed))
      assert run_log.summary == "Run failed: Deploy to production"
      assert run_log.run_id == run_id
      assert run_log.duration_ms == 500
      assert run_log.model_used == "openrouter:test-model"
      assert run_log.details["objective"] == "Deploy to production"
      assert run_log.details["error"] == "LLM timeout"
      assert run_log.details["finish_reason"] == "error"
      assert run_log.details["empty?"] == true

      # Process dict should be cleaned up
      assert Process.get(:activity_log_last_failed_run) == nil
    end
  end

  describe "caching" do
    test "caches user and default agent across multiple signals" do
      user = generate(user())
      default_agent = Magus.Agents.create_default_agent!(%{name: "Default Agent"}, actor: user)

      {agent, _conv} = build_agent_state(user)

      context = %{agent: agent}

      # First signal — cold cache
      ActivityLogPlugin.handle_signal(%{type: "ai.request.completed", data: %{}}, context)

      # Verify cache was populated
      assert Process.get(:activity_log_user) != nil
      assert Process.get(:activity_log_default_agent_id) == default_agent.id

      # Second signal — should use cache
      ActivityLogPlugin.handle_signal(%{type: "ai.request.completed", data: %{}}, context)

      logs = Magus.Agents.list_agent_activity!(default_agent.id, authorize?: false)
      assert length(logs) == 2
    end
  end
end
