defmodule MagusWeb.Api.V2.SourcesController do
  @moduledoc """
  Read-only access to `Magus.Brain.Source` rows by id. Sources are derived
  from page bodies (fenced ```source blocks); ingestion is async.
  """

  use MagusWeb, :controller

  import MagusWeb.Api.V2.ControllerHelpers

  alias Magus.Brain
  alias MagusWeb.Api.Plugs.RequireWorkspaceMatch
  alias MagusWeb.Api.V2.ApiView

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, source} <- Brain.get_source(id, actor: user, load: [:brain]),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, source.brain.workspace_id) do
      json(conn, ApiView.data(serialize(source)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end

  defp serialize(source) do
    %{
      id: source.id,
      brain_id: source.brain_id,
      url: source.url,
      title: source.title,
      description: source.description,
      source_type: source.source_type,
      ingest_status: source.ingest_status,
      ingested_at: source.ingested_at,
      ingested_content: source.ingested_content
    }
  end
end
