defmodule MagusWeb.Workbench.Resources.AgentView.Sections.Integrations do
  @moduledoc """
  Integrations agent settings section. Wraps the existing IntegrationsSectionComponent
  inside the workbench edit pane. handle_info delegates from the parent AgentView.
  """
  use MagusWeb, :live_component

  @impl true
  def update(%{agent: agent} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:agent_id, agent.id)}
  end

  def update(%{wizard_event: event} = assigns, socket) do
    case event do
      :complete ->
        send_update(MagusWeb.AgentsLive.Components.IntegrationsSectionComponent,
          id: "integrations-section-inner",
          wizard_event: :complete,
          integration: assigns[:integration]
        )

      :closed ->
        send_update(MagusWeb.AgentsLive.Components.IntegrationsSectionComponent,
          id: "integrations-section-inner",
          wizard_event: :closed
        )
    end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div data-section="integrations" class="p-4">
      <.live_component
        module={MagusWeb.AgentsLive.Components.IntegrationsSectionComponent}
        id="integrations-section-inner"
        agent_id={@agent_id}
        current_user={@current_user}
      />
    </div>
    """
  end
end
