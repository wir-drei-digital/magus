defmodule MagusWeb.Rpc.SkillsController do
  @moduledoc """
  Multipart skill-bundle import endpoint for the SPA (`POST /rpc/skills/import`).
  Runs in the `:rpc` pipeline (session-authenticated actor) and delegates to
  `Magus.Skills.Import.import_bundle/2`. Responses mirror the AshTypescript RPC
  envelope so the SPA data layer shares error handling.
  """
  use MagusWeb, :controller

  require Logger

  def create(conn, %{"file" => %Plug.Upload{} = upload} = params) do
    user = conn.assigns.current_user

    with {:ok, bytes} <- File.read(upload.path),
         {:ok, skill} <-
           Magus.Skills.Import.import_bundle(bytes,
             actor: user,
             workspace_id: cast_uuid(params["workspace_id"])
           ) do
      json(conn, %{success: true, data: %{id: skill.id, name: skill.name}})
    else
      {:error, reason} -> json(conn, error_envelope(reason))
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(error_envelope("missing multipart \"file\" field"))
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      _ -> nil
    end
  end

  defp error_envelope(reason) do
    message =
      case reason do
        r when is_binary(r) ->
          r

        r when is_atom(r) ->
          "Import failed: #{r}"

        %Ash.Error.Invalid{errors: [first | _]} when is_exception(first) ->
          Exception.message(first)

        other ->
          Logger.warning("RPC skill import failed: #{inspect(other)}")
          "Import failed"
      end

    %{
      success: false,
      errors: [
        %{
          type: "import_failed",
          message: message,
          shortMessage: "Import failed",
          vars: %{},
          fields: [],
          path: []
        }
      ]
    }
  end
end
