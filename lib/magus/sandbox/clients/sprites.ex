defmodule Magus.Sandbox.Clients.Sprites do
  @moduledoc """
  Sprites.dev sandbox provider implementation.

  Implements `Magus.Sandbox.Provider` behaviour using the Sprites.dev
  Firecracker MicroVM platform.

  ## Configuration

  Configure in `config/runtime.exs`:

      config :magus, Magus.Sandbox.Clients.Sprites,
        api_key: System.get_env("SPRITES_API_KEY"),
        base_url: System.get_env("SPRITES_BASE_URL") || "https://api.sprites.dev"
  """

  @behaviour Magus.Sandbox.Provider

  require Logger

  @default_timeout 600_000

  # Timeout for filesystem operations (read, write, list, etc.)
  @fs_timeout 60_000

  # Timeout for SDK client (must accommodate pip install which can be slow)
  @sdk_timeout 180_000

  # Runtime configuration

  defp api_key do
    Application.get_env(:magus, __MODULE__)[:api_key]
  end

  defp base_url do
    Application.get_env(:magus, __MODULE__)[:base_url] || "https://api.sprites.dev"
  end

  @doc """
  Check if the Sprites API is configured.
  """
  @impl true
  def configured? do
    api_key() != nil and api_key() != ""
  end

  @doc """
  Create a new Sprites client.
  """
  def client do
    if configured?() do
      {:ok, Sprites.new(api_key(), base_url: base_url(), timeout: @sdk_timeout)}
    else
      {:error, :not_configured}
    end
  end

  # ============================================================================
  # Provider Behaviour Implementations
  # ============================================================================

  @doc """
  Create a sandbox with optional network policy.

  Wraps `create_sprite/1` and optionally sets up network policy.

  ## Options

    * `:network_policy` - List of allowed domains (triggers `setup_network_policy/1`)
    * `:url_settings` - URL auth settings (default: `%{auth: "sprite"}`)
  """
  @impl true
  def create_sandbox(opts \\ []) do
    with {:ok, %{sprite_id: sprite_id, url: url}} <- create_sprite(opts) do
      if Keyword.has_key?(opts, :network_policy) do
        case setup_network_policy(sprite_id) do
          :ok ->
            {:ok, %{sandbox_id: sprite_id, url: url}}

          {:error, reason} ->
            # Network policy is a security boundary — cleanup and fail
            destroy(sprite_id)
            {:error, {:network_policy_failed, reason}}
        end
      else
        {:ok, %{sandbox_id: sprite_id, url: url}}
      end
    end
  end

  @doc """
  Get information about a sandbox (Sprite) to verify it exists.
  """
  @impl true
  def get_sandbox(sandbox_id), do: get_sprite(sandbox_id)

  @doc """
  Remove a path and its contents in the sandbox (like rm -rf).
  """
  @impl true
  def reset(sandbox_id, path), do: rm_rf(sandbox_id, path)

  # ============================================================================
  # Sprite-specific Operations
  # ============================================================================

  @doc """
  Get information about a Sprite to verify it exists.

  Returns `{:ok, info}` if the sprite exists, `{:error, :not_found}` if gone,
  or `{:error, reason}` for other errors.
  """
  @spec get_sprite(String.t()) :: {:ok, map()} | {:error, term()}
  def get_sprite(sprite_id) do
    with {:ok, client} <- client() do
      case Sprites.get_sprite(client, sprite_id) do
        {:ok, info} ->
          {:ok, info}

        {:error, {:not_found, _}} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Create a new Sprite (Python MicroVM).

  Returns `{:ok, %{sprite_id: String.t(), url: String.t()}}` on success.
  """
  @spec create_sprite(keyword()) :: {:ok, map()} | {:error, term()}
  def create_sprite(opts \\ []) do
    with {:ok, client} <- client() do
      sprite_name = "sandbox-#{Ecto.UUID.generate()}"
      url_settings = Keyword.get(opts, :url_settings, %{auth: "sprite"})

      case Req.post(client.req,
             url: "/v1/sprites",
             json: %{name: sprite_name, url_settings: url_settings},
             receive_timeout: @fs_timeout
           ) do
        {:ok, %{status: 201, body: %{"name" => name, "url" => url}}} ->
          {:ok, %{sprite_id: name, url: url}}

        {:ok, %{status: status, body: body}} ->
          Logger.error("Sprites API error creating sprite",
            status: status,
            body: inspect(body)
          )

          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("Failed to create sprite", error: inspect(reason))
          {:error, reason}
      end
    end
  end

  @doc """
  Execute a command in a Sprite.

  This is a generic command executor - it runs whatever command is given.
  The caller is responsible for setting up files and specifying the right command.

  Uses the POST exec endpoint (no WebSocket needed).

  ## Options

    * `:timeout` - Timeout in milliseconds (default: 600_000). No upper cap — the caller decides how long to wait.

  ## Examples

      # Run a Python script
      exec(sprite_id, "python3 /workspace/script.py")

      # Run a shell command
      exec(sprite_id, "ls -la /workspace")

      # Run Node.js
      exec(sprite_id, "node /workspace/script.js")

  Returns execution result with stdout, stderr, exit_code, and duration.
  """
  @max_ws_retries 3

  @impl true
  @spec exec(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exec(sprite_id, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    on_output = Keyword.get(opts, :on_output)
    # Derive max_run_after_disconnect from the requested timeout plus a 60s buffer.
    # This ensures the sandbox keeps running long enough to complete the command
    # even if the WebSocket connection drops.
    default_max_run = "#{div(timeout, 1_000) + 60}s"
    max_run = Keyword.get(opts, :max_run_after_disconnect, default_max_run)

    query =
      URI.encode_query([
        {"path", "bash"},
        {"cmd", "bash"},
        {"cmd", "-c"},
        {"cmd", command},
        {"stdin", "false"},
        {"max_run_after_disconnect", max_run}
      ])

    ws_url = "#{ws_base_url()}/v1/sprites/#{URI.encode(sprite_id)}/exec?#{query}"
    start_time = System.monotonic_time(:millisecond)

    case ws_exec_with_retry(ws_url, timeout, on_output, 1) do
      {:ok, output, exit_code} ->
        end_time = System.monotonic_time(:millisecond)

        {:ok,
         %{
           stdout: sanitize_output(output),
           stderr: "",
           exit_code: exit_code,
           duration_ms: end_time - start_time
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Retry on transient connection failures (:closed, :upgrade_timeout)
  # which happen during sprite cold-starts.
  defp ws_exec_with_retry(url, timeout, on_output, attempt) do
    case ws_exec(url, timeout, on_output) do
      {:error, reason} when reason in [:closed, :upgrade_timeout] and attempt < @max_ws_retries ->
        Logger.warning("Sprites exec #{reason}, retrying",
          attempt: attempt,
          max_retries: @max_ws_retries
        )

        Process.sleep(1000 * attempt)
        ws_exec_with_retry(url, timeout, on_output, attempt + 1)

      result ->
        result
    end
  end

  # WebSocket-based command execution using gun directly.
  # Connects, runs command, collects output, and optionally streams via callback.
  defp ws_exec(url, timeout, on_output) do
    uri = URI.parse(url)
    host = String.to_charlist(uri.host)
    port = uri.port || if(uri.scheme == "wss", do: 443, else: 80)
    transport = if uri.scheme == "wss", do: :tls, else: :tcp

    gun_opts = %{
      protocols: [:http],
      transport: transport,
      connect_timeout: 15_000,
      tls_opts: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    }

    case :gun.open(host, port, gun_opts) do
      {:ok, conn} ->
        case :gun.await_up(conn, 10_000) do
          {:ok, _protocol} ->
            path = "#{uri.path}?#{uri.query || ""}"
            headers = [{"authorization", "Bearer #{api_key()}"}]
            stream_ref = :gun.ws_upgrade(conn, path, headers)

            result = ws_await_upgrade(conn, stream_ref, timeout, on_output)
            :gun.close(conn)
            result

          {:error, reason} ->
            :gun.close(conn)

            if reason == :closed,
              do: {:error, :closed},
              else: {:error, {:execution_error, inspect(reason)}}
        end

      {:error, reason} ->
        {:error, {:execution_error, inspect(reason)}}
    end
  end

  defp ws_await_upgrade(conn, stream_ref, timeout, on_output) do
    receive do
      {:gun_upgrade, ^conn, ^stream_ref, ["websocket"], _headers} ->
        ws_collect_output(
          conn,
          stream_ref,
          %{acc: "", timeout: timeout, exit_code: nil},
          on_output
        )

      {:gun_response, ^conn, ^stream_ref, is_fin, status, _headers} ->
        body = read_gun_body(conn, stream_ref, is_fin)
        Logger.error("Sprites WS upgrade rejected: HTTP #{status}, body=#{inspect(body)}")
        :gun.close(conn)
        {:error, {:upgrade_failed, status}}

      {:gun_error, ^conn, ^stream_ref, reason} ->
        :gun.close(conn)
        {:error, {:execution_error, inspect(reason)}}

      {:gun_error, ^conn, reason} ->
        :gun.close(conn)
        {:error, {:execution_error, inspect(reason)}}

      {:gun_down, ^conn, _protocol, _reason, _killed} ->
        {:error, :closed}
    after
      10_000 ->
        :gun.close(conn)
        {:error, :upgrade_timeout}
    end
  end

  defp read_gun_body(_conn, _stream_ref, :fin), do: ""

  defp read_gun_body(conn, stream_ref, :nofin) do
    receive do
      {:gun_data, ^conn, ^stream_ref, _, data} -> data
    after
      3_000 -> ""
    end
  end

  defp ws_collect_output(conn, stream_ref, %{} = state, on_output) do
    receive do
      {:gun_ws, ^conn, ^stream_ref, {:binary, <<1, payload::binary>>}} ->
        if on_output, do: on_output.({:stdout, payload})
        ws_collect_output(conn, stream_ref, %{state | acc: state.acc <> payload}, on_output)

      {:gun_ws, ^conn, ^stream_ref, {:binary, <<2, payload::binary>>}} ->
        if on_output, do: on_output.({:stderr, payload})
        ws_collect_output(conn, stream_ref, %{state | acc: state.acc <> payload}, on_output)

      {:gun_ws, ^conn, ^stream_ref, {:binary, <<3, rest::binary>>}} ->
        code = decode_exit_code(rest)
        :gun.ws_send(conn, stream_ref, :close)
        # Store exit code and drain remaining messages until close/gun_down
        ws_collect_output(conn, stream_ref, %{state | exit_code: code}, on_output)

      {:gun_ws, ^conn, ^stream_ref, {:text, json}} ->
        case Jason.decode(json) do
          {:ok, %{"type" => "exit", "code" => code}} ->
            :gun.ws_send(conn, stream_ref, :close)
            ws_collect_output(conn, stream_ref, %{state | exit_code: code}, on_output)

          _ ->
            ws_collect_output(conn, stream_ref, state, on_output)
        end

      {:gun_ws, ^conn, ^stream_ref, {:close, _code, _reason}} ->
        # Close frame after exit is a clean shutdown; without exit, assume success
        {:ok, state.acc, state.exit_code || 0}

      {:gun_down, ^conn, _protocol, _reason, _killed} when state.exit_code != nil ->
        # Already received exit code — this is a clean shutdown after command completed
        {:ok, state.acc, state.exit_code}

      {:gun_down, ^conn, _protocol, reason, _killed} ->
        Logger.error(
          "Sprites WS gun_down during output: #{inspect(reason)}, accumulated=#{byte_size(state.acc)} bytes"
        )

        {:error, {:execution_error, inspect(reason)}}

      {:gun_error, ^conn, ^stream_ref, reason} ->
        Logger.error("Sprites WS gun_error (stream): #{inspect(reason)}")
        {:error, {:execution_error, inspect(reason)}}

      {:gun_error, ^conn, reason} ->
        Logger.error("Sprites WS gun_error (conn): #{inspect(reason)}")
        {:error, {:execution_error, inspect(reason)}}

      other ->
        # Ignore unexpected messages (e.g. unrelated process messages) and continue
        Logger.warning("Sprites WS unexpected message during output: #{inspect(other)}")
        ws_collect_output(conn, stream_ref, state, on_output)
    after
      state.timeout ->
        if state.exit_code do
          # Command completed but connection didn't close cleanly — still a success
          {:ok, state.acc, state.exit_code}
        else
          {:error, :timeout}
        end
    end
  end

  defp decode_exit_code(<<code::big-unsigned-32>>), do: code
  defp decode_exit_code(<<code::unsigned-8>>), do: code
  defp decode_exit_code(<<>>), do: 0
  defp decode_exit_code(bin), do: :binary.decode_unsigned(bin)

  defp ws_base_url do
    String.replace(base_url(), ~r/^http/, "ws")
  end

  # Strip null bytes (\u0000) that PostgreSQL text columns reject.
  defp sanitize_output(str) when is_binary(str), do: String.replace(str, <<0>>, "")
  defp sanitize_output(other), do: other

  # ============================================================================
  # Filesystem Operations
  #
  # Note: We implement these directly instead of using Sprites.Filesystem
  # because the SDK's filesystem module has a bug where it doesn't include
  # the sprite name in the URL path (it generates /fs/read instead of
  # /v1/sprites/{name}/fs/read).
  # ============================================================================

  @doc """
  Read a file from a Sprite's filesystem.
  """
  @impl true
  @spec read_file(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(sprite_id, path) do
    with {:ok, client} <- client() do
      url = fs_url(sprite_id, "/fs/read", path: path)

      case Req.get(client.req, url: url, decode_body: false, receive_timeout: @fs_timeout) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Write a file to a Sprite's filesystem.

  Creates parent directories automatically.
  """
  @impl true
  @spec write_file(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(sprite_id, path, content) do
    with {:ok, client} <- client() do
      url = fs_url(sprite_id, "/fs/write", path: path, mkdirParents: "true", mode: "0644")

      case Req.put(client.req, url: url, body: content, receive_timeout: @fs_timeout) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  List files in a Sprite's directory.
  """
  @impl true
  @spec list_files(String.t(), String.t()) :: {:ok, list(map())} | {:error, term()}
  def list_files(sprite_id, path \\ "/workspace") do
    with {:ok, client} <- client() do
      url = fs_url(sprite_id, "/fs/list", path: path)

      case Req.get(client.req, url: url, receive_timeout: @fs_timeout) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          # Handle nil or malformed body
          entries =
            case body do
              %{"entries" => entries} when is_list(entries) -> entries
              _ -> []
            end

          {:ok, entries}

        {:ok, %{status: 404}} ->
          {:error, :enoent}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Suspend a Sprite.

  Sprites auto-hibernate when idle so no explicit checkpoint is needed.
  Returns `:ok` to signal the Suspend change that no checkpoint_id is stored.
  """
  @impl true
  @spec checkpoint(String.t()) :: :ok | {:error, term()}
  def checkpoint(_sprite_id), do: :ok

  @doc """
  Resume a Sprite.

  Sprites auto-wake on any interaction, so we just verify it still exists.
  """
  @impl true
  @spec restore(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def restore(sprite_id, _checkpoint_id) do
    case get_sprite(sprite_id) do
      {:ok, _info} ->
        {:ok, %{sprite_id: sprite_id, url: "#{base_url()}/sprites/#{sprite_id}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Destroy a Sprite.
  """
  @impl true
  @spec destroy(String.t()) :: :ok | {:error, term()}
  def destroy(sprite_id) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, sprite_id)

      case Sprites.destroy(sprite) do
        :ok -> :ok
        {:error, %Sprites.Error.APIError{status: 404}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Configure network policy for package installation.

  Restricts network access to package registries and essential services.
  """
  @spec setup_network_policy(String.t()) :: :ok | {:error, term()}
  def setup_network_policy(sprite_id) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, sprite_id)

      policy = %Sprites.Policy{
        rules: [
          # Python
          %Sprites.Policy.Rule{domain: "pypi.org", action: "allow"},
          %Sprites.Policy.Rule{domain: "files.pythonhosted.org", action: "allow"},
          %Sprites.Policy.Rule{domain: "astral.sh", action: "allow"},
          # Node.js
          %Sprites.Policy.Rule{domain: "registry.npmjs.org", action: "allow"},
          # Rust
          %Sprites.Policy.Rule{domain: "crates.io", action: "allow"},
          %Sprites.Policy.Rule{domain: "static.crates.io", action: "allow"},
          # Ruby
          %Sprites.Policy.Rule{domain: "rubygems.org", action: "allow"},
          # Ubuntu/apt
          %Sprites.Policy.Rule{domain: "archive.ubuntu.com", action: "allow"},
          %Sprites.Policy.Rule{domain: "security.ubuntu.com", action: "allow"},
          # Go
          %Sprites.Policy.Rule{domain: "proxy.golang.org", action: "allow"},
          %Sprites.Policy.Rule{domain: "sum.golang.org", action: "allow"},
          # GitHub (for git clone, releases)
          %Sprites.Policy.Rule{domain: "github.com", action: "allow"},
          %Sprites.Policy.Rule{domain: "raw.githubusercontent.com", action: "allow"},
          %Sprites.Policy.Rule{domain: "objects.githubusercontent.com", action: "allow"},
          # Elixir/Erlang
          %Sprites.Policy.Rule{domain: "hex.pm", action: "allow"},
          %Sprites.Policy.Rule{domain: "repo.hex.pm", action: "allow"},
          %Sprites.Policy.Rule{domain: "builds.hex.pm", action: "allow"},
          # LaTeX (CTAN)
          %Sprites.Policy.Rule{domain: "ctan.org", action: "allow"},
          %Sprites.Policy.Rule{domain: "mirrors.ctan.org", action: "allow"}
        ]
      }

      case Sprites.update_network_policy(sprite, policy) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Install uv package manager (much faster than pip).
  """
  @spec install_uv(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def install_uv(sprite_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    exec(sprite_id, "curl -LsSf https://astral.sh/uv/install.sh | sh",
      timeout: timeout,
      max_run_after_disconnect: "60s"
    )
  end

  @doc """
  Install Python packages via uv (fast Rust-based package manager).

  ## Options

    * `:timeout` - Timeout in milliseconds (default: 120_000 for multiple packages)
  """
  @spec uv_install(String.t(), list(String.t()), keyword()) :: {:ok, map()} | {:error, term()}
  def uv_install(sprite_id, packages, opts \\ []) when is_list(packages) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    package_list = Enum.join(packages, " ")

    # uv is installed to ~/.local/bin by default
    exec(sprite_id, "~/.local/bin/uv pip install --system #{package_list}",
      timeout: timeout,
      max_run_after_disconnect: "180s"
    )
  end

  @doc """
  Install Python packages via pip.

  ## Options

    * `:timeout` - Timeout in milliseconds (default: 120_000 for multiple packages)
  """
  @spec pip_install(String.t(), list(String.t()), keyword()) :: {:ok, map()} | {:error, term()}
  def pip_install(sprite_id, packages, opts \\ []) when is_list(packages) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    package_list = Enum.join(packages, " ")

    exec(sprite_id, "pip install #{package_list}",
      timeout: timeout,
      max_run_after_disconnect: "180s"
    )
  end

  @doc """
  Create a directory in the sprite filesystem.

  Creates parent directories automatically (like mkdir -p).
  """
  @impl true
  @spec ensure_directory(String.t(), String.t()) :: :ok | {:error, term()}
  def ensure_directory(sprite_id, path) do
    # Create directory by writing an empty placeholder file with mkdirParents,
    # then delete it. This is the same approach the SDK uses.
    with {:ok, client} <- client() do
      placeholder_path = Path.join(path, ".mkdir_placeholder")

      url =
        fs_url(sprite_id, "/fs/write", path: placeholder_path, mkdirParents: "true", mode: "0644")

      case Req.put(client.req, url: url, body: "", receive_timeout: @fs_timeout) do
        {:ok, %{status: status}} when status in 200..299 ->
          # Delete the placeholder
          delete_url = fs_url(sprite_id, "/fs/delete", path: placeholder_path, recursive: "false")
          Req.delete(client.req, url: delete_url, receive_timeout: @fs_timeout)
          :ok

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Remove a directory and its contents (like rm -rf).
  """
  @spec rm_rf(String.t(), String.t()) :: :ok | {:error, term()}
  def rm_rf(sprite_id, path) do
    with {:ok, client} <- client() do
      url = fs_url(sprite_id, "/fs/delete", path: path, recursive: "true")

      case Req.delete(client.req, url: url, receive_timeout: @fs_timeout) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: 404}} ->
          # Already doesn't exist - that's fine for rm_rf
          :ok

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Get file or directory information.

  Returns a map with:
  - `"name"` - File/directory name
  - `"size"` - Size in bytes
  - `"isDir"` - Whether it's a directory
  - `"mode"` - File permissions
  - `"modTime"` - Modification time
  """
  @spec stat_file(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def stat_file(sprite_id, path) do
    # Get stat by listing the parent directory and finding the entry
    parent_dir = Path.dirname(path)
    basename = Path.basename(path)

    case list_files(sprite_id, parent_dir) do
      {:ok, entries} ->
        case Enum.find(entries, fn entry -> entry["name"] == basename end) do
          nil -> {:error, :not_found}
          entry -> {:ok, entry}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List only files (not directories) in a directory.

  Returns a list of file entries with name, size, etc.
  """
  @spec list_files_only(String.t(), String.t()) :: {:ok, list(map())} | {:error, term()}
  def list_files_only(sprite_id, path) do
    case list_files(sprite_id, path) do
      {:ok, entries} ->
        files = Enum.reject(entries, fn entry -> entry["isDir"] == true end)
        {:ok, files}

      error ->
        error
    end
  end

  # ============================================================================
  # Service Management
  # ============================================================================

  @doc """
  Create or update a service definition in a Sprite.

  Config should include:
  - `cmd` - Command to run (e.g. "node", "python3")
  - `args` - Command arguments (e.g. ["server.js"])
  - `http_port` - Port the service listens on (optional)
  - `needs` - Service dependencies, started first (optional, default [])
  """
  @spec create_service(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def create_service(sprite_id, service_name, config) do
    cmd = Map.fetch!(config, :cmd)
    args = Map.get(config, :args, [])
    needs = Map.get(config, :needs, [])
    http_port = Map.get(config, :http_port)

    # Write a start script to avoid multiple --args flags (sprite-env may not accumulate them).
    # The script contains the full command and is referenced as a single --args value.
    working_dir = Map.get(config, :working_dir, "/workspace")
    full_command = Enum.map_join([cmd | args], " ", &shell_escape/1)
    script_path = "/.sprite/services/#{service_name}.sh"
    script_content = "#!/bin/sh\ncd #{shell_escape(working_dir)}\nexec #{full_command}\n"

    case write_file(sprite_id, script_path, script_content) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to write service script: #{inspect(reason)}")
    end

    exec(sprite_id, "chmod +x #{shell_escape(script_path)}", timeout: @fs_timeout)

    # Delete existing service first — sprite-env create doesn't overwrite
    delete_command =
      Enum.map_join(["sprite-env", "services", "delete", service_name], " ", &shell_escape/1)

    exec(sprite_id, delete_command, timeout: @fs_timeout)

    # Create service pointing to the start script (single --args)
    parts = [
      "sprite-env",
      "services",
      "create",
      service_name,
      "--cmd",
      "sh",
      "--args",
      script_path
    ]

    parts =
      Enum.reduce(needs, parts, fn dep, acc ->
        acc ++ ["--needs", dep]
      end)

    parts =
      case http_port do
        nil -> parts
        port -> parts ++ ["--http-port", to_string(port)]
      end

    command = Enum.map_join(parts, " ", &shell_escape/1)
    Logger.debug("create_service via exec: #{command}")

    case exec(sprite_id, command, timeout: @fs_timeout) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: code, stdout: output}} ->
        Logger.debug("create_service failed (exit #{code}): #{output}")
        {:error, {:service_create_error, code, output}}

      {:error, reason} ->
        Logger.debug("create_service error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Start a service in a Sprite.

  The API returns streaming NDJSON with stdout/stderr events.
  We consume the stream and check for errors.

  Returns `{:ok, :started}` on success.
  """
  @spec start_service(String.t(), String.t(), keyword()) :: {:ok, :started} | {:error, term()}
  def start_service(sprite_id, service_name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @fs_timeout)

    # Use sprite-env CLI workaround (services API is currently broken)
    command =
      Enum.map_join(["sprite-env", "services", "start", service_name], " ", &shell_escape/1)

    Logger.debug("start_service via exec: #{command}")

    case exec(sprite_id, command, timeout: timeout) do
      {:ok, %{exit_code: 0}} ->
        {:ok, :started}

      {:ok, %{exit_code: code, stdout: output}} ->
        Logger.debug("start_service failed (exit #{code}): #{output}")
        {:error, {:service_start_error, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stop a service in a Sprite.

  The API returns streaming NDJSON with stop progress events.
  """
  @spec stop_service(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def stop_service(sprite_id, service_name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @fs_timeout)

    # Use sprite-env CLI workaround (services API is currently broken)
    command =
      Enum.map_join(["sprite-env", "services", "stop", service_name], " ", &shell_escape/1)

    Logger.debug("stop_service via exec: #{command}")

    case exec(sprite_id, command, timeout: timeout) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: code, stdout: output}} ->
        Logger.debug("stop_service failed (exit #{code}): #{output}")
        {:error, {:service_stop_error, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List services in a Sprite.
  """
  @spec list_services(String.t()) :: {:ok, list(map())} | {:error, term()}
  def list_services(sprite_id) do
    with {:ok, client} <- client() do
      url = service_url(sprite_id, "/services")

      case Req.get(client.req, url: url, receive_timeout: @fs_timeout) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Get logs for a service.
  """
  @spec get_service_logs(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def get_service_logs(sprite_id, service_name, opts \\ []) do
    with {:ok, client} <- client() do
      timeout = Keyword.get(opts, :timeout, @fs_timeout)
      url = service_url(sprite_id, "/services/#{URI.encode(service_name)}/logs")

      case Req.get(client.req, url: url, receive_timeout: timeout, decode_body: false) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # WebSocket TCP Tunnel Proxy
  #
  # Routes HTTP requests through a WebSocket TCP tunnel to services running
  # inside sprites. Authenticates with the API key (Bearer token) so the
  # browser never needs to authenticate with sprites.dev directly.
  #
  # Flow:
  # 1. Open WS to wss://<api_base>/v1/sprites/{name}/proxy
  # 2. Send {"host": "localhost", "port": <port>} init message
  # 3. After {"status": "connected"}, send raw HTTP/1.1 request bytes
  # 4. Collect raw HTTP/1.1 response bytes (Connection: close signals end)
  # 5. Parse and return the response
  # ============================================================================

  @proxy_timeout 30_000

  @doc """
  Proxy an HTTP request through a WebSocket TCP tunnel to a sprite service.

  Takes the sprite_id, the port the service is listening on, and a structured
  request map. Builds raw HTTP/1.1 bytes internally for the WS tunnel.

  ## Request Map

    * `method` - HTTP method (e.g. "GET", "POST")
    * `path` - Request path including query string (e.g. "/api?foo=bar")
    * `headers` - List of `{name, value}` tuples
    * `body` - Request body as binary

  ## Returns

    * `{:ok, %{status: integer, headers: [{name, value}], body: binary}}` on success
    * `{:error, reason}` on failure
  """
  @impl true
  @spec proxy_request(String.t(), integer(), map()) ::
          {:ok, %{status: integer(), headers: [{String.t(), String.t()}], body: binary()}}
          | {:error, term()}
  def proxy_request(sprite_id, port, request) when is_map(request) do
    if configured?() do
      raw_request = build_raw_http_request(request)
      ws_url = "#{ws_base_url()}/v1/sprites/#{URI.encode(sprite_id)}/proxy"
      uri = URI.parse(ws_url)
      host = String.to_charlist(uri.host)
      ws_port = uri.port || if(uri.scheme == "wss", do: 443, else: 80)
      transport = if uri.scheme == "wss", do: :tls, else: :tcp

      gun_opts = %{
        protocols: [:http],
        transport: transport,
        connect_timeout: 15_000,
        tls_opts: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 3,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      }

      case :gun.open(host, ws_port, gun_opts) do
        {:ok, conn} ->
          case :gun.await_up(conn, 10_000) do
            {:ok, _protocol} ->
              path = uri.path || "/"
              headers = [{"authorization", "Bearer #{api_key()}"}]
              stream_ref = :gun.ws_upgrade(conn, path, headers)

              result = proxy_await_upgrade(conn, stream_ref, port, raw_request)
              :gun.close(conn)
              result

            {:error, reason} ->
              :gun.close(conn)
              {:error, {:proxy_error, inspect(reason)}}
          end

        {:error, reason} ->
          {:error, {:proxy_error, inspect(reason)}}
      end
    else
      {:error, :not_configured}
    end
  end

  # Wait for WS upgrade, then send the init JSON with host/port.
  defp proxy_await_upgrade(conn, stream_ref, port, raw_request) do
    receive do
      {:gun_upgrade, ^conn, ^stream_ref, ["websocket"], _headers} ->
        init_json = Jason.encode!(%{"host" => "localhost", "port" => port})
        :gun.ws_send(conn, stream_ref, {:text, init_json})
        proxy_await_connected(conn, stream_ref, raw_request)

      {:gun_response, ^conn, ^stream_ref, _fin, status, _headers} ->
        {:error, {:proxy_upgrade_failed, status}}

      {:gun_error, ^conn, _ref, reason} ->
        {:error, {:proxy_error, inspect(reason)}}

      {:gun_down, ^conn, _protocol, _reason, _killed} ->
        {:error, :proxy_closed}
    after
      10_000 ->
        {:error, :proxy_upgrade_timeout}
    end
  end

  # Wait for {"status": "connected"} from the tunnel, then send the raw HTTP request.
  @max_proxy_unexpected_messages 10

  defp proxy_await_connected(conn, stream_ref, raw_request, attempts \\ 0) do
    receive do
      {:gun_ws, ^conn, ^stream_ref, {:text, json}} ->
        case Jason.decode(json) do
          {:ok, %{"status" => "connected"}} ->
            :gun.ws_send(conn, stream_ref, {:binary, IO.iodata_to_binary(raw_request)})
            proxy_collect_response(conn, stream_ref, [])

          {:ok, %{"status" => status, "error" => error}} ->
            {:error, {:proxy_connect_failed, "#{status}: #{error}"}}

          {:ok, %{"status" => status}} ->
            {:error, {:proxy_connect_failed, status}}

          _ when attempts < @max_proxy_unexpected_messages ->
            proxy_await_connected(conn, stream_ref, raw_request, attempts + 1)

          _ ->
            {:error, :proxy_connect_timeout}
        end

      {:gun_ws, ^conn, ^stream_ref, {:close, _code, reason}} ->
        {:error, {:proxy_closed, reason}}

      {:gun_down, ^conn, _protocol, _reason, _killed} ->
        {:error, :proxy_closed}
    after
      10_000 ->
        {:error, :proxy_connect_timeout}
    end
  end

  # Collect binary frames (raw HTTP response bytes) until we have a complete response.
  # We detect completion via Content-Length when available, falling back to tunnel close
  # or an idle timeout for responses without Content-Length (e.g., chunked).
  #
  # State tracks parsed header info to avoid re-parsing on every frame:
  #   :collecting_headers — haven't seen end-of-headers yet
  #   {:collecting_body, content_length, header_size} — headers parsed, waiting for body
  @idle_timeout 2_000

  defp proxy_collect_response(conn, stream_ref, acc) do
    proxy_collect_response(conn, stream_ref, acc, :collecting_headers)
  end

  defp proxy_collect_response(conn, stream_ref, acc, phase) do
    # Use short idle timeout once we have data but no Content-Length
    timeout =
      case {phase, acc} do
        {:no_content_length, _} -> @idle_timeout
        {_, []} -> @proxy_timeout
        _ -> @proxy_timeout
      end

    receive do
      {:gun_ws, ^conn, ^stream_ref, {:binary, data}} ->
        new_acc = [data | acc]
        new_phase = maybe_advance_phase(new_acc, phase)

        case new_phase do
          :complete ->
            parse_http_response(IO.iodata_to_binary(Enum.reverse(new_acc)))

          other ->
            proxy_collect_response(conn, stream_ref, new_acc, other)
        end

      {:gun_ws, ^conn, ^stream_ref, {:close, _code, _reason}} ->
        parse_http_response(IO.iodata_to_binary(Enum.reverse(acc)))

      {:gun_down, ^conn, _protocol, _reason, _killed} ->
        parse_http_response(IO.iodata_to_binary(Enum.reverse(acc)))

      {:gun_ws, ^conn, ^stream_ref, {:text, _}} ->
        proxy_collect_response(conn, stream_ref, acc, phase)

      {:gun_error, ^conn, _ref, _reason} ->
        case acc do
          [] -> {:error, :proxy_error}
          _ -> parse_http_response(IO.iodata_to_binary(Enum.reverse(acc)))
        end
    after
      timeout ->
        case acc do
          [] -> {:error, :proxy_timeout}
          _ -> parse_http_response(IO.iodata_to_binary(Enum.reverse(acc)))
        end
    end
  end

  # Check if accumulated data forms a complete HTTP response.
  # Returns :complete, {:collecting_body, content_length, header_size}, :no_content_length,
  # or :collecting_headers.
  defp maybe_advance_phase(_acc, :complete), do: :complete

  defp maybe_advance_phase(acc, {:collecting_body, content_length, header_size}) do
    total = IO.iodata_length(acc)
    body_received = total - header_size

    if body_received >= content_length,
      do: :complete,
      else: {:collecting_body, content_length, header_size}
  end

  defp maybe_advance_phase(acc, phase) when phase in [:collecting_headers, :no_content_length] do
    data = IO.iodata_to_binary(Enum.reverse(acc))

    # Check if we have the full headers (look for \r\n\r\n)
    case :binary.match(data, "\r\n\r\n") do
      {pos, 4} ->
        header_size = pos + 4

        # Parse headers to find Content-Length
        case :erlang.decode_packet(:http_bin, data, []) do
          {:ok, {:http_response, _, _, _}, header_rest} ->
            {headers, _body} = parse_http_headers(header_rest, [])
            cl = Enum.find_value(headers, fn {k, v} -> if k == "content-length", do: v end)

            case cl do
              nil ->
                # No Content-Length — use idle timeout to detect end of response
                :no_content_length

              cl_str ->
                content_length = String.to_integer(cl_str)
                body_received = byte_size(data) - header_size

                if body_received >= content_length do
                  :complete
                else
                  {:collecting_body, content_length, header_size}
                end
            end

          _ ->
            :collecting_headers
        end

      :nomatch ->
        :collecting_headers
    end
  end

  # Parse raw HTTP/1.1 response bytes using Erlang's built-in HTTP parser.
  # Uses :erlang.decode_packet to parse status line and headers, remainder is body.
  defp parse_http_response(<<>>) do
    {:error, :empty_response}
  end

  defp parse_http_response(data) do
    case :erlang.decode_packet(:http_bin, data, []) do
      {:ok, {:http_response, _vsn, status_code, _reason}, rest} ->
        {headers, body} = parse_http_headers(rest, [])
        {:ok, %{status: status_code, headers: headers, body: body}}

      {:more, _} ->
        {:error, :incomplete_response}

      {:error, reason} ->
        {:error, {:parse_error, reason}}
    end
  end

  defp parse_http_headers(data, acc) do
    case :erlang.decode_packet(:httph_bin, data, []) do
      {:ok, {:http_header, _, name, _, value}, rest} ->
        header_name =
          case name do
            atom when is_atom(atom) -> atom |> Atom.to_string() |> String.downcase()
            bin when is_binary(bin) -> String.downcase(bin)
          end

        parse_http_headers(rest, [{header_name, value} | acc])

      {:ok, :http_eoh, body} ->
        {Enum.reverse(acc), body}

      {:more, _} ->
        # Incomplete headers — return what we have
        {Enum.reverse(acc), <<>>}

      {:error, _} ->
        {Enum.reverse(acc), data}
    end
  end

  # Escape a string for safe use as a shell argument.
  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  # Build a service API URL with the sprite name correctly included.
  defp service_url(sprite_id, endpoint) do
    "/v1/sprites/#{URI.encode(sprite_id)}#{endpoint}"
  end

  # Build a filesystem API URL with the sprite name correctly included.
  # The Sprites SDK has a bug where it doesn't include the sprite name in
  # filesystem URLs, so we build them manually here.
  defp fs_url(sprite_id, endpoint, params) do
    query = URI.encode_query(params)
    "/v1/sprites/#{URI.encode(sprite_id)}#{endpoint}?#{query}"
  end

  # Build raw HTTP/1.1 request bytes from a structured request map.
  # Used by proxy_request/3 to convert the provider-agnostic structured
  # format into the raw bytes needed by the Sprites WS TCP tunnel.
  defp build_raw_http_request(%{method: method, path: path, headers: headers, body: body}) do
    header_lines =
      headers
      |> Enum.map(fn {name, value} -> "#{name}: #{value}" end)
      |> Enum.join("\r\n")

    "#{method} #{path} HTTP/1.1\r\n#{header_lines}\r\n\r\n#{body}"
  end
end
