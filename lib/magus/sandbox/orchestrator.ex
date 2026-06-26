defmodule Magus.Sandbox.Orchestrator do
  @moduledoc """
  Main entry point for sandbox operations.

  Orchestrates code execution, command execution, file operations, and service
  management through pluggable sandbox providers (Sprites.dev, Daytona).
  """

  alias Magus.Sandbox
  alias Magus.Sandbox.CodeRunner
  alias Magus.Sandbox.CommandRunner
  alias Magus.Sandbox.FilesExtractor
  alias Magus.Sandbox.Provider
  alias Magus.Sandbox.WorkspaceManager

  require Ash.Query
  require Logger

  # 100 MB max for URL uploads
  @max_upload_bytes 100 * 1024 * 1024

  @doc """
  Resolves the effective conversation ID for sandbox operations.

  If the conversation has a `sandbox_conversation_id` set (meaning it shares
  a parent's sandbox), returns that ID. Otherwise returns the conversation's own ID.
  """
  @spec resolve_effective_conversation_id(Ecto.UUID.t()) :: Ecto.UUID.t()
  def resolve_effective_conversation_id(conversation_id) do
    case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
      {:ok, %{sandbox_conversation_id: sandbox_id}} when not is_nil(sandbox_id) ->
        sandbox_id

      _ ->
        conversation_id
    end
  end

  # Resolves sandbox conversation ID and authorizes in one pass.
  # When sandbox_conversation_id is nil (common case), avoids a redundant DB query
  # by reusing the conversation loaded during resolution for the authorization check.
  defp resolve_and_authorize(conversation_id, opts) do
    case Keyword.get(opts, :user_id) do
      nil ->
        {:error, :unauthorized, "user_id is required for sandbox execution"}

      user_id ->
        with {:ok, user} <- Magus.Accounts.get_user(user_id),
             {:ok, conversation} <- Magus.Chat.get_conversation(conversation_id, actor: user) do
          effective_id = conversation.sandbox_conversation_id || conversation_id

          if effective_id == conversation_id do
            # Common case: no sandbox sharing, conversation already authorized
            {:ok, effective_id, user}
          else
            # Child conversation: authorize against the sandbox (parent) conversation
            case Magus.Chat.get_conversation(effective_id, actor: user) do
              {:ok, _} -> {:ok, effective_id, user}
              {:error, _} -> {:error, :not_found, "Conversation not found"}
            end
          end
        else
          {:error, _} -> {:error, :not_found, "Conversation not found"}
        end
    end
  end

  @doc """
  Execute Python code in a conversation's sandbox.

  ## Options

    * `:timeout_ms` - Maximum execution time in milliseconds (default: 30_000, max: 600_000)
    * `:description` - Brief description of what the code does (for logging)
    * `:message_id` - Associated message ID
    * `:user_id` - User ID for authorization verification (optional but recommended)
    * `:cleanup` - Whether to cleanup workspace after execution (default: false)
    * `:files` - List of files to copy to workspace before execution (each with `:name` and `:content`)

  ## Returns

    * `{:ok, result}` - Execution succeeded with stdout, stderr, files, etc.
    * `{:error, :forbidden_code, message}` - Code failed validation
    * `{:error, :timeout, partial}` - Execution timed out
    * `{:error, :oom, partial}` - Out of memory
    * `{:error, reason, details}` - Other error
  """
  @spec execute(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom(), term()}
  def execute(conversation_id, code, opts \\ []) do
    cleanup? = Keyword.get(opts, :cleanup, false)
    files = Keyword.get(opts, :files, [])

    with {:ok, effective_id, actor} <- resolve_and_authorize(conversation_id, opts),
         {:ok, sandbox} <- ensure_sandbox(effective_id, actor),
         :ok <- setup_workspace(sandbox),
         {:ok, _copied} <- maybe_copy_files(sandbox, files),
         {:ok, execution} <- create_execution(sandbox, code, opts) do
      # Run code and finalize - handles both success and error cases
      result =
        CodeRunner.run(sandbox, execution, code, opts)
        |> finalize_result(execution, sandbox)

      if cleanup?, do: cleanup_workspace(sandbox)

      result
    else
      error -> normalize_error(error)
    end
  end

  @doc """
  Install Python packages in a conversation's sandbox.

  ## Options

    * `:timeout_ms` - Maximum installation time in milliseconds (default: 120_000, max: 300_000)
    * `:user_id` - User ID for authorization verification (required)

  ## Returns

    * `{:ok, result}` - Installation succeeded with stdout, stderr, exit_code, duration_ms
    * `{:error, :timeout, partial}` - Installation timed out
    * `{:error, reason, details}` - Other error
  """
  @spec install_packages(Ecto.UUID.t(), list(String.t()), keyword()) ::
          {:ok, map()} | {:error, atom(), term()}
  def install_packages(conversation_id, packages, opts \\ []) when is_list(packages) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 120_000) |> min(300_000)

    with {:ok, effective_id, actor} <- resolve_and_authorize(conversation_id, opts),
         {:ok, sandbox} <- ensure_sandbox(effective_id, actor),
         :ok <- setup_workspace(sandbox) do
      # Execute uv pip install via provider exec (falls back to pip if uv not available)
      client = Provider.client_for(sandbox)
      escaped_packages = packages |> Enum.map(&shell_escape/1) |> Enum.join(" ")
      start_time = System.monotonic_time(:millisecond)

      case client.exec(sandbox.sprite_id, "uv pip install --system #{escaped_packages}",
             timeout: timeout_ms,
             max_run_after_disconnect: "180s"
           ) do
        {:ok, result} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time

          {:ok,
           %{
             stdout: result.stdout || "",
             stderr: result.stderr || "",
             exit_code: result.exit_code,
             duration_ms: duration_ms
           }}

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:error, :timeout, %{}}

        {:error, reason} ->
          {:error, :installation_failed, reason}
      end
    else
      error -> normalize_error(error)
    end
  end

  @doc """
  Execute a shell command in a conversation's sandbox.

  ## Options

    * `:timeout_ms` - Maximum execution time in milliseconds (default: 300_000, no upper cap)
    * `:working_dir` - Working directory (default: "/workspace")
    * `:description` - Brief description (for execution record)
    * `:message_id` - Associated message ID
    * `:user_id` - User ID for authorization (required)
    * `:on_output` - Optional callback `fn {stream_type, chunk} -> ... end` for streaming output

  ## Returns

    * `{:ok, result}` - Command completed with stdout, stderr, exit_code, duration_ms
    * `{:error, :timeout, partial}` - Command timed out
    * `{:error, :oom, partial}` - Out of memory
    * `{:error, reason, details}` - Other error
  """
  @spec exec_command(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom(), term()}
  def exec_command(conversation_id, command, opts \\ []) do
    with {:ok, effective_id, actor} <- resolve_and_authorize(conversation_id, opts),
         {:ok, sandbox} <- ensure_sandbox(effective_id, actor),
         {:ok, sandbox} <- setup_workspace_or_reprovision(sandbox, actor),
         {:ok, execution} <- create_command_execution(sandbox, command, opts) do
      CommandRunner.run(sandbox, command, opts)
      |> enrich_with_workspace_files(sandbox)
      |> finalize_result(execution, sandbox)
    else
      error -> normalize_error(error)
    end
  end

  @doc """
  Read a file from the sandbox filesystem.

  ## Options

    * `:user_id` - User ID for authorization (required)

  ## Returns

    * `{:ok, %{content: binary, path: String.t()}}` - File contents
    * `{:error, :not_found, message}` - File doesn't exist
    * `{:error, reason, details}` - Other error
  """
  @spec read_file(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom(), term()}
  def read_file(conversation_id, path, opts \\ []) do
    with {:ok, effective_id, actor} <- resolve_and_authorize(conversation_id, opts),
         {:ok, sandbox} <- ensure_sandbox(effective_id, actor) do
      client = Provider.client_for(sandbox)
      normalized_path = normalize_sandbox_path(path)

      case client.read_file(sandbox.sprite_id, normalized_path) do
        {:ok, content} ->
          {:ok, %{content: content, path: normalized_path, size_bytes: byte_size(content)}}

        {:error, :not_found} ->
          {:error, :not_found, "File not found: #{normalized_path}"}

        {:error, :not_configured} ->
          {:error, :not_configured, "Sandbox service not configured"}

        {:error, reason} ->
          {:error, :file_error, reason}
      end
    else
      error -> normalize_error(error)
    end
  end

  @doc """
  Write a file to the sandbox filesystem.

  ## Options

    * `:user_id` - User ID for authorization (required)

  ## Returns

    * `{:ok, %{path: String.t(), size_bytes: integer}}` - File written
    * `{:error, reason, details}` - Error
  """
  @spec write_file(Ecto.UUID.t(), String.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, atom(), term()}
  def write_file(conversation_id, path, content, opts \\ []) do
    with {:ok, effective_id, actor} <- resolve_and_authorize(conversation_id, opts),
         {:ok, sandbox} <- ensure_sandbox(effective_id, actor) do
      client = Provider.client_for(sandbox)
      normalized_path = normalize_sandbox_path(path)

      case client.write_file(sandbox.sprite_id, normalized_path, content) do
        :ok ->
          {:ok, %{path: normalized_path, size_bytes: byte_size(content)}}

        {:error, :not_configured} ->
          {:error, :not_configured, "Sandbox service not configured"}

        {:error, reason} ->
          {:error, :file_error, reason}
      end
    else
      error -> normalize_error(error)
    end
  end

  @doc """
  List files in a sandbox directory.

  ## Options

    * `:user_id` - User ID for authorization (required)

  ## Returns

    * `{:ok, list(map)}` - List of file entries
    * `{:error, reason, details}` - Error
  """
  @spec list_files(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, list(map())} | {:error, atom(), term()}
  def list_files(conversation_id, path, opts \\ []) do
    with {:ok, effective_id, actor} <- resolve_and_authorize(conversation_id, opts),
         {:ok, sandbox} <- ensure_sandbox(effective_id, actor) do
      client = Provider.client_for(sandbox)
      normalized_path = normalize_sandbox_path(path)

      case client.list_files(sandbox.sprite_id, normalized_path) do
        {:ok, entries} ->
          {:ok, entries}

        {:error, :enoent} ->
          {:error, :not_found, "Directory not found: #{normalized_path}"}

        {:error, :not_configured} ->
          {:error, :not_configured, "Sandbox service not configured"}

        {:error, reason} ->
          {:error, :file_error, reason}
      end
    else
      error -> normalize_error(error)
    end
  end

  @doc """
  Download a file from the sandbox and persist it to permanent storage.

  Unlike `read_file/3` which returns raw content for the LLM, this function
  persists the file to the Files domain and returns a download URL for the user.

  ## Options

    * `:user_id` - User ID for authorization (required)

  ## Returns

    * `{:ok, %{id, filename, mime_type, size_bytes, download_url}}` - File persisted
    * `{:error, :not_found, message}` - File doesn't exist
    * `{:error, reason, details}` - Other error
  """
  @spec download_file(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom(), term()}
  def download_file(conversation_id, path, opts \\ []) do
    with {:ok, effective_id, actor} <- resolve_and_authorize(conversation_id, opts),
         {:ok, sandbox} <- ensure_sandbox(effective_id, actor) do
      client = Provider.client_for(sandbox)
      normalized_path = normalize_sandbox_path(path)
      filename = Path.basename(normalized_path)
      user_id = Keyword.fetch!(opts, :user_id)

      case client.read_file(sandbox.sprite_id, normalized_path) do
        {:ok, content} ->
          case FilesExtractor.persist_file(content, filename, user_id, conversation_id) do
            {:ok, file_info} ->
              {:ok, file_info}

            {:error, reason} ->
              {:error, :persistence_error, reason}
          end

        {:error, :not_found} ->
          {:error, :not_found, "File not found: #{normalized_path}"}

        {:error, :not_configured} ->
          {:error, :not_configured, "Sandbox service not configured"}

        {:error, reason} ->
          {:error, :file_error, reason}
      end
    else
      error -> normalize_error(error)
    end
  end

  @doc """
  Upload a file into the sandbox filesystem.

  Accepts either a platform File ID or a URL as the source.

  ## Source

    * `{:file_id, uuid}` - Upload a file already stored in the platform
    * `{:url, string}` - Download from URL and upload to sandbox

  ## Options

    * `:user_id` - User ID for authorization (required)
    * `:path` - Destination path in sandbox (default: `/workspace/{filename}`)

  ## Returns

    * `{:ok, %{path: String.t(), filename: String.t(), size_bytes: integer, source: String.t()}}` - File uploaded
    * `{:error, reason, details}` - Error
  """
  @spec upload_file(Ecto.UUID.t(), {:file_id, Ecto.UUID.t()} | {:url, String.t()}, keyword()) ::
          {:ok, map()} | {:error, atom(), term()}
  def upload_file(conversation_id, source, opts \\ []) do
    # Resolve source before ensuring sandbox to fail fast on invalid sources
    # (avoids slow sandbox provisioning when file_id is invalid or URL is 404)
    with {:ok, effective_id, actor} <- resolve_and_authorize(conversation_id, opts),
         {:ok, content, filename, source_type} <- resolve_upload_source(source, actor),
         {:ok, sandbox} <- ensure_sandbox(effective_id, actor) do
      dest_path = Keyword.get(opts, :path) || "/workspace/#{filename}"
      normalized_path = normalize_sandbox_path(dest_path)
      client = Provider.client_for(sandbox)

      case client.write_file(sandbox.sprite_id, normalized_path, content) do
        :ok ->
          {:ok,
           %{
             path: normalized_path,
             filename: filename,
             size_bytes: byte_size(content),
             source: source_type
           }}

        {:error, :not_configured} ->
          {:error, :not_configured, "Sandbox service not configured"}

        {:error, reason} ->
          {:error, :file_error, reason}
      end
    else
      error -> normalize_error(error)
    end
  end

  defp resolve_upload_source({:file_id, file_id}, actor) do
    case Magus.Files.get_file(file_id, actor: actor) do
      {:ok, file} ->
        case Magus.Files.Storage.get(file.file_path) do
          {:ok, content} ->
            {:ok, content, file.name, "file"}

          {:error, reason} ->
            {:error, :storage_error, "Failed to read file content: #{inspect(reason)}"}
        end

      {:error, _} ->
        {:error, :not_found, "File not found: #{file_id}"}
    end
  end

  defp resolve_upload_source({:url, url}, _actor) do
    uri = URI.parse(url)

    if uri.scheme not in ["http", "https"] do
      {:error, :invalid_url, "Only http:// and https:// URLs are supported"}
    else
      case Req.get(url, receive_timeout: 60_000, max_redirects: 5, decode_body: false) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          if byte_size(body) > @max_upload_bytes do
            {:error, :too_large,
             "File exceeds maximum upload size of #{div(@max_upload_bytes, 1_048_576)} MB"}
          else
            filename = filename_from_url(url)
            {:ok, body, filename, "url"}
          end

        {:ok, %{status: status}} ->
          {:error, :fetch_error, "URL returned HTTP #{status}"}

        {:error, reason} ->
          {:error, :fetch_error, "Failed to fetch URL: #{inspect(reason)}"}
      end
    end
  end

  defp filename_from_url(url) do
    uri = URI.parse(url)
    path_basename = if uri.path, do: Path.basename(uri.path), else: nil

    case path_basename do
      nil -> "download"
      "" -> "download"
      "." -> "download"
      "/" -> "download"
      name -> name
    end
  end

  @doc """
  Start a service in the sandbox and return the proxied preview URL.

  ## Options

    * `:user_id` - User ID for authorization (required)

  ## Returns

    * `{:ok, %{preview_url: String.t(), service_name: String.t(), status: String.t()}}` - Service started
    * `{:error, reason, details}` - Error
  """
  @spec start_service(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()} | {:error, atom(), term()}
  def start_service(conversation_id, service_config, opts \\ []) do
    with {:ok, effective_id, actor} <- resolve_and_authorize(conversation_id, opts),
         {:ok, sandbox} <- ensure_sandbox(effective_id, actor),
         :ok <- setup_workspace(sandbox) do
      name = Map.fetch!(service_config, :name)
      command = Map.fetch!(service_config, :command)
      args = Map.get(service_config, :args, [])
      port = Map.fetch!(service_config, :port)
      working_dir = Map.get(service_config, :working_dir, "/workspace")

      config = %{name: name, command: command, args: args, port: port, working_dir: working_dir}

      with :ok <- do_start_service(sandbox, name, command, args, port, working_dir),
           {:ok, _} <-
             Sandbox.set_service_port(
               sandbox,
               %{service_port: port, service_config: config},
               authorize?: false
             ) do
        preview_url = "/sandbox/preview/#{conversation_id}/"

        {:ok,
         %{
           preview_url: preview_url,
           service_name: name,
           status: "running",
           port: port
         }}
      else
        {:error, reason} -> {:error, :service_error, reason}
      end
    else
      error -> normalize_error(error)
    end
  end

  @doc """
  Stop a service in the sandbox.
  """
  @spec stop_service(Ecto.UUID.t(), String.t(), keyword()) ::
          :ok | {:error, atom(), term()}
  def stop_service(conversation_id, service_name, opts \\ []) do
    with {:ok, effective_id, actor} <- resolve_and_authorize(conversation_id, opts),
         {:ok, sandbox} <- ensure_sandbox(effective_id, actor) do
      case do_stop_service(sandbox, service_name) do
        :ok ->
          case Sandbox.set_service_port(sandbox, %{service_port: nil}, authorize?: false) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.warning("Failed to clear service_port after stopping service",
                sandbox_id: sandbox.id,
                error: inspect(reason)
              )

              :ok
          end

        {:error, reason} ->
          {:error, :service_error, reason}
      end
    else
      error -> normalize_error(error)
    end
  end

  # Service management is provider-specific.
  # Sprites uses its sprite-env service management API.
  # Other providers start services as background processes via exec.
  defp do_start_service(%{provider: :sprites} = sandbox, name, command, args, port, working_dir) do
    sprites = Magus.Sandbox.Clients.Sprites
    config = %{cmd: command, args: args, http_port: port, working_dir: working_dir}

    with :ok <- sprites.create_service(sandbox.sprite_id, name, config),
         {:ok, :started} <- sprites.start_service(sandbox.sprite_id, name) do
      :ok
    end
  end

  defp do_start_service(
         %{provider: :daytona} = sandbox,
         name,
         command,
         args,
         port,
         working_dir
       ) do
    # Daytona kills background processes when an exec session ends.
    # Use a persistent Daytona session to keep the service alive.
    escaped_args = Enum.map_join(args, " ", &shell_escape/1)
    escaped_cmd = shell_escape(command)
    escaped_dir = shell_escape(working_dir)
    full_command = "cd #{escaped_dir} && PORT=#{port} #{escaped_cmd} #{escaped_args}"

    Magus.Sandbox.Clients.Daytona.start_service(sandbox.sprite_id, full_command, name: name)
  end

  defp do_start_service(sandbox, _name, command, args, port, working_dir) do
    client = Provider.client_for(sandbox)
    escaped_args = Enum.map_join(args, " ", &shell_escape/1)
    escaped_cmd = shell_escape(command)
    escaped_dir = shell_escape(working_dir)
    full_command = "cd #{escaped_dir} && PORT=#{port} #{escaped_cmd} #{escaped_args} &"

    case client.exec(sandbox.sprite_id, full_command, timeout: 10_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_stop_service(%{provider: :sprites} = sandbox, service_name) do
    Magus.Sandbox.Clients.Sprites.stop_service(sandbox.sprite_id, service_name)
  end

  defp do_stop_service(%{provider: :daytona} = sandbox, service_name) do
    Magus.Sandbox.Clients.Daytona.stop_service(sandbox.sprite_id, service_name)
  end

  defp do_stop_service(sandbox, _service_name) do
    client = Provider.client_for(sandbox)

    case client.exec(sandbox.sprite_id, "pkill -f 'PORT=' || true", timeout: 10_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Normalize various error formats into consistent {:error, atom, details} tuples
  defp normalize_error({:error, reason, message}) when is_atom(reason) and is_binary(message) do
    {:error, reason, message}
  end

  defp normalize_error({:error, reason, details}) when is_atom(reason) do
    {:error, reason, details}
  end

  defp normalize_error({:error, %Ash.Error.Invalid{errors: errors}}) do
    message = extract_ash_error_message(errors)
    {:error, :validation_error, message}
  end

  defp normalize_error({:error, %Ash.Error.Query.NotFound{}}) do
    {:error, :not_found, "Resource not found"}
  end

  defp normalize_error({:error, %{__struct__: _} = error}) do
    {:error, :internal_error, extract_error_message(error)}
  end

  defp normalize_error({:error, reason}) when is_atom(reason) do
    {:error, reason, %{}}
  end

  defp normalize_error({:error, reason}) do
    {:error, :unknown_error, reason}
  end

  # Extract a clean error message from Ash nested errors
  defp extract_ash_error_message(errors) when is_list(errors) do
    errors
    |> Enum.map(&extract_single_error_message/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
    |> case do
      "" -> "An error occurred"
      message -> message
    end
  end

  defp extract_ash_error_message(_), do: "An error occurred"

  defp extract_single_error_message(%{errors: nested_errors}) when is_list(nested_errors) do
    extract_ash_error_message(nested_errors)
  end

  defp extract_single_error_message(%{message: message}) when is_binary(message) do
    message
  end

  defp extract_single_error_message(%{__struct__: _} = error) do
    try do
      Exception.message(error)
    rescue
      _ -> nil
    end
  end

  defp extract_single_error_message(_), do: nil

  defp extract_error_message(%{message: message}) when is_binary(message), do: message

  defp extract_error_message(error) do
    try do
      Exception.message(error)
    rescue
      _ -> "An error occurred"
    end
  end

  # Ensure a sandbox exists and is active for the conversation.
  # Uses a two-phase approach:
  # 1. Transaction + advisory lock: check state and create DB record if needed (fast)
  # 2. Outside transaction: provision via HTTP API + polling (slow, can take 60s+)
  # This prevents holding a DB connection during long-running HTTP polling.
  defp ensure_sandbox(conversation_id, actor) do
    # Phase 1: Determine what action is needed under advisory lock
    lock_result =
      Magus.Repo.transaction(fn ->
        sandbox_lock(conversation_id, fn ->
          opts = [actor: actor]

          case Sandbox.get_sandbox_by_conversation(conversation_id, opts) do
            {:ok, [%{state: :terminated} = old_sandbox]} ->
              {:needs_replace, old_sandbox}

            {:ok, [%{state: :uninitialized} = sandbox]} ->
              {:needs_provision, sandbox}

            {:ok, [sandbox]} ->
              activate_sandbox(sandbox, actor)

            {:ok, []} ->
              Logger.info("Creating new sandbox", conversation_id: conversation_id)
              # Create the DB record inside the lock, provision outside the transaction
              notify_opts = [actor: actor, return_notifications?: true]

              case Sandbox.create_sandbox(conversation_id, notify_opts) do
                {:ok, sandbox, notifications} ->
                  Ash.Notifier.notify(notifications)
                  {:needs_provision, sandbox}

                error ->
                  error
              end

            {:ok, [first | _rest]} ->
              Logger.warning("Multiple sandboxes found for conversation, using first",
                conversation_id: conversation_id,
                sandbox_id: first.id
              )

              activate_sandbox(first, actor)

            {:error, reason} ->
              Logger.error("Failed to get sandbox",
                conversation_id: conversation_id,
                error: inspect(reason)
              )

              {:error, :sandbox_error, reason}
          end
        end)
      end)

    # Phase 2: Handle provisioning outside the transaction
    case lock_result do
      {:ok, {:needs_alive_check, sandbox}} ->
        case verify_alive(sandbox) do
          :ok ->
            {:ok, sandbox}

          {:error, :sandbox_stopped} ->
            # Stopped upstream but DB says :active. Start it directly
            # via the provider, bypassing the Ash state machine.
            client = Provider.client_for(sandbox)

            case client.restore(sandbox.sprite_id, sandbox.checkpoint_id) do
              {:ok, _} -> {:ok, sandbox}
              {:error, _} -> terminate_and_reprovision(sandbox, actor)
            end

          {:error, :sandbox_dead} ->
            terminate_and_reprovision(sandbox, actor)
        end

      {:ok, {:needs_provision, sandbox}} ->
        provision_sandbox(sandbox, actor)

      {:ok, {:needs_resume, sandbox}} ->
        resume_sandbox(sandbox, actor)

      {:ok, {:needs_replace, old_sandbox}} ->
        replace_terminated_sandbox(old_sandbox, actor)

      {:ok, {:needs_create_and_provision, conversation_id}} ->
        create_and_provision_sandbox(conversation_id, actor)

      {:ok, {:ok, sandbox, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, sandbox}

      other ->
        unwrap_transaction(other)
    end
  end

  @doc """
  Acquire a PostgreSQL advisory lock scoped to a conversation's sandbox operations.
  Prevents concurrent provisioning/resume from creating duplicate sandbox services.
  Uses lock class 2 to avoid collisions with agent run locks (class 0) and mention locks (class 1).
  """
  def sandbox_lock(conversation_id, fun) do
    case Magus.Repo.query(
           "SELECT pg_advisory_xact_lock(hashtext($1), 2)",
           [conversation_id]
         ) do
      {:ok, _} -> fun.()
      {:error, reason} -> {:error, :lock_failed, reason}
    end
  end

  # Unwrap Repo.transaction's {:ok, result} / {:error, result} envelope
  # so callers see the same return types as before.
  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, :rollback, reason}), do: {:error, :sandbox_error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, :sandbox_error, reason}

  defp create_and_provision_sandbox(conversation_id, actor, retry_count \\ 0)

  defp create_and_provision_sandbox(conversation_id, _actor, retry_count) when retry_count >= 2 do
    Logger.error("Sandbox creation failed after max retries",
      conversation_id: conversation_id,
      retry_count: retry_count
    )

    {:error, :sandbox_error, "Failed to create sandbox after multiple attempts"}
  end

  defp create_and_provision_sandbox(conversation_id, actor, retry_count) do
    opts = [actor: actor]

    # Retry if we hit a unique constraint violation (race condition)
    # This can happen if two concurrent requests try to create a sandbox
    case do_create_and_provision_sandbox(conversation_id, opts) do
      {:ok, sandbox, notifications} ->
        {:ok, sandbox, notifications}

      {:error, %Ash.Error.Invalid{errors: errors}} = error ->
        if has_unique_constraint_error?(errors) do
          # Race condition - another request created the sandbox, fetch it
          Logger.debug("Sandbox creation race condition, fetching existing",
            conversation_id: conversation_id,
            retry_count: retry_count
          )

          case Sandbox.get_sandbox_by_conversation(conversation_id, opts) do
            {:ok, [%{state: :terminated} = old_sandbox]} ->
              Ash.destroy(old_sandbox, opts)
              create_and_provision_sandbox(conversation_id, actor, retry_count + 1)

            {:ok, [sandbox]} ->
              activate_sandbox(sandbox, actor)

            {:ok, []} ->
              create_and_provision_sandbox(conversation_id, actor, retry_count + 1)

            {:ok, [first | _]} ->
              activate_sandbox(first, actor)

            {:error, reason} ->
              {:error, :sandbox_error, reason}
          end
        else
          error
        end

      error ->
        error
    end
  end

  defp do_create_and_provision_sandbox(conversation_id, opts) do
    notify_opts = Keyword.put(opts, :return_notifications?, true)

    with {:ok, sandbox, create_notifs} <- Sandbox.create_sandbox(conversation_id, notify_opts),
         {:ok, sandbox, provision_notifs} <- Sandbox.provision(sandbox, notify_opts) do
      {:ok, sandbox, create_notifs ++ provision_notifs}
    end
  end

  defp has_unique_constraint_error?(errors) when is_list(errors) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidChanges{message: msg} when is_binary(msg) ->
        String.contains?(msg, "unique") or String.contains?(msg, "already exists")

      %{errors: nested} when is_list(nested) ->
        has_unique_constraint_error?(nested)

      _ ->
        false
    end)
  end

  defp has_unique_constraint_error?(_), do: false

  # Create an execution record
  defp create_execution(sandbox, code, opts) do
    attrs = %{
      code: code,
      description: Keyword.get(opts, :description),
      sandbox_id: sandbox.id,
      message_id: Keyword.get(opts, :message_id)
    }

    Sandbox.create_execution(attrs, authorize?: false)
  end

  # Finalize execution record and update sandbox stats.
  # Shared by both code execution and command execution paths.
  # Result is piped in as the first argument.
  defp finalize_result({:error, :timeout, partial}, execution, _sandbox) do
    Sandbox.timeout_execution(
      execution,
      %{
        stdout: partial[:stdout] || "",
        stderr: partial[:stderr] || "",
        duration_ms: 0
      },
      authorize?: false
    )

    {:error, :timeout, partial}
  end

  defp finalize_result({:error, :oom, partial}, execution, _sandbox) do
    Sandbox.fail_execution(
      execution,
      %{
        stdout: partial[:stdout] || "",
        stderr: partial[:stderr] || "",
        exit_code: 137,
        duration_ms: 0,
        error_type: :oom
      },
      authorize?: false
    )

    {:error, :oom, partial}
  end

  defp finalize_result({:error, error_type, details}, execution, _sandbox) do
    stderr = extract_stderr(details)

    Sandbox.fail_execution(
      execution,
      %{
        stdout: "",
        stderr: stderr,
        exit_code: 1,
        duration_ms: 0,
        error_type: :runtime_error
      },
      authorize?: false
    )

    {:error, error_type, details}
  end

  defp finalize_result({:ok, result}, execution, sandbox) do
    cost = estimate_cost(result.duration_ms)
    workspace_files = Map.get(result, :workspace_files, [])

    if result.exit_code == 0 do
      Sandbox.complete_execution(
        execution,
        %{
          stdout: result.stdout,
          stderr: result.stderr,
          exit_code: result.exit_code,
          duration_ms: result.duration_ms,
          estimated_cost_usd: cost,
          files_created: workspace_files
        },
        authorize?: false
      )
    else
      Sandbox.fail_execution(
        execution,
        %{
          stdout: result.stdout,
          stderr: result.stderr,
          exit_code: result.exit_code,
          duration_ms: result.duration_ms,
          error_type: :runtime_error
        },
        authorize?: false
      )
    end

    Sandbox.record_execution(
      sandbox,
      result.duration_ms,
      cost,
      %{workspace_files: workspace_files},
      authorize?: false
    )

    {:ok, Map.put(result, :execution_id, execution.id)}
  end

  defp extract_stderr(%{stderr: s}) when is_binary(s), do: s
  defp extract_stderr({:execution_error, msg}) when is_binary(msg), do: msg
  defp extract_stderr(msg) when is_binary(msg), do: msg
  defp extract_stderr(other), do: inspect(other)

  # Estimate execution cost based on duration
  # Based on typical cloud compute pricing (~$0.0001/cpu-second)
  @cost_per_cpu_second Decimal.new("0.0001")
  @cost_per_gb_second Decimal.new("0.00005")
  @memory_gb Decimal.new("0.5")

  defp estimate_cost(duration_ms) do
    cpu_seconds = Decimal.div(Decimal.new(duration_ms), Decimal.new(1000))

    cpu_cost = Decimal.mult(cpu_seconds, @cost_per_cpu_second)
    memory_cost = Decimal.mult(Decimal.mult(cpu_seconds, @memory_gb), @cost_per_gb_second)

    Decimal.add(cpu_cost, memory_cost)
    |> Decimal.round(6)
  end

  # Bring a sandbox to the :active state based on its current state.
  # Returns {:needs_*, sandbox} tuples for states requiring HTTP calls,
  # so those can be handled outside the DB transaction.
  defp activate_sandbox(%{state: :active} = sandbox, _actor) do
    {:needs_alive_check, sandbox}
  end

  defp activate_sandbox(%{state: :suspended} = sandbox, _actor) do
    {:needs_resume, sandbox}
  end

  defp activate_sandbox(%{state: :uninitialized} = sandbox, _actor) do
    {:needs_provision, sandbox}
  end

  defp activate_sandbox(%{state: :terminated} = sandbox, actor) do
    replace_terminated_sandbox(sandbox, actor)
  end

  # Resume a suspended sandbox outside the DB transaction to avoid holding a
  # connection during HTTP polling (resume can trigger redeployment polling).
  defp resume_sandbox(sandbox, actor) do
    Logger.info("Resuming suspended sandbox", sandbox_id: sandbox.id)

    case Sandbox.resume(sandbox, actor: actor) do
      {:ok, sandbox} ->
        {:ok, sandbox}

      {:error, _reason} ->
        Logger.warning("Resume failed, terminating and reprovisioning",
          sandbox_id: sandbox.id,
          sprite_id: sandbox.sprite_id
        )

        terminate_and_reprovision(sandbox, actor)
    end
  end

  # Provision a sandbox outside the DB transaction to avoid holding a connection
  # during long-running HTTP polling (can take 60s+).
  defp provision_sandbox(sandbox, actor) do
    Logger.info("Provisioning sandbox", sandbox_id: sandbox.id)

    case Sandbox.provision(sandbox, actor: actor, return_notifications?: true) do
      {:ok, sandbox, notifications} ->
        Ash.Notifier.notify(notifications)
        {:ok, sandbox}

      error ->
        error
    end
  end

  # Replace a terminated sandbox: clean up old executions and records, then create new.
  defp replace_terminated_sandbox(old_sandbox, actor) do
    Logger.info("Replacing terminated sandbox",
      conversation_id: old_sandbox.conversation_id,
      old_sandbox_id: old_sandbox.id
    )

    # Delete executions first to avoid FK constraint violation
    Magus.Sandbox.Execution
    |> Ash.Query.filter(sandbox_id == ^old_sandbox.id)
    |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false)

    case Ash.destroy(old_sandbox, authorize?: false) do
      :ok ->
        create_and_provision_sandbox(old_sandbox.conversation_id, actor)

      {:error, reason} ->
        Logger.error("Failed to destroy terminated sandbox",
          sandbox_id: old_sandbox.id,
          error: inspect(reason)
        )

        {:error, :sandbox_error, "Failed to replace terminated sandbox"}
    end
  end

  # Verify that a sandbox is actually alive by checking with the provider.
  # Returns :ok if alive, {:error, :sandbox_dead} if gone or unreachable.
  # For ambiguous errors (API 500, auth issues), assumes alive to avoid
  # mass reprovisioning during provider API downtime.
  defp verify_alive(sandbox) do
    client = Provider.client_for(sandbox)

    case client.get_sandbox(sandbox.sprite_id) do
      {:ok, %{"state" => state}} when state in ~w(stopped stopping) ->
        Logger.info("Sandbox stopped upstream, needs resume",
          sandbox_id: sandbox.id,
          sprite_id: sandbox.sprite_id,
          upstream_state: state
        )

        {:error, :sandbox_stopped}

      {:ok, _info} ->
        :ok

      {:error, :not_found} ->
        Logger.warning("Sandbox confirmed dead (404)",
          sandbox_id: sandbox.id,
          sprite_id: sandbox.sprite_id
        )

        {:error, :sandbox_dead}

      {:error, :not_configured} ->
        # Client not configured — let actual operation fail downstream
        :ok

      {:error, %Req.TransportError{reason: reason}} when reason in [:closed, :timeout] ->
        Logger.warning("Sandbox unreachable (#{reason}), treating as dead",
          sandbox_id: sandbox.id,
          sprite_id: sandbox.sprite_id
        )

        {:error, :sandbox_dead}

      {:error, reason} ->
        # Ambiguous error (API 500, auth, etc.) — assume alive
        Logger.warning("Sandbox health check ambiguous, assuming alive",
          sandbox_id: sandbox.id,
          sprite_id: sandbox.sprite_id,
          error: inspect(reason)
        )

        :ok
    end
  end

  # Terminate a dead sandbox and reprovision a fresh one.
  defp terminate_and_reprovision(sandbox, actor) do
    Logger.info("Reprovisioning dead sandbox",
      sandbox_id: sandbox.id,
      sprite_id: sandbox.sprite_id,
      conversation_id: sandbox.conversation_id
    )

    opts = [actor: actor, authorize?: false]

    with {:ok, _terminated} <- Ash.update(sandbox, %{}, [action: :terminate] ++ opts),
         {:ok, new_sandbox} <- create_and_provision_sandbox(sandbox.conversation_id, actor) do
      {:ok, new_sandbox}
    end
  end

  # Setup workspace directories before execution
  # Tries to set up workspace; if the sandbox is dead, terminates it,
  # reprovisions a new one, and sets up workspace on the fresh one.
  # Returns {:ok, sandbox} with the sandbox to use for subsequent operations.
  defp setup_workspace_or_reprovision(sandbox, actor) do
    case setup_workspace(sandbox) do
      :ok ->
        {:ok, sandbox}

      {:error, :sprite_not_found, _} ->
        Logger.info("Sandbox dead, terminating and reprovisioning",
          sandbox_id: sandbox.id,
          sprite_id: sandbox.sprite_id
        )

        opts = [actor: actor, authorize?: false]

        with {:ok, _terminated} <- Ash.update(sandbox, %{}, [action: :terminate] ++ opts),
             {:ok, new_sandbox} <- create_and_provision_sandbox(sandbox.conversation_id, actor),
             :ok <- setup_workspace(new_sandbox) do
          {:ok, new_sandbox}
        end

      error ->
        error
    end
  end

  defp setup_workspace(sandbox) do
    case WorkspaceManager.setup(sandbox) do
      :ok ->
        :ok

      {:error, {:api_error, 404, _}} ->
        Logger.error("Sandbox #{sandbox.sprite_id} not found - may need reprovisioning")
        {:error, :sprite_not_found, "Sandbox not found. Please try again."}

      {:error, :not_configured} ->
        {:error, :not_configured, "Sandbox service not configured"}

      {:error, %Req.TransportError{reason: reason}} when reason in [:closed, :timeout] ->
        Logger.error(
          "Sandbox #{sandbox.sprite_id} unreachable (#{reason}) - needs reprovisioning"
        )

        {:error, :sprite_not_found, "Sandbox unreachable. Please try again."}

      {:error, reason} ->
        Logger.warning(
          "Failed to setup workspace for sandbox #{sandbox.sprite_id}: #{inspect(reason)}"
        )

        # Continue anyway - directories might already exist from preinstall
        :ok
    end
  end

  # Copy files to workspace if provided
  defp maybe_copy_files(_sandbox, []), do: {:ok, []}

  defp maybe_copy_files(sandbox, files) do
    WorkspaceManager.copy_files(sandbox, files)
  end

  # Cleanup workspace after execution
  defp cleanup_workspace(sandbox) do
    case WorkspaceManager.cleanup(sandbox) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to cleanup workspace for sandbox #{sandbox.sprite_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Normalize a path to be absolute under /workspace
  defp normalize_sandbox_path("/" <> _ = path), do: path
  defp normalize_sandbox_path(path), do: Path.join("/workspace", path)

  # Shell-escape a single argument using single quotes.
  # Single quotes prevent all shell interpretation; embedded single quotes
  # are escaped by ending the quote, adding an escaped quote, and reopening.
  defp shell_escape(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  # Create an execution record for a command (type: :command)
  defp create_command_execution(sandbox, command, opts) do
    attrs = %{
      command: command,
      type: :command,
      description: Keyword.get(opts, :description),
      sandbox_id: sandbox.id,
      message_id: Keyword.get(opts, :message_id)
    }

    Sandbox.create_execution(attrs, authorize?: false)
  end

  # Enrich a command result with workspace file listing.
  # For code execution, CodeRunner already includes workspace_files in the result.
  # For command execution, we fetch them after the command completes.
  defp enrich_with_workspace_files({:ok, result}, sandbox) do
    workspace_files =
      case WorkspaceManager.list_workspace_files(sandbox) do
        {:ok, files} -> files
        {:error, _} -> []
      end

    {:ok, Map.put(result, :workspace_files, workspace_files)}
  end

  defp enrich_with_workspace_files(error, _sandbox), do: error
end
