defmodule MagusWeb.Workbench.Tab.RightRail.JobsPanel do
  @moduledoc """
  Floating panel that lists active workflow jobs for the current
  conversation, with pause / resume / stop affordances.
  """
  use MagusWeb, :live_component

  @impl true
  def update(assigns, socket) do
    user = Magus.Accounts.get_user!(assigns.user_id, authorize?: false)

    jobs =
      case Magus.Workflows.list_jobs_for_conversation(assigns.conversation_id, actor: user) do
        {:ok, list} -> list
        _ -> []
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:current_user, user)
     |> assign(:jobs, jobs)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-3 flex flex-col gap-2">
      <h3 class="text-xs font-semibold uppercase tracking-wider text-wb-text-muted">
        Active jobs
      </h3>
      <ul :if={@jobs != []} class="flex flex-col gap-1">
        <li
          :for={job <- @jobs}
          data-rail-job={job.id}
          class="text-sm flex items-center justify-between gap-2 p-2 rounded bg-wb-surface-2"
        >
          <div class="min-w-0 flex-1">
            <div class="text-wb-text truncate">{job.name}</div>
            <div class="text-xs text-wb-text-muted">{job.status}</div>
          </div>
          <button
            :if={job.status == :active}
            type="button"
            phx-click="pause_job"
            phx-value-id={job.id}
            phx-target={@myself}
            class="text-xs px-1.5 py-0.5 rounded hover:bg-wb-hover text-wb-text-muted"
            title="Pause"
          >
            <.icon name="lucide-pause" class="w-3.5 h-3.5" />
          </button>
          <button
            :if={job.status == :paused}
            type="button"
            phx-click="resume_job"
            phx-value-id={job.id}
            phx-target={@myself}
            class="text-xs px-1.5 py-0.5 rounded hover:bg-wb-hover text-wb-text-muted"
            title="Resume"
          >
            <.icon name="lucide-play" class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            phx-click="stop_job"
            phx-value-id={job.id}
            phx-target={@myself}
            class="text-xs px-1.5 py-0.5 rounded hover:bg-wb-hover text-error"
            title="Stop"
          >
            <.icon name="lucide-square" class="w-3.5 h-3.5" />
          </button>
        </li>
      </ul>
      <p :if={@jobs == []} class="text-sm text-wb-text-muted">No active jobs.</p>
    </div>
    """
  end

  @impl true
  def handle_event("pause_job", %{"id" => id}, socket) do
    job = Magus.Workflows.get_job!(id, actor: socket.assigns.current_user)
    Magus.Workflows.pause_job!(job, actor: socket.assigns.current_user)
    {:noreply, refresh(socket)}
  end

  def handle_event("resume_job", %{"id" => id}, socket) do
    job = Magus.Workflows.get_job!(id, actor: socket.assigns.current_user)
    Magus.Workflows.resume_job!(job, actor: socket.assigns.current_user)
    {:noreply, refresh(socket)}
  end

  def handle_event("stop_job", %{"id" => id}, socket) do
    job = Magus.Workflows.get_job!(id, actor: socket.assigns.current_user)
    Magus.Workflows.stop_job!(job, actor: socket.assigns.current_user)
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    {:ok, jobs} =
      Magus.Workflows.list_jobs_for_conversation(socket.assigns.conversation_id,
        actor: socket.assigns.current_user
      )

    assign(socket, :jobs, jobs)
  end
end
