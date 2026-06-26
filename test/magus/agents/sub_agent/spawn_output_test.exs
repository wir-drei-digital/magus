defmodule Magus.Agents.SubAgent.SpawnOutputTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.SubAgent.SpawnOutput

  describe "build/2 — complete run" do
    test "returns terminal payload with result_text and metadata" do
      run = %Magus.Agents.AgentRun{
        id: "01H000000000000000000000RR",
        kind: :subtask,
        status: :complete,
        objective: "fetch news",
        result_text: "Here are the headlines.",
        target_conversation_id: nil,
        model_key: "openrouter:anthropic/claude-sonnet-4",
        duration_ms: 12_345,
        metadata: %{"agent_name" => "researcher"}
      }

      out = SpawnOutput.build(run, [])

      assert out.status == "complete"
      assert out.task_id == to_string(run.id)
      assert out.objective == "fetch news"
      assert out.result_text == "Here are the headlines."
      assert out.duration_ms == 12_345
      assert out.agent_name == "researcher"
      assert out.model == "openrouter:anthropic/claude-sonnet-4"
      assert out.files_created == []
      assert out.tools_used == []
      refute Map.has_key?(out, :error_message)
    end
  end

  describe "build/2 — error run" do
    test "includes error_message and omits result_text" do
      run = %Magus.Agents.AgentRun{
        id: "01H000000000000000000000EE",
        kind: :subtask,
        status: :error,
        objective: "fetch news",
        error_message: "boom",
        target_conversation_id: nil,
        model_key: "x",
        duration_ms: 1,
        metadata: %{}
      }

      out = SpawnOutput.build(run, [])

      assert out.status == "error"
      assert out.error_message == "boom"
      assert out.result_text in [nil, ""]
    end
  end
end
