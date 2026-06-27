defmodule MagusWeb.OnboardingLive.RegisterLive do
  @moduledoc """
  Custom registration LiveView that supports the Select-Register-Pay onboarding flow.

  Handles registration with an optional plan parameter:
  - `/register` - Register for free plan
  - `/register?plan=starter` - Register and redirect to Starter plan checkout
  - `/register?plan=pro` - Register and redirect to Pro plan checkout
  """
  use MagusWeb, :live_view

  alias AshPhoenix.Form
  alias Magus.Accounts.User

  on_mount {MagusWeb.LiveUserAuth, :live_no_user}

  # Valid plan keys that can be selected during registration.
  # "payg" is the pay-as-you-go base tier (flat fee + usage); after auth the
  # user is routed to /onboarding/checkout?plan=payg, which resolves the Stripe
  # base price.
  @valid_plans ["free", "starter", "pro", "payg"]

  @impl true
  def mount(params, session, socket) do
    selected_plan = validate_plan(Map.get(params, "plan"))
    lang = Map.get(params, "lang")
    invite_token = Map.get(params, "invite_token") || Map.get(session, "invite_token")

    form =
      Form.for_create(User, :register_with_password,
        domain: Magus.Accounts,
        as: "user",
        context: %{private: %{ash_authentication?: true}}
      )

    socket =
      socket
      |> assign(:page_title, gettext("Create Account"))
      |> assign(:selected_plan, selected_plan)
      |> assign(:lang, lang)
      |> assign(:invite_token, invite_token)
      |> assign(:form, to_form(form))
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

          <h1 class="card-title text-2xl justify-center mb-2">{gettext("Create your account")}</h1>

          <.plan_badge :if={@selected_plan != "free"} plan={@selected_plan} />

          <.form
            for={@form}
            id="register-form"
            phx-change="validate"
            phx-submit="save"
            phx-trigger-action={@trigger_action}
            action={~p"/auth/user/password/register"}
            method="post"
            class="space-y-4"
          >
            <input type="hidden" name="user[selected_plan_key]" value={@selected_plan} />
            <input :if={@lang} type="hidden" name="user[language]" value={@lang} />
            <input :if={@invite_token} type="hidden" name="invite_token" value={@invite_token} />

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

            <div>
              <.input
                field={@form[:email]}
                type="email"
                label={gettext("Email")}
                required
                autocomplete="email"
                phx-debounce="blur"
              />
            </div>

            <div>
              <.input
                field={@form[:password]}
                type="password"
                label={gettext("Password")}
                required
                autocomplete="new-password"
                phx-debounce="blur"
              />
              <p class="text-xs text-base-content/60 mt-1">
                {gettext("Must be at least 8 characters")}
              </p>
            </div>

            <div>
              <.input
                field={@form[:password_confirmation]}
                type="password"
                label={gettext("Confirm Password")}
                required
                autocomplete="new-password"
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
              {if @selected_plan == "free",
                do: gettext("Create Account"),
                else: gettext("Create Account & Continue to Payment")}
            </button>
          </.form>

          <div class="divider">{gettext("or")}</div>

          <.link
            navigate={~p"/sign-in?#{sign_in_params(@selected_plan, @lang, @invite_token)}"}
            class="btn btn-outline w-full"
          >
            {gettext("Already have an account? Sign in")}
          </.link>

          <p :if={@selected_plan != "free"} class="text-xs text-center text-base-content/60 mt-4">
            {gettext("You won't be charged until you complete the payment step.")}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp plan_badge(assigns) do
    plan_name =
      case assigns.plan do
        "starter" -> "Starter"
        "pro" -> "Pro"
        "payg" -> "Pay-as-you-go"
        other -> String.capitalize(other)
      end

    assigns = assign(assigns, :plan_name, plan_name)

    ~H"""
    <div class="flex justify-center mb-4">
      <span class="badge badge-primary badge-lg gap-2">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-4 w-4"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M5 13l4 4L19 7"
          />
        </svg>
        {gettext("Selected plan: %{plan}", plan: @plan_name)}
      </span>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    # Add the selected plan to params
    user_params = Map.put(user_params, "selected_plan_key", socket.assigns.selected_plan)

    form =
      Form.validate(socket.assigns.form, user_params, errors: true)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    # Add the selected plan to params
    user_params = Map.put(user_params, "selected_plan_key", socket.assigns.selected_plan)

    form = Form.validate(socket.assigns.form, user_params, errors: true)

    # Don't call Form.submit here — that would create the user in the DB.
    # Instead, only validate and set trigger_action to POST the form to the
    # auth controller, which handles both creation and session setup.
    if form.source.valid? do
      socket =
        socket
        |> assign(:form, to_form(form))
        |> assign(:trigger_action, true)

      {:noreply, socket}
    else
      {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  # Validates the plan parameter, defaulting to "free" if invalid.
  #
  # Paid plans require the commercial billing edition (Magus.Usage.billing_edition?/0).
  # OSS self-host has no checkout flow, so any paid plan param normalizes to
  # "free" instead of routing to the cloud-only /onboarding/checkout (magus-rim5).
  defp validate_plan(plan) do
    if plan in valid_plans(), do: plan, else: "free"
  end

  defp valid_plans do
    if Magus.Usage.billing_edition?(), do: @valid_plans, else: ["free"]
  end

  defp sign_in_params(plan, lang, invite_token) do
    %{}
    |> then(fn p -> if plan != "free", do: Map.put(p, "plan", plan), else: p end)
    |> then(fn p -> if lang, do: Map.put(p, "lang", lang), else: p end)
    |> then(fn p ->
      if invite_token, do: Map.put(p, "invite_token", invite_token), else: p
    end)
  end
end
