defmodule MagusWeb.ChatLive.Components.Brain.BrainSettingsModalComponent do
  @moduledoc """
  LiveComponent for editing brain settings (title, description, icon, color)
  and deleting a brain.

  ## Usage

      <.live_component
        module={MagusWeb.ChatLive.Components.Brain.BrainSettingsModalComponent}
        id="brain-settings-modal"
        show={@show_brain_settings}
        brain={@editing_brain}
        current_user={@current_user}
      />

  ## Events sent to parent

  - `{BrainSettingsModalComponent, {:brain_saved, brain}}` - When a brain is updated
  - `{BrainSettingsModalComponent, {:brain_deleted, brain_id}}` - When a brain is deleted
  - `{BrainSettingsModalComponent, :modal_closed}` - When the modal is closed/cancelled
  """
  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  alias AshPhoenix.Form
  alias MagusWeb.Workbench.WorkspaceShare

  def render(assigns) do
    ~H"""
    <div>
      <.modal id="brain-settings-modal" show={@show} on_close="cancel" target={@myself}>
        <:title>{gettext("Brain settings")}</:title>

        <.form
          :if={@brain}
          for={@form}
          phx-submit="save"
          phx-change="validate"
          phx-target={@myself}
        >
          <.input
            field={@form[:title]}
            type="text"
            label={gettext("Title")}
            placeholder={gettext("Brain title")}
            required
          />
          <.input
            field={@form[:description]}
            type="textarea"
            label={gettext("Description")}
            placeholder={gettext("What's this brain for?")}
            class="textarea h-20"
          />
          <%!-- <.input
            field={@form[:icon]}
            type="text"
            label={gettext("Icon")}
            placeholder={gettext("Emoji, e.g. 🧠")}
            maxlength="4"
          />
          <.input
            field={@form[:color]}
            type="text"
            label={gettext("Color")}
            placeholder={gettext("Hex color, e.g. #6366f1")}
          /> --%>

          <div :if={@brain.workspace_id} class="form-control mt-4">
            <label class="label">
              <span class="label-text">{gettext("Workspace sharing")}</span>
            </label>
            <div class="flex items-center justify-between gap-3 p-3 rounded-md bg-base-200/50 border border-base-300">
              <div class="min-w-0">
                <div class="text-sm font-medium">
                  <%= if @brain.is_shared_to_workspace do %>
                    {gettext("Shared with workspace")}
                  <% else %>
                    {gettext("Personal")}
                  <% end %>
                </div>
                <div class="text-xs text-base-content/60">
                  <%= if @brain.is_shared_to_workspace do %>
                    {gettext("Everyone in this workspace can read and edit this brain.")}
                  <% else %>
                    {gettext("Only you can see this brain.")}
                  <% end %>
                </div>
              </div>
              <button
                type="button"
                class={[
                  "btn btn-sm",
                  if(@brain.is_shared_to_workspace, do: "btn-outline", else: "btn-primary")
                ]}
                phx-click="toggle_workspace_share"
                phx-target={@myself}
              >
                <%= if @brain.is_shared_to_workspace do %>
                  <.icon name="lucide-user-check" class="w-4 h-4" />
                  {gettext("Unshare")}
                <% else %>
                  <.icon name="lucide-users" class="w-4 h-4" />
                  {gettext("Share with workspace")}
                <% end %>
              </button>
            </div>
          </div>

          <div class="modal-action justify-between">
            <button
              type="button"
              class="btn btn-error btn-outline"
              phx-click="delete"
              phx-target={@myself}
              data-confirm={gettext("Delete this brain and all its pages? This cannot be undone.")}
            >
              <.icon name="lucide-trash-2" class="w-4 h-4" />
              {gettext("Delete brain")}
            </button>
            <div class="flex gap-2">
              <button type="button" class="btn" phx-click="cancel" phx-target={@myself}>
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary">
                {gettext("Save")}
              </button>
            </div>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     |> assign(:show, false)
     |> assign(:brain, nil)
     |> assign_form(nil)}
  end

  def update(%{show: true, brain: brain} = assigns, socket) when not is_nil(brain) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(brain)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    form = Form.validate(socket.assigns.form.source, params)
    {:noreply, assign(socket, :form, to_form(form))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case Form.submit(socket.assigns.form.source, params: params) do
      {:ok, brain} ->
        notify_parent({:brain_saved, brain})

        {:noreply,
         socket
         |> assign(:show, false)
         |> assign(:brain, nil)}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  def handle_event("toggle_workspace_share", _params, socket) do
    brain = socket.assigns.brain
    user = socket.assigns.current_user

    action = if brain.is_shared_to_workspace, do: :unshare, else: :share

    result =
      case action do
        :share -> WorkspaceShare.share(:brain, brain, user)
        :unshare -> WorkspaceShare.unshare(:brain, brain, user)
      end

    case result do
      {:ok, _} ->
        case Magus.Brain.get_brain(brain.id, actor: user, load: [:is_shared_to_workspace]) do
          {:ok, fresh} ->
            notify_parent({:brain_visibility_changed, fresh})
            {:noreply, assign(socket, :brain, fresh)}

          _ ->
            {:noreply, socket}
        end

      :no_workspace ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("delete", _params, socket) do
    brain = socket.assigns.brain

    if brain do
      case Magus.Brain.destroy_brain(brain, actor: socket.assigns.current_user) do
        :ok ->
          notify_parent({:brain_deleted, brain.id})

          {:noreply,
           socket
           |> assign(:show, false)
           |> assign(:brain, nil)}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel", _, socket) do
    notify_parent(:modal_closed)

    {:noreply,
     socket
     |> assign(:show, false)
     |> assign(:brain, nil)}
  end

  defp assign_form(socket, nil) do
    assign(socket, :form, to_form(%{}, as: :form))
  end

  defp assign_form(socket, brain) do
    form = Form.for_update(brain, :update, actor: socket.assigns[:current_user])
    assign(socket, :form, to_form(form))
  end
end
