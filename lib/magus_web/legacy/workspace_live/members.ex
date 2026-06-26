defmodule MagusWeb.WorkspaceLive.Members do
  @moduledoc """
  Workspace member management page for owners.
  Lists members, handles invitations, role changes, and deactivation.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts
  alias Magus.Workspaces.WorkspaceMember

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    current_user = socket.assigns.current_user
    socket = init_assigns(socket, slug, current_user)
    {:ok, socket}
  end

  @doc """
  Public init hook used by WorkspaceMembersView (workbench detail view).
  """
  def init_assigns(socket, slug, actor) do
    case Magus.Workspaces.get_workspace_by_slug(slug, actor: actor) do
      {:ok, workspace} ->
        workspace = Ash.load!(workspace, [members: :user], actor: actor)
        member = Enum.find(workspace.members, &(&1.user_id == actor.id))

        if member && member.role == :admin do
          if connected?(socket) do
            Phoenix.PubSub.subscribe(Magus.PubSub, "workspaces:#{workspace.id}")
          end

          socket
          |> assign(:page_title, gettext("Workspace Members"))
          |> assign(:workspace, workspace)
          |> assign(:members, workspace.members)
          |> assign(:invite_form, build_invite_form(workspace.id, actor))
          |> assign(:current_member, member)
          |> assign(:last_invite_at, nil)
        else
          socket
          |> put_flash(:error, gettext("Only workspace owners can manage members."))
          |> push_navigate(to: ~p"/chat")
        end

      {:error, _} ->
        socket
        |> put_flash(:error, gettext("Workspace not found."))
        |> push_navigate(to: ~p"/chat")
    end
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
      <div class="min-h-full">
        <div class="max-w-3xl mx-auto p-4 md:p-8">
          {render_members_section(assigns)}
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc """
  Renders the workspace members page body (no Layouts.app wrapper).
  Used by WorkspaceMembersView (workbench detail view).
  """
  def render_members_section(assigns) do
    ~H"""
    <%!-- Page header --%>
    <div class="flex items-center gap-3 mb-6">
      <div class="flex items-center justify-center w-10 h-10 rounded-lg bg-primary/10 text-primary font-bold">
        {String.first(@workspace.name)}
      </div>
      <div>
        <h1 class="text-2xl font-bold text-base-content">{@workspace.name}</h1>
        <p class="text-sm text-base-content/60">{gettext("Workspace Members")}</p>
      </div>
    </div>

    <%!-- Invite Form --%>
    <div class="bg-base-200 border border-base-300 rounded-xl p-5 shadow-sm mb-6">
      <h3 class="text-lg font-semibold text-base-content mb-4">{gettext("Invite Member")}</h3>
      <.form
        for={@invite_form}
        phx-change="validate_invite"
        phx-submit="invite_member"
        class="flex gap-3 items-start"
      >
        <div class="flex-1">
          <.input
            field={@invite_form[:invite_email]}
            type="email"
            placeholder={gettext("colleague@company.com")}
            required
          />
        </div>
        <button type="submit" class="btn btn-primary" phx-debounce="1000">
          <.icon name="lucide-send" class="w-4 h-4" />
          {gettext("Invite")}
        </button>
      </.form>
    </div>

    <%!-- Members List --%>
    <div class="bg-base-200 border border-base-300 rounded-xl p-5 shadow-sm">
      <h3 class="text-lg font-semibold text-base-content mb-4">{gettext("Members")}</h3>
      <div class="space-y-3">
        <div
          :for={member <- @members}
          class="flex items-center gap-3 p-4 bg-base-200/50 rounded-lg"
        >
          <div class="flex items-center justify-center w-10 h-10 rounded-full bg-primary/10 text-primary font-bold">
            {member_initial(member)}
          </div>

          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <span class="font-medium truncate">
                {member_display_name(member)}
              </span>
              <span class={[
                "badge badge-sm",
                member.role == :admin && "badge-primary",
                member.role == :member && "badge-ghost"
              ]}>
                {member.role}
              </span>
            </div>
            <span class="text-xs text-base-content/50">
              {member.invite_email}
            </span>
          </div>

          <div class="flex items-center gap-2">
            <span class={[
              "badge badge-sm",
              member.status == :active && "badge-success",
              member.status == :invited && "badge-warning",
              member.status == :deactivated && "badge-error"
            ]}>
              {member.status}
            </span>

            <%= if member.id != @current_member.id && member.status == :active do %>
              <form phx-change="change_role" class="inline">
                <input type="hidden" name="member_id" value={member.id} />
                <select name="role" class="select select-ghost select-xs">
                  <option value="member" selected={member.role == :member}>
                    {gettext("Member")}
                  </option>
                  <option value="admin" selected={member.role == :admin}>
                    {gettext("Admin")}
                  </option>
                </select>
              </form>

              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="transfer_ownership"
                phx-value-member-id={member.id}
                data-confirm={
                  gettext("Transfer ownership to this member? You will become a regular member.")
                }
                title={gettext("Transfer ownership")}
              >
                <.icon name="lucide-crown" class="w-4 h-4" />
              </button>

              <button
                type="button"
                class="btn btn-ghost btn-xs btn-square text-error"
                phx-click="deactivate_member"
                phx-value-member-id={member.id}
                data-confirm={gettext("Are you sure you want to remove this member?")}
              >
                <.icon name="lucide-user-minus" class="w-4 h-4" />
              </button>
            <% end %>

            <%= if member.status == :invited do %>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="resend_invite"
                phx-value-member-id={member.id}
                title={gettext("Resend invite")}
              >
                <.icon name="lucide-send" class="w-4 h-4" />
              </button>

              <button
                type="button"
                class="btn btn-ghost btn-xs btn-square text-error"
                phx-click="revoke_invite"
                phx-value-member-id={member.id}
                data-confirm={gettext("Revoke this invitation?")}
                title={gettext("Revoke invite")}
              >
                <.icon name="lucide-x" class="w-4 h-4" />
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @invite_cooldown_ms 3_000

  defp build_invite_form(workspace_id, actor) do
    WorkspaceMember
    |> AshPhoenix.Form.for_create(:invite,
      actor: actor,
      transform_params: fn _form, params, _ ->
        Map.put(params, "workspace_id", workspace_id)
      end
    )
    |> to_form()
  end

  @impl true
  def handle_event("validate_invite", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.invite_form, params)
    {:noreply, assign(socket, :invite_form, form)}
  end

  @impl true
  def handle_event("invite_member", %{"form" => params}, socket) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns[:last_invite_at]

    cond do
      last && now - last < @invite_cooldown_ms ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Please wait a moment before sending another invitation.")
         )}

      true ->
        case AshPhoenix.Form.submit(socket.assigns.invite_form, params: params) do
          {:ok, member} ->
            workspace =
              Ash.load!(socket.assigns.workspace, [members: :user],
                actor: socket.assigns.current_user
              )

            {:noreply,
             socket
             |> assign(:members, workspace.members)
             |> assign(
               :invite_form,
               build_invite_form(socket.assigns.workspace.id, socket.assigns.current_user)
             )
             |> assign(:last_invite_at, now)
             |> put_flash(
               :info,
               gettext("Invitation sent to %{email}.", email: member.invite_email)
             )}

          {:error, form} ->
            {:noreply, assign(socket, :invite_form, form)}
        end
    end
  end

  @impl true
  def handle_event("change_role", %{"member_id" => member_id, "role" => role_str}, socket) do
    role = String.to_existing_atom(role_str)
    member = Enum.find(socket.assigns.members, &(&1.id == member_id))

    if member do
      case Magus.Workspaces.change_member_role(member, role, actor: socket.assigns.current_user) do
        {:ok, _} ->
          workspace =
            Ash.load!(socket.assigns.workspace, [members: :user],
              actor: socket.assigns.current_user
            )

          {:noreply,
           socket
           |> assign(:members, workspace.members)
           |> put_flash(:info, gettext("Role updated."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not change role."))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("transfer_ownership", %{"member-id" => member_id}, socket) do
    member = Enum.find(socket.assigns.members, &(&1.id == member_id))

    if member do
      case Magus.Workspaces.transfer_ownership_to(member, actor: socket.assigns.current_user) do
        {:ok, _} ->
          workspace =
            Ash.load!(socket.assigns.workspace, [members: :user],
              actor: socket.assigns.current_user
            )

          current_member =
            Enum.find(workspace.members, &(&1.user_id == socket.assigns.current_user.id))

          if current_member && current_member.role == :admin do
            {:noreply,
             socket
             |> assign(:members, workspace.members)
             |> assign(:current_member, current_member)
             |> put_flash(:info, gettext("Ownership transferred."))}
          else
            {:noreply,
             socket
             |> put_flash(:info, gettext("Ownership transferred."))
             |> push_navigate(to: ~p"/chat")}
          end

        {:error, error} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Could not transfer ownership: %{reason}", reason: format_error(error))
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("deactivate_member", %{"member-id" => member_id}, socket) do
    member = Enum.find(socket.assigns.members, &(&1.id == member_id))

    if member do
      case Magus.Workspaces.deactivate_member(member, actor: socket.assigns.current_user) do
        {:ok, _} ->
          workspace =
            Ash.load!(socket.assigns.workspace, [members: :user],
              actor: socket.assigns.current_user
            )

          {:noreply,
           socket
           |> assign(:members, workspace.members)
           |> put_flash(:info, gettext("Member removed."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not remove member."))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("resend_invite", %{"member-id" => member_id}, socket) do
    member = Enum.find(socket.assigns.members, &(&1.id == member_id))

    if member do
      case Magus.Workspaces.resend_invite(member, actor: socket.assigns.current_user) do
        {:ok, _} ->
          workspace =
            Ash.load!(socket.assigns.workspace, [members: :user],
              actor: socket.assigns.current_user
            )

          {:noreply,
           socket
           |> assign(:members, workspace.members)
           |> put_flash(:info, gettext("Invitation resent."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not resend invitation."))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("revoke_invite", %{"member-id" => member_id}, socket) do
    member = Enum.find(socket.assigns.members, &(&1.id == member_id))

    if member do
      case Magus.Workspaces.deactivate_member(member, actor: socket.assigns.current_user) do
        {:ok, _} ->
          workspace =
            Ash.load!(socket.assigns.workspace, [members: :user],
              actor: socket.assigns.current_user
            )

          {:noreply,
           socket
           |> assign(:members, workspace.members)
           |> put_flash(:info, gettext("Invitation revoked."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not revoke invitation."))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:workspace_deactivated, _workspace_id}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("This workspace has been deactivated."))
     |> push_navigate(to: ~p"/chat")}
  end

  defp format_error(%Ash.Error.Invalid{errors: errors}) do
    errors |> Enum.map(&safe_message/1) |> Enum.join(", ")
  end

  defp format_error(error), do: safe_message(error)

  defp safe_message(error) when is_exception(error), do: Exception.message(error)
  defp safe_message(%{message: message}) when is_binary(message), do: message
  defp safe_message(other), do: inspect(other)

  defp member_initial(member) do
    cond do
      member.user && member.user.display_name ->
        String.first(member.user.display_name)

      member.invite_email ->
        member.invite_email |> String.first() |> String.upcase()

      true ->
        "?"
    end
  end

  defp member_display_name(member) do
    cond do
      member.user && member.user.display_name -> member.user.display_name
      member.user && member.user.email -> member.user.email
      member.invite_email -> member.invite_email
      true -> gettext("Unknown")
    end
  end
end
