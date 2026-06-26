defmodule Magus.Agents.CustomAgentDestroyCleanupTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  setup do
    user = generate(user())
    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    agent = custom_agent(user)
    %{user: user, agent: agent}
  end

  test "deletes files uploaded via this agent that are not attached elsewhere",
       %{user: user, agent: agent} do
    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "Internal.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "tmp/i.pdf",
          uploaded_via_agent_id: agent.id
        },
        actor: user
      )

    {:ok, _} =
      Magus.Agents.create_attachment(
        %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
        actor: user
      )

    :ok = Magus.Agents.destroy_custom_agent(agent, actor: user)

    assert {:error, _} = Magus.Files.get_file(file.id, actor: user)
  end

  test "preserves files picked from existing files (uploaded_via_agent_id == nil)",
       %{user: user, agent: agent} do
    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "Shared.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "tmp/s.pdf"
        },
        actor: user
      )

    {:ok, _} =
      Magus.Agents.create_attachment(
        %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
        actor: user
      )

    :ok = Magus.Agents.destroy_custom_agent(agent, actor: user)

    assert {:ok, _} = Magus.Files.get_file(file.id, actor: user)
  end

  test "preserves files uploaded via this agent if attached to another agent",
       %{user: user, agent: agent} do
    other_agent = custom_agent(user)

    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "Reused.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "tmp/r.pdf",
          uploaded_via_agent_id: agent.id
        },
        actor: user
      )

    {:ok, _} =
      Magus.Agents.create_attachment(
        %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
        actor: user
      )

    {:ok, _} =
      Magus.Agents.create_attachment(
        %{custom_agent_id: other_agent.id, file_id: file.id, mode: :search},
        actor: user
      )

    :ok = Magus.Agents.destroy_custom_agent(agent, actor: user)

    assert {:ok, _} = Magus.Files.get_file(file.id, actor: user)
  end
end
