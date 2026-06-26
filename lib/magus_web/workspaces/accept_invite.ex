defmodule MagusWeb.WorkspaceLive.AcceptInvite do
  @moduledoc """
  Handles workspace invite acceptance.

  - If user is logged in: accepts the invite and redirects to workspace.
  - If not logged in: shows a message to sign in/register first, storing
    the invite token in the session for post-auth acceptance.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts

  on_mount {MagusWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Magus.Workspaces.get_member_by_token(token, authorize?: false) do
      {:ok, member} ->
        member = Ash.load!(member, :workspace, authorize?: false)

        if socket.assigns[:current_user] do
          handle_logged_in_user(socket, member)
        else
          {:ok,
           socket
           |> assign(:page_title, gettext("Workspace Invitation"))
           |> assign(:member, member)
           |> assign(:workspace_name, member.workspace.name)
           |> assign(:token, token)
           |> assign(:state, :needs_auth)}
        end

      {:error, _} ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Invalid Invitation"))
         |> assign(:state, :invalid)}
    end
  end

  defp handle_logged_in_user(socket, member) do
    case Magus.Workspaces.accept_invite(member.invite_token,
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:ok,
         socket
         |> put_flash(:info, gettext("Welcome to %{name}!", name: member.workspace.name))
         |> push_navigate(to: ~p"/chat")}

      {:error, :expired} ->
        {:ok,
         socket
         |> put_flash(
           :error,
           gettext("This invitation has expired. Ask the workspace owner to resend it.")
         )
         |> push_navigate(to: ~p"/chat")}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(
           :error,
           gettext("Invitation not found. It may have already been used or revoked.")
         )
         |> push_navigate(to: ~p"/chat")}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(
           :error,
           gettext("Could not accept invitation. It may have already been used.")
         )
         |> push_navigate(to: ~p"/chat")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={assigns[:current_user]}
      show_sidebar={false}
      bg_class="bg-spectral"
    >
      <div class="max-w-md mx-auto px-4 py-24 text-center">
        <div :if={@state == :invalid} class="space-y-4">
          <.icon name="lucide-alert-circle" class="w-12 h-12 text-error mx-auto" />
          <h1 class="text-2xl font-bold text-base-content">
            {gettext("Invalid Invitation")}
          </h1>
          <p class="text-base-content/60">
            {gettext("This invitation link is invalid or has already been used.")}
          </p>
          <.link navigate={~p"/chat"} class="btn btn-primary">
            {gettext("Go to Chat")}
          </.link>
        </div>

        <div :if={@state == :needs_auth} class="space-y-6">
          <.icon name="lucide-mail-check" class="w-12 h-12 text-primary mx-auto" />
          <h1 class="text-2xl font-bold text-base-content">
            {gettext("You're invited!")}
          </h1>
          <p class="text-base-content/60">
            {gettext("You've been invited to join %{name}.", name: @workspace_name)}
          </p>
          <p class="text-base-content/60 text-sm">
            {gettext("Sign in or create an account to accept this invitation.")}
          </p>
          <div class="flex flex-col gap-3">
            <.link
              navigate={~p"/sign-in?invite_token=#{@token}"}
              class="btn btn-primary"
            >
              {gettext("Sign In to Accept")}
            </.link>
            <.link
              navigate={~p"/register?invite_token=#{@token}"}
              class="btn btn-outline"
            >
              {gettext("Create Account")}
            </.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
