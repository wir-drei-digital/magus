defmodule MagusWeb.Api.V2.TasksController do
  @moduledoc """
  Plan-task surface for external agents over `/api/v2`.

  Tasks live under a brain plan page. Primary authorization is the Ash
  brain-access policy (a task is readable/writable when the actor can access
  the page's brain via `ActorCanAccessTaskPage`/`:via_brain_page`). For parity
  with the pages controller we ALSO apply `RequireWorkspaceMatch.check/2`
  against the task's brain workspace as defense-in-depth: load
  `task -> brain_page -> brain` (or the plan page directly for index/create)
  and compare `brain.workspace_id` against the token's workspace.
  """

  use MagusWeb, :controller

  import MagusWeb.Api.V2.ControllerHelpers

  require Ash.Query

  alias Magus.Brain
  alias Magus.Plan
  alias Magus.Plan.Errors.AlreadyClaimed
  alias Magus.Plan.Errors.NotClaimant
  alias Magus.Plan.Errors.PlanTaskCapReached
  alias MagusWeb.Api.Plugs.RequireWorkspaceMatch
  alias MagusWeb.Api.V2.ApiView

  # ---------------------------------------------------------------------------
  # Index / create (scoped to a plan page via :plan_id)
  # ---------------------------------------------------------------------------

  def index(conn, %{"plan_id" => plan_id} = params) do
    user = conn.assigns.current_user

    with {:ok, conn} <- check_plan_workspace(conn, plan_id, user),
         {:ok, tasks} <- list_plan_tasks(plan_id, params, user) do
      json(conn, ApiView.data(Enum.map(tasks, &serialize/1)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end

  def create(conn, %{"plan_id" => plan_id} = params) do
    user = conn.assigns.current_user
    attrs = params |> task_attrs() |> Map.put(:created_by_label, sanitize_label(params["as"]))

    with {:ok, conn} <- check_plan_workspace(conn, plan_id, user),
         {:ok, task} <- Plan.create_plan_task(plan_id, attrs, actor: user) do
      conn
      |> put_status(:created)
      |> json(ApiView.data(serialize(task)))
    else
      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      {:error, %Ash.Error.Invalid{errors: errors} = err} ->
        if Enum.any?(errors, &match?(%PlanTaskCapReached{}, &1)) do
          conn
          |> put_status(:unprocessable_entity)
          |> json(ApiView.error("plan_task_cap_reached", "Plan has reached its open-task cap"))
        else
          conn
          |> put_status(:unprocessable_entity)
          |> json(ApiView.error("validation_error", "Invalid task input", ash_errors(err)))
        end

      _ ->
        not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Show / update (by task id)
  # ---------------------------------------------------------------------------

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, task} <- fetch_task(id, user),
         {:ok, conn} <- check_task_workspace(conn, task) do
      json(conn, ApiView.data(serialize(task)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    attrs = task_attrs(params)

    with {:ok, task} <- fetch_task(id, user),
         {:ok, conn} <- check_task_workspace(conn, task),
         {:claimant, true} <- {:claimant, claimant_ok?(task, params["as"])},
         {:ok, updated} <- Plan.update_task(task, attrs, actor: user) do
      json(conn, ApiView.data(serialize(updated)))
    else
      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      {:claimant, false} ->
        conn
        |> put_status(:conflict)
        |> json(ApiView.error("not_claimant", "Task is not claimed by this caller"))

      {:error, %Ash.Error.Invalid{} = err} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ApiView.error("validation_error", "Invalid task update", ash_errors(err)))

      _ ->
        not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Claim / release
  # ---------------------------------------------------------------------------

  def claim(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    label = sanitize_label(params["as"])
    assignee = if label, do: %{assigned_to_agent: label}, else: %{assigned_to_user_id: user.id}

    with {:ok, task} <- fetch_task(id, user),
         {:ok, conn} <- check_task_workspace(conn, task),
         {:ok, claimed} <- Plan.claim_task(task, assignee, actor: user) do
      json(conn, ApiView.data(serialize(claimed)))
    else
      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      {:error, %Ash.Error.Invalid{errors: errors} = err} ->
        if Enum.any?(errors, &match?(%AlreadyClaimed{}, &1)) do
          conn
          |> put_status(:conflict)
          |> json(ApiView.error("already_claimed", "Task is already claimed"))
        else
          conn
          |> put_status(:unprocessable_entity)
          |> json(ApiView.error("validation_error", "Could not claim task", ash_errors(err)))
        end

      _ ->
        not_found(conn)
    end
  end

  def release(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, task} <- fetch_task(id, user),
         {:ok, conn} <- check_task_workspace(conn, task),
         {:claimant, true} <- {:claimant, claimant_ok?(task, params["as"])},
         {:ok, released} <- Plan.release_task(task, actor: user) do
      json(conn, ApiView.data(serialize(released)))
    else
      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      {:claimant, false} ->
        conn
        |> put_status(:conflict)
        |> json(ApiView.error("not_claimant", "Task is not claimed by this caller"))

      {:error, %Ash.Error.Invalid{} = err} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ApiView.error("validation_error", "Could not release task", ash_errors(err)))

      _ ->
        not_found(conn)
    end
  end

  def heartbeat(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    label = sanitize_label(params["as"])

    with {:ok, task} <- fetch_task(id, user),
         {:ok, conn} <- check_task_workspace(conn, task),
         {:ok, beat} <- Plan.heartbeat_task(task, %{as: label}, actor: user) do
      json(conn, ApiView.data(serialize(beat)))
    else
      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      {:error, %Ash.Error.Invalid{errors: errors} = err} ->
        if Enum.any?(errors, &match?(%NotClaimant{}, &1)) do
          conn
          |> put_status(:conflict)
          |> json(ApiView.error("not_claimant", "Task is not claimed by this caller"))
        else
          conn
          |> put_status(:unprocessable_entity)
          |> json(ApiView.error("validation_error", "Could not heartbeat task", ash_errors(err)))
        end

      _ ->
        not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Dependencies
  # ---------------------------------------------------------------------------

  def add_dependency(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    depends_on_id = params["depends_on_id"]

    with {:ok, task} <- fetch_task(id, user),
         {:ok, conn} <- check_task_workspace(conn, task),
         {:ok, dep} <- Plan.add_task_dependency(task.id, depends_on_id, actor: user) do
      conn
      |> put_status(:created)
      |> json(ApiView.data(serialize_dependency(dep)))
    else
      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      {:error, %Ash.Error.Invalid{} = err} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ApiView.error("validation_error", "Could not add dependency", ash_errors(err)))

      _ ->
        not_found(conn)
    end
  end

  def remove_dependency(conn, %{"id" => id, "dep_id" => dep_id}) do
    user = conn.assigns.current_user

    with {:ok, task} <- fetch_task(id, user),
         {:ok, conn} <- check_task_workspace(conn, task),
         {:ok, dep} <- fetch_dependency(task.id, dep_id, user),
         :ok <- Plan.remove_task_dependency(dep, actor: user) do
      json(conn, ApiView.data(%{id: dep.id, removed: true}))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Loading + workspace checks
  # ---------------------------------------------------------------------------

  defp fetch_task(id, actor) do
    Plan.get_task(id, actor: actor, load: [brain_page: :brain])
  end

  # Read the edge through the `:for_task` action (whose policy resolves
  # `task_id` from the argument); a bare by-id read can't be authorized because
  # the dependency `:read` policy needs the task's plan-page in context.
  defp fetch_dependency(task_id, dep_id, actor) do
    case Plan.dependencies_of(task_id, actor: actor) do
      {:ok, deps} ->
        case Enum.find(deps, &(&1.id == dep_id)) do
          nil -> {:error, :not_found}
          dep -> {:ok, dep}
        end

      err ->
        err
    end
  end

  defp list_plan_tasks(plan_id, params, actor) do
    case params["ready"] do
      "true" -> Plan.ready_tasks_for_plan(plan_id, actor: actor)
      _ -> Plan.tasks_for_plan(plan_id, actor: actor)
    end
  end

  # Index/create take the plan page id; resolve the page's brain workspace and
  # apply the redundant workspace boundary before touching the domain.
  defp check_plan_workspace(conn, plan_id, actor) do
    case Brain.get_page(plan_id, actor: actor, load: [:brain]) do
      {:ok, page} -> RequireWorkspaceMatch.check(conn, page.brain.workspace_id)
      {:error, _} -> {:error, :not_found}
    end
  end

  # Show/update/claim/release/deps already loaded `brain_page: :brain` on the task.
  defp check_task_workspace(conn, %{brain_page: %{brain: %{workspace_id: ws_id}}}) do
    RequireWorkspaceMatch.check(conn, ws_id)
  end

  # A plan task always has a brain page; if the relationship is unexpectedly
  # missing (e.g. a conversation task surfaced via get_task), fall closed.
  defp check_task_workspace(_conn, _task), do: {:error, :not_found}

  # ---------------------------------------------------------------------------
  # Params
  # ---------------------------------------------------------------------------

  @task_fields [
    :title,
    :description,
    :status,
    :priority,
    :position,
    :assigned_to_agent,
    :assigned_to_user_id,
    :assigned_to_custom_agent_id,
    :blocked_reason,
    :due_at
  ]

  defp task_attrs(params) do
    attrs = to_atom_map(params, @task_fields)

    # `assigned_to_agent` is the agent-controlled claimant key; normalize it the
    # same way as `created_by_label` so the stored value matches what the
    # advisory claimant check (and heartbeat) compare against.
    if Map.has_key?(attrs, :assigned_to_agent) do
      Map.update!(attrs, :assigned_to_agent, &sanitize_label/1)
    else
      attrs
    end
  end

  # Agent-controlled free string. Trim, cap length, nilify blank. NEVER atomized.
  @max_label_len 200
  defp sanitize_label(nil), do: nil

  defp sanitize_label(label) when is_binary(label) do
    case label |> String.trim() |> String.slice(0, @max_label_len) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp sanitize_label(_), do: nil

  # Advisory, opt-in claimant guard for the `/api/v2` boundary (controller-only;
  # the shared Ash actions stay unguarded so humans can override from the board).
  # A blank/absent `as` always passes (the human-override path); a present `as`
  # must match the task's current `assigned_to_agent`.
  defp claimant_ok?(task, raw_as) do
    case sanitize_label(raw_as) do
      nil -> true
      as -> as == task.assigned_to_agent
    end
  end

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  defp serialize(task) do
    %{
      id: task.id,
      title: task.title,
      status: task.status,
      priority: task.priority,
      assigned_to_agent: task.assigned_to_agent,
      assigned_to_user_id: task.assigned_to_user_id,
      assigned_to_custom_agent_id: task.assigned_to_custom_agent_id,
      claimed_at: task.claimed_at,
      lease_expires_at: task.lease_expires_at,
      created_by_label: task.created_by_label,
      brain_page_id: task.brain_page_id,
      position: task.position,
      inserted_at: task.inserted_at
    }
  end

  defp serialize_dependency(dep) do
    %{
      id: dep.id,
      task_id: dep.task_id,
      depends_on_id: dep.depends_on_id,
      inserted_at: dep.inserted_at
    }
  end
end
