defmodule MagusWeb.Workbench.Resources.AgentView.Sections.Knowledge do
  @moduledoc """
  Knowledge agent settings section. Wraps the agent attachments component and
  the KnowledgeSectionComponent inside the workbench edit pane.
  """
  use MagusWeb, :live_component

  @impl true
  def update(%{agent: agent, current_user: current_user} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:agent_id, agent.id)
     |> assign(:user_id, current_user.id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div data-section="knowledge" class="p-4 space-y-6">
      <.live_component
        module={MagusWeb.AgentsLive.Components.AgentAttachmentsComponent}
        id="agent-attachments"
        custom_agent_id={@agent_id}
        current_user={@current_user}
      />

      <.live_component
        module={MagusWeb.AgentsLive.Components.KnowledgeSectionComponent}
        id="knowledge-section"
        custom_agent_id={@agent_id}
        user_id={@user_id}
        current_user={@current_user}
      />
    </div>
    """
  end
end
