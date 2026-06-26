defmodule Magus.Sandbox.FilesExtractor do
  @moduledoc """
  Persists files created during sandbox execution to permanent storage.

  Files are captured inline during Python execution (base64 encoded),
  so this module only handles persistence to the Files domain.
  """

  alias Magus.Files
  alias Magus.Files.Storage
  alias Magus.Files.Upload

  require Logger

  # Maximum file size for sandbox-generated files (50MB)
  @max_sandbox_file_bytes 50_000_000

  @doc """
  Persist files created during execution to permanent storage.

  Takes file data maps from CodeRunner (with inline content) and
  persists them to the Files domain.

  ## Parameters

  - `sandbox` - The sandbox record
  - `execution` - The execution record
  - `files_data` - List of file data maps with `:name`, `:content`, etc.

  ## Returns

  A list of file metadata maps with:
  - `:id` - File ID in the database
  - `:filename` - Original filename
  - `:mime_type` - Detected MIME type
  - `:size_bytes` - File size
  - `:download_url` - URL to download the file
  """
  def extract_files(_sandbox, _execution, []), do: []

  def extract_files(sandbox, execution, files_data) do
    start_time = System.monotonic_time()

    # Load conversation to get user_id for file ownership
    {:ok, sandbox} = Ash.load(sandbox, [:conversation], authorize?: false)
    user_id = sandbox.conversation.user_id
    conversation_id = sandbox.conversation_id

    # Process each file with inline content
    results =
      files_data
      |> Enum.map(fn file_data ->
        process_file(file_data, user_id, conversation_id, sandbox.id, execution.id)
      end)
      |> Enum.reject(&is_nil/1)

    duration = System.monotonic_time() - start_time

    # Emit telemetry for file registration
    :telemetry.execute(
      [:magus, :sandbox, :files, :registered],
      %{
        duration: duration,
        file_count: length(results),
        total_bytes: Enum.reduce(results, 0, fn f, acc -> acc + (f[:size_bytes] || 0) end)
      },
      %{
        sandbox_id: sandbox.id,
        execution_id: execution.id,
        conversation_id: conversation_id,
        attempted_count: length(files_data)
      }
    )

    results
  end

  # Process a file with inline content
  defp process_file(%{error: error, name: name}, _user_id, _conv_id, sandbox_id, _exec_id)
       when not is_nil(error) do
    Logger.warning(
      "File had error during capture: #{name} (sandbox: #{sandbox_id}, error: #{error})"
    )

    nil
  end

  defp process_file(%{skipped: "too_large", name: name, size: size}, _, _, sandbox_id, _) do
    Logger.warning(
      "File too large for inline capture: #{name} (size: #{size} bytes, sandbox: #{sandbox_id})"
    )

    nil
  end

  defp process_file(%{content: nil, name: name}, _user_id, _conv_id, sandbox_id, _exec_id) do
    Logger.warning("File has no content: #{name} (sandbox: #{sandbox_id})")
    nil
  end

  defp process_file(
         %{name: filename, content: content},
         user_id,
         conversation_id,
         sandbox_id,
         execution_id
       )
       when is_binary(content) do
    mime_type = guess_mime_type(filename)

    persist_file_to_storage(
      content,
      filename,
      mime_type,
      user_id,
      conversation_id,
      sandbox_id,
      execution_id
    )
  end

  defp process_file(file_data, _user_id, _conv_id, sandbox_id, _exec_id) do
    Logger.warning("Unexpected file data format: #{inspect(file_data)} (sandbox: #{sandbox_id})")

    nil
  end

  # Persist a sandbox-created file to the Files domain for permanent storage
  defp persist_file_to_storage(
         content,
         filename,
         _mime_type,
         _user_id,
         _conversation_id,
         sandbox_id,
         _execution_id
       )
       when is_binary(content) and byte_size(content) > @max_sandbox_file_bytes do
    Logger.warning(
      "Sandbox file too large, skipping: #{filename} (size: #{byte_size(content)} bytes, max: #{@max_sandbox_file_bytes}, sandbox: #{sandbox_id})"
    )

    nil
  end

  defp persist_file_to_storage(
         content,
         filename,
         mime_type,
         user_id,
         conversation_id,
         sandbox_id,
         execution_id
       )
       when is_binary(content) do
    case Upload.detect_type(mime_type, content) do
      {:ok, file_type} ->
        input = %{
          name: filename,
          type: file_type,
          mime_type: mime_type,
          user_id: user_id,
          conversation_id: conversation_id,
          content: content
        }

        case Files.create_file_from_content(input, actor: ai_actor()) do
          {:ok, file} ->
            Logger.debug(
              "Persisted sandbox file to storage: #{filename} (file_id: #{file.id}, sandbox: #{sandbox_id}, execution: #{execution_id})"
            )

            download_url =
              case Storage.get_url(file.file_path) do
                {:ok, url} -> url
                _ -> nil
              end

            %{
              id: file.id,
              filename: filename,
              mime_type: mime_type,
              size_bytes: file.file_size,
              download_url: download_url
            }

          {:error, reason} ->
            Logger.error(
              "Failed to persist sandbox file to storage: #{filename} (sandbox: #{sandbox_id}, error: #{inspect(reason)})"
            )

            nil
        end

      {:error, reason} ->
        Logger.error(
          "Unsupported file type for sandbox file: #{filename} (sandbox: #{sandbox_id}, error: #{reason})"
        )

        nil
    end
  end

  defp persist_file_to_storage(
         _content,
         filename,
         _mime_type,
         _user_id,
         _conversation_id,
         sandbox_id,
         _execution_id
       ) do
    Logger.warning(
      "Sandbox file content is not binary, skipping: #{filename} (sandbox: #{sandbox_id})"
    )

    nil
  end

  @doc """
  Persist a file directly to permanent storage given its content.

  Unlike `extract_files/3` which processes lists of file data from code execution,
  this function takes raw binary content and persists a single file.

  ## Returns

    * `{:ok, %{id, filename, mime_type, size_bytes, download_url}}` on success
    * `{:error, reason}` on failure
  """
  @spec persist_file(binary(), String.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, term()}
  def persist_file(content, _filename, _user_id, _conversation_id)
      when is_binary(content) and byte_size(content) > @max_sandbox_file_bytes do
    {:error, "File too large (#{byte_size(content)} bytes, max: #{@max_sandbox_file_bytes})"}
  end

  def persist_file(content, filename, user_id, conversation_id) when is_binary(content) do
    mime_type = guess_mime_type(filename)

    case Upload.detect_type(mime_type, content) do
      {:error, reason} ->
        {:error, reason}

      {:ok, file_type} ->
        input = %{
          name: filename,
          type: file_type,
          mime_type: mime_type,
          user_id: user_id,
          conversation_id: conversation_id,
          content: content
        }

        case Files.create_file_from_content(input, actor: ai_actor()) do
          {:ok, file} ->
            download_url =
              case Storage.get_url(file.file_path) do
                {:ok, url} -> url
                _ -> nil
              end

            {:ok,
             %{
               id: file.id,
               filename: filename,
               mime_type: mime_type,
               size_bytes: file.file_size,
               download_url: download_url
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def persist_file(_content, _filename, _user_id, _conversation_id) do
    {:error, "Content must be binary"}
  end

  defp ai_actor, do: %Magus.Agents.Support.AiAgent{}

  @doc """
  Guess the MIME type from a filename's extension.
  """
  @spec guess_mime_type(String.t()) :: String.t()
  def guess_mime_type(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".csv" -> "text/csv"
      ".json" -> "application/json"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".html" -> "text/html"
      ".xml" -> "application/xml"
      ".pdf" -> "application/pdf"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".svg" -> "image/svg+xml"
      ".xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      ".xls" -> "application/vnd.ms-excel"
      ".docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      ".zip" -> "application/zip"
      ".py" -> "text/x-python"
      ".js" -> "application/javascript"
      _ -> "application/octet-stream"
    end
  end
end
