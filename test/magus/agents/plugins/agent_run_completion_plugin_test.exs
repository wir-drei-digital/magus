defmodule Magus.Agents.Plugins.AgentRunCompletionPluginTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Plugins.AgentRunCompletionPlugin

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp build_agent(conversation_id, overrides \\ %{}) do
    base_state =
      Map.merge(
        %{
          conversation_id: conversation_id,
          user_id: "test-user-id",
          mode: :chat,
          model_keys: %{chat: "test-model"},
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        },
        overrides
      )

    %{id: "conv:#{conversation_id}", state: base_state}
  end

  defp build_context(agent) do
    %{agent: agent}
  end

  defp make_signal(type, data) do
    Jido.Signal.new!(type, data)
  end

  defp create_parent_and_child_conversations do
    user = generate(user())
    parent_conv = generate(conversation(actor: user))

    child_conv =
      generate(
        conversation(
          actor: user,
          is_task_conversation: true,
          parent_conversation_id: parent_conv.id
        )
      )

    {user, parent_conv, child_conv}
  end

  defp create_agent_run(parent_conv, child_conv, opts \\ []) do
    sub_agent_run(
      Keyword.merge(
        [
          source_conversation_id: parent_conv.id,
          target_conversation_id: child_conv.id
        ],
        opts
      )
    )
  end

  # ============================================================================
  # Plugin Metadata
  # ============================================================================

  describe "plugin_spec metadata" do
    test "has correct name and state_key" do
      assert AgentRunCompletionPlugin.name() == "agent_run_completion"
      assert AgentRunCompletionPlugin.state_key() == :agent_run_completion
    end

    test "has signal patterns for request completion and failure" do
      patterns = AgentRunCompletionPlugin.signal_patterns()
      assert "ai.request.completed" in patterns
      assert "ai.request.failed" in patterns
      assert length(patterns) == 2
    end

    test "has no actions" do
      assert AgentRunCompletionPlugin.actions() == []
    end
  end

  # ============================================================================
  # Mount
  # ============================================================================

  describe "mount/2" do
    test "initializes plugin state with config" do
      agent = build_agent("some-conv-id")
      {:ok, state} = AgentRunCompletionPlugin.mount(agent, %{some: :config})

      assert state[:config] == %{some: :config}
    end
  end

  # ============================================================================
  # ai.request.completed — task conversations
  # ============================================================================

  describe "handle_signal/2 with ai.request.completed for task conversations" do
    test "marks AgentRun as complete with result text from strategy state" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      # Start the run so it's in :running status
      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent =
        build_agent(child_conv.id, %{
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "Here is the research result.",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        })

      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      # Verify the run was completed
      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :complete
      assert updated_run.result_text == "Here is the research result."
      assert updated_run.completed_at != nil
    end

    test "marks AgentRun as complete with result from signal data when no streaming text" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent = build_agent(child_conv.id)
      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{result: "Signal result text"})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :complete
      assert updated_run.result_text == "Signal result text"
    end

    test "auto-starts pending run before completing it" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      # Run is in :pending status (not started)
      assert run.status == :pending

      agent =
        build_agent(child_conv.id, %{
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "Auto-started result.",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        })

      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :complete
      assert updated_run.result_text == "Auto-started result."
    end

    test "handles string-keyed signal data" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent = build_agent(child_conv.id)
      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{"result" => "String-keyed result"})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :complete
      assert updated_run.result_text == "String-keyed result"
    end

    test "defaults to nil result_text when no result text available" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent = build_agent(child_conv.id)
      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :complete
      # Empty string is stored as nil in the database
      assert updated_run.result_text == nil
    end

    test "correlates completion by request_id when multiple active runs share the same target conversation" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()

      run1 = create_agent_run(parent_conv, child_conv, request_id: "req-a")
      run2 = create_agent_run(parent_conv, child_conv, request_id: "req-b")

      agent =
        build_agent(child_conv.id, %{
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "Result for req-b",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        })

      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: "req-b"})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      {:ok, updated_run1} = Magus.Agents.get_agent_run(run1.id, authorize?: false)
      {:ok, updated_run2} = Magus.Agents.get_agent_run(run2.id, authorize?: false)

      assert updated_run1.status == :pending
      assert updated_run2.status == :complete
      assert updated_run2.result_text == "Result for req-b"
    end

    test "does not complete any run when request_id is missing and multiple runs are active" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()

      run1 = create_agent_run(parent_conv, child_conv, request_id: "req-a")
      run2 = create_agent_run(parent_conv, child_conv, request_id: "req-b")

      agent =
        build_agent(child_conv.id, %{
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "Ambiguous completion",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        })

      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      {:ok, updated_run1} = Magus.Agents.get_agent_run(run1.id, authorize?: false)
      {:ok, updated_run2} = Magus.Agents.get_agent_run(run2.id, authorize?: false)

      assert updated_run1.status == :pending
      assert updated_run2.status == :pending
    end
  end

  # ============================================================================
  # ai.request.failed — task conversations
  # ============================================================================

  describe "handle_signal/2 with ai.request.failed for task conversations" do
    test "marks AgentRun as failed with error message" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent = build_agent(child_conv.id)
      context = build_context(agent)
      signal = make_signal("ai.request.failed", %{error: "LLM provider error"})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :error
      assert updated_run.error_message == "LLM provider error"
      assert updated_run.completed_at != nil
    end

    test "handles atom error values" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent = build_agent(child_conv.id)
      context = build_context(agent)
      signal = make_signal("ai.request.failed", %{error: :timeout})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :error
      assert updated_run.error_message == ":timeout"
    end

    test "handles string-keyed error data" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent = build_agent(child_conv.id)
      context = build_context(agent)
      signal = make_signal("ai.request.failed", %{"error" => "Rate limited"})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :error
      assert updated_run.error_message == "Rate limited"
    end

    test "handles nil error gracefully" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent = build_agent(child_conv.id)
      context = build_context(agent)
      signal = make_signal("ai.request.failed", %{})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :error
      assert updated_run.error_message == "nil"
    end
  end

  # ============================================================================
  # Task result_summary update
  # ============================================================================

  describe "handle_signal/2 task result_summary update" do
    test "updates task result_summary when run has a task_id" do
      {user, parent_conv, child_conv} = create_parent_and_child_conversations()

      orchestrator = custom_agent(user, %{name: "Orchestrator"})
      worker = custom_agent(user, %{name: "Worker"})

      {:ok, task} =
        Magus.Plan.create_task(
          parent_conv.id,
          %{
            title: "Research task",
            assigned_to_custom_agent_id: worker.id,
            assigned_by_custom_agent_id: orchestrator.id
          },
          actor: user
        )

      run =
        create_agent_run(parent_conv, child_conv, task_id: task.id)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent =
        build_agent(child_conv.id, %{
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "Research complete: Elixir concurrency is great.",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        })

      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      {:ok, updated_task} = Magus.Plan.get_task(task.id, authorize?: false)
      assert updated_task.result_summary == "Research complete: Elixir concurrency is great."
      assert updated_task.status == :done
    end

    test "truncates result_summary to 2000 characters" do
      {user, parent_conv, child_conv} = create_parent_and_child_conversations()

      orchestrator = custom_agent(user, %{name: "Orchestrator"})
      worker = custom_agent(user, %{name: "Worker"})

      {:ok, task} =
        Magus.Plan.create_task(
          parent_conv.id,
          %{
            title: "Long result task",
            assigned_to_custom_agent_id: worker.id,
            assigned_by_custom_agent_id: orchestrator.id
          },
          actor: user
        )

      run = create_agent_run(parent_conv, child_conv, task_id: task.id)
      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      long_text = String.duplicate("a", 3000)

      agent =
        build_agent(child_conv.id, %{
          __strategy__: %{
            active_request_id: nil,
            streaming_text: long_text,
            streaming_thinking: "",
            pending_tool_calls: []
          }
        })

      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      {:ok, updated_task} = Magus.Plan.get_task(task.id, authorize?: false)
      assert String.length(updated_task.result_summary) == 2000
    end

    test "does not update task when result_text is empty" do
      {user, parent_conv, child_conv} = create_parent_and_child_conversations()

      orchestrator = custom_agent(user, %{name: "Orchestrator"})
      worker = custom_agent(user, %{name: "Worker"})

      {:ok, task} =
        Magus.Plan.create_task(
          parent_conv.id,
          %{
            title: "Empty result task",
            assigned_to_custom_agent_id: worker.id,
            assigned_by_custom_agent_id: orchestrator.id
          },
          actor: user
        )

      run = create_agent_run(parent_conv, child_conv, task_id: task.id)
      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent = build_agent(child_conv.id)
      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      {:ok, updated_task} = Magus.Plan.get_task(task.id, authorize?: false)
      assert updated_task.result_summary == nil
    end

    test "does not update task when run has no task_id" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)
      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent =
        build_agent(child_conv.id, %{
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "Some result.",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        })

      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      # Should succeed without error — no task to update
      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)
    end
  end

  # ============================================================================
  # Non-task conversations (no active AgentRun)
  # ============================================================================

  describe "handle_signal/2 for non-task conversations" do
    test "does nothing for ai.request.completed when no AgentRun exists" do
      agent = build_agent(Ash.UUID.generate())
      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{result: "Normal completion"})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "does nothing for ai.request.failed when no AgentRun exists" do
      agent = build_agent(Ash.UUID.generate())
      context = build_context(agent)
      signal = make_signal("ai.request.failed", %{error: "Normal failure"})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "does nothing when conversation_id is nil" do
      agent = %{id: "conv:unknown", state: %{}}
      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{result: "Done"})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end
  end

  # ============================================================================
  # Passthrough for unrelated signals
  # ============================================================================

  describe "handle_signal/2 with unrelated signals" do
    test "passes through unrecognized signal types" do
      agent = build_agent("some-conv-id")
      context = build_context(agent)
      signal = make_signal("ai.llm.delta", %{delta: "hello"})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "passes through message.user signals" do
      agent = build_agent("some-conv-id")
      context = build_context(agent)
      signal = make_signal("message.user", %{text: "Hello"})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "passes through orchestration signals" do
      agent = build_agent("some-conv-id")
      context = build_context(agent)
      signal = make_signal("agent.task.spawned", %{task_id: "t-1"})

      result = AgentRunCompletionPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end
  end

  # ============================================================================
  # Side effects: PubSub broadcasts and message persistence
  # ============================================================================

  describe "handle_signal/2 side effects" do
    test "broadcasts run.completed to source conversation PubSub" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      # Subscribe to the parent (source) conversation's PubSub topic
      MagusWeb.Endpoint.subscribe("agents:#{parent_conv.id}")

      agent =
        build_agent(child_conv.id, %{
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "The answer is 42",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        })

      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "run.completed", result_text: result_text}
      }

      assert result_text =~ "The answer is 42"
    end

    test "persists response message in source conversation" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv, kind: :delegate)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent =
        build_agent(child_conv.id, %{
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "Research complete: Elixir is great.",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        })

      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      # Query messages in the source (parent) conversation
      {:ok, messages} = Magus.Chat.message_history(parent_conv.id, authorize?: false)

      agent_messages = Enum.filter(messages, &(&1.role == :agent))
      assert length(agent_messages) >= 1

      persisted = Enum.find(agent_messages, &(&1.text =~ "Research complete: Elixir is great."))
      assert persisted != nil
      assert persisted.complete == true
    end

    test "broadcasts run.failed on failure" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      # Subscribe to the parent (source) conversation's PubSub topic
      MagusWeb.Endpoint.subscribe("agents:#{parent_conv.id}")

      agent = build_agent(child_conv.id)
      context = build_context(agent)
      signal = make_signal("ai.request.failed", %{error: "LLM timeout"})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "run.failed", error: error_text}
      }

      assert error_text =~ "LLM timeout"
    end

    test "creates error event message in source conversation on failure" do
      {_user, parent_conv, child_conv} = create_parent_and_child_conversations()
      run = create_agent_run(parent_conv, child_conv)

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      agent = build_agent(child_conv.id)
      context = build_context(agent)
      signal = make_signal("ai.request.failed", %{error: "LLM timeout"})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      # Query messages in the source (parent) conversation
      {:ok, messages} = Magus.Chat.message_history(parent_conv.id, authorize?: false)

      event_messages = Enum.filter(messages, &(&1.message_type == :event))
      assert length(event_messages) >= 1

      error_event = Enum.find(event_messages, &(&1.text =~ "Run failed"))
      assert error_event != nil
      assert error_event.text =~ "LLM timeout"
    end
  end

  # ============================================================================
  # Subtask completion mutates spawn tool message output (Task 4)
  # ============================================================================

  describe "subtask completion mutates spawn tool message output" do
    test "complete run replaces tool_call_data.output with terminal payload" do
      user = generate(user())
      parent_conv = generate(conversation(actor: user))

      child_conv =
        generate(
          conversation(
            actor: user,
            is_task_conversation: true,
            parent_conversation_id: parent_conv.id
          )
        )

      spawn_event_id = Ash.UUID.generate()

      Magus.Chat.upsert_event_message!(
        spawn_event_id,
        "Spawning sub-agent...",
        parent_conv.id,
        %{
          "id" => spawn_event_id,
          "tool_use_id" => "tu_test_1",
          "tool_name" => "spawn_sub_agent",
          "display_name" => "Sub-agent",
          "inputs" => %{"objective" => "research news"},
          "output" => %{
            "status" => "spawning",
            "task_id" => "stub",
            "objective" => "research news"
          },
          "output_summary" => "Sub-agent spawning: research news",
          "status" => "spawning"
        },
        true,
        authorize?: false
      )

      {:ok, run} =
        Magus.Agents.create_agent_run(
          %{
            kind: :subtask,
            source: :sub_agent_spawn,
            source_conversation_id: parent_conv.id,
            source_event_id: spawn_event_id,
            target_conversation_id: child_conv.id,
            objective: "research news",
            model_key: "openrouter:anthropic/claude-sonnet-4",
            metadata: %{"agent_name" => "researcher"},
            request_id: "subtask:test-#{System.unique_integer([:positive])}"
          },
          authorize?: false
        )

      {:ok, started} = Magus.Agents.start_agent_run(run, authorize?: false)

      {:ok, completed} =
        Magus.Agents.complete_agent_run(started, %{result_text: "All done."}, authorize?: false)

      Magus.Agents.Plugins.AgentRunCompletionPlugin.handle_run_completed(completed)

      {:ok, refreshed} = Magus.Chat.get_message(spawn_event_id, authorize?: false)
      output = refreshed.tool_call_data["output"]

      assert output["status"] == "complete"
      assert output["task_id"] == to_string(completed.id)
      assert output["result_text"] == "All done."
      assert output["agent_name"] == "researcher"
      assert output["objective"] == "research news"
    end

    test "failed run sets status: error and error_message in output" do
      user = generate(user())
      parent_conv = generate(conversation(actor: user))

      child_conv =
        generate(
          conversation(
            actor: user,
            is_task_conversation: true,
            parent_conversation_id: parent_conv.id
          )
        )

      spawn_event_id = Ash.UUID.generate()

      Magus.Chat.upsert_event_message!(
        spawn_event_id,
        "Spawning sub-agent...",
        parent_conv.id,
        %{
          "id" => spawn_event_id,
          "tool_use_id" => "tu_test_2",
          "tool_name" => "spawn_sub_agent",
          "display_name" => "Sub-agent",
          "inputs" => %{"objective" => "x"},
          "output" => %{"status" => "spawning"},
          "output_summary" => "x",
          "status" => "spawning"
        },
        true,
        authorize?: false
      )

      {:ok, run} =
        Magus.Agents.create_agent_run(
          %{
            kind: :subtask,
            source: :sub_agent_spawn,
            source_conversation_id: parent_conv.id,
            source_event_id: spawn_event_id,
            target_conversation_id: child_conv.id,
            objective: "x",
            model_key: "openrouter:anthropic/claude-sonnet-4",
            request_id: "subtask:test-#{System.unique_integer([:positive])}"
          },
          authorize?: false
        )

      {:ok, started} = Magus.Agents.start_agent_run(run, authorize?: false)

      {:ok, failed} =
        Magus.Agents.fail_agent_run(started, %{error_message: "boom"}, authorize?: false)

      Magus.Agents.Plugins.AgentRunCompletionPlugin.handle_run_failed(failed)

      {:ok, refreshed} = Magus.Chat.get_message(spawn_event_id, authorize?: false)
      output = refreshed.tool_call_data["output"]

      assert output["status"] == "error"
      assert output["error_message"] == "boom"
    end
  end

  # ============================================================================
  # Post-completion: linked inbox events + heartbeat schedule fallback (Task 17)
  # ============================================================================

  describe "post-completion behavior" do
    setup do
      user = generate(user())

      agent =
        custom_agent(user, %{
          heartbeat_default_interval_minutes: 60,
          next_scheduled_at: nil
        })

      conv = generate(conversation(actor: user))
      %{user: user, agent: agent, conv: conv}
    end

    test "resolves linked inbox events when run completes via handle_run_completed",
         %{user: user, agent: agent, conv: conv} do
      run =
        sub_agent_run(
          source_conversation_id: conv.id,
          target_conversation_id: conv.id,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          source: :heartbeat,
          kind: :delegate
        )

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :content,
            urgency: :deferred,
            title: "Linked",
            source_type: :integration
          },
          actor: user
        )

      {:ok, _} = Magus.Agents.link_event_to_run(event, run.id, actor: user)

      AgentRunCompletionPlugin.handle_run_completed(run)

      reloaded = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, actor: user)
      assert reloaded.status == :resolved
      assert reloaded.resolved_by == :run_completed
    end

    test "clears agent_run_id on linked events when run fails via handle_run_failed",
         %{user: user, agent: agent, conv: conv} do
      run =
        sub_agent_run(
          source_conversation_id: conv.id,
          target_conversation_id: conv.id,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          source: :heartbeat,
          kind: :delegate
        )

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :content,
            urgency: :deferred,
            title: "Linked",
            source_type: :integration
          },
          actor: user
        )

      {:ok, _} = Magus.Agents.link_event_to_run(event, run.id, actor: user)

      AgentRunCompletionPlugin.handle_run_failed(run, "boom")

      reloaded = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, actor: user)
      assert reloaded.status == :pending
      assert reloaded.agent_run_id == nil
    end

    test "sets next_scheduled_at to default interval when not set during heartbeat run",
         %{user: user, agent: agent, conv: conv} do
      run =
        sub_agent_run(
          source_conversation_id: conv.id,
          target_conversation_id: conv.id,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          source: :heartbeat,
          kind: :delegate
        )

      before_at = DateTime.utc_now()

      AgentRunCompletionPlugin.handle_run_completed(run)

      reloaded = Magus.Agents.get_custom_agent!(agent.id, actor: user)
      expected = DateTime.add(before_at, 60 * 60, :second)
      assert reloaded.next_scheduled_at != nil
      diff = DateTime.diff(reloaded.next_scheduled_at, expected, :second)
      assert abs(diff) < 5
    end

    test "respects existing next_scheduled_at if set during the run",
         %{user: user, agent: agent, conv: conv} do
      custom =
        DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:microsecond)

      {:ok, _} = Magus.Agents.set_custom_agent_next_scheduled_at(agent, custom, actor: user)

      run =
        sub_agent_run(
          source_conversation_id: conv.id,
          target_conversation_id: conv.id,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          source: :heartbeat,
          kind: :delegate
        )

      AgentRunCompletionPlugin.handle_run_completed(run)

      reloaded = Magus.Agents.get_custom_agent!(agent.id, actor: user)
      diff = DateTime.diff(reloaded.next_scheduled_at, custom, :second)
      assert abs(diff) < 5
    end

    test "does not advance schedule for :manual_trigger runs",
         %{user: user, agent: agent, conv: conv} do
      run =
        sub_agent_run(
          source_conversation_id: conv.id,
          target_conversation_id: conv.id,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          source: :manual_trigger,
          kind: :delegate
        )

      AgentRunCompletionPlugin.handle_run_completed(run)

      reloaded = Magus.Agents.get_custom_agent!(agent.id, actor: user)
      assert reloaded.next_scheduled_at == nil
    end
  end
end
