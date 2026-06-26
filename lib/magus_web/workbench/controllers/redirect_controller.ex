defmodule MagusWeb.RedirectController do
  @moduledoc """
  Handles HTTP redirects for legacy routes that have been folded into the
  workbench with URL query params.
  """
  use MagusWeb, :controller

  def agent_edit(conn, %{"id" => id}) do
    redirect(conn, to: "/agents/#{id}?edit=true&section=general")
  end

  def agent_edit_section(conn, %{"id" => id, "section" => section}) do
    redirect(conn, to: "/agents/#{id}?edit=true&section=#{section}")
  end

  def prompt_edit(conn, %{"id" => id}) do
    redirect(conn, to: "/prompts_library/#{id}?edit=true")
  end
end
