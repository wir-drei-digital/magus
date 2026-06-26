defmodule MagusWeb.Api.V2.TagsController do
  @moduledoc """
  Per-brain tag listing. Returns deduped tags with page counts across all
  pages in the brain.
  """

  use MagusWeb, :controller

  import MagusWeb.Api.V2.ControllerHelpers

  alias Magus.Brain
  alias MagusWeb.Api.Plugs.RequireWorkspaceMatch
  alias MagusWeb.Api.V2.ApiView

  def index(conn, %{"brain_id" => brain_id}) do
    user = conn.assigns.current_user

    with {:ok, brain} <- fetch_brain(brain_id, user),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, brain.workspace_id),
         {:ok, rows} <- Brain.list_tags_for_brain(brain.id, actor: user) do
      payload =
        rows
        |> Enum.group_by(& &1.tag)
        |> Enum.map(fn {tag, group} ->
          %{tag: tag, count: group |> Enum.map(& &1.page_id) |> Enum.uniq() |> length()}
        end)
        |> Enum.sort_by(& &1.tag)

      json(conn, ApiView.data(payload))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end
end
