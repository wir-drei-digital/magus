defmodule MagusWeb.Admin.AnnouncementsLive do
  @moduledoc """
  Admin view for managing feature announcements.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts
  alias Magus.FeatureUsage.Announcement

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Announcements")
      |> assign(:current_path, "/admin/announcements")
      |> load_announcements()

    {:ok, socket}
  end

  defp load_announcements(socket) do
    require Ash.Query

    announcements =
      Announcement
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(authorize?: false)

    assign(socket, :announcements, announcements)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Announcements")
    |> assign(:announcement, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    form =
      Announcement
      |> AshPhoenix.Form.for_create(:create, authorize?: false, forms: [auto?: true])
      |> to_form()

    socket
    |> assign(:page_title, "New Announcement")
    |> assign(:announcement, nil)
    |> assign(:form, form)
    |> assign(:lang_tab, "en")
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Ash.get(Announcement, id, authorize?: false) do
      {:ok, announcement} ->
        form =
          announcement
          |> AshPhoenix.Form.for_update(:update, authorize?: false, forms: [auto?: true])
          |> to_form()

        socket
        |> assign(:page_title, "Edit Announcement")
        |> assign(:announcement, announcement)
        |> assign(:form, form)
        |> assign(:lang_tab, "en")

      {:error, _} ->
        socket
        |> put_flash(:error, "Announcement not found")
        |> push_navigate(to: ~p"/admin/announcements")
    end
  end

  @impl true
  def handle_event("switch_lang_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :lang_tab, tab)}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form.source, params)
    {:noreply, assign(socket, :form, to_form(form))}
  end

  @impl true
  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _announcement} ->
        action = if socket.assigns.live_action == :new, do: "created", else: "updated"

        {:noreply,
         socket
         |> put_flash(:info, "Announcement #{action} successfully")
         |> push_navigate(to: ~p"/admin/announcements")}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    case Ash.get(Announcement, id, authorize?: false) do
      {:ok, announcement} ->
        result =
          announcement
          |> Ash.Changeset.for_update(:update, %{active: !announcement.active})
          |> Ash.update(authorize?: false)

        case result do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Announcement #{if announcement.active, do: "deactivated", else: "activated"}"
             )
             |> load_announcements()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update announcement")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Announcement not found")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Ash.get(Announcement, id, authorize?: false) do
      {:ok, announcement} ->
        case Ash.destroy(announcement, authorize?: false) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Announcement deleted")
             |> load_announcements()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete announcement")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Announcement not found")}
    end
  end

  @impl true
  def render(assigns) do
    if assigns.live_action in [:new, :edit] do
      render_form(assigns)
    else
      render_index(assigns)
    end
  end

  defp render_index(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">Announcements</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Manage feature announcements shown on the new chat page
            </p>
          </div>
          <.link navigate={~p"/admin/announcements/new"} class="btn btn-primary btn-sm">
            <.icon name="lucide-plus" class="w-4 h-4" /> New Announcement
          </.link>
        </div>

        <div class="card bg-base-200 border border-base-300 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="bg-base-300/50">
                  <th>Key</th>
                  <th>Title</th>
                  <th>Description</th>
                  <th class="text-center">Status</th>
                  <th>Action</th>
                  <th class="text-center">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= if @announcements == [] do %>
                  <tr>
                    <td colspan="6" class="text-center py-8 text-base-content/50">
                      No announcements yet
                    </td>
                  </tr>
                <% else %>
                  <%= for announcement <- @announcements do %>
                    <tr class="hover:bg-base-300/30">
                      <td>
                        <div class="flex items-center gap-2">
                          <span :if={announcement.icon} class="text-lg">{announcement.icon}</span>
                          <code class="text-xs bg-base-300 px-1 py-0.5 rounded">
                            {announcement.key}
                          </code>
                        </div>
                      </td>
                      <td class="font-medium">{announcement.title["en"] || ""}</td>
                      <td class="text-base-content/70 max-w-xs truncate">
                        {announcement.description["en"] || ""}
                      </td>
                      <td class="text-center">
                        <%= if announcement.active do %>
                          <span class="badge badge-success badge-sm">Active</span>
                        <% else %>
                          <span class="badge badge-ghost badge-sm">Inactive</span>
                        <% end %>
                      </td>
                      <td>
                        <code class="text-xs bg-base-300 px-1 py-0.5 rounded">
                          {announcement.action_type}
                        </code>
                        <span class="text-xs text-base-content/50 ml-1">
                          {announcement.action_payload}
                        </span>
                      </td>
                      <td>
                        <div class="flex items-center justify-center gap-1">
                          <.link
                            navigate={~p"/admin/announcements/#{announcement.id}/edit"}
                            class="btn btn-ghost btn-xs"
                            title="Edit"
                          >
                            <.icon name="lucide-pencil" class="w-4 h-4" />
                          </.link>
                          <button
                            type="button"
                            phx-click="toggle_active"
                            phx-value-id={announcement.id}
                            class="btn btn-ghost btn-xs"
                            title={if announcement.active, do: "Deactivate", else: "Activate"}
                          >
                            <%= if announcement.active do %>
                              <.icon name="lucide-pause" class="w-4 h-4" />
                            <% else %>
                              <.icon name="lucide-play" class="w-4 h-4" />
                            <% end %>
                          </button>
                          <button
                            type="button"
                            phx-click="delete"
                            phx-value-id={announcement.id}
                            data-confirm="Are you sure you want to delete this announcement?"
                            class="btn btn-ghost btn-xs text-error"
                            title="Delete"
                          >
                            <.icon name="lucide-trash-2" class="w-4 h-4" />
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
          <.link navigate={~p"/admin/announcements"} class="btn btn-ghost btn-sm btn-circle">
            <.icon name="lucide-arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-2xl font-bold text-base-content">
              {if @live_action == :new, do: "New Announcement", else: "Edit Announcement"}
            </h1>
            <p class="text-base-content/60 text-sm mt-1">
              {if @live_action == :new,
                do: "Create a new feature announcement",
                else: "Update announcement details"}
            </p>
          </div>
        </div>

        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-6">
              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Content</h3>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 [&_.fieldset]:mb-0">
                  <.input
                    field={@form[:key]}
                    label="Key"
                    placeholder="e.g., files_2026_03"
                    phx-debounce="300"
                  />
                  <.input
                    field={@form[:icon]}
                    label="Icon (emoji)"
                    placeholder="e.g., 🎉"
                    phx-debounce="300"
                  />
                </div>

                <div class="tabs tabs-boxed mt-4 mb-4 w-fit">
                  <button
                    type="button"
                    phx-click="switch_lang_tab"
                    phx-value-tab="en"
                    class={"tab #{if @lang_tab == "en", do: "tab-active"}"}
                  >
                    English
                  </button>
                  <button
                    type="button"
                    phx-click="switch_lang_tab"
                    phx-value-tab="de"
                    class={"tab #{if @lang_tab == "de", do: "tab-active"}"}
                  >
                    Deutsch
                  </button>
                </div>

                <div class="space-y-4 [&_.fieldset]:mb-0">
                  <%!-- Hidden inputs for the inactive language to preserve values across tab switches --%>
                  <% inactive_lang = if @lang_tab == "en", do: "de", else: "en" %>
                  <input
                    type="hidden"
                    name={"form[title][#{inactive_lang}]"}
                    value={get_translation(@form, :title, inactive_lang)}
                  />
                  <input
                    type="hidden"
                    name={"form[description][#{inactive_lang}]"}
                    value={get_translation(@form, :description, inactive_lang)}
                  />

                  <.input
                    name={"form[title][#{@lang_tab}]"}
                    value={get_translation(@form, :title, @lang_tab)}
                    label={"Title (#{if @lang_tab == "en", do: "English", else: "German"})"}
                    placeholder="e.g., File uploads are here!"
                    phx-debounce="300"
                  />
                  <.input
                    name={"form[description][#{@lang_tab}]"}
                    value={get_translation(@form, :description, @lang_tab)}
                    type="textarea"
                    label={"Description (#{if @lang_tab == "en", do: "English", else: "German"})"}
                    placeholder="Short description of the announcement"
                    class="textarea h-20"
                    phx-debounce="300"
                  />
                </div>
              </div>

              <div class="divider"></div>

              <div>
                <h3 class="text-lg font-semibold text-base-content mb-4">Action</h3>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 [&_.fieldset]:mb-0">
                  <.input
                    field={@form[:action_type]}
                    label="Action Type"
                    type="select"
                    options={[
                      {"Navigate", "navigate"},
                      {"Send Message", "send_message"},
                      {"Prefill", "prefill"}
                    ]}
                  />
                  <.input
                    field={@form[:action_payload]}
                    label="Action Payload"
                    placeholder="e.g., /chat?skill=onboarding&topic=files"
                    phx-debounce="300"
                  />
                </div>
                <p class="text-xs text-base-content/50 mt-2">
                  Navigate: URL path to link to. Send Message / Prefill: text to send or insert.
                </p>
              </div>

              <%= if @live_action == :edit do %>
                <div class="divider"></div>

                <div>
                  <h3 class="text-lg font-semibold text-base-content mb-4">Status</h3>
                  <div class="[&_.fieldset]:mb-0">
                    <.input type="checkbox" field={@form[:active]} label="Active" />
                  </div>
                  <p class="text-xs text-base-content/50 mt-1">
                    Inactive announcements are hidden from users
                  </p>
                </div>
              <% end %>

              <div class="flex items-center justify-end gap-3 pt-4 border-t border-base-300">
                <.link navigate={~p"/admin/announcements"} class="btn btn-ghost">
                  Cancel
                </.link>
                <button type="submit" class="btn btn-primary">
                  {if @live_action == :new, do: "Create Announcement", else: "Save Changes"}
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  defp get_translation(form, field, locale) do
    case form[field].value do
      map when is_map(map) ->
        Map.get(map, locale) || Map.get(map, String.to_existing_atom(locale), "") || ""

      _ ->
        ""
    end
  rescue
    ArgumentError -> ""
  end
end
