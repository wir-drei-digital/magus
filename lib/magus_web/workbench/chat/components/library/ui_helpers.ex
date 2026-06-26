defmodule MagusWeb.ChatLive.Components.Library.UIHelpers do
  @moduledoc """
  Shared UI helper components for the Library sidebar.

  Contains reusable function components for prompts and jobs display.
  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.CoreComponents
  import MagusWeb.Live.Shared.ComponentUtils, only: [prompt_type_label: 1]

  @doc """
  Renders a prompt list item with actions.
  """
  attr :prompt, :map, required: true
  attr :myself, :any, required: true
  attr :compact, :boolean, default: false
  attr :active, :boolean, default: false

  def prompt_item(assigns) do
    ~H"""
    <div
      id={if @compact, do: "fav-prompt-#{@prompt.id}", else: "prompt-#{@prompt.id}"}
      class={"sidebar-item cursor-move #{if @active, do: "ring-1 ring-primary"}"}
      draggable="true"
      data-prompt-id={@prompt.id}
      data-prompt-type={@prompt.type}
    >
      <div class="flex items-center justify-between">
        <div
          class="flex items-center gap-2 min-w-0 flex-1 cursor-pointer hover:opacity-80"
          phx-click="view_prompt_detail"
          phx-value-id={@prompt.id}
          phx-target={@myself}
        >
          <span class={"type-tag #{type_tag_class(@prompt.type)}"}>
            {if @compact,
              do: String.first(prompt_type_label(@prompt.type)),
              else: prompt_type_label(@prompt.type)}
          </span>
          <span class="text-sm truncate">{@prompt.name}</span>
          <.icon :if={@prompt.is_public} name="lucide-globe" class="w-4 h-4 opacity-40 shrink-0" />
        </div>
        <div class="flex items-center gap-1">
          <%!-- Activate button for system prompts --%>
          <button
            :if={!@compact && @prompt.type == :system && !@active}
            class="icon-btn text-success"
            phx-click="activate_system_prompt"
            phx-value-id={@prompt.id}
            phx-target={@myself}
            title={gettext("Activate")}
          >
            <.icon name="lucide-play" class="w-4 h-4" />
          </button>
          <%!-- Insert button for user prompts --%>
          <button
            :if={!@compact && @prompt.type == :user}
            class="icon-btn text-success"
            phx-click="insert_prompt_content"
            phx-value-id={@prompt.id}
            phx-target={@myself}
            title={gettext("Insert into chat")}
          >
            <.icon name="lucide-play" class="w-4 h-4" />
          </button>
          <.popover_menu :if={!@compact} id={"prompt-menu-#{@prompt.id}"}>
            <:trigger>
              <.icon name="lucide-more-vertical" class="w-4 h-4" />
            </:trigger>
            <:item>
              <button phx-click="edit_prompt" phx-value-id={@prompt.id} phx-target={@myself}>
                {gettext("Edit")}
              </button>
            </:item>
            <:item>
              <button phx-click="publish_prompt" phx-value-id={@prompt.id} phx-target={@myself}>
                {if @prompt.is_public, do: gettext("Unpublish"), else: gettext("Publish")}
              </button>
            </:item>
            <:item>
              <button
                phx-click="delete_prompt"
                phx-value-id={@prompt.id}
                phx-target={@myself}
                data-confirm={gettext("Are you sure you want to delete this prompt?")}
                class="text-error"
              >
                {gettext("Delete")}
              </button>
            </:item>
          </.popover_menu>
        </div>
      </div>
      <%!-- Model info for system prompts --%>
      <p
        :if={!@compact && @prompt.type == :system && @prompt.model}
        class="text-xs opacity-50 mt-1 pl-7"
      >
        <.icon name="lucide-cpu" class="w-3 h-3 inline" /> {@prompt.model.name}
      </p>
    </div>
    """
  end

  @doc """
  Renders a job list item with controls.
  """
  attr :job, :map, required: true
  attr :myself, :any, required: true

  def job_item(assigns) do
    ~H"""
    <div class="sidebar-item">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2 min-w-0">
          <.job_status_icon status={@job.status} />
          <span class="text-sm truncate">{@job.name}</span>
        </div>
        <div class="flex items-center gap-1">
          <button
            :if={@job.status == :active}
            class="icon-btn text-warning"
            phx-click="pause_job"
            phx-value-id={@job.id}
            phx-target={@myself}
            title={gettext("Pause")}
          >
            <.icon name="lucide-pause" class="w-4 h-4" />
          </button>
          <button
            :if={@job.status == :paused}
            class="icon-btn text-success"
            phx-click="resume_job"
            phx-value-id={@job.id}
            phx-target={@myself}
            title={gettext("Resume")}
          >
            <.icon name="lucide-play" class="w-4 h-4" />
          </button>
          <button
            class="icon-btn text-error"
            phx-click="stop_job"
            phx-value-id={@job.id}
            phx-target={@myself}
            title={gettext("Stop")}
          >
            <.icon name="lucide-square" class="w-4 h-4" />
          </button>
        </div>
      </div>
      <div class="text-xs text-base-content/50 mt-1 pl-6">
        {format_job_schedule(@job)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a job status icon.
  """
  attr :status, :atom, required: true

  def job_status_icon(assigns) do
    {icon, color} =
      case assigns.status do
        :active -> {"lucide-play-circle", "text-success"}
        :paused -> {"lucide-pause-circle", "text-warning"}
        :stopped -> {"lucide-circle-stop", "text-error"}
        :completed -> {"lucide-check-circle", "text-info"}
      end

    assigns = assign(assigns, :icon, icon)
    assigns = assign(assigns, :color, color)

    ~H"""
    <.icon name={@icon} class={["w-4 h-4", @color]} />
    """
  end

  # Helper functions
  defp type_tag_class(:system), do: "type-tag-system"
  defp type_tag_class(:user), do: "type-tag-user"

  defp format_job_schedule(job) do
    case job.schedule_type do
      :cron -> job.cron_expression_local || job.cron_expression
      :one_time -> gettext("One-time")
    end
  end
end
