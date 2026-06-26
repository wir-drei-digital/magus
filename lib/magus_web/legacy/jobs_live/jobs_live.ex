defmodule MagusWeb.JobsLive do
  @moduledoc """
  LiveView for managing scheduled workflow jobs.

  Displays a list of the user's jobs with filtering, styled to match the search view.
  """
  use MagusWeb, :live_view

  alias Magus.Workflows
  alias MagusWeb.Layouts

  import MagusWeb.JobsLive.Helpers, only: [format_datetime: 2, describe_cron: 1]

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    socket = init_assigns(socket, socket.assigns.current_user)
    {:ok, socket}
  end

  @doc """
  Public init hook used by JobsView (workbench detail view).
  """
  def init_assigns(socket, user) do
    jobs = filter_jobs(user.id, :all, user)

    socket
    |> assign(:page_title, gettext("Scheduled Jobs"))
    |> assign(:user, user)
    |> assign(:filter, :all)
    |> assign(:jobs, jobs)
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
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
      <:notification_bell>
        <.live_component
          module={MagusWeb.NotificationBellComponent}
          id="notification-bell"
          current_user={@current_user}
          unread_count={@unread_count}
        />
      </:notification_bell>

      <div class="min-h-full">
        <div class="max-w-4xl mx-auto p-4 md:p-8">
          {render_jobs_list(assigns)}
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc """
  Renders the jobs list body (no Layouts.app wrapper).
  Used by JobsView (workbench detail view).
  """
  def render_jobs_list(assigns) do
    ~H"""
    <div class="mb-8">
      <h1 class="text-2xl font-bold text-base-content mb-2">{gettext("Scheduled Jobs")}</h1>
      <p class="text-base-content/60">
        {gettext("Manage automated tasks scheduled to run in your conversations")}
      </p>
    </div>

    <div class="space-y-6">
      <%!-- Filter Buttons --%>
      <div class="flex flex-wrap gap-2">
        <.filter_button filter={:all} current={@filter} count={count_jobs(@jobs, :all)} />
        <.filter_button filter={:active} current={@filter} count={count_jobs(@jobs, :active)} />
        <.filter_button filter={:paused} current={@filter} count={count_jobs(@jobs, :paused)} />
      </div>

      <%!-- Results --%>
      <div class="min-h-[300px]">
        <%= if @jobs == [] do %>
          <.empty_state filter={@filter} />
        <% else %>
          <.job_list jobs={filter_display(@jobs, @filter)} user={@user} />
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================
  # Components
  # ============================================

  defp filter_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="filter"
      phx-value-filter={@filter}
      class={[
        "flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
        if(@filter == @current,
          do: "bg-primary text-primary-content",
          else: "bg-base-200 text-base-content/60 hover:bg-base-300"
        )
      ]}
    >
      <.filter_icon filter={@filter} />
      <span>{filter_label(@filter)}</span>
      <span
        :if={@count > 0}
        class={[
          "px-1.5 py-0.5 text-xs rounded-full",
          if(@filter == @current,
            do: "bg-primary-content/20 text-primary-content",
            else: "bg-base-300 text-base-content/60"
          )
        ]}
      >
        {@count}
      </span>
    </button>
    """
  end

  defp filter_icon(%{filter: :all} = assigns),
    do: ~H|<.icon name="lucide-list" class="w-4 h-4" />|

  defp filter_icon(%{filter: :active} = assigns),
    do: ~H|<.icon name="lucide-play" class="w-4 h-4" />|

  defp filter_icon(%{filter: :paused} = assigns),
    do: ~H|<.icon name="lucide-pause" class="w-4 h-4" />|

  defp filter_label(:all), do: gettext("All")
  defp filter_label(:active), do: gettext("Active")
  defp filter_label(:paused), do: gettext("Paused")

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-base-content/50">
      <.icon name="lucide-clock" class="w-12 h-12 mb-4 opacity-50" />
      <%= if @filter == :all do %>
        <p class="text-lg mb-2">{gettext("No scheduled jobs yet")}</p>
        <p class="text-sm">
          {gettext("Create jobs in conversations by asking the assistant to schedule tasks")}
        </p>
      <% else %>
        <p class="text-lg">{gettext("No %{filter} jobs", filter: filter_label(@filter))}</p>
      <% end %>
    </div>
    """
  end

  defp job_list(assigns) do
    ~H"""
    <div class="grid gap-4">
      <.list_card :for={job <- @jobs} navigate={~p"/jobs/#{job.id}"} icon="lucide-clock">
        <:title>{job.name}</:title>
        <:badge><.status_badge status={job.status} /></:badge>
        <:subtitle :if={job.description}>{job.description}</:subtitle>
        <:meta>
          <span class="flex items-center gap-1">
            <.icon name="lucide-calendar" class="w-3.5 h-3.5" />
            {format_schedule(job)}
          </span>
          <span :if={job.next_run_at} class="flex items-center gap-1">
            <.icon name="lucide-arrow-right-circle" class="w-3.5 h-3.5" />
            {gettext("Next: %{time}", time: format_datetime(job.next_run_at, @user.timezone))}
          </span>
          <span :if={job.last_run_at} class="flex items-center gap-1">
            <.icon name="lucide-check-circle" class="w-3.5 h-3.5" />
            {gettext("Last: %{time}", time: format_datetime(job.last_run_at, @user.timezone))}
          </span>
        </:meta>
      </.list_card>
    </div>
    """
  end

  defp status_badge(assigns) do
    {color, text} =
      case assigns.status do
        :active -> {"bg-success/10 text-success", gettext("Active")}
        :paused -> {"bg-warning/10 text-warning", gettext("Paused")}
        :stopped -> {"bg-error/10 text-error", gettext("Stopped")}
        :completed -> {"bg-info/10 text-info", gettext("Completed")}
      end

    assigns = assign(assigns, :color, color)
    assigns = assign(assigns, :text, text)

    ~H"""
    <span class={["text-xs px-2 py-0.5 rounded-full shrink-0", @color]}>{@text}</span>
    """
  end

  defp format_schedule(job) do
    case job.schedule_type do
      :cron ->
        local_cron = job.cron_expression_local || job.cron_expression
        describe_cron(local_cron)

      :one_time ->
        gettext("One-time")
    end
  end

  # ============================================
  # Events
  # ============================================

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    filter = String.to_existing_atom(filter)
    {:noreply, assign(socket, :filter, filter)}
  end

  # ============================================
  # Helpers
  # ============================================

  defp filter_jobs(user_id, _filter, actor) do
    # Load all jobs, filtering happens client-side for instant switching
    Workflows.list_jobs_for_user!(user_id, actor: actor)
  end

  defp filter_display(jobs, :all), do: jobs
  defp filter_display(jobs, filter), do: Enum.filter(jobs, &(&1.status == filter))

  defp count_jobs(jobs, :all), do: length(jobs)
  defp count_jobs(jobs, filter), do: Enum.count(jobs, &(&1.status == filter))
end
