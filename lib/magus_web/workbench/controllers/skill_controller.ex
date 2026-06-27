defmodule MagusWeb.Workbench.SkillController do
  @moduledoc """
  Serves a skill's stored bundle zip as a download (`GET /skills/:id/download`).
  Session-authenticated; authorization is delegated to `Magus.Skills.get_skill/2`
  with the current user as actor. Mirrors the Files download controller.
  """
  use MagusWeb, :controller

  def download(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, skill} <- Magus.Skills.get_skill(id, actor: user),
         path when is_binary(path) <- skill.bundle_path,
         {:ok, bytes} <- Magus.Files.Storage.get(path) do
      conn
      |> put_resp_content_type("application/zip")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{skill.name}.zip")
      )
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "Skill bundle not found"})
    end
  end
end
