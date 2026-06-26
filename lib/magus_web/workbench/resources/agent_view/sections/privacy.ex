defmodule MagusWeb.Workbench.Resources.AgentView.Sections.Privacy do
  @moduledoc """
  Privacy & Isolation agent settings section, ported from AgentPrivacyLive.
  """
  use MagusWeb, :live_component

  use Gettext, backend: MagusWeb.Gettext

  alias AshPhoenix.Form

  @impl true
  def update(%{agent: agent, current_user: current_user} = assigns, socket) do
    form =
      agent
      |> Form.for_update(:update, actor: current_user, forms: [auto?: true])
      |> to_form()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, form)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div data-section="privacy" class="p-4">
      <.form for={@form} phx-change="validate" phx-submit="save" phx-target={@myself}>
        <.content_card
          title={gettext("Privacy & Isolation")}
          icon="lucide-shield"
          subtitle={
            gettext(
              "Control what data this agent can access. Disable these for agents exposed to third parties via integrations."
            )
          }
        >
          <div class="space-y-3">
            <.input
              field={@form[:can_read_global_memories]}
              type="checkbox"
              label={gettext("Access global memories")}
            />
            <.input
              field={@form[:can_write_global_memories]}
              type="checkbox"
              label={gettext("Contribute to global memories")}
            />
            <.input
              field={@form[:can_access_global_files]}
              type="checkbox"
              label={gettext("Access global files")}
            />
          </div>
        </.content_card>

        <div class="flex justify-end mt-6">
          <button
            type="submit"
            class="btn btn-primary btn-sm"
            phx-disable-with={gettext("Saving...")}
          >
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form =
      socket.assigns.form.source
      |> Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, gettext("Privacy settings saved"))}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end
end
