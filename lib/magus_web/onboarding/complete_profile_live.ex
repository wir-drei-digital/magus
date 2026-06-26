defmodule MagusWeb.OnboardingLive.CompleteProfileLive do
  @moduledoc """
  Post-sign-in profile completion page for magic link users.
  Collects name and legal consent (terms + age) before allowing
  access to the rest of the application. Only shown once.
  """
  use MagusWeb, :live_view

  alias AshPhoenix.Form

  on_mount {MagusWeb.LiveUserAuth, :live_user_required_no_profile_check}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # If profile is already complete, redirect to chat
    if user.accepted_terms do
      {:ok, push_navigate(socket, to: ~p"/chat")}
    else
      form =
        user
        |> Form.for_update(:complete_profile,
          domain: Magus.Accounts,
          as: "user",
          actor: user
        )
        |> to_form()

      socket =
        socket
        |> assign(:page_title, gettext("Complete Your Profile"))
        |> assign(:form, form)

      {:ok, socket}
    end
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

          <h2 class="text-xl font-semibold text-center">
            {gettext("Complete Your Profile")}
          </h2>
          <p class="text-sm text-base-content/60 text-center mb-6">
            {gettext("Please fill in your details to get started.")}
          </p>

          <.form
            for={@form}
            id="complete-profile-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <div>
              <.input
                field={@form[:name]}
                type="text"
                label={gettext("Name")}
                required
                autocomplete="name"
                phx-debounce="blur"
              />
            </div>

            <div>
              <.input
                field={@form[:display_name]}
                type="text"
                label={gettext("Username (optional)")}
                autocomplete="username"
                phx-debounce="blur"
              />
            </div>

            <div class="space-y-3">
              <label class="flex items-start gap-3 cursor-pointer">
                <input
                  type="checkbox"
                  name="user[accepted_terms]"
                  value="true"
                  checked={
                    @form[:accepted_terms].value == true || @form[:accepted_terms].value == "true"
                  }
                  class="checkbox checkbox-primary mt-0.5"
                  required
                />
                <span class="text-sm">
                  {gettext("I accept the")}
                  <.link
                    navigate={"/#{Gettext.get_locale(MagusWeb.Gettext)}/terms"}
                    class="link link-primary"
                    target="_blank"
                  >
                    {gettext("Terms of Service")}
                  </.link>
                  {gettext("and")}
                  <.link
                    navigate={"/#{Gettext.get_locale(MagusWeb.Gettext)}/privacy"}
                    class="link link-primary"
                    target="_blank"
                  >
                    {gettext("Privacy Policy")}
                  </.link>
                </span>
              </label>

              <label class="flex items-start gap-3 cursor-pointer">
                <input
                  type="checkbox"
                  name="user[accepted_age_requirement]"
                  value="true"
                  checked={
                    @form[:accepted_age_requirement].value == true ||
                      @form[:accepted_age_requirement].value == "true"
                  }
                  class="checkbox checkbox-primary mt-0.5"
                  required
                />
                <span class="text-sm">
                  {gettext("I confirm that I am at least 16 years old")}
                </span>
              </label>
            </div>

            <button type="submit" class="btn btn-primary w-full">
              {gettext("Continue")}
            </button>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    form =
      Form.validate(socket.assigns.form, params, errors: true)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"user" => params}, socket) do
    form = Form.validate(socket.assigns.form, params)

    case Form.submit(form, params: params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Profile completed successfully!"))
         |> push_navigate(to: ~p"/chat")}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end
end
