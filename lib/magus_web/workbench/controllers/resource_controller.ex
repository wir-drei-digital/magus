defmodule MagusWeb.FileController do
  @moduledoc """
  Controller for file operations: authenticated serving and downloading.

  Does NOT use `MagusWeb, :controller` because that macro adds
  `formats: [:html, :json]` which rejects binary file formats (.png, .mp4, etc.).
  """
  use Phoenix.Controller, formats: []
  use Gettext, backend: MagusWeb.Gettext

  import Plug.Conn

  use Phoenix.VerifiedRoutes,
    endpoint: MagusWeb.Endpoint,
    router: MagusWeb.Router,
    statics: MagusWeb.static_paths()

  alias Magus.Chat
  alias Magus.Files
  alias Magus.Files.Storage

  @doc """
  Serves a file inline through the authenticated proxy.

  Handles two path patterns:
  - Avatars (`avatars/{filename}`): anyone can view (single segment only)
  - Regular files (`{user_id}/{file_id}.ext`): enforces Ash policies, with
    fallback to share-link-based access for files in shared conversations
  """
  def serve(conn, %{"path" => ["avatars", _filename]}) do
    # Phoenix strips the extension from the last catch-all segment,
    # so reconstruct the full path from conn.path_info which preserves it
    relative_path = conn.path_info |> Enum.drop(2) |> Path.join()
    serve_from_storage(conn, relative_path)
  end

  def serve(conn, %{"path" => ["avatars" | _]}) do
    conn |> put_status(:not_found) |> json(%{error: "File not found"})
  end

  def serve(conn, %{"path" => ["agent_images", _filename]}) do
    relative_path = conn.path_info |> Enum.drop(2) |> Path.join()
    serve_from_storage(conn, relative_path)
  end

  def serve(conn, %{"path" => ["agent_images" | _]}) do
    conn |> put_status(:not_found) |> json(%{error: "File not found"})
  end

  def serve(conn, %{"path" => _path_parts}) do
    # Reconstruct the relative storage path from conn.path_info to preserve
    # the extension on the last segment (Phoenix may strip it for format
    # negotiation in the action params).
    relative_path = conn.path_info |> Enum.drop(2) |> Path.join()
    current_user = conn.assigns[:current_user]

    case get_file_by_path_with_share_fallback(relative_path, current_user) do
      {:ok, file} ->
        serve_from_storage(conn, file.file_path, file.mime_type, file.name)

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "File not found"})
    end
  end

  @doc """
  Downloads a file as an attachment.
  """
  def download(conn, %{"id" => id}) do
    current_user = conn.assigns[:current_user]

    case get_file_with_share_fallback(id, current_user) do
      {:ok, file} ->
        serve_download(conn, file)

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "File not found"})
    end
  end

  # Serve from storage with explicit content type and filename
  defp serve_from_storage(conn, relative_path, content_type, filename) do
    case Storage.get(relative_path) do
      {:ok, content} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("content-disposition", content_disposition("inline", filename))
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> send_resp(200, content)

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "File not found in storage"})
    end
  end

  # Serve from storage with content type inferred from path (for avatars)
  defp serve_from_storage(conn, relative_path) do
    content_type = MIME.from_path(relative_path)

    case Storage.get(relative_path) do
      {:ok, content} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_resp(200, content)

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "File not found in storage"})
    end
  end

  # Serve as a downloadable attachment
  defp serve_download(conn, file) do
    case Storage.get(file.file_path) do
      {:ok, content} ->
        conn
        |> put_resp_content_type(file.mime_type)
        |> put_resp_header("content-disposition", content_disposition("attachment", file.name))
        |> send_resp(200, content)

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "File not found in storage"})
    end
  end

  # Try normal authorized access first, then fall back to share-link-based access
  # for files attached to conversations with active share links.
  defp get_file_with_share_fallback(file_id, current_user) do
    case Files.get_file(file_id, actor: current_user) do
      {:ok, file} ->
        {:ok, file}

      {:error, _} ->
        with {:ok, file} <- Files.get_file(file_id, authorize?: false),
             true <- file_accessible_via_share_link?(file, current_user) do
          {:ok, file}
        else
          _ -> :error
        end
    end
  end

  # Same as `get_file_with_share_fallback/2` but looks up by storage path
  # instead of id. Used by `serve/2` because the URL path embeds the
  # storage filename (which may differ from `file.id` for legacy uploads).
  defp get_file_by_path_with_share_fallback(file_path, current_user) do
    case Files.get_file_by_path(file_path, actor: current_user) do
      {:ok, file} ->
        {:ok, file}

      {:error, _} ->
        with {:ok, file} <- Files.get_file_by_path(file_path, authorize?: false),
             true <- file_accessible_via_share_link?(file, current_user) do
          {:ok, file}
        else
          _ -> :error
        end
    end
  end

  defp file_accessible_via_share_link?(file, current_user) do
    case file.conversation_id do
      nil ->
        false

      conversation_id ->
        case Chat.get_active_share_links(conversation_id, authorize?: false) do
          {:ok, links} ->
            Enum.any?(links, fn link ->
              link.access_type == :public or
                (link.access_type == :authenticated and current_user != nil)
            end)

          _ ->
            false
        end
    end
  end

  # Sanitize filename for Content-Disposition header to prevent header injection
  defp content_disposition(type, filename) do
    safe_name =
      filename
      |> String.replace(~r/["\\\r\n]/, "_")
      |> String.slice(0, 255)

    ~s(#{type}; filename="#{safe_name}")
  end
end
