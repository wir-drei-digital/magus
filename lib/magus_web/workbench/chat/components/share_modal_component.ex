defmodule MagusWeb.ChatLive.Components.ShareModalComponent do
  @moduledoc """
  Modal component for managing conversation sharing.

  Allows users to:
  - Create read-only share links (public or authenticated)
  - View and manage existing share links
  - Enable/disable multiplayer mode
  """
  use MagusWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal id={@id <> "-dialog"} show={@show} on_close="close_share_modal">
        <:title>{gettext("Share Conversation")}</:title>

        <div class="space-y-6">
          <%!-- Read-only Links Section --%>
          <div>
            <h3 class="font-medium mb-2 flex items-center gap-2">
              <.icon name="lucide-link" class="w-4 h-4" />
              {gettext("Read-only Links")}
            </h3>
            <p class="text-sm text-base-content/60 mb-3">
              {gettext("Anyone with these links can view this conversation.")}
            </p>

            <%!-- Existing links --%>
            <div :if={length(@share_links) > 0} class="space-y-2 mb-4">
              <.share_link_item
                :for={link <- @share_links}
                link={link}
                base_url={@base_url}
                target={@myself}
              />
            </div>

            <%!-- Create new link form --%>
            <.form for={@form} phx-submit="create_share_link" phx-target={@myself} class="space-y-3">
              <div class="flex gap-2">
                <div class="flex-1">
                  <label class="label pb-1">
                    <span class="label-text text-xs">{gettext("Access Type")}</span>
                  </label>
                  <div class="flex gap-2">
                    <label class="flex items-center gap-2 cursor-pointer">
                      <input
                        type="radio"
                        name="access_type"
                        value="public"
                        checked={
                          @form[:access_type].value == :public ||
                            @form[:access_type].value == "public"
                        }
                        class="radio radio-sm radio-primary"
                      />
                      <span class="text-sm flex items-center gap-1">
                        <.icon name="lucide-globe" class="w-3.5 h-3.5" />
                        {gettext("Public")}
                      </span>
                    </label>
                    <label class="flex items-center gap-2 cursor-pointer">
                      <input
                        type="radio"
                        name="access_type"
                        value="authenticated"
                        checked={
                          @form[:access_type].value == :authenticated ||
                            @form[:access_type].value == "authenticated"
                        }
                        class="radio radio-sm radio-primary"
                      />
                      <span class="text-sm flex items-center gap-1">
                        <.icon name="lucide-lock" class="w-3.5 h-3.5" />
                        {gettext("Logged-in only")}
                      </span>
                    </label>
                  </div>
                </div>
              </div>

              <div class="flex gap-2">
                <input
                  type="text"
                  name="label"
                  placeholder={gettext("Optional label (e.g., 'For team review')")}
                  class="input input-bordered input-sm flex-1"
                />
                <button type="submit" class="btn btn-primary btn-sm gap-1">
                  <.icon name="lucide-plus" class="w-4 h-4" />
                  {gettext("Create Link")}
                </button>
              </div>
            </.form>
          </div>

          <div class="divider" />

          <%!-- Multiplayer Section --%>
          <div>
            <h3 class="font-medium mb-2 flex items-center gap-2">
              <.icon name="lucide-users" class="w-4 h-4" />
              {gettext("Collaborative Editing")}
            </h3>
            <p class="text-sm text-base-content/60 mb-3">
              {gettext("Invite people to participate in this conversation.")}
            </p>

            <%= if @conversation.is_multiplayer do %>
              <div class="flex gap-2">
                <button
                  type="button"
                  class="btn btn-sm btn-outline text-error! gap-1"
                  phx-click="disable_multiplayer"
                  data-confirm={gettext("This will remove all participants except you. Continue?")}
                >
                  <.icon name="lucide-user-minus" class="w-4 h-4" />
                  {gettext("Disable Multiplayer")}
                </button>
              </div>
            <% else %>
              <button
                type="button"
                class="btn btn-sm btn-outline gap-1"
                phx-click="enable_multiplayer"
              >
                <.icon name="lucide-user-plus" class="w-4 h-4" />
                {gettext("Enable Multiplayer")}
              </button>
            <% end %>
          </div>
        </div>
      </.modal>
    </div>
    """
  end

  attr :link, :map, required: true
  attr :base_url, :string, required: true
  attr :target, :any, required: true

  defp share_link_item(assigns) do
    url = "#{assigns.base_url}/shared/#{assigns.link.token}"
    assigns = assign(assigns, :url, url)

    ~H"""
    <div class="flex items-center gap-2 p-2 bg-base-200 rounded-lg">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <%= if @link.access_type == :public do %>
            <.icon name="lucide-globe" class="w-4 h-4 text-success" />
            <span class="text-sm font-medium">{gettext("Public link")}</span>
          <% else %>
            <.icon name="lucide-lock" class="w-4 h-4 text-warning" />
            <span class="text-sm font-medium">{gettext("Logged-in users only")}</span>
          <% end %>
        </div>
        <div :if={@link.label} class="text-xs text-base-content/60 mt-0.5 truncate">
          "{@link.label}"
        </div>
        <div class="text-xs text-base-content/40 mt-0.5">
          {gettext("Created")} {format_date(@link.inserted_at)}
        </div>
      </div>
      <div class="flex items-center gap-1">
        <button
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="copy_share_link"
          phx-value-url={@url}
          phx-target={@target}
          title={gettext("Copy link")}
        >
          <.icon name="lucide-copy" class="w-4 h-4" />
        </button>
        <button
          type="button"
          class="btn btn-ghost btn-xs text-error"
          phx-click="revoke_share_link"
          phx-value-id={@link.id}
          phx-target={@target}
          title={gettext("Revoke link")}
          data-confirm={
            gettext("Are you sure you want to revoke this link? Anyone using it will lose access.")
          }
        >
          <.icon name="lucide-trash-2" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:form, to_form(%{"access_type" => "public", "label" => ""}))}
  end

  @impl true
  def update(assigns, socket) do
    base_url = Magus.Endpoint.url()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:base_url, base_url)}
  end

  @impl true
  def handle_event("create_share_link", params, socket) do
    access_type =
      case params["access_type"] do
        "authenticated" -> :authenticated
        _ -> :public
      end

    attrs = %{
      access_type: access_type,
      label: if(params["label"] == "", do: nil, else: params["label"])
    }

    case Magus.Chat.create_share_link(
           socket.assigns.conversation.id,
           attrs,
           actor: socket.assigns.current_user
         ) do
      {:ok, _link} ->
        send(self(), {__MODULE__, :share_links_changed})

        {:noreply,
         socket
         |> assign(:form, to_form(%{"access_type" => "public", "label" => ""}))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create share link"))}
    end
  end

  def handle_event("revoke_share_link", %{"id" => link_id}, socket) do
    link = Enum.find(socket.assigns.share_links, &(&1.id == link_id))

    if link do
      case Magus.Chat.revoke_share_link(link, actor: socket.assigns.current_user) do
        {:ok, _} ->
          send(self(), {__MODULE__, :share_links_changed})
          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to revoke share link"))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("copy_share_link", %{"url" => url}, socket) do
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: url})}
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end
end
