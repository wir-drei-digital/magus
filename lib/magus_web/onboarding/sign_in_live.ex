defmodule MagusWeb.OnboardingLive.SignInLive do
  @moduledoc """
  Custom sign-in LiveView that supports both password and magic link sign-in.
  Both forms are shown on a single page with a divider between them.
  """
  use MagusWeb, :live_view

  alias AshPhoenix.Form
  alias Magus.Accounts.User

  on_mount {MagusWeb.LiveUserAuth, :live_no_user}

  @impl true
  def mount(params, session, socket) do
    selected_plan = Map.get(params, "plan")
    lang = Map.get(params, "lang")
    invite_token = Map.get(params, "invite_token") || Map.get(session, "invite_token")

    org_invite_token =
      Map.get(params, "org_invite_token") || Map.get(session, "org_invite_token")

    password_form =
      Form.for_action(User, :sign_in_with_password,
        domain: Magus.Accounts,
        as: "user"
      )

    socket =
      socket
      |> assign(:page_title, gettext("Sign In"))
      |> assign(:selected_plan, selected_plan)
      |> assign(:lang, lang)
      |> assign(:invite_token, invite_token)
      |> assign(:org_invite_token, org_invite_token)
      |> assign(:password_form, to_form(password_form))
      |> assign(:trigger_action, false)
      |> assign(:magic_link_email, "")
      |> assign(:magic_link_sent, false)

    {:ok, socket}
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

          <.form
            for={@password_form}
            id="password-sign-in-form"
            phx-change="validate_password"
            phx-submit="password_sign_in"
            phx-trigger-action={@trigger_action}
            action={~p"/auth/user/password/sign_in"}
            method="post"
            class="space-y-4"
          >
            <input :if={@invite_token} type="hidden" name="invite_token" value={@invite_token} />
            <input
              :if={@org_invite_token}
              type="hidden"
              name="org_invite_token"
              value={@org_invite_token}
            />

            <.input
              field={@password_form[:email]}
              type="email"
              label={gettext("Email")}
              required
              autocomplete="email"
              phx-debounce="blur"
            />

            <.input
              field={@password_form[:password]}
              type="password"
              label={gettext("Password")}
              required
              autocomplete="current-password"
              phx-debounce="blur"
            />

            <div class="flex items-center justify-between">
              <.link navigate={~p"/reset"} class="link link-primary text-sm">
                {gettext("Forgot your password?")}
              </.link>

              <.link
                navigate={
                  ~p"/register?#{register_params(@selected_plan, @lang, @invite_token, @org_invite_token)}"
                }
                class="link link-primary text-sm"
              >
                {gettext("Need an account?")}
              </.link>
            </div>

            <label class="flex items-center gap-2 cursor-pointer">
              <input type="hidden" name="user[remember_me]" value="false" />
              <input
                type="checkbox"
                name="user[remember_me]"
                value="true"
                checked={
                  @password_form[:remember_me].value == true ||
                    @password_form[:remember_me].value == "true"
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text">{gettext("Remember me for 30 days")}</span>
            </label>

            <button type="submit" class="btn btn-primary w-full">
              {gettext("Sign in")}
            </button>
          </.form>

          <div class="divider">{gettext("or")}</div>

          <div :if={@magic_link_sent} class="alert alert-success">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="stroke-current shrink-0 h-6 w-6"
              fill="none"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
            <span>{gettext("Check your email for a sign-in link!")}</span>
          </div>

          <form :if={!@magic_link_sent} phx-submit="request_magic_link" class="space-y-4">
            <.input
              type="email"
              name="email"
              label={gettext("Email")}
              value={@magic_link_email}
              required
              autocomplete="email"
              phx-debounce="blur"
            />

            <button type="submit" class="btn btn-primary w-full">
              {gettext("Request magic link")}
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate_password", %{"user" => params}, socket) do
    form =
      Form.validate(socket.assigns.password_form, params, errors: true)
      |> to_form()

    {:noreply, assign(socket, :password_form, form)}
  end

  @impl true
  def handle_event("password_sign_in", %{"user" => params}, socket) do
    form = Form.validate(socket.assigns.password_form, params)

    case Form.submit(form, params: params) do
      {:ok, _user} ->
        socket =
          socket
          |> assign(:password_form, to_form(form))
          |> assign(:trigger_action, true)

        {:noreply, socket}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:password_form, to_form(form))
         |> put_flash(:error, gettext("Invalid email or password"))}
    end
  end

  @impl true
  def handle_event("request_magic_link", %{"email" => email}, socket) do
    # Request the magic link - this always succeeds (no error for non-existent emails)
    Magus.Accounts.User
    |> Ash.ActionInput.for_action(:request_magic_link, %{email: email})
    |> Ash.run_action(authorize?: false)

    {:noreply,
     socket
     |> assign(:magic_link_sent, true)
     |> assign(:magic_link_email, email)}
  end

  defp register_params(plan, lang, invite_token, org_invite_token) do
    %{}
    |> then(fn p -> if plan, do: Map.put(p, "plan", plan), else: p end)
    |> then(fn p -> if lang, do: Map.put(p, "lang", lang), else: p end)
    |> then(fn p ->
      if invite_token, do: Map.put(p, "invite_token", invite_token), else: p
    end)
    |> then(fn p ->
      if org_invite_token, do: Map.put(p, "org_invite_token", org_invite_token), else: p
    end)
  end
end
