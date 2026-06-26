defmodule MagusWeb.ChatLive.Components.Tasks.TaskPaneComponent do
  @moduledoc """
  Collapsible task list rendered above the chat input.

  Compact by default (single header bar with progress), expands to show
  the full task list with checkboxes, inline editing, and add buttons.
  Coexists with the draft/pdf side pane. Supports drag-to-reorder via Sortable.js.
  """

  use MagusWeb, :live_component

  import MagusWeb.ChatLive.Components.Tasks.DueDateHelpers

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:expanded, fn -> false end)
      |> assign_new(:adding_task, fn -> false end)
      |> assign_new(:adding_subtask_for, fn -> nil end)
      |> assign_new(:editing_task_id, fn -> nil end)

    grouped = group_tasks(assigns.tasks)

    {:ok, assign(socket, :grouped_tasks, grouped)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={if @expanded, do: "border-b border-base-300/50"}>
      <%!-- Collapse/expand header --%>
      <button
        type="button"
        phx-click="toggle_expanded"
        phx-target={@myself}
        class="flex items-center gap-2 w-full px-3 py-1.5 text-sm cursor-pointer rounded-xl hover:bg-base-200/30 transition-colors"
      >
        <.icon
          name={if @expanded, do: "lucide-chevron-down", else: "lucide-chevron-right"}
          class="w-3.5 h-3.5 text-base-content/50"
        />
        <.icon name="lucide-check-square" class="w-3.5 h-3.5 text-primary" />
        <span class="font-medium text-base-content/70">{gettext("Tasks")}</span>
        <span class="text-xs text-base-content/40 font-mono">
          {done_count(@tasks)}/{length(@tasks)}
        </span>
        <.progress_dots tasks={@tasks} />
      </button>

      <%!-- Expanded task list --%>
      <div :if={@expanded} class="px-3 pb-2 max-h-64 overflow-y-auto">
        <%!-- Top-level tasks (sortable) --%>
        <div
          id="top-level-tasks"
          phx-hook=".TaskSortable"
          data-parent-id=""
          data-target={@myself}
        >
          <div
            :for={{top_task, subtasks} <- @grouped_tasks}
            class="mb-0.5"
            data-task-id={top_task.id}
          >
            <.task_row
              task={top_task}
              current_user={@current_user}
              editing={@editing_task_id == to_string(top_task.id)}
              myself={@myself}
              is_subtask={false}
            />

            <%!-- Subtasks (sortable within parent) --%>
            <div
              id={"subtasks-#{top_task.id}"}
              phx-hook=".TaskSortable"
              data-parent-id={top_task.id}
              data-target={@myself}
            >
              <.task_row
                :for={subtask <- subtasks}
                task={subtask}
                current_user={@current_user}
                editing={@editing_task_id == to_string(subtask.id)}
                myself={@myself}
                is_subtask={true}
              />
            </div>

            <%!-- Add subtask inline form --%>
            <div :if={@adding_subtask_for == to_string(top_task.id)}>
              <.inline_add_form myself={@myself} event="add_subtask" parent_id={top_task.id} />
            </div>
          </div>
        </div>

        <%!-- Add top-level task --%>
        <div :if={@adding_task} class="mt-1">
          <.inline_add_form myself={@myself} event="add_task" parent_id="" />
        </div>
        <button
          :if={!@adding_task}
          type="button"
          phx-click="start_add_task"
          phx-target={@myself}
          class="text-xs text-base-content/30 hover:text-base-content/60 cursor-pointer flex items-center gap-1 mt-1 py-0.5"
        >
          <.icon name="lucide-plus" class="w-3 h-3" />
          {gettext("Add task")}
        </button>
      </div>

      <%!-- Sortable.js hook for drag-to-reorder --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".TaskSortable">
        export default {
          mounted() {
            this.sortable = window.Sortable.create(this.el, {
              animation: 150,
              handle: ".task-handle",
              ghostClass: "opacity-30",
              onEnd: (evt) => {
                const taskId = evt.item.dataset.taskId
                const newIndex = evt.newIndex
                this.pushEventTo(this.el.dataset.target, "reorder_task", {
                  task_id: taskId,
                  position: newIndex
                })
              }
            })
          },
          destroyed() {
            if (this.sortable) this.sortable.destroy()
          },
          updated() {
            // Sortable persists across patches
          }
        }
      </script>
    </div>
    """
  end

  # ============================================================================
  # Sub-components
  # ============================================================================

  attr :tasks, :list, required: true

  defp progress_dots(assigns) do
    ~H"""
    <span class="flex items-center gap-0.5 ml-auto">
      <span
        :for={task <- Enum.filter(@tasks, &is_nil(&1.parent_id))}
        class={[
          "w-1.5 h-1.5 rounded-full",
          case task.status do
            :done -> "bg-success"
            :in_progress -> "bg-primary"
            :cancelled -> "bg-base-content/20"
            _ -> "bg-base-content/15"
          end
        ]}
      />
    </span>
    """
  end

  attr :task, :map, required: true
  attr :current_user, :map, required: true
  attr :editing, :boolean, required: true
  attr :myself, :any, required: true
  attr :is_subtask, :boolean, required: true

  defp task_row(%{editing: true} = assigns) do
    ~H"""
    <div class={["flex items-center gap-2 py-1 px-2 rounded-lg", if(@is_subtask, do: "pl-8")]}>
      <.status_icon status={@task.status} />
      <form phx-submit="save_title" phx-target={@myself} class="flex-1">
        <input type="hidden" name="task_id" value={@task.id} />
        <input
          type="text"
          name="title"
          value={@task.title}
          autofocus
          class="input input-sm input-bordered w-full text-sm"
          phx-keydown="cancel_edit"
          phx-key="Escape"
          phx-target={@myself}
        />
      </form>
    </div>
    """
  end

  defp task_row(assigns) do
    ~H"""
    <div
      class={[
        "flex items-center gap-2 py-1 px-2 -mx-2 rounded-lg hover:bg-base-200/40 group transition-colors",
        if(@is_subtask, do: "pl-8")
      ]}
      data-task-id={@task.id}
    >
      <%!-- Drag handle --%>
      <div class="task-handle cursor-grab flex-shrink-0 text-base-content/30 group-hover:text-base-content/60 transition-colors select-none text-[14px] leading-none">
        ⠿
      </div>

      <%!-- Status checkbox --%>
      <div
        phx-click={unless(@task.status == :done, do: "toggle_task")}
        phx-value-id={@task.id}
        phx-target={@myself}
        class={["flex-shrink-0", if(@task.status != :done, do: "cursor-pointer")]}
      >
        <.status_icon status={@task.status} />
      </div>

      <%!-- Title (click to edit, unless done) --%>
      <%= if @task.status in [:done, :cancelled] do %>
        <span class="flex-1 text-sm line-through text-base-content/40">
          {@task.title}
        </span>
      <% else %>
        <span
          class="flex-1 text-sm text-base-content/80 cursor-pointer"
          phx-click="start_edit"
          phx-value-id={@task.id}
          phx-target={@myself}
        >
          {@task.title}
        </span>
      <% end %>

      <%!-- Due date --%>
      <span
        :if={@task.due_at}
        class={[
          "text-xs ml-1 flex-shrink-0",
          overdue?(@task.due_at) && "text-error",
          !overdue?(@task.due_at) && "text-base-content/50"
        ]}
      >
        {format_due_date(@task.due_at)}
      </span>

      <%!-- Assignment badge --%>
      <.assignment_badge task={@task} current_user={@current_user} />

      <%!-- Add subtask button (top-level only, not done) --%>
      <button
        :if={is_nil(@task.parent_id) and @task.status != :done}
        type="button"
        phx-click="start_add_subtask"
        phx-value-parent-id={@task.id}
        phx-target={@myself}
        class="opacity-0 group-hover:opacity-60 hover:!opacity-100 cursor-pointer transition-opacity flex-shrink-0"
        title={gettext("Add subtask")}
      >
        <.icon name="lucide-plus" class="w-3.5 h-3.5 text-base-content/50" />
      </button>

      <%!-- Remove task --%>
      <button
        type="button"
        phx-click="remove_task"
        phx-value-id={@task.id}
        phx-target={@myself}
        class="opacity-0 group-hover:opacity-40 hover:!opacity-100 cursor-pointer transition-opacity flex-shrink-0"
        title={gettext("Remove task")}
      >
        <.icon name="lucide-x-circle" class="w-3.5 h-3.5 text-base-content/50 hover:text-error" />
      </button>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status_icon(%{status: :done} = assigns) do
    ~H"""
    <.icon name="lucide-check-square" class="w-4 h-4 text-success flex-shrink-0" />
    """
  end

  defp status_icon(%{status: :in_progress} = assigns) do
    ~H"""
    <.icon name="lucide-loader" class="w-4 h-4 text-primary flex-shrink-0" />
    """
  end

  defp status_icon(assigns) do
    ~H"""
    <.icon name="lucide-square" class="w-4 h-4 text-base-content/30 flex-shrink-0" />
    """
  end

  attr :task, :map, required: true
  attr :current_user, :map, required: true

  defp assignment_badge(%{task: %{assigned_to_user_id: uid}, current_user: %{id: uid}} = assigns)
       when not is_nil(uid) do
    ~H"""
    <span class="text-xs text-primary flex-shrink-0">@{gettext("you")}</span>
    """
  end

  defp assignment_badge(%{task: %{assigned_to_user_id: uid}} = assigns)
       when not is_nil(uid) do
    ~H"""
    <span class="text-xs text-base-content flex-shrink-0">@{gettext("user")}</span>
    """
  end

  defp assignment_badge(%{task: %{assigned_to_agent: agent}} = assigns)
       when not is_nil(agent) and agent != "" do
    ~H"""
    <span class="text-xs text-secondary flex-shrink-0">@{gettext("agent")}</span>
    """
  end

  defp assignment_badge(assigns) do
    ~H"""
    """
  end

  attr :myself, :any, required: true
  attr :event, :string, required: true
  attr :parent_id, :any, required: true

  defp inline_add_form(assigns) do
    ~H"""
    <form phx-submit={@event} phx-target={@myself} class="py-0.5 pl-8 flex items-center gap-1.5">
      <input type="hidden" name="parent_id" value={@parent_id} />
      <input
        type="text"
        name="title"
        autofocus
        placeholder={gettext("Task title...")}
        class="input input-sm input-bordered flex-1 text-sm"
        phx-keydown="cancel_add"
        phx-key="Escape"
        phx-target={@myself}
      />
      <select name="assigned_to" class="select select-sm select-bordered text-xs w-auto min-w-0">
        <option value="agent" selected>{gettext("@agent")}</option>
        <option value="user">{gettext("@you")}</option>
      </select>
    </form>
    """
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("toggle_expanded", _params, socket) do
    {:noreply, assign(socket, :expanded, !socket.assigns.expanded)}
  end

  def handle_event("toggle_task", %{"id" => task_id}, socket) do
    notify_parent({:toggle_task, task_id})
    {:noreply, socket}
  end

  def handle_event("remove_task", %{"id" => task_id}, socket) do
    notify_parent({:remove_task, task_id})
    {:noreply, socket}
  end

  def handle_event("start_edit", %{"id" => task_id}, socket) do
    {:noreply, assign(socket, editing_task_id: task_id)}
  end

  def handle_event("save_title", %{"task_id" => task_id, "title" => title}, socket) do
    title = String.trim(title)

    if title != "" do
      notify_parent({:update_title, task_id, title})
    end

    {:noreply, assign(socket, editing_task_id: nil)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_task_id: nil)}
  end

  def handle_event("start_add_task", _params, socket) do
    {:noreply, assign(socket, adding_task: true)}
  end

  def handle_event("start_add_subtask", %{"parent-id" => parent_id}, socket) do
    # Use the inline_add_form inside the subtask area
    {:noreply, assign(socket, adding_task: false, adding_subtask_for: parent_id)}
  end

  def handle_event("cancel_add", _params, socket) do
    {:noreply, assign(socket, adding_task: false, adding_subtask_for: nil)}
  end

  def handle_event("add_task", %{"title" => title, "parent_id" => parent_id} = params, socket) do
    assigned_to = params["assigned_to"] || "agent"
    notify_parent({:add_task, title, parent_id, assigned_to})
    {:noreply, assign(socket, adding_task: false, adding_subtask_for: nil)}
  end

  def handle_event("add_subtask", %{"title" => title, "parent_id" => parent_id} = params, socket) do
    assigned_to = params["assigned_to"] || "agent"
    notify_parent({:add_task, title, parent_id, assigned_to})
    {:noreply, assign(socket, adding_task: false, adding_subtask_for: nil)}
  end

  def handle_event("reorder_task", %{"task_id" => task_id, "position" => position}, socket) do
    notify_parent({:reorder_task, task_id, position})
    {:noreply, socket}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp group_tasks(tasks) do
    top_level = tasks |> Enum.filter(&is_nil(&1.parent_id)) |> Enum.sort_by(& &1.position)

    subtasks_by_parent =
      tasks
      |> Enum.filter(&(not is_nil(&1.parent_id)))
      |> Enum.group_by(& &1.parent_id)

    Enum.map(top_level, fn task ->
      subs =
        subtasks_by_parent
        |> Map.get(task.id, [])
        |> Enum.sort_by(& &1.position)

      {task, subs}
    end)
  end

  defp done_count(tasks), do: Enum.count(tasks, &(&1.status == :done))

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
