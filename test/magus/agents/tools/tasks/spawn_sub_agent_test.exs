defmodule Magus.Agents.Tools.Tasks.SpawnSubAgentTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Tasks.SpawnSubAgent

  require Ash.Query

  setup do
    user = generate(user())
    conversation = generate(conversation(actor: user))
    user = Ash.load!(user, [], authorize?: false)

    context = %{
      conversation_id: conversation.id,
      user_id: user.id,
      user: user
    }

    %{user: user, conversation: conversation, context: context}
  end

  describe "run/2" do
    test "creates child conversation with parent link (inline mode)", %{
      context: context,
      conversation: parent
    } do
      {:ok, result} =
        SpawnSubAgent.run(
          %{"objective" => "Review this code for bugs"},
          context
        )

      assert result.status == "spawning"
      assert result.objective == "Review this code for bugs"
      assert is_binary(result.task_id)
      assert is_binary(result.target_conversation_id)

      # Verify child conversation was created
      child_convs =
        Magus.Chat.Conversation
        |> Ash.Query.filter(parent_conversation_id == ^parent.id and is_task_conversation == true)
        |> Ash.read!(authorize?: false)

      assert length(child_convs) >= 1
      child = hd(child_convs)
      assert child.is_task_conversation == true
      assert child.parent_conversation_id == parent.id
      assert result.target_conversation_id == to_string(child.id)
    end

    test "creates AgentRun record", %{context: context, conversation: parent} do
      {:ok, result} =
        SpawnSubAgent.run(
          %{"objective" => "Analyze performance"},
          context
        )

      {:ok, runs} =
        Magus.Agents.running_agent_runs(parent.id, authorize?: false)

      assert length(runs) >= 1
      run = hd(runs)
      assert run.objective == "Analyze performance"
      assert run.status == :pending
      assert run.source_conversation_id == parent.id

      # task_id in return value should match the run record
      assert result.task_id == to_string(run.id)
    end

    test "uses provided model_key in inline mode", %{context: context, conversation: parent} do
      {:ok, result} =
        SpawnSubAgent.run(
          %{
            "objective" => "Second opinion",
            "model_key" => "openrouter:google/gemini-2.5-pro"
          },
          context
        )

      assert result.model == "openrouter:google/gemini-2.5-pro"

      {:ok, runs} = Magus.Agents.running_agent_runs(parent.id, authorize?: false)
      run = hd(runs)
      assert run.model_key == "openrouter:google/gemini-2.5-pro"
    end

    test "respects concurrency limit of 3", %{context: context, conversation: parent} do
      # Create 3 running sub-agent runs
      for _i <- 1..3 do
        run = sub_agent_run(source_conversation_id: parent.id)
        Magus.Agents.start_agent_run(run, authorize?: false)
      end

      {:ok, result} =
        SpawnSubAgent.run(
          %{"objective" => "This should fail"},
          context
        )

      assert result.error =~ "Maximum"
    end

    test "returns error with missing context fields" do
      {:ok, result} =
        SpawnSubAgent.run(
          %{"objective" => "Test"},
          %{}
        )

      assert result.error
    end

    test "spawns with custom_agent_id", %{context: context, user: user} do
      # Create a custom agent to use
      {:ok, custom_agent} =
        Magus.Agents.create_custom_agent(
          %{name: "My Custom Agent", instructions: "Be helpful"},
          actor: user
        )

      {:ok, result} =
        SpawnSubAgent.run(
          %{
            "objective" => "Do work",
            "target_agent_id" => to_string(custom_agent.id)
          },
          context
        )

      assert result.status == "spawning"
      assert result.agent_name == "My Custom Agent"
    end

    test "inline mode works with system_prompt", %{context: context} do
      {:ok, result} =
        SpawnSubAgent.run(
          %{"objective" => "Quick task", "system_prompt" => "Be concise"},
          context
        )

      assert result.status == "spawning"
    end

    test "child conversation inherits workspace_id from tool context", %{user: user} do
      ensure_workspace_plan(user)

      workspace =
        Magus.Workspaces.create_workspace!(
          %{name: "Test WS", slug: "test-ws-#{System.unique_integer([:positive])}"},
          actor: user
        )

      parent =
        Magus.Chat.create_conversation!(
          %{title: "Parent", workspace_id: workspace.id},
          actor: user
        )

      context = %{
        conversation_id: parent.id,
        user_id: user.id,
        user: user,
        workspace_id: workspace.id
      }

      assert {:ok, result} = SpawnSubAgent.run(%{"objective" => "summarize something"}, context)
      assert result.status == "spawning"

      child =
        Magus.Chat.Conversation
        |> Ash.Query.filter(parent_conversation_id == ^parent.id)
        |> Ash.read_one!(authorize?: false)

      assert child.workspace_id == workspace.id
    end

    test "child conversation has no workspace_id when context has none", %{
      context: context,
      conversation: parent
    } do
      assert {:ok, result} = SpawnSubAgent.run(%{"objective" => "summarize"}, context)
      assert result.status == "spawning"

      child =
        Magus.Chat.Conversation
        |> Ash.Query.filter(parent_conversation_id == ^parent.id)
        |> Ash.read_one!(authorize?: false)

      assert is_nil(child.workspace_id)
    end

    test "child conversation inherits parent's sandbox_conversation_id", %{
      context: context,
      conversation: parent
    } do
      {:ok, result} =
        SpawnSubAgent.run(
          %{"objective" => "Work in parent sandbox"},
          context
        )

      assert result.status == "spawning"

      # Fetch the child conversation
      child_convs =
        Magus.Chat.Conversation
        |> Ash.Query.filter(parent_conversation_id == ^parent.id and is_task_conversation == true)
        |> Ash.read!(authorize?: false)

      assert length(child_convs) >= 1
      child = hd(child_convs)

      # Parent has no sandbox_conversation_id, so child should inherit parent.id
      assert child.sandbox_conversation_id == parent.id
    end

    test "grandchild inherits root sandbox_conversation_id through chain", %{user: user} do
      # Create a "root" conversation (the grandparent)
      root = generate(conversation(actor: user, title: "Root"))

      # Create an intermediate parent that is itself a child (has sandbox_conversation_id pointing to root)
      intermediate =
        generate(
          conversation(
            actor: user,
            title: "Intermediate",
            is_task_conversation: true,
            parent_conversation_id: root.id,
            sandbox_conversation_id: root.id
          )
        )

      intermediate_context = %{
        conversation_id: intermediate.id,
        user_id: user.id,
        user: user
      }

      {:ok, result} =
        SpawnSubAgent.run(
          %{"objective" => "Grandchild task"},
          intermediate_context
        )

      assert result.status == "spawning"

      # Fetch the grandchild conversation
      grandchild_convs =
        Magus.Chat.Conversation
        |> Ash.Query.filter(
          parent_conversation_id == ^intermediate.id and is_task_conversation == true
        )
        |> Ash.read!(authorize?: false)

      assert length(grandchild_convs) >= 1
      grandchild = hd(grandchild_convs)

      # Grandchild should point to root, not intermediate
      assert grandchild.sandbox_conversation_id == root.id
    end
  end
end
