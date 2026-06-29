defmodule MagusWeb.NextUiController do
  @moduledoc """
  Serves the SvelteKit SPA shell (`priv/static/next/index.html`, built from
  `frontend/`). The SPA is the primary UI, served at the site root: its hashed
  assets under `/_app/*` are handled by `Plug.Static` in the endpoint, and this
  controller is the catch-all that makes client-side routing work for every
  other browser path.
  """
  use MagusWeb, :controller

  def spa(conn, _params) do
    user = conn.assigns[:current_user]

    # Profile-completion gate (parity with the classic `:live_user_required`
    # on_mount): a user who hasn't accepted the terms is sent to complete their
    # profile before reaching the app. `/complete-profile` has its own route, so
    # the catch-all never serves it — no redirect loop.
    if user && !user.accepted_terms do
      redirect(conn, to: ~p"/complete-profile")
    else
      serve_shell(conn)
    end
  end

  defp serve_shell(conn) do
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
        "The SvelteKit app is not built. Run: cd frontend && npm install && npm run build"
      )
    end
  end
end
