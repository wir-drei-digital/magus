defmodule Magus.Agents.Tools.ToolBuilderAttachedDocsTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.ToolBuilder
  alias Magus.Agents.Tools.Files.SearchAttachedDocs

  setup do
    user = generate(user())
    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    agent = custom_agent(user)
    {:ok, conv} = Magus.Chat.create_conversation(%{custom_agent_id: agent.id}, actor: user)
    conv = Ash.load!(conv, [:custom_agent, :user], actor: user)
    %{user: user, agent: agent, conversation: conv}
  end

  test "does not include SearchAttachedDocs when agent has no :search attachments",
       %{conversation: conv, agent: agent} do
    {tools, _ctx} = ToolBuilder.build_tools(:chat, conv, true, nil, agent, [])
    refute SearchAttachedDocs in tools
  end

  test "includes SearchAttachedDocs when at least one :search attachment exists",
       %{user: user, conversation: conv, agent: agent} do
    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "M.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "tmp/m.pdf"
        },
        actor: user
      )

    {:ok, _} =
      Magus.Agents.create_attachment(
        %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
        actor: user
      )

    {tools, _ctx} = ToolBuilder.build_tools(:chat, conv, true, nil, agent, [])
    assert SearchAttachedDocs in tools
  end
end
