defmodule MagusWeb.Admin.WorkspacesLive do
  @moduledoc """
  Admin view for managing workspaces and assigning plans.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts
  alias Magus.Workspaces.Workspace

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Workspaces")
      |> assign(:current_path, "/admin/workspaces")
      |> load_workspaces()

    {:ok, socket}
  end

  defp load_workspaces(socket) do
    workspaces = Magus.Workspaces.all_workspaces!(authorize?: false)
    assign(socket, :workspaces, workspaces)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Workspaces")
    |> assign(:workspace, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Ash.get(Workspace, id, authorize?: false, load: [:members]) do
      {:ok, workspace} ->
        form =
          workspace
          |> AshPhoenix.Form.for_update(:admin_update,
            actor: socket.assigns.current_user,
            authorize?: false,
            forms: [auto?: true]
          )
          |> to_form()

        socket
        |> assign(:page_title, "Edit #{workspace.name}")
        |> assign(:workspace, workspace)
        |> assign(:form, form)

      {:error, _} ->
        socket
        |> put_flash(:error, "Workspace not found")
        |> push_navigate(to: ~p"/admin/workspaces")
    end
  end

  # ============================================================================
  # Form Events
  # ============================================================================

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form.source, params)
    {:noreply, assign(socket, :form, to_form(form))}
  end

  @impl true
  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source,
           params: params,
           actor: socket.assigns.current_user
         ) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workspace updated successfully")
         |> push_navigate(to: ~p"/admin/workspaces")}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    case Ash.get(Workspace, id, authorize?: false) do
      {:ok, workspace} ->
        result =
          if workspace.is_active do
            Magus.Workspaces.deactivate_workspace(workspace,
              actor: socket.assigns.current_user,
              authorize?: false
            )
          else
            Magus.Workspaces.admin_update_workspace(workspace, %{is_active: true},
              actor: socket.assigns.current_user,
              authorize?: false
            )
          end

        case result do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Workspace #{if workspace.is_active, do: "deactivated", else: "activated"}"
             )
             |> load_workspaces()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update workspace")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Workspace not found")}
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    if assigns.live_action == :edit do
      render_form(assigns)
    else
      render_index(assigns)
    end
  end

  defp render_index(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-bold text-base-content">Workspaces</h1>
          <p class="text-base-content/60 text-sm mt-1">
            Manage workspaces and their configuration.
          </p>
        </div>

        <div class="card bg-base-200 border border-base-300 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="bg-base-300/50">
                  <th>Workspace</th>
                  <th class="text-center">Status</th>
                  <th class="text-center">Members</th>
                  <th>Owner</th>
                  <th class="text-center">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= if @workspaces == [] do %>
                  <tr>
                    <td colspan="5" class="text-center py-8 text-base-content/50">
                      No workspaces yet
                    </td>
                  </tr>
                <% else %>
                  <%= for ws <- @workspaces do %>
                    <tr class="hover:bg-base-300/30">
                      <td>
                        <div>
                          <span class="font-medium">{ws.name}</span>
                          <div class="text-xs text-base-content/50">
                            <code class="bg-base-300 px-1 py-0.5 rounded">{ws.slug}</code>
                          </div>
                        </div>
                      </td>
                      <td class="text-center">
                        <%= if ws.is_active do %>
                          <span class="badge badge-success badge-sm">Active</span>
                        <% else %>
                          <span class="badge badge-ghost badge-sm">Inactive</span>
                        <% end %>
                      </td>
                      <td class="text-center">
                        <span class="badge badge-sm badge-ghost">
                          {length(ws.members)}
                        </span>
                      </td>
                      <td class="text-sm">
                        {owner_email(ws)}
                      </td>
                      <td>
                        <div class="flex items-center justify-center gap-1">
                          <.link
                            navigate={~p"/admin/workspaces/#{ws.id}/edit"}
                            class="btn btn-ghost btn-xs"
                            title="Edit"
                          >
                            <.icon name="lucide-pencil" class="w-4 h-4" />
                          </.link>
                          <button
                            type="button"
                            phx-click="toggle_active"
                            phx-value-id={ws.id}
                            class="btn btn-ghost btn-xs"
                            title={if ws.is_active, do: "Deactivate", else: "Activate"}
                          >
                            <%= if ws.is_active do %>
                              <.icon name="lucide-pause" class="w-4 h-4" />
                            <% else %>
                              <.icon name="lucide-play" class="w-4 h-4" />
                            <% end %>
                          </button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  defp render_form(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center gap-4">
          <.link navigate={~p"/admin/workspaces"} class="btn btn-ghost btn-sm btn-circle">
            <.icon name="lucide-arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-2xl font-bold text-base-content">Edit {@workspace.name}</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Manage workspace configuration.
            </p>
          </div>
        </div>

        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-6">
              <%!-- Basic Info --%>
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Basic Information</h3>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 [&_.fieldset]:mb-0">
                  <.input field={@form[:name]} label="Name" />
                  <div>
                    <label class="label">
                      <span class="label-text">Slug</span>
                    </label>
                    <input
                      type="text"
                      value={@workspace.slug}
                      disabled
                      class="input input-bordered w-full opacity-50"
                    />
                  </div>
                </div>
              </div>

              <div class="divider"></div>

              <%!-- Status --%>
              <div class="[&_.fieldset]:mb-0">
                <.input
                  type="checkbox"
                  field={@form[:is_active]}
                  label="Workspace active"
                />
              </div>

              <%!-- Workspace Info (read-only) --%>
              <div class="border-t border-base-300 pt-4">
                <h3 class="text-lg font-semibold text-base-content mb-4">Info</h3>
                <dl class="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm">
                  <div>
                    <dt class="text-base-content/60">Owner</dt>
                    <dd class="font-medium">{owner_email(@workspace)}</dd>
                  </div>
                  <div>
                    <dt class="text-base-content/60">Active members</dt>
                    <dd class="font-medium">{active_member_count(@workspace)}</dd>
                  </div>
                  <div>
                    <dt class="text-base-content/60">Total members</dt>
                    <dd class="font-medium">{length(@workspace.members)}</dd>
                  </div>
                  <div>
                    <dt class="text-base-content/60">Created</dt>
                    <dd class="font-medium">
                      {Calendar.strftime(@workspace.inserted_at, "%Y-%m-%d")}
                    </dd>
                  </div>
                </dl>
              </div>

              <%!-- Form Actions --%>
              <div class="flex items-center justify-end gap-3 pt-4 border-t border-base-300">
                <.link navigate={~p"/admin/workspaces"} class="btn btn-ghost">
                  Cancel
                </.link>
                <button type="submit" class="btn btn-primary">
                  Save Changes
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  defp active_member_count(workspace) do
    Enum.count(workspace.members, & &1.is_active)
  end

  defp owner_email(workspace) do
    case Enum.find(workspace.members, &(&1.role == :admin)) do
      %{invite_email: email} when not is_nil(email) -> email
      _ -> "—"
    end
  end
end
