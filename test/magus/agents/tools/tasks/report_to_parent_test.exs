defmodule Magus.Agents.Tools.Tasks.ReportToParentTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Tasks.ReportToParent

  require Ash.Query

  setup do
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

    # Create a running AgentRun linking parent → child
    run =
      sub_agent_run(
        source_conversation_id: parent.id,
        target_conversation_id: child.id,
        objective: "Research cheap flights",
        metadata: %{"agent_name" => "travel-researcher"}
      )

    {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

    context = %{
      conversation_id: child.id
    }

    %{user: user, parent: parent, child: child, run: run, context: context}
  end

  describe "schema" do
    test "has the correct action name" do
      assert ReportToParent.name() == "report_to_parent"
    end
  end

  describe "display_name/0 and summarize_output/1" do
    test "display_name returns expected string" do
      assert ReportToParent.display_name() == "Reporting to parent..."
    end

    test "summarize_output with reported: true" do
      assert ReportToParent.summarize_output(%{reported: true}) == "Progress reported"
    end

    test "summarize_output with unknown shape" do
      assert ReportToParent.summarize_output(%{}) == "Completed"
    end
  end

  describe "run/2" do
    test "broadcasts progress to parent conversation via PubSub", %{
      context: context,
      parent: parent
    } do
      # Subscribe to the parent conversation's PubSub topic
      MagusWeb.Endpoint.subscribe("agents:#{parent.id}")

      {:ok, result} =
        ReportToParent.run(
          %{"status" => "Found 3 cheap flights under $400"},
          context
        )

      assert result.reported == true
      assert result.status == "Found 3 cheap flights under $400"

      # Verify the PubSub broadcast was received
      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{
          type: "tool.progress",
          tool_name: "sub_agent",
          progress_type: :progress_report,
          data: data
        }
      }

      assert data.status == "Found 3 cheap flights under $400"
      assert data.objective == "Research cheap flights"
      assert data.agent_name == "travel-researcher"
    end

    test "includes progress_percent when provided", %{context: context, parent: parent} do
      MagusWeb.Endpoint.subscribe("agents:#{parent.id}")

      {:ok, result} =
        ReportToParent.run(
          %{"status" => "Halfway done", "progress_percent" => 50},
          context
        )

      assert result.reported == true

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{
          type: "tool.progress",
          data: data
        }
      }

      assert data.progress_percent == 50
    end

    test "updates heartbeat on the AgentRun", %{context: context, run: run} do
      heartbeat_before = run.last_heartbeat_at

      # Small delay to ensure timestamp differs
      Process.sleep(10)

      {:ok, _result} =
        ReportToParent.run(
          %{"status" => "Still working"},
          context
        )

      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert DateTime.compare(updated_run.last_heartbeat_at, heartbeat_before) == :gt
    end

    test "returns error when not running as a sub-agent task", %{user: user} do
      orphan = generate(conversation(actor: user))

      context = %{
        conversation_id: orphan.id
      }

      {:ok, result} =
        ReportToParent.run(%{"status" => "No parent"}, context)

      assert result.error == "Not running as a sub-agent task"
    end

    test "returns error when missing required context" do
      {:ok, result} =
        ReportToParent.run(%{"status" => "Test"}, %{})

      assert result.error =~ "Missing required context"
    end
  end
end
