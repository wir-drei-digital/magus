defmodule MagusWeb.RootController do
  @moduledoc """
  Open-core root route.

  Sends authenticated visitors to the SPA (`/next`, the primary UI) and
  unauthenticated visitors to sign-in. The classic workbench (`/chat`) stays
  reachable by direct URL. The commercial edition (magus_cloud) replaces this
  route with a marketing landing page.
  """
  use MagusWeb, :controller

  def index(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: "/next")
    else
      redirect(conn, to: "/sign-in")
    end
  end
end
