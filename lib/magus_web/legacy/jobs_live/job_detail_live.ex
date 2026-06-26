defmodule MagusWeb.JobDetailLive do
  @moduledoc """
  LiveView for displaying job details.

  Shows comprehensive job information including schedule, trigger prompt,
  run history, and action buttons.
  """
  use MagusWeb, :live_view

  alias Magus.Workflows
  alias MagusWeb.Layouts

  import MagusWeb.JobsLive.Helpers,
    only: [format_datetime_full: 2, format_duration: 2, describe_cron: 1]

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user
    socket = init_assigns(socket, id, user)
    {:ok, socket}
  end

  @doc """
  Public init hook used by JobsView (workbench detail view).
  Returns the socket; on not-found pushes navigate to /jobs.
  """
  def init_assigns(socket, id, user) do
    case Workflows.get_job(id, actor: user) do
      {:ok, job} ->
        runs = Workflows.list_recent_runs_for_job!(job.id, actor: user, query: [limit: 10])

        socket
        |> assign(:page_title, job.name)
        |> assign(:user, user)
        |> assign(:job, job)
        |> assign(:runs, runs)

      {:error, _} ->
        socket
        |> put_flash(:error, gettext("Job not found"))
        |> push_navigate(to: ~p"/jobs")
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
          {render_job_detail(assigns)}
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc """
  Renders the job detail body (no Layouts.app wrapper).
  Used by JobsView (workbench detail view).
  """
  def render_job_detail(assigns) do
    ~H"""
    <%!-- Back Link --%>
    <.link
      navigate={~p"/jobs"}
      class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-primary mb-6"
    >
      <.icon name="lucide-arrow-left" class="w-4 h-4" />
      {gettext("Back to Jobs")}
    </.link>

    <%!-- Header --%>
    <div class="flex items-start justify-between mb-8">
      <div>
        <div class="flex items-center gap-3 mb-2">
          <h1 class="text-2xl font-bold text-base-content">{@job.name}</h1>
          <.status_badge status={@job.status} />
        </div>
        <p :if={@job.description} class="text-base-content/60">
          {@job.description}
        </p>
      </div>
      <.link
        navigate={~p"/chat/#{@job.conversation_id}"}
        class="btn btn-primary btn-sm"
      >
        <.icon name="lucide-messages-square" class="w-4 h-4" />
        {gettext("Open Chat")}
      </.link>
    </div>

    <div class="grid gap-6 md:grid-cols-2">
      <%!-- Details Card --%>
      <div class="bg-base-100 border border-base-300 rounded-xl p-6 shadow-sm">
        <h2 class="font-semibold text-base-content mb-4">{gettext("Details")}</h2>

        <dl class="space-y-4">
          <%!-- Schedule --%>
          <div>
            <dt class="text-sm text-base-content/50 mb-1">{gettext("Schedule")}</dt>
            <dd class="text-sm">{format_full_schedule(@job, @user.timezone)}</dd>
          </div>

          <%!-- Next Run --%>
          <div :if={@job.next_run_at}>
            <dt class="text-sm text-base-content/50 mb-1">{gettext("Next Run")}</dt>
            <dd class="text-sm">{format_datetime_full(@job.next_run_at, @user.timezone)}</dd>
          </div>

          <%!-- Last Run --%>
          <div :if={@job.last_run_at}>
            <dt class="text-sm text-base-content/50 mb-1">{gettext("Last Run")}</dt>
            <dd class="text-sm">{format_datetime_full(@job.last_run_at, @user.timezone)}</dd>
          </div>

          <%!-- Memory --%>
          <div :if={@job.memory_name}>
            <dt class="text-sm text-base-content/50 mb-1">{gettext("Memory")}</dt>
            <dd class="text-sm">{@job.memory_name}</dd>
          </div>

          <%!-- Created --%>
          <div>
            <dt class="text-sm text-base-content/50 mb-1">{gettext("Created")}</dt>
            <dd class="text-sm">{format_datetime_full(@job.inserted_at, @user.timezone)}</dd>
          </div>

          <%!-- Ends --%>
          <div :if={@job.ends_at}>
            <dt class="text-sm text-base-content/50 mb-1">{gettext("Ends")}</dt>
            <dd class="text-sm">{format_datetime_full(@job.ends_at, @user.timezone)}</dd>
          </div>
        </dl>

        <%!-- Actions --%>
        <div class="flex flex-wrap gap-2 mt-6 pt-4 border-t border-base-300">
          <button
            :if={@job.status == :active}
            class="btn btn-sm btn-warning"
            phx-click="pause"
          >
            <.icon name="lucide-pause" class="w-4 h-4" />
            {gettext("Pause")}
          </button>

          <button
            :if={@job.status == :paused}
            class="btn btn-sm btn-success"
            phx-click="resume"
          >
            <.icon name="lucide-play" class="w-4 h-4" />
            {gettext("Resume")}
          </button>

          <button
            :if={@job.status in [:active, :paused]}
            class="btn btn-sm btn-error"
            phx-click="stop"
            data-confirm={gettext("Are you sure? This will permanently stop this job.")}
          >
            <.icon name="lucide-square" class="w-4 h-4" />
            {gettext("Stop")}
          </button>
        </div>
      </div>

      <%!-- Trigger Prompt Card --%>
      <div class="bg-base-100 border border-base-300 rounded-xl p-6 shadow-sm">
        <h2 class="font-semibold text-base-content mb-4">{gettext("Trigger Prompt")}</h2>
        <div class="text-sm text-base-content leading-relaxed whitespace-pre-wrap">
          {@job.trigger_prompt}
        </div>
      </div>
    </div>

    <%!-- Run History Card --%>
    <div class="bg-base-100 border border-base-300 rounded-xl p-6 shadow-sm mt-6">
      <div class="flex items-center justify-between mb-4">
        <h2 class="font-semibold text-base-content">{gettext("Run History")}</h2>
        <button
          :if={@job.status == :active}
          class="btn btn-sm btn-primary"
          phx-click="run_now"
        >
          <.icon name="lucide-play" class="w-4 h-4" />
          {gettext("Run Now")}
        </button>
      </div>

      <div :if={Enum.empty?(@runs)} class="text-sm text-base-content/50 text-center py-8">
        <.icon name="lucide-clock" class="w-8 h-8 mx-auto mb-2 opacity-50" />
        <p>{gettext("No runs yet")}</p>
      </div>

      <div :if={@runs != []} class="divide-y divide-base-200">
        <div
          :for={run <- @runs}
          class="flex items-center gap-4 py-3 first:pt-0 last:pb-0"
        >
          <.run_status_icon status={run.status} />

          <div class="flex-1 min-w-0">
            <div class="font-medium text-sm">
              {format_datetime_full(run.started_at, @user.timezone)}
            </div>
            <div :if={run.error_message} class="text-error text-xs truncate mt-0.5">
              {run.error_message}
            </div>
          </div>

          <div class="text-xs text-base-content/50">
            <%= if run.completed_at do %>
              {format_duration(run.started_at, run.completed_at)}
            <% else %>
              <span class="flex items-center gap-1">
                <span class="loading loading-spinner loading-xs"></span>
                {gettext("Running")}
              </span>
            <% end %>
          </div>

          <.link
            :if={run.response_message_id}
            navigate={~p"/chat/#{@job.conversation_id}?highlight=#{run.response_message_id}"}
            class="btn btn-ghost btn-xs"
          >
            {gettext("View")}
            <.icon name="lucide-arrow-right" class="w-3 h-3" />
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # ============================================
  # Components
  # ============================================

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
    <span class={["text-xs px-2 py-0.5 rounded-full", @color]}>{@text}</span>
    """
  end

  defp run_status_icon(assigns) do
    {icon, color} =
      case assigns.status do
        :success -> {"lucide-check-circle", "text-success"}
        :failed -> {"lucide-x-circle", "text-error"}
        :running -> {"lucide-refresh-cw", "text-info animate-spin"}
        :retrying -> {"lucide-refresh-cw", "text-warning"}
        :pending -> {"lucide-clock", "text-base-content/40"}
      end

    assigns = assign(assigns, :icon, icon)
    assigns = assign(assigns, :color, color)

    ~H"""
    <.icon name={@icon} class={["w-5 h-5 shrink-0", @color]} />
    """
  end

  defp format_full_schedule(job, timezone) do
    tz = job.user_timezone || timezone || "UTC"

    case job.schedule_type do
      :cron ->
        local_cron = job.cron_expression_local || job.cron_expression
        "#{describe_cron(local_cron)} (#{local_cron} #{tz})"

      :one_time ->
        gettext("Once at %{time}", time: format_datetime_full(job.scheduled_at, timezone))
    end
  end

  # ============================================
  # Events
  # ============================================

  @impl true
  def handle_event("run_now", _params, socket) do
    case Workflows.trigger_job_now(socket.assigns.job, actor: socket.assigns.user) do
      {:ok, _job} ->
        # Reload runs to show the new run
        runs =
          Workflows.list_recent_runs_for_job!(socket.assigns.job.id,
            actor: socket.assigns.user,
            query: [limit: 10]
          )

        {:noreply,
         socket
         |> assign(:runs, runs)
         |> put_flash(:info, gettext("Job triggered - check the chat for results"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to trigger job"))}
    end
  end

  @impl true
  def handle_event("pause", _params, socket) do
    case Workflows.pause_job(socket.assigns.job, actor: socket.assigns.user) do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(:job, job)
         |> put_flash(:info, gettext("Job paused"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to pause job"))}
    end
  end

  @impl true
  def handle_event("resume", _params, socket) do
    case Workflows.resume_job(socket.assigns.job, actor: socket.assigns.user) do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(:job, job)
         |> put_flash(:info, gettext("Job resumed"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to resume job"))}
    end
  end

  @impl true
  def handle_event("stop", _params, socket) do
    case Workflows.stop_job(socket.assigns.job, actor: socket.assigns.user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Job stopped"))
         |> push_navigate(to: ~p"/jobs")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to stop job"))}
    end
  end
end
