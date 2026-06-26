defmodule Magus.Files.Upload do
  @moduledoc """
  Shared module for creating Files.File records from uploaded files.

  This module provides a unified interface for creating file records
  from file uploads, whether they come from the chat UI attachments or
  the files sidebar.
  """

  require Logger

  alias Magus.Files
  alias Magus.Files.{FileAnalyzer, Storage}

  @doc """
  Creates a Files.File from uploaded file content.

  ## Options

    * `:actor` - Required. The user uploading the file.
    * `:conversation_id` - Optional. Associate file with a conversation.
    * `:folder_id` - Optional. Associate file with a folder.
    * `:workspace_id` - Optional. Associate file with a workspace.
    * `:extra_attrs` - Optional map of additional attributes to merge into the
      create call (for example `%{uploaded_via_agent_id: agent.id}`). Only
      attributes accepted by the `:create` action are honored.

  ## Returns

    * `{:ok, file}` on success
    * `{:error, reason}` on failure

  ## Example

      iex> Upload.create_file_from_upload(
      ...>   content,
      ...>   "document.pdf",
      ...>   "application/pdf",
      ...>   500_000,
      ...>   actor: user,
      ...>   conversation_id: conv.id
      ...> )
      {:ok, %File{}}
  """
  @spec create_file_from_upload(
          binary(),
          String.t(),
          String.t() | nil,
          non_neg_integer(),
          keyword()
        ) :: {:ok, Files.File.t()} | {:error, term()}
  def create_file_from_upload(content, filename, mime_type, file_size, opts) do
    user = Keyword.fetch!(opts, :actor)
    conversation_id = Keyword.get(opts, :conversation_id)
    folder_id = Keyword.get(opts, :folder_id)
    workspace_id = Keyword.get(opts, :workspace_id)
    extra_attrs = Keyword.get(opts, :extra_attrs, %{})
    normalized_mime = normalize_mime(mime_type)
    stored_mime = if(normalized_mime == "", do: "application/octet-stream", else: normalized_mime)

    case detect_type(stored_mime, content) do
      {:ok, type} ->
        file_id = Ash.UUIDv7.generate()
        storage_path = Storage.generate_path(user.id, file_id, filename)

        with {:ok, _} <- Storage.store(storage_path, content) do
          attrs =
            %{
              name: filename,
              type: type,
              mime_type: stored_mime,
              file_size: file_size,
              file_path: storage_path
            }
            |> maybe_add(:conversation_id, conversation_id)
            |> maybe_add(:folder_id, folder_id)
            |> maybe_add(:workspace_id, workspace_id)
            |> Map.merge(extra_attrs)

          case Files.create_file(attrs, actor: user) do
            {:ok, file} ->
              {:ok, file}

            {:error, _reason} = error ->
              # The DB record was rejected (quota, auth, validation) after the
              # bytes were already written, so compensate to avoid an orphan.
              compensate_orphaned_upload(storage_path)
              error
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates Files.File records from a list of attachments.

  Each attachment should be a map with keys: `:name`, `:type` (mime type), `:content`.

  ## Options

    * `:actor` - Required. The user uploading the files.
    * `:conversation_id` - Optional. Associate files with a conversation.
    * `:folder_id` - Optional. Associate files with a folder.

  ## Returns

  A list of `{:ok, file}` or `{:error, reason}` tuples.
  """
  @spec create_files_from_attachments(list(map()), keyword()) ::
          list({:ok, Files.File.t()} | {:error, term()})
  def create_files_from_attachments(attachments, opts) when is_list(attachments) do
    Enum.map(attachments, fn %{name: name, type: mime_type, content: content} ->
      create_file_from_upload(
        content,
        name,
        mime_type,
        byte_size(content),
        opts
      )
    end)
  end

  @doc """
  Detects file type from MIME type and content.

  Uses MIME type for known formats (documents, images, video, email, text/*).
  For unknown MIME types (e.g. application/octet-stream), falls back to
  content-based detection using the null-byte heuristic.

  Returns `{:ok, type}` or `{:error, reason}` for unsupported binary files.
  """
  @spec detect_type(String.t() | nil, binary()) ::
          {:ok, :document | :text | :image | :video | :email} | {:error, String.t()}
  def detect_type(mime_type, content) do
    case mime_to_type(normalize_mime(mime_type)) do
      :unknown ->
        if FileAnalyzer.text?(content) do
          {:ok, :text}
        else
          {:error,
           "Unsupported file type. Only text, document, image, and video files are supported."}
        end

      type ->
        {:ok, type}
    end
  end

  @spec mime_to_type(String.t()) :: :document | :text | :image | :video | :email | :unknown
  defp mime_to_type(mime) when is_binary(mime) do
    cond do
      # Email (check before documents since ms-outlook is application/*)
      mime == "message/rfc822" -> :email
      String.contains?(mime, "ms-outlook") -> :email
      # Text (includes HTML, XML, CSV, common code MIME types)
      String.starts_with?(mime, "text/") -> :text
      mime == "application/json" -> :text
      String.ends_with?(mime, "+json") -> :text
      mime == "application/xml" -> :text
      String.ends_with?(mime, "+xml") -> :text
      # Images
      String.starts_with?(mime, "image/") -> :image
      # Video
      String.starts_with?(mime, "video/") -> :video
      # Documents - anything Kreuzberg can extract from
      kreuzberg_supported?(mime) -> :document
      # Unknown - needs content-based detection
      true -> :unknown
    end
  end

  defp kreuzberg_supported?(mime) do
    match?({:ok, _}, Kreuzberg.validate_mime_type(mime))
  end

  defp normalize_mime(nil), do: ""

  defp normalize_mime(mime) when is_binary(mime) do
    mime
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp compensate_orphaned_upload(storage_path) do
    case Storage.delete(storage_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Upload compensation failed to delete orphaned bytes at #{storage_path}: #{inspect(reason)}"
        )
    end
  end
end
