defmodule MagusWeb.Api.V2.PlansController do
  @moduledoc """
  Plan delivery-lifecycle surface for external agents over `/api/v2`.

  Plans are brain `:plan` pages. Primary authorization is the Ash brain-access
  policy (a page is readable/writable when the actor can access its brain) and
  the deliver/undeliver/spec actions are additionally editor-gated at the
  resource layer. For parity with the task surface we ALSO apply
  `RequireWorkspaceMatch.check/2` against the page's brain workspace as
  defense-in-depth: load `page -> brain` with `actor: current_user` and compare
  `brain.workspace_id` against the token's workspace before touching the domain.

  Endpoints:

    * `POST /plans/:id/deliver`   -> `mark_delivered` (optional `delivery_ref`)
    * `POST /plans/:id/undeliver` -> `undeliver`
    * `GET  /plans/:id`           -> serialized plan (lifecycle/delivered/spec)
    * `POST /plans/:id/spec`      -> `set_spec` (nullable `spec_page_id`)
    * `GET  /brains/:brain_id/stranded` -> done-but-not-delivered plans
    * `GET  /specs/:id/plans`     -> the plans implementing a spec page
  """

  use MagusWeb, :controller

  import MagusWeb.Api.V2.ControllerHelpers

  alias Magus.Brain
  alias MagusWeb.Api.Plugs.RequireWorkspaceMatch
  alias MagusWeb.Api.V2.ApiView

  @page_loads [:lifecycle, :delivered_at, :delivery_ref, :kind, :spec_page_id]

  # ---------------------------------------------------------------------------
  # Show
  # ---------------------------------------------------------------------------

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, page} <- fetch_page(id, user),
         {:ok, conn} <- check_page_workspace(conn, page) do
      json(conn, ApiView.data(serialize(page)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Deliver / undeliver
  # ---------------------------------------------------------------------------

  def deliver(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    attrs = to_atom_map(params, [:delivery_ref])

    with {:ok, page} <- fetch_page(id, user),
         {:ok, conn} <- check_page_workspace(conn, page),
         {:ok, delivered} <- Brain.mark_page_delivered(page, attrs, actor: user) do
      json(conn, ApiView.data(serialize_loaded(delivered, user)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      {:error, %Ash.Error.Invalid{} = err} -> invalid(conn, "Could not deliver plan", err)
      _ -> not_found(conn)
    end
  end

  def undeliver(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, page} <- fetch_page(id, user),
         {:ok, conn} <- check_page_workspace(conn, page),
         {:ok, undelivered} <- Brain.undeliver_page(page, actor: user) do
      json(conn, ApiView.data(serialize_loaded(undelivered, user)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      {:error, %Ash.Error.Invalid{} = err} -> invalid(conn, "Could not undeliver plan", err)
      _ -> not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Spec link
  # ---------------------------------------------------------------------------

  def set_spec(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    spec_page_id = Map.get(params, "spec_page_id")

    with {:ok, page} <- fetch_page(id, user),
         {:ok, conn} <- check_page_workspace(conn, page),
         {:ok, updated} <- Brain.set_page_spec(page, spec_page_id, actor: user) do
      json(conn, ApiView.data(serialize_loaded(updated, user)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      {:error, %Ash.Error.Invalid{} = err} -> invalid(conn, "Could not set spec", err)
      _ -> not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Stranded plans (scoped to a brain)
  # ---------------------------------------------------------------------------

  def stranded(conn, %{"brain_id" => brain_id}) do
    user = conn.assigns.current_user

    with {:ok, brain} <- fetch_brain(brain_id, user),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, brain.workspace_id),
         {:ok, plans} <- Brain.stranded_plans(brain.id, actor: user, load: @page_loads) do
      json(conn, ApiView.data(Enum.map(plans, &serialize/1)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Plans implementing a spec
  # ---------------------------------------------------------------------------

  def for_spec(conn, %{"id" => spec_id}) do
    user = conn.assigns.current_user

    with {:ok, spec} <- fetch_page(spec_id, user),
         {:ok, conn} <- check_page_workspace(conn, spec),
         {:ok, plans} <- Brain.plans_for_spec(spec.id, actor: user, load: @page_loads) do
      json(conn, ApiView.data(Enum.map(plans, &serialize/1)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Loading + workspace checks
  # ---------------------------------------------------------------------------

  # Load the page actor-scoped (so the Ash brain-access policy applies) with the
  # lifecycle/delivery fields plus its brain for the workspace boundary.
  #
  # `get_page` wraps an unknown/inaccessible id as
  # `%Ash.Error.Invalid{errors: [%NotFound{}]}`; normalize that to
  # `{:error, :not_found}` here so a missing page falls to 404 in the `with`,
  # leaving the `%Ash.Error.Invalid{}` branch for genuine action-validation
  # errors (e.g. an invalid spec_page_id) which map to 422.
  defp fetch_page(id, actor) do
    case Brain.get_page(id, actor: actor, load: [:brain | @page_loads]) do
      {:ok, page} -> {:ok, page}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp check_page_workspace(conn, %{brain: %{workspace_id: ws_id}}) do
    RequireWorkspaceMatch.check(conn, ws_id)
  end

  # A page always has a brain; fall closed if the relationship is unexpectedly
  # missing rather than leaking past the workspace boundary.
  defp check_page_workspace(_conn, _page), do: {:error, :not_found}

  # mark_delivered/undeliver/set_spec return the updated record but not the
  # recomputed calc-only `:lifecycle`; reload it actor-scoped for the response.
  defp serialize_loaded(page, actor) do
    case Brain.get_page(page.id, actor: actor, load: @page_loads) do
      {:ok, reloaded} -> serialize(reloaded)
      _ -> serialize(page)
    end
  end

  defp invalid(conn, message, err) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ApiView.error("validation_error", message, ash_errors(err)))
  end

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  defp serialize(page) do
    %{
      id: page.id,
      title: page.title,
      kind: page.kind,
      lifecycle: page.lifecycle,
      delivered_at: page.delivered_at,
      delivery_ref: page.delivery_ref,
      spec_page_id: page.spec_page_id,
      brain_id: page.brain_id
    }
  end
end
