defmodule Magus.Sandbox.Clients.Daytona do
  @moduledoc """
  Sandbox provider backed by the Daytona (daytona.io) Sandbox API.

  Implements `Magus.Sandbox.Provider` behaviour using Daytona sandboxes
  as persistent per-conversation execution environments.

  ## Configuration

  Configure in `config/runtime.exs`:

      config :magus, Magus.Sandbox.Clients.Daytona,
        api_key: System.get_env("DAYTONA_API_KEY"),
        image: System.get_env("DAYTONA_SANDBOX_IMAGE") || "ghcr.io/wir-drei-digital/magus-sandbox:latest",
        cpu: 2,
        memory: 2,
        disk: 5

  ## Architecture

  Daytona exposes two API surfaces:

  - **Control Plane** (`https://app.daytona.io/api`) for lifecycle (create, delete, stop, start)
  - **Toolbox** (`https://proxy.app.daytona.io/toolbox/{sandboxId}`) for execution and filesystem

  ## Command Execution

  - Without `on_output` callback: synchronous `POST /process/execute`
  - With `on_output` callback: async session + WebSocket log streaming

  ## Suspend / Resume

  Uses Daytona stop/start. `checkpoint/1` returns `:ok` (no checkpoint ID).
  `restore/2` ignores the checkpoint_id argument.
  """

  @behaviour Magus.Sandbox.Provider

  require Logger

  @poll_interval 2_000
  @poll_max_attempts 60
  @exec_timeout 300_000
  @max_ws_retries 3

  # ---------------------------------------------------------------------------
  # Configuration helpers
  # ---------------------------------------------------------------------------

  defp config, do: Application.get_env(:magus, __MODULE__) || []
  defp api_key, do: config()[:api_key]

  defp image,
    do: config()[:image] || "ghcr.io/wir-drei-digital/magus-sandbox:latest"

  defp cpu, do: config()[:cpu] || 2
  defp memory, do: config()[:memory] || 2
  defp disk, do: config()[:disk] || 5

  defp control_base_url, do: config()[:control_base_url] || "https://app.daytona.io/api"
  defp toolbox_base_url, do: config()[:toolbox_base_url] || "https://proxy.app.daytona.io/toolbox"

  defp control_client do
    Req.new(
      base_url: control_base_url(),
      headers: [
        {"authorization", "Bearer #{api_key()}"},
        {"content-type", "application/json"}
      ],
      receive_timeout: 30_000
    )
  end

  defp toolbox_client(sandbox_id) do
    Req.new(
      base_url: "#{toolbox_base_url()}/#{URI.encode(sandbox_id)}",
      headers: [
        {"authorization", "Bearer #{api_key()}"}
      ],
      receive_timeout: 60_000,
      retry: &toolbox_retry?/2,
      retry_delay: fn n -> min(1000 * Integer.pow(2, n), 8000) end,
      max_retries: 5
    )
  end

  # Retry on transient errors AND 400, which Daytona returns when the
  # toolbox container doesn't have a routable IP yet after resume.
  defp toolbox_retry?(_request, %Req.Response{status: status})
       when status in [400, 408, 429, 500, 502, 503, 504],
       do: true

  defp toolbox_retry?(_request, %Req.TransportError{reason: reason})
       when reason in [:timeout, :econnrefused, :closed],
       do: true

  defp toolbox_retry?(_request, _other), do: false

  # ---------------------------------------------------------------------------
  # Provider behaviour - Configuration
  # ---------------------------------------------------------------------------

  @impl true
  def configured? do
    key = api_key()
    is_binary(key) and key != ""
  end

  # ---------------------------------------------------------------------------
  # Provider behaviour - Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def create_sandbox(opts \\ []) do
    if not configured?() do
      {:error, :not_configured}
    else
      if Keyword.has_key?(opts, :network_policy) do
        Logger.info("Daytona sandbox: network_policy option ignored (not supported)")
      end

      do_create_sandbox()
    end
  end

  defp do_create_sandbox do
    sandbox_name = "sandbox-#{Ecto.UUID.generate()}"

    # Daytona uses buildInfo.dockerfileContent for custom OCI images.
    # The `image` field is treated as a snapshot name and cannot be combined
    # with resource specifications (cpu/memory/disk).
    body = %{
      name: sandbox_name,
      buildInfo: %{
        dockerfileContent: "FROM #{image()}\n"
      },
      cpu: cpu(),
      memory: memory(),
      disk: disk()
    }

    case Req.post(control_client(), url: "/sandbox", json: body) do
      {:ok, %{status: status, body: resp_body}} when status in 200..201 ->
        sandbox_id = resp_body["id"] || sandbox_name

        case poll_until_started(sandbox_id) do
          :ok ->
            {:ok, %{sandbox_id: sandbox_id, url: toolbox_url(sandbox_id)}}

          {:error, reason} ->
            Logger.error("Daytona sandbox failed to start: #{inspect(reason)}")
            destroy(sandbox_id)
            {:error, reason}
        end

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("Daytona create_sandbox failed",
          status: status,
          body: inspect(resp_body)
        )

        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def destroy(sandbox_id) do
    case Req.delete(control_client(), url: "/sandbox/#{URI.encode(sandbox_id)}") do
      {:ok, %{status: status}} when status in 200..204 -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_sandbox(sandbox_id) do
    case Req.get(control_client(), url: "/sandbox/#{URI.encode(sandbox_id)}") do
      {:ok, %{status: 200, body: data}} when is_map(data) ->
        {:ok, data}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Provider behaviour - Execution
  # ---------------------------------------------------------------------------

  @impl true
  def exec(sandbox_id, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @exec_timeout)
    on_output = Keyword.get(opts, :on_output)

    if on_output do
      exec_streaming(sandbox_id, command, timeout, on_output)
    else
      exec_sync(sandbox_id, command, timeout)
    end
  end

  # Synchronous execution via POST /process/execute
  defp exec_sync(sandbox_id, command, timeout) do
    start_time = System.monotonic_time(:millisecond)
    # Daytona timeout is in seconds
    timeout_seconds = div(timeout, 1_000)

    body = %{
      command: command,
      cwd: "/workspace",
      timeout: timeout_seconds
    }

    case Req.post(toolbox_client(sandbox_id),
           url: "/process/execute",
           json: body,
           receive_timeout: timeout + 5_000
         ) do
      {:ok, %{status: 200, body: resp}} when is_map(resp) ->
        duration = System.monotonic_time(:millisecond) - start_time
        output = resp["result"] || ""
        exit_code = resp["exitCode"] || 0

        {:ok,
         %{
           stdout: sanitize_output(output),
           stderr: "",
           exit_code: exit_code,
           duration_ms: duration
         }}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:api_error, status, resp}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Streaming execution via session + WebSocket log streaming
  defp exec_streaming(sandbox_id, command, timeout, on_output) do
    session_id = Ecto.UUID.generate()
    start_time = System.monotonic_time(:millisecond)

    with :ok <- create_session(sandbox_id, session_id),
         {:ok, cmd_id} <- exec_in_session(sandbox_id, session_id, command),
         {:ok, output} <-
           ws_stream_logs_with_retry(sandbox_id, session_id, cmd_id, timeout, on_output, 1) do
      duration = System.monotonic_time(:millisecond) - start_time

      {:ok,
       %{
         stdout: sanitize_output(output),
         stderr: "",
         exit_code: 0,
         duration_ms: duration
       }}
    end
  end

  defp create_session(sandbox_id, session_id) do
    body = %{sessionId: session_id}

    case Req.post(toolbox_client(sandbox_id), url: "/process/session", json: body) do
      {:ok, %{status: status}} when status in 200..201 ->
        :ok

      {:ok, %{status: status, body: resp}} ->
        {:error, {:session_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exec_in_session(sandbox_id, session_id, command) do
    body = %{command: command, runAsync: true}

    case Req.post(toolbox_client(sandbox_id),
           url: "/process/session/#{URI.encode(session_id)}/exec",
           json: body
         ) do
      {:ok, %{status: status, body: resp}} when status in 200..202 and is_map(resp) ->
        # API returns 202 for async commands; may return "cmdId" or "commandId"
        cmd_id = resp["cmdId"] || resp["commandId"]

        if cmd_id do
          {:ok, cmd_id}
        else
          {:error, {:missing_cmd_id, resp}}
        end

      {:ok, %{status: status, body: resp}} ->
        {:error, {:exec_session_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Retry WebSocket log streaming on transient failures
  defp ws_stream_logs_with_retry(sandbox_id, session_id, cmd_id, timeout, on_output, attempt) do
    case ws_stream_logs(sandbox_id, session_id, cmd_id, timeout, on_output) do
      {:error, reason} when reason in [:closed, :upgrade_timeout] and attempt < @max_ws_retries ->
        Logger.warning("Daytona log stream #{reason}, retrying",
          attempt: attempt,
          max_retries: @max_ws_retries
        )

        Process.sleep(1000 * attempt)
        ws_stream_logs_with_retry(sandbox_id, session_id, cmd_id, timeout, on_output, attempt + 1)

      result ->
        result
    end
  end

  defp ws_stream_logs(sandbox_id, session_id, cmd_id, timeout, on_output) do
    toolbox_host = URI.parse(toolbox_base_url())
    host = String.to_charlist(toolbox_host.host)
    port = toolbox_host.port || 443
    transport = if toolbox_host.scheme == "https", do: :tls, else: :tcp

    path =
      "/toolbox/#{URI.encode(sandbox_id)}/process/session/#{URI.encode(session_id)}/command/#{URI.encode(cmd_id)}/logs?follow=true"

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
            headers = [{"authorization", "Bearer #{api_key()}"}]
            stream_ref = :gun.ws_upgrade(conn, path, headers)
            result = ws_await_log_upgrade(conn, stream_ref, timeout, on_output)
            :gun.close(conn)
            flush_gun_messages(conn)
            result

          {:error, reason} ->
            :gun.close(conn)
            flush_gun_messages(conn)

            if reason == :closed,
              do: {:error, :closed},
              else: {:error, {:execution_error, inspect(reason)}}
        end

      {:error, reason} ->
        {:error, {:execution_error, inspect(reason)}}
    end
  end

  defp ws_await_log_upgrade(conn, stream_ref, timeout, on_output) do
    receive do
      {:gun_upgrade, ^conn, ^stream_ref, ["websocket"], _headers} ->
        ws_collect_logs(conn, stream_ref, %{acc: "", timeout: timeout}, on_output)

      {:gun_response, ^conn, ^stream_ref, _fin, status, _headers} ->
        Logger.error("Daytona WS log upgrade rejected: HTTP #{status}")
        {:error, {:upgrade_failed, status}}

      {:gun_error, ^conn, ^stream_ref, reason} ->
        {:error, {:execution_error, inspect(reason)}}

      {:gun_error, ^conn, reason} ->
        {:error, {:execution_error, inspect(reason)}}

      {:gun_down, ^conn, _protocol, _reason, _killed} ->
        {:error, :closed}
    after
      10_000 ->
        {:error, :upgrade_timeout}
    end
  end

  defp ws_collect_logs(conn, stream_ref, state, on_output) do
    receive do
      {:gun_ws, ^conn, ^stream_ref, {:text, data}} ->
        if on_output, do: on_output.({:stdout, data})
        ws_collect_logs(conn, stream_ref, %{state | acc: state.acc <> data}, on_output)

      {:gun_ws, ^conn, ^stream_ref, {:binary, data}} ->
        if on_output, do: on_output.({:stdout, data})
        ws_collect_logs(conn, stream_ref, %{state | acc: state.acc <> data}, on_output)

      {:gun_ws, ^conn, ^stream_ref, {:close, _code, _reason}} ->
        {:ok, state.acc}

      {:gun_down, ^conn, _protocol, _reason, _killed} when state.acc != "" ->
        {:ok, state.acc}

      {:gun_down, ^conn, _protocol, reason, _killed} ->
        Logger.error("Daytona WS gun_down during log stream: #{inspect(reason)}")
        {:error, {:execution_error, inspect(reason)}}

      {:gun_error, ^conn, ^stream_ref, reason} ->
        Logger.error("Daytona WS gun_error (stream): #{inspect(reason)}")
        {:error, {:execution_error, inspect(reason)}}

      {:gun_error, ^conn, reason} ->
        Logger.error("Daytona WS gun_error (conn): #{inspect(reason)}")
        {:error, {:execution_error, inspect(reason)}}

      other ->
        Logger.warning("Daytona WS unexpected message during log stream: #{inspect(other)}")
        ws_collect_logs(conn, stream_ref, state, on_output)
    after
      state.timeout ->
        if state.acc != "" do
          {:ok, state.acc}
        else
          {:error, :timeout}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Provider behaviour - File operations
  # ---------------------------------------------------------------------------

  @impl true
  def read_file(sandbox_id, path) do
    case Req.get(toolbox_client(sandbox_id),
           url: "/files/download",
           params: [path: path],
           decode_body: false,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def write_file(sandbox_id, path, content) do
    # Ensure parent directory exists first
    parent_dir = Path.dirname(path)

    with :ok <- maybe_ensure_directory(sandbox_id, parent_dir) do
      do_upload_file(sandbox_id, path, content)
    end
  end

  defp maybe_ensure_directory(_sandbox_id, parent) when parent in ["/", "."], do: :ok
  defp maybe_ensure_directory(sandbox_id, parent), do: ensure_directory(sandbox_id, parent)

  defp do_upload_file(sandbox_id, path, content) do
    # Upload via multipart form data
    case Req.post(toolbox_client(sandbox_id),
           url: "/files/upload",
           params: [path: path],
           form_multipart: [file: {content, filename: Path.basename(path)}],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: status}} when status in 200..201 ->
        :ok

      {:ok, %{status: status, body: resp}} ->
        {:error, {:api_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_files(sandbox_id, path \\ "/workspace") do
    case Req.get(toolbox_client(sandbox_id),
           url: "/files",
           params: [path: path],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: entries}} when is_list(entries) ->
        {:ok, entries}

      {:ok, %{status: 200, body: _other}} ->
        {:ok, []}

      {:ok, %{status: 404}} ->
        {:error, :enoent}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def ensure_directory(sandbox_id, path) do
    case Req.post(toolbox_client(sandbox_id),
           url: "/files/folder",
           params: [path: path, mode: "0755"],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: status}} when status in 200..201 ->
        :ok

      # Already exists is fine
      {:ok, %{status: 409}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def reset(sandbox_id, path) do
    # Delete the path and recreate it
    case Req.delete(toolbox_client(sandbox_id),
           url: "/files",
           params: [path: path],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: status}} when status in 200..204 ->
        ensure_directory(sandbox_id, path)

      {:ok, %{status: 404}} ->
        # Path didn't exist, just create it
        ensure_directory(sandbox_id, path)

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Service management
  #
  # Daytona kills background processes when an exec session ends, so the
  # generic "cmd &" approach doesn't work. Instead, we create a persistent
  # Daytona session and run the service command async within it. The session
  # keeps the process alive indefinitely.
  # ---------------------------------------------------------------------------

  @doc """
  Start a long-running service in a persistent Daytona session.

  Creates a session named "svc-{name}" and runs the command async within it.
  The session keeps the process alive even after this function returns.
  """
  @spec start_service(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def start_service(sandbox_id, command, opts \\ []) do
    name = Keyword.get(opts, :name, "default")
    session_id = "svc-#{name}"

    with :ok <- create_or_reset_session(sandbox_id, session_id),
         {:ok, _cmd_id} <- exec_in_session(sandbox_id, session_id, command) do
      :ok
    end
  end

  @doc """
  Stop a service by deleting its persistent session.
  """
  @spec stop_service(String.t(), String.t()) :: :ok | {:error, term()}
  def stop_service(sandbox_id, name) do
    session_id = "svc-#{name}"
    delete_session(sandbox_id, session_id)
  end

  defp create_or_reset_session(sandbox_id, session_id) do
    case create_session(sandbox_id, session_id) do
      :ok ->
        :ok

      {:error, {:session_error, 409, _}} ->
        # Session already exists -- delete and recreate
        with :ok <- delete_session(sandbox_id, session_id) do
          create_session(sandbox_id, session_id)
        end

      error ->
        error
    end
  end

  defp delete_session(sandbox_id, session_id) do
    case Req.delete(toolbox_client(sandbox_id),
           url: "/process/session/#{URI.encode(session_id)}"
         ) do
      {:ok, %{status: status}} when status in 200..204 ->
        :ok

      {:ok, %{status: 404}} ->
        :ok

      {:ok, %{status: status, body: resp}} ->
        {:error, {:session_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Provider behaviour - Suspend / Resume
  # ---------------------------------------------------------------------------

  @impl true
  def checkpoint(sandbox_id) do
    case Req.post(control_client(),
           url: "/sandbox/#{URI.encode(sandbox_id)}/stop"
         ) do
      {:ok, %{status: status}} when status in 200..204 ->
        # Wait for sandbox to actually reach stopped state
        poll_until_stopped(sandbox_id)

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @max_restore_retries 15

  @impl true
  def restore(sandbox_id, _checkpoint_id) do
    do_restore(sandbox_id, 1)
  end

  defp do_restore(_sandbox_id, attempt) when attempt > @max_restore_retries do
    {:error, :restore_timeout}
  end

  defp do_restore(sandbox_id, attempt) do
    case Req.post(control_client(),
           url: "/sandbox/#{URI.encode(sandbox_id)}/start",
           receive_timeout: 120_000
         ) do
      {:ok, %{status: status}} when status in 200..204 ->
        invalidate_preview_cache(sandbox_id)
        # The control plane returns 200 before the toolbox inside the
        # container is reachable. Wait for it before declaring ready.
        wait_for_toolbox(sandbox_id)
        {:ok, %{sprite_id: sandbox_id, url: toolbox_url(sandbox_id)}}

      {:ok, %{status: 409, body: _body}} ->
        # State change in progress (e.g. still stopping). Wait and retry.
        Logger.debug("Daytona restore: 409 conflict, retrying (attempt #{attempt})")
        Process.sleep(@poll_interval)
        do_restore(sandbox_id, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Provider behaviour - Proxy
  # ---------------------------------------------------------------------------

  @impl true
  def proxy_request(sandbox_id, port, request) when is_map(request) do
    case cached_preview_url(sandbox_id, port) do
      {:ok, %{url: preview_url, token: token}} ->
        url = "#{preview_url}#{request.path}"
        method = http_method(request.method)

        # Strip the host header — Daytona uses host-based routing, so the Host
        # must match the preview URL domain, not "localhost" from the controller.
        # Req sets the correct Host header automatically from the URL.
        forwarded_headers =
          Enum.reject(request.headers, fn {name, _} -> String.downcase(name) == "host" end)

        headers =
          forwarded_headers ++
            [{"x-daytona-skip-preview-warning", "true"}] ++
            if(token && token != "", do: [{"x-daytona-preview-token", token}], else: [])

        req_opts = [
          method: method,
          url: url,
          headers: headers,
          body: request.body,
          receive_timeout: 30_000
        ]

        case Req.request(req_opts) do
          {:ok, %Req.Response{status: status, headers: resp_headers, body: body}} ->
            flat_headers =
              Enum.flat_map(resp_headers, fn {name, values} ->
                values
                |> List.wrap()
                |> Enum.map(&{name, &1})
              end)

            {:ok, %{status: status, headers: flat_headers, body: body}}

          {:error, reason} ->
            {:error, {:proxy_error, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Preview URL caching
  # ---------------------------------------------------------------------------

  defp cached_preview_url(sandbox_id, port) do
    key = {:daytona_preview_url, sandbox_id, port}

    case Process.get(key) do
      nil ->
        result = fetch_preview_url(sandbox_id, port)

        case result do
          {:ok, _data} -> Process.put(key, result)
          _ -> :ok
        end

        result

      cached ->
        cached
    end
  end

  defp invalidate_preview_cache(sandbox_id) do
    Process.get_keys()
    |> Enum.each(fn
      {:daytona_preview_url, ^sandbox_id, _port} = key -> Process.delete(key)
      _ -> :ok
    end)
  end

  defp fetch_preview_url(sandbox_id, port) do
    case Req.get(control_client(),
           url: "/sandbox/#{URI.encode(sandbox_id)}/ports/#{port}/preview-url"
         ) do
      {:ok, %{status: 200, body: %{"url" => url} = body}} ->
        {:ok, %{url: url, token: body["token"]}}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Polling helpers
  # ---------------------------------------------------------------------------

  defp poll_until_started(sandbox_id, attempt \\ 1) do
    if attempt > @poll_max_attempts do
      {:error, :provision_timeout}
    else
      case get_sandbox(sandbox_id) do
        {:ok, %{"state" => "started"}} ->
          :ok

        {:ok, %{"state" => state}}
        when state in ~w(creating starting pending_build building_snapshot) ->
          Process.sleep(@poll_interval)
          poll_until_started(sandbox_id, attempt + 1)

        {:ok, %{"state" => "error"}} ->
          {:error, :sandbox_error}

        {:ok, %{"state" => "stopped"}} ->
          {:error, :sandbox_stopped}

        {:ok, %{"state" => state}} ->
          Logger.debug("Daytona poll: state=#{inspect(state)}")
          Process.sleep(@poll_interval)
          poll_until_started(sandbox_id, attempt + 1)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp poll_until_stopped(sandbox_id, attempt \\ 1) do
    if attempt > @poll_max_attempts do
      {:error, :stop_timeout}
    else
      case get_sandbox(sandbox_id) do
        {:ok, %{"state" => "stopped"}} ->
          :ok

        {:ok, %{"state" => "started"}} ->
          Process.sleep(@poll_interval)
          poll_until_stopped(sandbox_id, attempt + 1)

        {:ok, %{"state" => _state}} ->
          Process.sleep(@poll_interval)
          poll_until_stopped(sandbox_id, attempt + 1)

        {:error, :not_found} ->
          Logger.warning("Daytona sandbox #{sandbox_id} not found during stop polling")
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The control plane returns 200 from /start before the toolbox container
  # has a routable IP. Probe with a lightweight exec until it responds.
  @toolbox_ready_max_attempts 15

  defp wait_for_toolbox(sandbox_id, attempt \\ 1) do
    if attempt > @toolbox_ready_max_attempts do
      Logger.warning("Toolbox not ready after #{@toolbox_ready_max_attempts} attempts",
        sandbox_id: sandbox_id
      )
    else
      case Req.post(toolbox_client(sandbox_id),
             url: "/process/execute",
             json: %{command: "true", cwd: "/", timeout: 5},
             receive_timeout: 10_000
           ) do
        {:ok, %{status: 200}} ->
          :ok

        _ ->
          Process.sleep(@poll_interval)
          wait_for_toolbox(sandbox_id, attempt + 1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp toolbox_url(sandbox_id) do
    "#{toolbox_base_url()}/#{sandbox_id}"
  end

  defp http_method(method_string) when is_binary(method_string) do
    case String.downcase(method_string) do
      "get" -> :get
      "post" -> :post
      "put" -> :put
      "patch" -> :patch
      "delete" -> :delete
      "head" -> :head
      "options" -> :options
      other -> String.to_existing_atom(other)
    end
  end

  defp http_method(method) when is_atom(method), do: method

  # Strip null bytes that PostgreSQL text columns reject.
  defp sanitize_output(str) when is_binary(str), do: String.replace(str, <<0>>, "")
  defp sanitize_output(other), do: other

  # Drain any remaining :gun messages from the process mailbox
  defp flush_gun_messages(conn) do
    receive do
      {:gun_ws, ^conn, _, _} -> flush_gun_messages(conn)
      {:gun_ws, ^conn, _, _, _} -> flush_gun_messages(conn)
      {:gun_down, ^conn, _, _, _} -> flush_gun_messages(conn)
      {:gun_error, ^conn, _, _} -> flush_gun_messages(conn)
      {:gun_error, ^conn, _} -> flush_gun_messages(conn)
    after
      0 -> :ok
    end
  end
end
