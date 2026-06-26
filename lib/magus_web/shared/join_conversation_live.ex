defmodule MagusWeb.JoinConversationLive do
  @moduledoc """
  LiveView for handling conversation join requests.

  Supports two types of invites:
  - Public links (/chat/join/:token) - Anyone with the link can join (if conversation is public)
  - Email invitations (/chat/invite/:token) - Only the invited email can join

  If the user is not logged in, they'll be prompted to sign in/register first.
  After authentication, they'll be redirected back to complete the join.
  """
  use MagusWeb, :live_view

  on_mount {MagusWeb.LiveUserAuth, :live_user_optional}

  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200">
      <div class="card w-96 bg-base-100 shadow-xl">
        <div class="card-body">
          <%= if @error do %>
            <div class="alert alert-error mb-4">
              <.icon name="lucide-alert-circle" class="w-5 h-5" />
              <span>{@error}</span>
            </div>
            <.link navigate={~p"/"} class="btn btn-primary">
              {gettext("Go Home")}
            </.link>
          <% else %>
            <h2 class="card-title">{gettext("Join Conversation")}</h2>
            <p class="text-base-content/70">
              {gettext("You've been invited to join \"%{title}\"", title: @conversation_title)}
            </p>

            <%= if @current_user do %>
              <%= if @already_member do %>
                <div class="alert alert-info mt-4">
                  <.icon name="lucide-info" class="w-5 h-5" />
                  <span>{gettext("You're already a member of this conversation.")}</span>
                </div>
                <div class="card-actions justify-end mt-4">
                  <.link navigate={~p"/chat/#{@conversation_id}"} class="btn btn-primary">
                    {gettext("Open Conversation")}
                  </.link>
                </div>
              <% else %>
                <%= if @email_mismatch do %>
                  <div class="alert alert-warning mt-4">
                    <.icon name="lucide-triangle-alert" class="w-5 h-5" />
                    <div>
                      <p>{gettext("This invitation was sent to a different email address.")}</p>
                      <p class="text-sm mt-1">
                        {gettext(
                          "You're signed in as %{current_email}, but the invitation was sent to %{invited_email}.",
                          current_email: @current_user.email,
                          invited_email: @invited_email
                        )}
                      </p>
                    </div>
                  </div>
                  <div class="card-actions justify-end mt-4">
                    <.link navigate={~p"/"} class="btn btn-ghost">
                      {gettext("Go Home")}
                    </.link>
                    <.link
                      navigate={~p"/sign-in?return_to=#{@return_path}"}
                      class="btn btn-primary"
                    >
                      {gettext("Sign in with different account")}
                    </.link>
                  </div>
                <% else %>
                  <%= if @needs_password do %>
                    <.form for={%{}} phx-submit="join_with_password" class="mt-4">
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text">
                            {gettext("This conversation is password protected")}
                          </span>
                        </label>
                        <input
                          type="password"
                          name="password"
                          class={"input input-bordered #{if @password_error, do: "input-error"}"}
                          placeholder={gettext("Enter password")}
                          required
                          autofocus
                        />
                        <label :if={@password_error} class="label">
                          <span class="label-text-alt text-error">{@password_error}</span>
                        </label>
                      </div>
                      <div class="card-actions justify-end mt-4">
                        <.link navigate={~p"/"} class="btn btn-ghost">
                          {gettext("Cancel")}
                        </.link>
                        <button type="submit" class="btn btn-primary">
                          {gettext("Join")}
                        </button>
                      </div>
                    </.form>
                  <% else %>
                    <div class="mt-4">
                      <p class="text-sm text-base-content/60 mb-4">
                        {gettext("You'll join as:")}
                        <span class="font-medium">{role_label(@role)}</span>
                      </p>
                    </div>
                    <div class="card-actions justify-end mt-4">
                      <.link navigate={~p"/"} class="btn btn-ghost">
                        {gettext("Cancel")}
                      </.link>
                      <button class="btn btn-primary" phx-click="join">
                        {gettext("Join Conversation")}
                      </button>
                    </div>
                  <% end %>
                <% end %>
              <% end %>
            <% else %>
              <p class="text-sm text-base-content/60 mt-4">
                {gettext("Please sign in or create an account to join this conversation.")}
              </p>
              <div class="card-actions justify-end mt-4">
                <.link
                  navigate={~p"/sign-in?return_to=#{@return_path}"}
                  class="btn btn-primary"
                >
                  {gettext("Sign In")}
                </.link>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    socket =
      socket
      |> assign(:token, token)
      |> assign(:error, nil)
      |> assign(:conversation_title, nil)
      |> assign(:conversation_id, nil)
      |> assign(:needs_password, false)
      |> assign(:password_error, nil)
      |> assign(:role, nil)
      |> assign(:already_member, false)
      |> assign(:email_mismatch, false)
      |> assign(:invited_email, nil)
      |> assign(:return_path, nil)

    {:ok, socket}
  end

  def handle_params(%{"token" => token}, _uri, socket) do
    invite_type = socket.assigns.live_action

    socket =
      socket
      |> assign(:token, token)
      |> assign(:return_path, return_path(invite_type, token))

    socket =
      case invite_type do
        :public_link -> handle_public_link(socket, token)
        :email_invite -> handle_email_invite(socket, token)
      end

    {:noreply, socket}
  end

  # Handle public invite link (anyone can join if conversation is public)
  defp handle_public_link(socket, token) do
    case Magus.Chat.get_invite_link_by_token(token, authorize?: false) do
      {:ok, nil} ->
        assign(socket, :error, gettext("This invite link is invalid or has expired."))

      {:ok, invite_link} ->
        invite_link =
          Ash.load!(invite_link, [:conversation, :is_expired, :is_exhausted, :has_password],
            authorize?: false
          )

        conversation = invite_link.conversation

        cond do
          invite_link.is_expired ->
            assign(socket, :error, gettext("This invite link has expired."))

          invite_link.is_exhausted ->
            assign(
              socket,
              :error,
              gettext("This invite link has reached its maximum number of uses.")
            )

          true ->
            already_member =
              if socket.assigns[:current_user] do
                check_already_member(conversation.id, socket.assigns.current_user.id)
              else
                false
              end

            socket
            |> assign(:invite_link, invite_link)
            |> assign(:invite_type, :public_link)
            |> assign(:conversation_title, conversation.title || "Untitled")
            |> assign(:conversation_id, conversation.id)
            |> assign(:needs_password, invite_link.has_password)
            |> assign(:role, invite_link.role)
            |> assign(:already_member, already_member)
        end

      {:error, _} ->
        assign(socket, :error, gettext("This invite link is invalid."))
    end
  end

  # Handle email invitation (only the invited email can join)
  defp handle_email_invite(socket, token) do
    case Magus.Chat.get_invitation_by_token(token, authorize?: false) do
      {:ok, nil} ->
        assign(socket, :error, gettext("This invitation is invalid or has already been used."))

      {:ok, invitation} ->
        invitation = Ash.load!(invitation, [:conversation], authorize?: false)
        conversation = invitation.conversation

        # Check if user email matches invitation
        email_mismatch =
          if socket.assigns[:current_user] do
            String.downcase(to_string(socket.assigns.current_user.email)) !=
              String.downcase(to_string(invitation.email))
          else
            false
          end

        already_member =
          if socket.assigns[:current_user] && !email_mismatch do
            check_already_member(conversation.id, socket.assigns.current_user.id)
          else
            false
          end

        socket
        |> assign(:invitation, invitation)
        |> assign(:invite_type, :email_invite)
        |> assign(:conversation_title, conversation.title || "Untitled")
        |> assign(:conversation_id, conversation.id)
        |> assign(:role, invitation.role)
        |> assign(:already_member, already_member)
        |> assign(:email_mismatch, email_mismatch)
        |> assign(:invited_email, to_string(invitation.email))

      {:error, _} ->
        assign(socket, :error, gettext("This invitation is invalid."))
    end
  end

  def handle_event("join", _, socket) do
    join_conversation(socket)
  end

  def handle_event("join_with_password", %{"password" => password}, socket) do
    # Verify password (only for public links)
    if Bcrypt.verify_pass(password, socket.assigns.invite_link.password_hash) do
      join_conversation(socket)
    else
      {:noreply, assign(socket, :password_error, gettext("Incorrect password"))}
    end
  end

  defp join_conversation(socket) do
    user = socket.assigns.current_user

    {conversation_id, role} =
      case socket.assigns.invite_type do
        :public_link ->
          {socket.assigns.invite_link.conversation_id, socket.assigns.invite_link.role}

        :email_invite ->
          {socket.assigns.invitation.conversation_id, socket.assigns.invitation.role}
      end

    # Add user as member
    case Magus.Chat.add_conversation_member(
           conversation_id,
           user.id,
           %{role: role},
           authorize?: false
         ) do
      {:ok, member} ->
        # Accept the invitation immediately
        Magus.Chat.accept_conversation_invitation!(member, authorize?: false)

        # Handle invite-specific cleanup
        case socket.assigns.invite_type do
          :public_link ->
            # Increment link uses
            Magus.Chat.increment_link_uses!(socket.assigns.invite_link, authorize?: false)

          :email_invite ->
            # Mark email invitation as accepted
            Magus.Chat.accept_invitation!(socket.assigns.invitation, authorize?: false)
        end

        {:noreply, push_navigate(socket, to: ~p"/chat/#{conversation_id}")}

      {:error, _} ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext("Could not join conversation. You may already be a member.")
         )}
    end
  end

  defp check_already_member(conversation_id, user_id) do
    require Ash.Query

    case Magus.Chat.ConversationMember
         |> Ash.Query.filter(conversation_id == ^conversation_id and user_id == ^user_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> false
      {:ok, _member} -> true
      {:error, _} -> false
    end
  end

  defp return_path(:public_link, token), do: "/chat/join/#{token}"
  defp return_path(:email_invite, token), do: "/chat/invite/#{token}"

  defp role_label(:owner), do: gettext("Owner")
  defp role_label(:member), do: gettext("Member")
  defp role_label(:observer), do: gettext("Observer (read-only)")
  defp role_label(_), do: gettext("Member")
end
