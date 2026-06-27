defmodule Magus.Plan do
  @moduledoc """
  The Plan domain manages tasks that belong to either a conversation or a Brain
  plan page.

  Tasks support single-level nesting (subtasks), status tracking, assignment to
  users or agents, and ordered positioning within scope. Plan-page tasks add
  dependencies between tasks, computed readiness (open + unassigned + all
  dependencies done), atomic claim/release with an advisory lock, and an
  append-only activity trail (`TaskEvent`).
  """

  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  require Ash.Query

  typescript_rpc do
    # New-chat landing "Your open tasks" section (classic parity).
    resource Magus.Plan.Task do
      rpc_action :list_open_tasks, :open_for_user
      rpc_action :complete_task, :complete
      rpc_action :dismiss_task, :dismiss
      # In-conversation collaborative task pane (SPA companion).
      rpc_action :conversation_tasks, :for_conversation
      rpc_action :create_conversation_task, :create
      rpc_action :update_conversation_task, :update
      rpc_action :destroy_conversation_task, :destroy
      # Plan-page task board (SPA brain plan view). Names are prefixed because
      # generated client function names are GLOBAL: `plan_`/`brain_`/`_plan_task`
      # keep them distinct from the conversation-task actions above.
      rpc_action :plan_tasks, :for_plan
      rpc_action :ready_plan_tasks, :ready_for_plan
      rpc_action :brain_tasks, :for_brain
      rpc_action :create_plan_task, :create_plan
      rpc_action :update_plan_task, :update
      rpc_action :claim_plan_task, :claim
      rpc_action :release_plan_task, :release
    end

    resource Magus.Plan.TaskDependency do
      rpc_action :add_task_dependency, :create
      rpc_action :remove_task_dependency, :destroy
      rpc_action :task_dependencies, :for_task
    end

    resource Magus.Plan.TaskEvent do
      rpc_action :plan_task_events, :for_plan
      rpc_action :brain_task_events, :for_brain
    end
  end

  resources do
    resource Magus.Plan.Task do
      define :create_task, action: :create, args: [:conversation_id]
      define :create_plan_task, action: :create_plan, args: [:brain_page_id]
      define :update_task, action: :update
      define :get_task, action: :read, get_by: [:id]
      define :list_tasks, action: :read
      define :tasks_for_conversation, action: :for_conversation, args: [:conversation_id]
      define :tasks_for_plan, action: :for_plan, args: [:brain_page_id]
      define :ready_tasks_for_plan, action: :ready_for_plan, args: [:brain_page_id]
      define :tasks_for_brain, action: :for_brain, args: [:brain_id]
      define :ready_tasks_for_brain, action: :ready_for_brain, args: [:brain_id]
      define :destroy_task, action: :destroy
      define :open_tasks_for_user, action: :open_for_user, args: [:user_id]
      define :complete_task, action: :complete
      define :claim_task, action: :claim
      define :release_task, action: :release
      define :heartbeat_task, action: :heartbeat
      define :reap_expired_claims, action: :reap_expired_claims
      define :dismiss_task, action: :dismiss
    end

    resource Magus.Plan.TaskDependency do
      define :add_task_dependency, action: :create, args: [:task_id, :depends_on_id]
      define :remove_task_dependency, action: :destroy
      define :dependencies_of, action: :for_task, args: [:task_id]
    end

    resource Magus.Plan.TaskEvent do
      define :task_events_for_plan, action: :for_plan, args: [:brain_page_id]
    end

    resource Magus.Plan.TaskPaneState do
      define :dismiss_task_pane, action: :dismiss, args: [:conversation_id, :user_id]
      define :reopen_task_pane, action: :reopen, args: [:conversation_id, :user_id]
    end
  end

  @doc """
  Returns all tasks for a conversation, ordered by position ascending.
  """
  def tasks_for_conversation(conversation_id),
    do: __MODULE__.tasks_for_conversation(conversation_id, [])

  @doc "Archive all done tasks for a conversation."
  def archive_done_tasks(conversation_id, opts \\ []) do
    {actor, read_opts} = Keyword.pop(opts, :actor)

    Magus.Plan.Task
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(conversation_id == ^conversation_id and status == :done)
    |> Ash.read!(read_opts)
    |> Enum.each(fn task ->
      task
      |> Ash.Changeset.for_update(:archive, %{}, actor: actor)
      |> Ash.update!()
    end)

    :ok
  end

  @doc "Archive all non-archived tasks for a conversation, regardless of status."
  def archive_all_tasks(conversation_id, opts \\ []) do
    {actor, read_opts} = Keyword.pop(opts, :actor)

    tasks =
      Magus.Plan.Task
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(conversation_id == ^conversation_id and status != :archived)
      |> Ash.read!(read_opts)

    Enum.each(tasks, fn task ->
      task
      |> Ash.Changeset.for_update(:archive, %{}, actor: actor)
      |> Ash.update!()
    end)

    {:ok, length(tasks)}
  end

  @doc "Archive all non-archived tasks for a plan page, regardless of status."
  def archive_all_plan_tasks(brain_page_id, opts \\ []) do
    {actor, read_opts} = Keyword.pop(opts, :actor)

    tasks =
      Magus.Plan.Task
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(brain_page_id == ^brain_page_id and status != :archived)
      |> Ash.read!(read_opts)

    Enum.each(tasks, fn task ->
      task
      |> Ash.Changeset.for_update(:archive, %{}, actor: actor)
      |> Ash.update!()
    end)

    {:ok, length(tasks)}
  end

  @doc """
  Read-only coordination rollup for a brain: every non-archived task across its
  plan pages, plus the most recent task activity. Authorization rides the Task
  `:for_brain` read (brain viewer); if that succeeds, activity is read internally.
  """
  def brain_task_overview(brain_id, opts \\ []) do
    {actor, _} = Keyword.pop(opts, :actor)

    with {:ok, tasks} <- __MODULE__.tasks_for_brain(brain_id, actor: actor) do
      activity =
        Magus.Plan.TaskEvent
        |> Ash.Query.for_read(:for_brain, %{brain_id: brain_id})
        |> Ash.read!(authorize?: false)

      {:ok, %{tasks: tasks, activity: activity}}
    end
  end
end
