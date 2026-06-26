defmodule MagusWeb.Rpc.UploadController do
  @moduledoc """
  Multipart upload endpoint for the SvelteKit workbench (`POST /rpc/upload`).

  Runs in the `:rpc` pipeline (session-authenticated actor) and delegates to
  `Magus.Files.Upload.create_file_from_upload/5`, the same path the classic
  LiveView uploads use — type detection, storage write, and the
  `CheckStorageLimits` validation (subscription storage + per-file budget)
  all apply identically. Responses mirror the AshTypescript RPC envelope
  (`{success, data | errors}`) so the SPA's data layer can share error
  handling.
  """
  use MagusWeb, :controller

  require Logger

  alias MagusWeb.Workbench.UploadHelpers

  def create(conn, %{"file" => %Plug.Upload{} = upload} = params) do
    user = conn.assigns.current_user

    # Check the on-disk size before reading the body into memory: Plug's
    # multipart parser buffers to a temp file, so an oversized upload is
    # rejected without ever allocating the binary.
    with :ok <- check_size(upload),
         {:ok, content} <- read_upload(upload),
         {:ok, file} <-
           Magus.Files.Upload.create_file_from_upload(
             content,
             upload.filename,
             upload.content_type,
             byte_size(content),
             actor: user,
             conversation_id: cast_uuid(params["conversation_id"]),
             workspace_id: cast_uuid(params["workspace_id"]),
             folder_id: cast_uuid(params["folder_id"])
           ) do
      json(conn, %{
        success: true,
        data: %{
          id: file.id,
          name: file.name,
          type: file.type,
          mimeType: file.mime_type,
          fileSize: file.file_size
        }
      })
    else
      {:error, reason} -> json(conn, error_envelope(reason))
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(error_envelope("missing multipart \"file\" field"))
  end

  # Raw multipart strings: a malformed id must surface as a validation error
  # (or be dropped), not as an Ecto cast crash inside the policy filters.
  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp read_upload(%Plug.Upload{path: path}) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, posix} -> {:error, "could not read upload: #{posix}"}
    end
  end

  defp check_size(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        if size <= UploadHelpers.max_file_size() do
          :ok
        else
          {:error, "file too large (max #{UploadHelpers.max_file_size()} bytes)"}
        end

      {:error, posix} ->
        {:error, "could not read upload: #{posix}"}
    end
  end

  # Only validation messages (Ash.Error.Invalid, e.g. storage limits) and our
  # own binary reasons reach the client; everything else is logged and
  # collapsed to a generic message so framework internals can't leak.
  defp error_envelope(reason) do
    message =
      case reason do
        reason when is_binary(reason) ->
          reason

        %Ash.Error.Invalid{errors: [first | _]} when is_exception(first) ->
          Exception.message(first)

        other ->
          Logger.warning("RPC upload failed: #{inspect(other)}")
          "Upload failed"
      end

    %{
      success: false,
      errors: [
        %{
          type: "upload_failed",
          message: message,
          shortMessage: "Upload failed",
          vars: %{},
          fields: [],
          path: []
        }
      ]
    }
  end
end
