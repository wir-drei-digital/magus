defmodule MagusWeb.Api.V2.BrainsController do
  use MagusWeb, :controller

  import MagusWeb.Api.V2.ControllerHelpers

  alias Magus.Brain
  alias MagusWeb.Api.Plugs.RequireWorkspaceMatch
  alias MagusWeb.Api.V2.ApiView

  def index(conn, _params) do
    user = conn.assigns.current_user
    token = conn.assigns.current_token

    brains =
      case token.workspace_id do
        nil ->
          {:ok, list} = Brain.list_brains(actor: user)
          list

        ws_id ->
          {:ok, list} = Brain.list_brains_for_workspace(ws_id, actor: user)
          list
      end

    json(conn, ApiView.data(Enum.map(brains, &serialize/1)))
  end

  def create(conn, params) do
    user = conn.assigns.current_user
    token = conn.assigns.current_token

    attrs =
      params
      |> Map.take(["title", "description", "icon", "color"])
      |> to_atom_map([:title, :description, :icon, :color])
      |> Map.put(:workspace_id, token.workspace_id)

    case Brain.create_brain(attrs, actor: user) do
      {:ok, brain} ->
        conn
        |> put_status(:created)
        |> json(ApiView.data(serialize(brain)))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(
          ApiView.error("validation_error", "Invalid brain attributes", ash_errors(changeset))
        )
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, brain} <- fetch_brain(id, user),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, brain.workspace_id) do
      json(conn, ApiView.data(serialize(brain)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      {:error, _} -> not_found(conn)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    attrs =
      params
      |> Map.take(["title", "description", "icon", "color"])
      |> to_atom_map([:title, :description, :icon, :color])

    with {:ok, brain} <- fetch_brain(id, user),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, brain.workspace_id),
         {:ok, updated} <- Brain.update_brain(brain, attrs, actor: user) do
      json(conn, ApiView.data(serialize(updated)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      {:error, _} -> not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, brain} <- fetch_brain(id, user),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, brain.workspace_id),
         {:ok, _} <- Brain.archive_brain(brain, actor: user) do
      send_resp(conn, :no_content, "")
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      {:error, _} -> not_found(conn)
    end
  end

  defp serialize(brain) do
    %{
      id: brain.id,
      slug: brain.slug,
      title: brain.title,
      description: brain.description,
      icon: brain.icon,
      color: brain.color,
      is_archived: brain.is_archived,
      workspace_id: brain.workspace_id,
      updated_at: brain.updated_at
    }
  end
end
