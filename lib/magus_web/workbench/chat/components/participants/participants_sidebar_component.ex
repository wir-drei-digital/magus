defmodule MagusWeb.ChatLive.Components.Participants.ParticipantsSidebarComponent do
  @moduledoc """
  Sidebar component for displaying and managing participants in a multiplayer conversation.

  Supports two visibility modes:
  - invite_only: Only users with email invitations can join
  - public: Anyone with a public link can join

  Uses `phx-target={@myself}` for all events.
  Notifies parent via `notify_parent/1` for flash messages and member reloads.
  """
  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  import MagusWeb.ChatLive.Components.Participants.UIHelpers

  alias Magus.Chat.ConversationInvitation.Senders.SendInvitationEmail

  def render(assigns) do
    ~H"""
    <div id={@id} class="p-2 h-full w-full flex flex-col">
      <div class="sidebar-card flex flex-col flex-1 overflow-hidden">
        <%!-- Header --%>
        <div class="flex items-center justify-between px-3 py-2.5 bg-base-100 border-b border-base-300">
          <div class="flex items-center gap-2">
            <.icon name="lucide-users" class="w-4 h-4 opacity-60" />
            <span class="text-sm font-medium">{gettext("Participants")}</span>
          </div>
          <div class="badge badge-sm badge-ghost">{length(@members)}</div>
        </div>

        <%!-- Content --%>
        <div class="sidebar-card-content flex-1 flex flex-col gap-3 overflow-y-auto">
          <%!-- Invite Button (Owner only) --%>
          <button
            :if={@is_owner}
            class="btn btn-primary btn-sm w-full"
            phx-click="show_invite_modal"
            phx-target={@myself}
          >
            <.icon name="lucide-user-plus" class="w-4 h-4" /> {gettext("Invite")}
          </button>

          <%!-- Members List --%>
          <div class="space-y-1">
            <.member_item
              :for={member <- @members}
              member={member}
              is_owner={@is_owner}
              myself={@myself}
            />

            <%!-- Pending Email Invitations --%>
            <.invitation_item
              :for={invitation <- @pending_invitations}
              invitation={invitation}
              is_owner={@is_owner}
              myself={@myself}
            />

            <div
              :if={@members == [] && @pending_invitations == []}
              class="text-center text-base-content/50 py-8"
            >
              {gettext("No participants yet.")}
            </div>
          </div>

          <%!-- Leave Button (Non-owners only) --%>
          <div :if={!@is_owner} class="mt-3 pt-3 border-t border-base-300">
            <button
              class="btn btn-outline btn-sm w-full"
              phx-click="leave_conversation"
              phx-target={@myself}
            >
              <.icon name="lucide-log-out" class="w-4 h-4" /> {gettext("Leave Conversation")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     |> assign(:show_invite_modal, false)
     |> assign(:show_role_modal, false)
     |> assign(:show_password_input, false)
     |> assign(:editing_member_id, nil)
     |> assign(:invite_links, [])
     |> assign(:pending_invitations, [])
     |> assign(:visibility, :invite_only)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> load_visibility()
      |> load_invite_links()
      |> load_pending_invitations()

    {:ok, socket}
  end

  # Event Handlers

  def handle_event("show_invite_modal", _, socket) do
    socket =
      socket
      |> assign(:show_invite_modal, true)
      |> load_invite_links()
      |> load_pending_invitations()

    push_modal_state(socket)
    {:noreply, socket}
  end

  def handle_event("hide_invite_modal", _, socket) do
    socket =
      socket
      |> assign(:show_invite_modal, false)
      |> assign(:show_password_input, false)

    push_modal_state(socket)
    {:noreply, socket}
  end

  def handle_event("toggle_visibility", _, socket) do
    new_visibility =
      case socket.assigns.visibility do
        :invite_only -> :public
        :public -> :invite_only
      end

    # Update conversation visibility
    conversation =
      Magus.Chat.get_conversation!(socket.assigns.conversation_id,
        actor: socket.assigns.current_user
      )

    case Magus.Chat.update_conversation_visibility(conversation, %{visibility: new_visibility},
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        socket = assign(socket, :visibility, new_visibility)
        push_modal_state(socket)
        {:noreply, socket}

      {:error, _} ->
        notify_parent({:flash, :error, "Could not update visibility"})
        {:noreply, socket}
    end
  end

  def handle_event("toggle_password", _, socket) do
    socket = assign(socket, :show_password_input, !socket.assigns.show_password_input)
    push_modal_state(socket)
    {:noreply, socket}
  end

  def handle_event("invite_by_email", %{"email" => email, "role" => role}, socket) do
    # Create email invitation
    case Magus.Chat.create_invitation(
           socket.assigns.conversation_id,
           %{email: email, role: String.to_existing_atom(role)},
           actor: socket.assigns.current_user
         ) do
      {:ok, invitation} ->
        # Load conversation and send email
        conversation =
          Magus.Chat.get_conversation!(socket.assigns.conversation_id,
            actor: socket.assigns.current_user
          )

        # Send invitation email
        Task.start(fn ->
          SendInvitationEmail.send(invitation, conversation, socket.assigns.current_user)
        end)

        notify_parent({:flash, :info, "Invitation sent to #{email}"})

        {:noreply, load_pending_invitations(socket)}

      {:error, error} ->
        # Check if it's a uniqueness error (identity constraint)
        error_message =
          case error do
            %Ash.Error.Invalid{errors: errors} ->
              if Enum.any?(errors, fn e ->
                   match?(%Ash.Error.Changes.InvalidChanges{}, e)
                 end) do
                "An invitation has already been sent to this email"
              else
                "Could not send invitation"
              end

            _ ->
              "Could not send invitation"
          end

        notify_parent({:flash, :error, error_message})
        {:noreply, socket}
    end
  end

  def handle_event("cancel_invitation", %{"id" => id}, socket) do
    invitation = Enum.find(socket.assigns.pending_invitations, &(&1.id == id))

    if invitation do
      Magus.Chat.delete_invitation!(invitation, actor: socket.assigns.current_user)
      notify_parent({:flash, :info, "Invitation cancelled"})
    end

    {:noreply, load_pending_invitations(socket)}
  end

  def handle_event("create_invite_link", params, socket) do
    role = String.to_existing_atom(params["role"] || "member")
    password = if params["has_password"] == "true", do: params["password"], else: nil

    case Magus.Chat.create_invite_link(
           socket.assigns.conversation_id,
           %{role: role, password: password},
           actor: socket.assigns.current_user
         ) do
      {:ok, _link} ->
        socket = load_invite_links(socket)
        push_modal_state(socket)
        {:noreply, socket}

      {:error, error} ->
        notify_parent({:flash, :error, "Could not create invite link: #{inspect(error)}"})
        {:noreply, socket}
    end
  end

  def handle_event("reset_links", _, socket) do
    socket = assign(socket, :invite_links, [])
    push_modal_state(socket)
    {:noreply, socket}
  end

  def handle_event("delete_link", %{"id" => id}, socket) do
    link = Enum.find(socket.assigns.invite_links, &(&1.id == id))

    if link do
      Magus.Chat.delete_invite_link!(link, actor: socket.assigns.current_user)
    end

    socket = load_invite_links(socket)
    push_modal_state(socket)
    {:noreply, socket}
  end

  def handle_event("mute_member", %{"id" => id}, socket) do
    member = find_member(socket, id)

    if member do
      Magus.Chat.mute_member!(member, actor: socket.assigns.current_user)
      notify_parent(:reload_members)
    end

    {:noreply, socket}
  end

  def handle_event("unmute_member", %{"id" => id}, socket) do
    member = find_member(socket, id)

    if member do
      Magus.Chat.unmute_member!(member, actor: socket.assigns.current_user)
      notify_parent(:reload_members)
    end

    {:noreply, socket}
  end

  def handle_event("show_role_modal", %{"id" => id}, socket) do
    socket =
      socket
      |> assign(:show_role_modal, true)
      |> assign(:editing_member_id, id)

    push_modal_state(socket)
    {:noreply, socket}
  end

  def handle_event("hide_role_modal", _, socket) do
    socket =
      socket
      |> assign(:show_role_modal, false)
      |> assign(:editing_member_id, nil)

    push_modal_state(socket)
    {:noreply, socket}
  end

  def handle_event("change_role", %{"member_id" => id, "role" => role}, socket) do
    member = find_member(socket, id)

    if member do
      new_role = String.to_existing_atom(role)

      Magus.Chat.change_member_role!(member, %{role: new_role},
        actor: socket.assigns.current_user
      )

      notify_parent(:reload_members)
    end

    socket =
      socket
      |> assign(:show_role_modal, false)
      |> assign(:editing_member_id, nil)

    push_modal_state(socket)
    {:noreply, socket}
  end

  def handle_event("kick_member", %{"id" => id}, socket) do
    member = find_member(socket, id)

    if member do
      Magus.Chat.remove_conversation_member!(member, actor: socket.assigns.current_user)
      notify_parent(:reload_members)
    end

    {:noreply, socket}
  end

  def handle_event("leave_conversation", _, socket) do
    member =
      Enum.find(socket.assigns.members, &(&1.user_id == socket.assigns.current_user.id))

    if member do
      Magus.Chat.remove_conversation_member!(member, actor: socket.assigns.current_user)
      notify_parent({:navigate, "/"})
    end

    {:noreply, socket}
  end

  # Private functions

  defp load_visibility(socket) do
    if socket.assigns[:conversation_id] do
      conversation =
        Magus.Chat.get_conversation!(socket.assigns.conversation_id,
          actor: socket.assigns.current_user
        )

      assign(socket, :visibility, conversation.visibility)
    else
      socket
    end
  end

  defp load_invite_links(socket) do
    if socket.assigns[:conversation_id] && socket.assigns[:is_owner] do
      links =
        Magus.Chat.get_active_invite_links!(
          socket.assigns.conversation_id,
          actor: socket.assigns.current_user
        )

      assign(socket, :invite_links, links)
    else
      assign(socket, :invite_links, [])
    end
  end

  defp load_pending_invitations(socket) do
    if socket.assigns[:conversation_id] && socket.assigns[:is_owner] do
      invitations =
        Magus.Chat.get_pending_invitations!(
          socket.assigns.conversation_id,
          actor: socket.assigns.current_user
        )

      assign(socket, :pending_invitations, invitations)
    else
      assign(socket, :pending_invitations, [])
    end
  end

  defp push_modal_state(socket) do
    notify_parent(
      {:modal_state,
       %{
         show_invite_modal: socket.assigns.show_invite_modal,
         visibility: socket.assigns.visibility,
         invite_links: socket.assigns.invite_links,
         show_password_input: socket.assigns.show_password_input,
         show_role_modal: socket.assigns.show_role_modal,
         editing_member_id: socket.assigns.editing_member_id
       }}
    )
  end

  defp find_member(socket, id) do
    Enum.find(socket.assigns.members, &(&1.id == id))
  end
end
