defmodule MagusWeb.Api.V2.OverviewController do
  @moduledoc """
  Read-only brain coordination rollup for external agents over `/api/v2`.

  `GET /api/v2/brains/:brain_id/overview` returns every non-archived task
  across the brain's plan pages plus the most recent task activity, sourced
  from `Magus.Plan.brain_task_overview/2`.

  Tenancy mirrors the pages/tasks controllers: the brain is loaded first (a
  stranger gets a 404 because the Ash brain-access policy filters it out), then
  `RequireWorkspaceMatch.check/2` applies the redundant workspace boundary (a
  wrong-workspace token gets a 403). Only after both pass does the rollup run;
  its `{:error, _}` path is the policy-layer backstop (403).
  """

  use MagusWeb, :controller

  import MagusWeb.Api.V2.ControllerHelpers

  alias Magus.Plan
  alias MagusWeb.Api.Plugs.RequireWorkspaceMatch
  alias MagusWeb.Api.V2.ApiView

  def show(conn, %{"brain_id" => brain_id}) do
    user = conn.assigns.current_user

    with {:ok, brain} <- fetch_brain(brain_id, user),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, brain.workspace_id),
         {:ok, %{tasks: tasks, activity: activity}} <-
           Plan.brain_task_overview(brain.id, actor: user) do
      json(
        conn,
        ApiView.data(%{
          tasks: Enum.map(tasks, &serialize_task/1),
          activity: Enum.map(activity, &serialize_event/1)
        })
      )
    else
      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      {:error, :not_found} ->
        not_found(conn)

      {:error, _} ->
        conn
        |> put_status(:forbidden)
        |> json(ApiView.error("forbidden", "No access to this brain"))
    end
  end

  defp serialize_task(task) do
    %{
      id: task.id,
      title: task.title,
      status: task.status,
      priority: task.priority,
      assigned_to_agent: task.assigned_to_agent,
      assigned_to_user_id: task.assigned_to_user_id,
      assigned_to_custom_agent_id: task.assigned_to_custom_agent_id,
      claimed_at: task.claimed_at,
      brain_page_id: task.brain_page_id
    }
  end

  defp serialize_event(event) do
    %{
      kind: event.kind,
      actor_label: event.actor_label,
      task_id: event.task_id,
      brain_page_id: event.brain_page_id,
      inserted_at: event.inserted_at
    }
  end
end
