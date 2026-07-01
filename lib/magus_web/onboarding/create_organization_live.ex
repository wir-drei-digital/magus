defmodule MagusWeb.OnboardingLive.CreateOrganizationLive do
  @moduledoc """
  Optional post-registration step: create an organization.

  Reached only when a brand-new user opted in on the register page
  (`create_org` intent flag), so the default signup path never lands here.
  Collects a name + slug (the slug auto-fills from the name), creates the org
  with the current user as owner, then sends them to the org billing settings.
  A "Skip for now" link returns to the app root.

  A user who already belongs to an organization is redirected to the members
  tab on mount, so this page never offers a duplicate-org path.
  """
  use MagusWeb, :live_view

  alias AshPhoenix.Form
  alias Magus.Organizations
  alias Magus.Organizations.Organization

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    case Organizations.my_organization(actor: user) do
      {:ok, [_ | _]} ->
        # Already in an org — nothing to create here.
        {:ok, push_navigate(socket, to: ~p"/settings/organization/members")}

      _ ->
        socket =
          socket
          |> assign(:page_title, gettext("Create an Organization"))
          |> assign(:auto_slug, "")
          |> assign(:form, build_form(user))

        {:ok, socket}
    end
  end

  defp build_form(user) do
    Organization
    |> Form.for_create(:create, domain: Magus.Organizations, as: "organization", actor: user)
    |> to_form()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-spectral p-4">
      <div class="card w-full max-w-md">
        <div class="card-body">
          <div class="flex flex-col items-center gap-2 mb-6">
            <a href="/" class="flex flex-col items-center gap-2">
              <img src="/images/logo-triangle.svg" class="w-12 h-12" alt="Logo" />
              <span class="text-3xl font-logo text-base-content">MAGUS</span>
            </a>
          </div>

          <h1 class="card-title text-2xl justify-center mb-2">
            {gettext("Create your organization")}
          </h1>
          <p class="text-sm text-base-content/60 text-center mb-6">
            {gettext("Set up a shared organization to invite teammates and pool billing.")}
          </p>

          <.form
            for={@form}
            id="create-organization-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <div>
              <.input
                field={@form[:name]}
                type="text"
                label={gettext("Organization name")}
                required
                phx-debounce="blur"
              />
            </div>

            <div>
              <.input
                field={@form[:slug]}
                type="text"
                label={gettext("URL slug")}
                required
                phx-debounce="blur"
              />
              <p class="text-xs text-base-content/60 mt-1">
                {gettext("Lowercase letters, numbers and dashes. Auto-filled from the name.")}
              </p>
            </div>

            <button type="submit" class="btn btn-primary w-full">
              {gettext("Create organization")}
            </button>
          </.form>

          <div class="divider">{gettext("or")}</div>

          <.link navigate={~p"/"} class="btn btn-outline w-full">
            {gettext("Skip for now")}
          </.link>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"organization" => params}, socket) do
    {params, auto_slug} = apply_auto_slug(params, socket)

    form =
      socket.assigns.form
      |> Form.validate(params, errors: true)
      |> to_form()

    {:noreply, socket |> assign(:form, form) |> assign(:auto_slug, auto_slug)}
  end

  @impl true
  def handle_event("save", %{"organization" => params}, socket) do
    {params, auto_slug} = apply_auto_slug(params, socket)
    user = socket.assigns.current_user

    case Organizations.create_organization(
           %{name: params["name"], slug: params["slug"]},
           actor: user
         ) do
      {:ok, _org} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Organization created."))
         |> push_navigate(to: ~p"/settings/organization/billing")}

      {:error, _error} ->
        # Surface validation errors (blank name, malformed/duplicate slug, ...).
        form =
          socket.assigns.form
          |> Form.validate(params, errors: true)
          |> to_form()

        {:noreply, socket |> assign(:form, form) |> assign(:auto_slug, auto_slug)}
    end
  end

  # Auto-fill the slug from the name while the user hasn't diverged it: keep
  # filling as long as the incoming slug is blank or still equals the last
  # value we generated. Once the user types a custom slug we leave it alone.
  defp apply_auto_slug(params, socket) do
    name = Map.get(params, "name", "")
    incoming_slug = Map.get(params, "slug", "")
    prev_auto = socket.assigns[:auto_slug] || ""

    if incoming_slug == "" or incoming_slug == prev_auto do
      slug = slugify(name)
      {Map.put(params, "slug", slug), slug}
    else
      {params, prev_auto}
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 64)
    |> String.trim("-")
  end
end
