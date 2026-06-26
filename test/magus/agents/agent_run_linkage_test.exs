defmodule Magus.Agents.AgentRunLinkageTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  setup do
    user = generate(user())
    parent = generate(conversation(actor: user))

    %{user: user, parent: parent}
  end

  describe "create with task_id" do
    test "stores task_id on the run", %{parent: parent} do
      task_id = Ash.UUIDv7.generate()

      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          task_id: task_id
        )

      assert run.task_id == task_id
    end

    test "task_id is nil by default", %{parent: parent} do
      run = sub_agent_run(source_conversation_id: parent.id)

      assert is_nil(run.task_id)
    end
  end

  describe "create with event_id" do
    test "stores event_id on the run", %{parent: parent, user: user} do
      agent = custom_agent(user)

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            title: "Test mention",
            source_type: :conversation
          },
          actor: user
        )

      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          event_id: event.id
        )

      assert run.event_id == event.id
    end

    test "event_id is nil by default", %{parent: parent} do
      run = sub_agent_run(source_conversation_id: parent.id)

      assert is_nil(run.event_id)
    end
  end

  describe "create with both task_id and event_id" do
    test "stores both fields together", %{parent: parent, user: user} do
      task_id = Ash.UUIDv7.generate()
      agent = custom_agent(user)

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :task_assigned,
            title: "Task assigned",
            source_type: :agent
          },
          actor: user
        )

      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          task_id: task_id,
          event_id: event.id
        )

      assert run.task_id == task_id
      assert run.event_id == event.id
    end
  end
end
