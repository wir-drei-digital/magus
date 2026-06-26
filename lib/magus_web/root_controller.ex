defmodule MagusWeb.RootController do
  @moduledoc """
  Open-core root route.

  Hands `/` off to the workbench; unauthenticated visitors are bounced to
  sign-in by the workbench's own auth `on_mount`. The commercial edition
  (magus_cloud) replaces this route with a marketing landing page.
  """
  use MagusWeb, :controller

  def index(conn, _params) do
    redirect(conn, to: "/chat")
  end
end
