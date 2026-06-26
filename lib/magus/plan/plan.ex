defmodule Magus.Plan do
  @moduledoc """
  The Plan domain manages tasks associated with conversations.

  Tasks support single-level nesting (subtasks), status tracking,
  assignment to users or agents, and ordered positioning within scope.
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
    end
  end

  resources do
    resource Magus.Plan.Task do
      define :create_task, action: :create, args: [:conversation_id]
      define :update_task, action: :update
      define :get_task, action: :read, get_by: [:id]
      define :list_tasks, action: :read
      define :tasks_for_conversation, action: :for_conversation, args: [:conversation_id]
      define :destroy_task, action: :destroy
      define :open_tasks_for_user, action: :open_for_user, args: [:user_id]
      define :complete_task, action: :complete
      define :dismiss_task, action: :dismiss
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
end
