defmodule MagusWeb.OnboardingLive.MagicLinkConfirmLive do
  @moduledoc """
  Magic link confirmation page. When a user clicks their magic link email,
  they land here and click "Sign In" to complete authentication.
  Consent and profile completion happen post-sign-in via /complete-profile.
  """
  use MagusWeb, :live_view

  on_mount {MagusWeb.LiveUserAuth, :live_no_user}

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Complete Sign In"))
      |> assign(:token, token)
      |> assign(:trigger_action, false)

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

          <h2 class="text-xl font-semibold text-center mb-2">
            {gettext("Complete your sign-in")}
          </h2>
          <p class="text-sm text-base-content/60 text-center mb-6">
            {gettext("Click the button below to sign in to your account.")}
          </p>

          <form
            id="magic-link-confirm-form"
            phx-submit="confirm_sign_in"
            phx-trigger-action={@trigger_action}
            action={~p"/auth/user/magic_link"}
            method="post"
          >
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <input type="hidden" name="user[token]" value={@token} />

            <button type="submit" class="btn btn-primary w-full">
              {gettext("Sign In")}
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("confirm_sign_in", _params, socket) do
    {:noreply, assign(socket, :trigger_action, true)}
  end
end
