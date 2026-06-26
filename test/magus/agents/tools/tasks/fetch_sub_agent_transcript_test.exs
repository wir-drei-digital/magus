defmodule Magus.Agents.Tools.Tasks.FetchSubAgentTranscriptTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Tasks.FetchSubAgentTranscript
  alias Magus.Agents.Support.AiAgent

  defp insert_run(parent_conv_id, child_conv_id) do
    {:ok, run} =
      Magus.Agents.create_agent_run(
        %{
          kind: :subtask,
          source: :sub_agent_spawn,
          source_conversation_id: parent_conv_id,
          target_conversation_id: child_conv_id,
          objective: "x",
          model_key: "k",
          request_id: "subtask:#{Ash.UUID.generate()}",
          metadata: %{}
        },
        authorize?: false
      )

    run
  end

  defp create_agent_message(conv_id, text) do
    Magus.Chat.Message
    |> Ash.Changeset.for_create(:upsert_response, %{
      id: Ash.UUIDv7.generate(),
      text: text,
      conversation_id: conv_id,
      complete: true
    })
    |> Ash.create!(actor: %AiAgent{})
  end

  describe "happy path" do
    test "returns messages and tools sections" do
      user = generate(user())
      parent = generate(conversation(actor: user))

      child =
        generate(
          conversation(
            actor: user,
            is_task_conversation: true,
            parent_conversation_id: parent.id
          )
        )

      run = insert_run(parent.id, child.id)

      # Insert one agent message
      create_agent_message(child.id, "Hello world")

      # Insert one tool event message
      Magus.Chat.upsert_event_message!(
        Ash.UUID.generate(),
        "Tool ran",
        child.id,
        %{
          "tool_name" => "web_search",
          "display_name" => "Web Search",
          "inputs" => %{"q" => "magus"},
          "output" => %{"results" => 3},
          "output_summary" => "3 hits",
          "status" => "complete"
        },
        true,
        authorize?: false
      )

      {:ok, result} =
        FetchSubAgentTranscript.run(
          %{"task_id" => to_string(run.id), "include" => [:messages, :tools]},
          %{conversation_id: parent.id, user_id: user.id}
        )

      assert result.task_id == to_string(run.id)
      assert is_list(result.messages)
      assert is_list(result.tools)
      assert Enum.any?(result.messages, &(&1.text == "Hello world"))
      assert Enum.any?(result.tools, &(&1.tool_name == "web_search"))
    end

    test "accepts string include values from raw LLM JSON" do
      user = generate(user())
      parent = generate(conversation(actor: user))

      child =
        generate(
          conversation(
            actor: user,
            is_task_conversation: true,
            parent_conversation_id: parent.id
          )
        )

      run = insert_run(parent.id, child.id)
      create_agent_message(child.id, "Hello world")

      {:ok, result} =
        FetchSubAgentTranscript.run(
          %{"task_id" => to_string(run.id), "include" => ["messages", "tools"]},
          %{conversation_id: parent.id, user_id: user.id}
        )

      assert is_list(result.messages)
      assert is_list(result.tools)
      assert Enum.any?(result.messages, &(&1.text == "Hello world"))
    end
  end

  describe "authorization" do
    test "rejects task_id from a different conversation" do
      user = generate(user())
      conv_a = generate(conversation(actor: user))
      conv_b = generate(conversation(actor: user))

      child =
        generate(
          conversation(
            actor: user,
            is_task_conversation: true,
            parent_conversation_id: conv_a.id
          )
        )

      run = insert_run(conv_a.id, child.id)

      assert {:ok, %{error: msg}} =
               FetchSubAgentTranscript.run(
                 %{"task_id" => to_string(run.id), "include" => [:messages]},
                 %{conversation_id: conv_b.id, user_id: user.id}
               )

      assert msg =~ "not found"
    end
  end

  describe "tail capping" do
    test "limits messages section to last N items" do
      user = generate(user())
      parent = generate(conversation(actor: user))

      child =
        generate(
          conversation(
            actor: user,
            is_task_conversation: true,
            parent_conversation_id: parent.id
          )
        )

      run = insert_run(parent.id, child.id)

      Enum.each(1..10, fn i ->
        create_agent_message(child.id, "msg#{i}")
      end)

      {:ok, result} =
        FetchSubAgentTranscript.run(
          %{"task_id" => to_string(run.id), "include" => [:messages], "tail" => 3},
          %{conversation_id: parent.id, user_id: user.id}
        )

      assert length(result.messages) == 3
    end
  end
end
