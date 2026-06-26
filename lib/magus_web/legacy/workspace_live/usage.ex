defmodule MagusWeb.WorkspaceLive.Usage do
  @moduledoc """
  Workspace usage view: aggregate token usage, per-member breakdown, and
  workspace storage. Rendered as a workbench detail view via
  `MagusWeb.Workbench.Detail.WorkspaceUsageView`.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    current_user = socket.assigns.current_user
    {:ok, init_assigns(socket, slug, current_user)}
  end

  @doc """
  Public init hook used by WorkspaceUsageView (workbench detail view).
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

          active_members = Enum.filter(workspace.members, & &1.is_active)

          socket
          |> assign(:page_title, gettext("Workspace Usage"))
          |> assign(:workspace, workspace)
          |> assign(:active_members, active_members)
          |> assign(:member_usage, [])
          |> load_usage_data()
        else
          socket
          |> put_flash(:error, gettext("Only workspace owners can access settings."))
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
          {render_usage_section(assigns)}
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc """
  Renders the workspace usage page body (no Layouts.app wrapper).
  Used by WorkspaceUsageView (workbench detail view).
  """
  def render_usage_section(assigns) do
    total_tokens =
      Enum.reduce(assigns.member_usage, 0, fn entry, acc -> acc + entry.tokens end)

    assigns = assign(assigns, :total_tokens, total_tokens)

    ~H"""
    <div class="flex items-center gap-3 mb-6">
      <div class="flex items-center justify-center w-10 h-10 rounded-lg bg-primary/10 text-primary font-bold">
        {String.first(@workspace.name)}
      </div>
      <div>
        <h1 class="text-2xl font-bold text-base-content">{@workspace.name}</h1>
        <p class="text-sm text-base-content/60">{gettext("Workspace Usage")}</p>
      </div>
    </div>

    <div class="space-y-6">
      <div class="bg-base-200 border border-base-300 rounded-xl shadow-sm">
        <div class="p-5">
          <h3 class="text-lg font-semibold text-base-content mb-4">{gettext("Today's Usage")}</h3>

          <div class="grid grid-cols-2 gap-6">
            <div>
              <p class="text-3xl font-bold text-primary">{@total_tokens}</p>
              <p class="text-sm text-base-content/60">{gettext("Billable tokens today")}</p>
            </div>
            <div>
              <p class="text-3xl font-bold">{length(@active_members)}</p>
              <p class="text-sm text-base-content/60">{gettext("Active members")}</p>
            </div>
          </div>

          <p class="text-xs text-base-content/50 mt-4">
            {gettext("Uses a UTC day window for this aggregate view")}
          </p>
        </div>
      </div>

      <div class="bg-base-200 border border-base-300 rounded-xl shadow-sm">
        <div class="p-5">
          <h3 class="text-lg font-semibold text-base-content mb-4">{gettext("Member Usage")}</h3>

          <div :if={@member_usage == []} class="text-sm text-base-content/60">
            {gettext("No member activity yet.")}
          </div>

          <div :if={@member_usage != []} class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>{gettext("Member")}</th>
                  <th>{gettext("Role")}</th>
                  <th>{gettext("Tokens today")}</th>
                  <th>{gettext("Storage")}</th>
                  <th>{gettext("Last active")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @member_usage}>
                  <td>{member_display_name(entry.member)}</td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      entry.member.role == :admin && "badge-primary",
                      entry.member.role == :member && "badge-ghost"
                    ]}>
                      {entry.member.role}
                    </span>
                  </td>
                  <td>{entry.tokens}</td>
                  <td>{format_bytes(entry.storage_bytes)}</td>
                  <td>
                    <span :if={entry.last_active_at} title={entry.last_active_at}>
                      {Calendar.strftime(entry.last_active_at, "%Y-%m-%d %H:%M")}
                    </span>
                    <span :if={is_nil(entry.last_active_at)} class="text-base-content/40">
                      {gettext("never")}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="bg-base-200 border border-base-300 rounded-xl shadow-sm">
        <div class="p-5">
          <h3 class="text-lg font-semibold text-base-content mb-4">{gettext("Workspace Storage")}</h3>
          <p class="text-sm text-base-content/60">
            {gettext("Storage used by files uploaded to this workspace.")}
          </p>
          <p class="text-2xl font-bold mt-2">{format_bytes(@workspace.storage_usage_bytes || 0)}</p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_info({:workspace_deactivated, _workspace_id}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("This workspace has been deactivated."))
     |> push_navigate(to: ~p"/chat")}
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  def load_usage_data(socket) do
    active_members = socket.assigns.active_members
    workspace_id = socket.assigns.workspace.id

    members_with_users =
      Ash.load!(active_members, [:user], actor: socket.assigns.current_user)

    user_ids = members_with_users |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1)

    storage_by_user = storage_by_user(workspace_id, user_ids)
    last_active_by_user = last_active_by_user(workspace_id, user_ids)
    tokens_by_user = tokens_today_by_user(workspace_id, user_ids)

    member_usage =
      members_with_users
      |> Enum.filter(& &1.user_id)
      |> Enum.map(fn member ->
        %{
          member: member,
          tokens: Map.get(tokens_by_user, member.user_id, 0),
          storage_bytes: Map.get(storage_by_user, member.user_id, 0),
          last_active_at: Map.get(last_active_by_user, member.user_id)
        }
      end)
      |> Enum.sort_by(
        fn m -> m.last_active_at || ~U[1970-01-01 00:00:00Z] end,
        {:desc, DateTime}
      )

    assign(socket, :member_usage, member_usage)
  end

  defp tokens_today_by_user(_workspace_id, []), do: %{}

  defp tokens_today_by_user(_workspace_id, user_ids) do
    # Uses a UTC day window for batching simplicity. Per-user timezones would
    # require grouping by timezone and running one query per distinct timezone.
    # The minor UTC drift is acceptable for owner-facing aggregate display.
    import Ecto.Query

    today = Date.utc_today()
    start_utc = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
    end_utc = DateTime.add(start_utc, 1, :day)

    from(u in Magus.Usage.MessageUsage,
      where:
        u.user_id in ^user_ids and
          u.billable == true and
          u.inserted_at >= ^start_utc and
          u.inserted_at < ^end_utc,
      group_by: u.user_id,
      select: {u.user_id, sum(u.total_tokens)}
    )
    |> Magus.Repo.all()
    |> Map.new(fn {uid, tokens} ->
      {uid, tokens || 0}
    end)
  end

  # deleted_at IS NULL guard must be maintained manually; Ash base_filter does not apply to raw Ecto.
  defp storage_by_user(_workspace_id, []), do: %{}

  defp storage_by_user(workspace_id, user_ids) do
    import Ecto.Query

    from(f in Magus.Files.File,
      where: f.workspace_id == ^workspace_id and f.user_id in ^user_ids,
      where: is_nil(f.deleted_at),
      group_by: f.user_id,
      select: {f.user_id, sum(f.file_size)}
    )
    |> Magus.Repo.all()
    |> Map.new(fn {uid, sum} -> {uid, sum || 0} end)
  end

  defp last_active_by_user(_workspace_id, []), do: %{}

  defp last_active_by_user(workspace_id, user_ids) do
    import Ecto.Query

    from(m in Magus.Chat.Message,
      join: c in Magus.Chat.Conversation,
      on: c.id == m.conversation_id,
      where:
        c.workspace_id == ^workspace_id and
          m.created_by_id in ^user_ids and
          m.role == :user,
      group_by: m.created_by_id,
      select: {m.created_by_id, max(m.inserted_at)}
    )
    |> Magus.Repo.all()
    |> Map.new()
  end

  defp format_bytes(bytes), do: MagusWeb.Formatters.format_bytes(bytes)

  defp member_display_name(member) do
    cond do
      member.user && member.user.display_name -> member.user.display_name
      member.user && member.user.email -> member.user.email
      member.invite_email -> member.invite_email
      true -> gettext("Unknown")
    end
  end
end
