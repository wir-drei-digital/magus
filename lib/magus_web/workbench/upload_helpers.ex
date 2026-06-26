defmodule MagusWeb.Workbench.UploadHelpers do
  @moduledoc """
  Shared upload pipeline used by both `MagusWeb.ChatLive.Components.Library.FilesSidebarComponent`
  and `MagusWeb.Workbench.Modes.FilesModeNav`. The behavior is lifted verbatim
  from the original FilesSidebarComponent — both call sites delegate here so
  the two file-upload UIs stay in lock-step.

  The upload uses the local Phoenix.LiveView upload pipeline (no `:external`
  presign). Callers are expected to set up `allow_upload(:file_uploads, ...)`
  themselves and then invoke `do_upload/2` from their `upload_files` event
  handler.
  """

  use Gettext, backend: MagusWeb.Gettext

  import Phoenix.LiveView, only: [consume_uploaded_entries: 3, put_flash: 3]

  @max_uploads 10
  @max_file_size 50_000_000

  @doc "Maximum number of files allowed in a single upload batch."
  def max_uploads, do: @max_uploads

  @doc "Maximum file size in bytes."
  def max_file_size, do: @max_file_size

  @doc """
  Consumes uploaded entries on the socket and creates `Magus.Files.File`
  records for each one.

  `upload_name` is the atom used in `allow_upload/3` (e.g. `:file_uploads`
  or `:files`). `context` is a map describing where the uploaded files
  should land:

    * `:current_user` — the actor (required)
    * `:workspace_id` — when uploading into a workspace library
    * `:folder_id` — when uploading into a specific folder
    * `:conversation_id` — when uploading into a conversation
    * `:scope` — one of `:global | :workspace | :folder | :conversation`
      (used to decide which of the optional ids above to forward to
      `Magus.Files.Upload.create_file_from_upload/5`)

  Returns the updated socket with files reloaded via `reload_fun` and
  any flash messages set. `reload_fun` is a 1-arity function that takes
  the socket and returns a new socket (typically calling
  `load_files/1` in the caller).
  """
  def do_upload(socket, opts \\ []) do
    upload_name = Keyword.get(opts, :upload_name, :file_uploads)
    reload_fun = Keyword.get(opts, :reload_fun, & &1)

    conversation_id = socket.assigns[:conversation_id]
    folder_id = socket.assigns[:folder_id]
    current_user = socket.assigns.current_user
    scope = socket.assigns[:file_scope]
    workspace_id = socket.assigns[:workspace_id]

    upload_opts =
      [actor: current_user]
      |> then(fn opts ->
        case scope do
          :workspace when not is_nil(workspace_id) ->
            Keyword.put(opts, :workspace_id, workspace_id)

          :folder when not is_nil(folder_id) ->
            Keyword.put(opts, :folder_id, folder_id)

          :conversation when not is_nil(conversation_id) ->
            Keyword.put(opts, :conversation_id, conversation_id)

          _ ->
            opts
        end
      end)

    results =
      consume_uploaded_entries(socket, upload_name, fn %{path: path}, entry ->
        content = File.read!(path)

        case Magus.Files.Upload.create_file_from_upload(
               content,
               entry.client_name,
               entry.client_type,
               byte_size(content),
               upload_opts
             ) do
          {:ok, file} -> {:ok, {:ok, file}}
          {:error, reason} -> {:ok, {:error, entry.client_name, reason}}
        end
      end)

    {successes, failures} =
      Enum.split_with(results, fn
        {:ok, _file} -> true
        {:error, _name, _reason} -> false
      end)

    files = Enum.map(successes, fn {:ok, file} -> file end)

    socket =
      if failures != [] do
        names = Enum.map_join(failures, ", ", fn {:error, name, _} -> name end)

        put_flash(
          socket,
          :error,
          gettext("Could not upload: %{names}. Unsupported file type.", names: names)
        )
      else
        socket
      end

    socket =
      if files != [] do
        put_flash(socket, :info, "#{length(files)} file(s) uploaded. Processing...")
      else
        socket
      end

    {:noreply, reload_fun.(socket)}
  end

  @doc """
  Sets up the standard `allow_upload` configuration on a socket. Pass
  through any caller-provided options (typically `:max_entries`,
  `:max_file_size`, `:auto_upload`).
  """
  def allow_uploads(socket, upload_name, opts \\ []) do
    defaults = [
      accept: :any,
      max_entries: @max_uploads,
      max_file_size: @max_file_size,
      auto_upload: false
    ]

    Phoenix.LiveView.allow_upload(socket, upload_name, Keyword.merge(defaults, opts))
  end

  @doc "Translates an upload error atom into a user-facing string."
  def error_to_string(:too_large), do: gettext("File too large (max 50MB)")
  def error_to_string(:not_accepted), do: gettext("File type not accepted")
  def error_to_string(:too_many_files), do: gettext("Too many files (max 10)")
  def error_to_string(err), do: to_string(err)
end
