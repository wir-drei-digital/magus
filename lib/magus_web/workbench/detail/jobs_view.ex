defmodule MagusWeb.Workbench.Detail.JobsView do
  @moduledoc """
  Jobs detail view. Master list (left aside) + selected job detail (right main area).
  Combines JobsLive (list) and JobDetailLive (detail) under one workbench LiveView.
  """
  use MagusWeb, :live_view

  on_mount({MagusWeb.LiveUserAuth, :restore_locale})

  @impl true
  def mount(_params, %{"user_id" => user_id} = session, socket) do
    user = Magus.Accounts.get_user!(user_id, authorize?: false)
    job_id = Map.get(session, "job_id")

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:selected_job_id, job_id)
      |> MagusWeb.JobsLive.init_assigns(user)
      |> maybe_load_job_detail(job_id, user)

    {:ok, socket}
  end

  defp maybe_load_job_detail(socket, nil, _user), do: socket

  defp maybe_load_job_detail(socket, id, user),
    do: MagusWeb.JobDetailLive.init_assigns(socket, id, user)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex bg-wb-bg" data-detail-view="jobs">
      <aside class="w-80 border-r border-wb-border overflow-y-auto p-4">
        {MagusWeb.JobsLive.render_jobs_list(assigns)}
      </aside>
      <section class="flex-1 overflow-y-auto p-6">
        <div :if={@selected_job_id}>
          {MagusWeb.JobDetailLive.render_job_detail(assigns)}
        </div>
        <div
          :if={is_nil(@selected_job_id)}
          class="h-full flex items-center justify-center text-wb-text-muted"
        >
          <p>Select a job to see details.</p>
        </div>
      </section>
    </div>
    """
  end

  @impl true
  def handle_event(event, params, %{assigns: %{selected_job_id: id}} = socket)
      when not is_nil(id) do
    MagusWeb.JobDetailLive.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket),
    do: MagusWeb.JobsLive.handle_event(event, params, socket)
end
