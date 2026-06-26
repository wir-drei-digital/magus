defmodule MagusWeb.WorkspaceLive.New do
  @moduledoc """
  LiveView for creating a new workspace.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    form = to_form(%{"name" => "", "slug" => ""}, as: "workspace")

    socket =
      socket
      |> assign(:page_title, gettext("Create Workspace"))
      |> assign(:form, form)
      |> assign(:slug_edited, false)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      show_sidebar={false}
      bg_class="bg-spectral"
    >
      <div class="max-w-lg mx-auto px-4 py-12">
        <h1 class="text-2xl font-bold text-base-content mb-2">
          {gettext("Create a Workspace")}
        </h1>
        <p class="text-base-content/60 text-sm mb-8">
          {gettext(
            "Workspaces let your team collaborate on shared conversations, prompts, and files."
          )}
        </p>

        <.form for={@form} phx-submit="create" phx-change="validate" class="space-y-6">
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Workspace Name")}
            placeholder={gettext("e.g. Acme Engineering")}
            required
          />

          <.input
            field={@form[:slug]}
            type="text"
            label={gettext("URL Slug")}
            placeholder={gettext("e.g. acme-engineering")}
            hint={gettext("Used in URLs. Only lowercase letters, numbers, and hyphens.")}
            required
          />

          <div class="flex gap-3">
            <.link navigate={~p"/chat"} class="btn btn-ghost">
              {gettext("Cancel")}
            </.link>
            <button type="submit" class="btn btn-primary flex-1">
              {gettext("Create Workspace")}
            </button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"workspace" => params} = event, socket) do
    slug_edited =
      case event["_target"] do
        ["workspace", "slug"] -> params["slug"] != ""
        _ -> socket.assigns.slug_edited
      end

    slug =
      if slug_edited,
        do: params["slug"],
        else: slugify(params["name"])

    form = to_form(%{params | "slug" => slug}, as: "workspace")

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:slug_edited, slug_edited)}
  end

  @impl true
  def handle_event("create", %{"workspace" => params}, socket) do
    case Magus.Workspaces.create_workspace(
           %{name: params["name"], slug: params["slug"]},
           actor: socket.assigns.current_user
         ) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Workspace created!"))
         |> push_navigate(to: ~p"/workspaces/#{workspace.slug}")}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not create workspace. Check the slug is unique.")
         )}
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end
end
