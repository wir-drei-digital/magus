defmodule MagusWeb.NextUiController do
  @moduledoc """
  Serves the SvelteKit SPA shell (`priv/static/next/index.html`, built from
  `frontend/`). Static assets under `/next/_app/*` are handled by
  `Plug.Static` in the endpoint; this controller is the catch-all that makes
  client-side routing work for any other `/next/*` path (and, via
  `MagusWeb.Plugs.NextUiSwitch`, for migrated workbench routes).
  """
  use MagusWeb, :controller

  def spa(conn, _params) do
    index = Path.join([Application.app_dir(:magus, "priv"), "static", "next", "index.html"])

    if File.exists?(index) do
      conn
      |> put_resp_content_type("text/html")
      # The shell references hashed immutable assets; the shell itself must
      # always be revalidated so deploys take effect immediately.
      |> put_resp_header("cache-control", "no-cache")
      |> send_file(200, index)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(
        404,
        "The SvelteKit workbench is not built. Run: cd frontend && npm install && npm run build"
      )
    end
  end
end
