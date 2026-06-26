defmodule MagusWeb.Workbench.Resources.TaskHandlers do
  @moduledoc """
  Task-related event and PubSub handlers for `MagusWeb.Workbench.Resources.ConversationView`.

  Tasks render as a collapsible list above the chat input; no separate
  pane state is needed.

  Lived under `MagusWeb.ChatLive.TaskHandlers` while the legacy
  ChatLive subtree was around. Moved here once the legacy subtree was
  retired (the workbench is now the only caller).
  """

  import Phoenix.Component, only: [assign: 3]

  # ============================================================================
  # PubSub Handlers
  # ============================================================================

  def handle_task_created(socket, %{task: task}) do
    existing_ids = Enum.map(socket.assigns.conversation_tasks, & &1.id)

    if task.id in existing_ids do
      socket
    else
      tasks = socket.assigns.conversation_tasks ++ [task]
      assign(socket, :conversation_tasks, tasks)
    end
  end

  def handle_task_updated(socket, %{task: updated}) do
    tasks =
      Enum.map(socket.assigns.conversation_tasks, fn t ->
        if t.id == updated.id, do: updated, else: t
      end)

    assign(socket, :conversation_tasks, tasks)
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  def handle_toggle_task(socket, task_id) do
    user = socket.assigns.current_user

    case Enum.find(socket.assigns.conversation_tasks, &(to_string(&1.id) == task_id)) do
      nil ->
        socket

      # Done tasks cannot be undone from the UI
      %{status: :done} ->
        socket

      task ->
        case Magus.Plan.update_task(task, %{status: :done}, actor: user) do
          {:ok, updated} ->
            tasks =
              Enum.map(socket.assigns.conversation_tasks, fn t ->
                if t.id == updated.id, do: updated, else: t
              end)

            assign(socket, :conversation_tasks, tasks)

          {:error, _} ->
            socket
        end
    end
  end

  def handle_add_task(socket, title, parent_id, assigned_to \\ "agent")

  def handle_add_task(socket, title, parent_id, assigned_to)
      when is_binary(title) and title != "" do
    user = socket.assigns.current_user
    conversation_id = socket.assigns.conversation.id

    attrs =
      %{title: String.trim(title)}
      |> then(fn a ->
        if parent_id && parent_id != "", do: Map.put(a, :parent_id, parent_id), else: a
      end)
      |> then(fn a ->
        case assigned_to do
          "user" -> Map.merge(a, %{assigned_to_user_id: user.id, assigned_to_agent: nil})
          _ -> a
        end
      end)

    case Magus.Plan.create_task(conversation_id, attrs, actor: user) do
      {:ok, task} ->
        tasks = socket.assigns.conversation_tasks ++ [task]
        assign(socket, :conversation_tasks, tasks)

      {:error, _} ->
        socket
    end
  end

  def handle_add_task(socket, _title, _parent_id, _assigned_to), do: socket

  def handle_update_title(socket, task_id, title) do
    user = socket.assigns.current_user

    case Enum.find(socket.assigns.conversation_tasks, &(to_string(&1.id) == task_id)) do
      nil ->
        socket

      task ->
        case Magus.Plan.update_task(task, %{title: title}, actor: user) do
          {:ok, updated} ->
            tasks =
              Enum.map(socket.assigns.conversation_tasks, fn t ->
                if t.id == updated.id, do: updated, else: t
              end)

            assign(socket, :conversation_tasks, tasks)

          {:error, _} ->
            socket
        end
    end
  end

  def handle_remove_task(socket, task_id) do
    user = socket.assigns.current_user

    case Enum.find(socket.assigns.conversation_tasks, &(to_string(&1.id) == task_id)) do
      nil ->
        socket

      task ->
        case Magus.Plan.destroy_task(task, actor: user) do
          :ok ->
            tasks = Enum.reject(socket.assigns.conversation_tasks, &(&1.id == task.id))
            assign(socket, :conversation_tasks, tasks)

          {:error, _} ->
            socket
        end
    end
  end

  def handle_reorder_task(socket, task_id, new_index) do
    new_index = if is_binary(new_index), do: String.to_integer(new_index), else: new_index
    tasks = socket.assigns.conversation_tasks

    # Find the task and determine its scope (same parent_id)
    case Enum.find(tasks, &(to_string(&1.id) == task_id)) do
      nil ->
        socket

      moved_task ->
        parent_id = moved_task.parent_id

        # Get siblings in the same scope, in current order
        siblings =
          tasks
          |> Enum.filter(&(&1.parent_id == parent_id))
          |> Enum.sort_by(& &1.position)

        # Remove the moved task and insert at new index
        without = Enum.reject(siblings, &(&1.id == moved_task.id))
        new_index = min(new_index, length(without))
        reordered = List.insert_at(without, new_index, moved_task)

        # Update all positions in the scope
        Enum.with_index(reordered, fn task, idx ->
          if task.position != idx do
            Magus.Plan.update_task(task, %{position: idx}, actor: socket.assigns.current_user)
          end
        end)

        # Reload to get consistent state
        case Magus.Plan.tasks_for_conversation(
               socket.assigns.conversation.id,
               actor: socket.assigns.current_user
             ) do
          {:ok, updated_tasks} -> assign(socket, :conversation_tasks, updated_tasks)
          _ -> socket
        end
    end
  end

  # ============================================================================
  # Assign Helpers
  # ============================================================================

  @doc "Loads tasks for the current conversation."
  def assign_task_pane(socket) do
    conversation = socket.assigns[:conversation]

    if is_nil(conversation) do
      assign(socket, :conversation_tasks, [])
    else
      tasks =
        case Magus.Plan.tasks_for_conversation(
               conversation.id,
               actor: socket.assigns.current_user
             ) do
          {:ok, tasks} -> tasks
          _ -> []
        end

      assign(socket, :conversation_tasks, tasks)
    end
  end
end
