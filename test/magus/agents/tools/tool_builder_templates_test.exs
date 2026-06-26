defmodule Magus.Agents.Tools.ToolBuilderTemplatesTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.ToolBuilder
  alias Magus.Agents.Tools.Files.ListWorkspaceTemplates

  test "ListWorkspaceTemplates is in the main tool list" do
    user = generate(user())
    agent = custom_agent(user)
    conv = generate(conversation(actor: user, custom_agent_id: agent.id))

    {tools, _ctx} =
      ToolBuilder.build_tools(:chat, %{conv | custom_agent: agent}, true, nil, agent, [])

    assert ListWorkspaceTemplates in tools
  end
end
