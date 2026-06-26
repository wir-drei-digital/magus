# Daytona Sandbox Provider

How the Daytona provider implements sandboxed code execution, file operations, and lifecycle management.

## Architecture

Daytona exposes two API surfaces, both authenticated with Bearer token (`DAYTONA_API_KEY`):

```
Control Plane (https://app.daytona.io/api)
    |
    +---> Sandbox lifecycle: create, get, delete, stop, start
    +---> Preview URLs: per-port URLs with auth tokens
    +---> Resource management: cpu, memory, disk

Toolbox (https://proxy.app.daytona.io/toolbox/{sandboxId})
    |
    +---> Command execution: sync + async sessions
    +---> File operations: upload, download, list, mkdir, delete
    +---> Log streaming: WebSocket follow on session commands
```

**File:** `lib/magus/sandbox/clients/daytona.ex`

## Configuration

```elixir
# config/runtime.exs
config :magus, Magus.Sandbox.Clients.Daytona,
  api_key: System.get_env("DAYTONA_API_KEY"),
  image: System.get_env("DAYTONA_SANDBOX_IMAGE") || "ghcr.io/wir-drei-digital/magus-sandbox:latest",
  cpu: String.to_integer(System.get_env("DAYTONA_CPU") || "2"),
  memory: String.to_integer(System.get_env("DAYTONA_MEMORY") || "2"),
  disk: String.to_integer(System.get_env("DAYTONA_DISK") || "5")
```

Activate with `SANDBOX_PROVIDER=daytona`.

## Sandbox Creation

Custom Docker images use `buildInfo.dockerfileContent`, not the `image` field. Daytona treats `image` as a snapshot name and rejects resource specs alongside it.

```
create_sandbox/1
    |
    +---> POST /api/sandbox
    |       body: {name, buildInfo: {dockerfileContent: "FROM <image>\n"}, cpu, memory, disk}
    |
    +---> poll_until_started (2s interval, max 60 attempts)
    |       states: creating -> pending_build -> building_snapshot -> started
    |       First build takes ~20-30s; subsequent builds use 24h cache
    |
    +---> On failure: destroy sandbox, return error
    |
    v
    {:ok, %{sandbox_id: id, url: toolbox_url}}
```

## Command Execution

Two paths based on whether `on_output` callback is provided:

### Sync (no streaming)

```
exec_sync/3
    |
    +---> POST /toolbox/{id}/process/execute
    |       body: {command, cwd: "/workspace", timeout: <seconds>}
    |       response: {result: "combined stdout/stderr", exitCode: N}
    |
    v
    {:ok, %{stdout: result, stderr: "", exit_code: N, duration_ms: D}}
```

- `stderr` is always empty (Daytona combines stdout/stderr in `result`)
- Exit code is accurate

### Streaming (with `on_output`)

```
exec_streaming/4
    |
    +---> POST /toolbox/{id}/process/session
    |       body: {sessionId: "<uuid>"}
    |
    +---> POST /toolbox/{id}/process/session/{sessionId}/exec
    |       body: {command, runAsync: true}
    |       response: 202, {cmdId: "..."}
    |
    +---> WebSocket: wss://proxy.app.daytona.io/toolbox/{id}/
    |       process/session/{sessionId}/command/{cmdId}/logs?follow=true
    |
    +---> Collect text/binary frames, feed to on_output({:stdout, chunk})
    |
    +---> Stream ends when connection closes
    |
    v
    {:ok, %{stdout: accumulated, stderr: "", exit_code: 0, duration_ms: D}}
```

- WebSocket uses `:gun` with TLS peer verification (same pattern as Sprites/Northflank)
- Retries up to 3x on transient failures (`:closed`, `:upgrade_timeout`)
- `flush_gun_messages/1` drains stale messages from process mailbox after close
- Exit code is always 0 in streaming mode (Daytona log stream endpoint does not provide exit codes)

## File Operations

All via Toolbox API. No custom file server needed (unlike Northflank's port 9090 server).

| Operation | Method | Endpoint | Notes |
|-----------|--------|----------|-------|
| `read_file` | GET | `/files/download?path=` | Raw binary response |
| `write_file` | POST | `/files/upload?path=` | Multipart form data (`file` field) |
| `list_files` | GET | `/files?path=` | JSON array with `name`, `isDir`, `size`, `modTime` |
| `ensure_directory` | POST | `/files/folder?path=&mode=0755` | 409 = already exists (OK) |
| `reset` | DELETE + POST | `/files?path=` then `/files/folder` | Remove and recreate |

`write_file` ensures parent directories exist before upload. Errors from `ensure_directory` are propagated (not swallowed).

## Suspend / Resume

No checkpointing. Uses Daytona stop/start. Filesystem is fully preserved across stop/start cycles.

```
checkpoint/1 (suspend)
    |
    +---> POST /api/sandbox/{id}/stop
    +---> poll_until_stopped (2s interval, max 60 attempts)
    +---> Returns :ok (no checkpoint ID)

restore/2 (resume)
    |
    +---> POST /api/sandbox/{id}/start
    |       On 409 (state change in progress): retry up to 15 times
    +---> Invalidate cached preview URLs (tokens reset on restart)
    +---> poll_until_started
    +---> Returns {:ok, %{sprite_id: sandbox_id, url: toolbox_url}}
```

## Proxy (Preview URLs)

Daytona exposes any port via preview URLs. No single-port restriction like Northflank.

```
proxy_request/3
    |
    +---> GET /api/sandbox/{id}/ports/{port}/preview-url
    |       response: {url: "https://...", token: "..."}
    |       Cached per {sandbox_id, port} in process dictionary
    |
    +---> Forward request to preview URL
    |       Headers: [{"authorization", "Bearer <token>"} | request.headers]
    |
    v
    {:ok, %{status: N, headers: [...], body: binary}}
```

Cache invalidation: `invalidate_preview_cache/1` clears all cached URLs for a sandbox. Called automatically on `restore/2` since tokens reset on restart.

**Important proxy headers:**
- `Host` must be stripped from forwarded requests. Daytona uses host-based routing (`{port}-{sandboxId}.daytonaproxy01.eu`), so a `host: localhost` header causes 404. Req sets the correct Host automatically from the preview URL.
- `X-Daytona-Skip-Preview-Warning: true` bypasses Daytona's first-visit warning page.
- `X-Daytona-Preview-Token: <token>` authenticates the request.

## Lifecycle Management

### Auto-Stop (Daytona-managed)

Daytona auto-stops sandboxes after 15 minutes of inactivity. Activity = Toolbox API calls, preview URL access, SSH. Background processes inside the sandbox do NOT count.

### Oban Triggers (our management)

Existing triggers work unchanged:
- `suspend_inactive`: Every 5 min, suspends sandboxes inactive 15+ min. If Daytona already stopped it, `checkpoint/1` polls until stopped (already stopped = instant).
- `terminate_stale`: Daily, terminates sandboxes inactive 30+ days.

### Dead Sandbox Detection

If Daytona auto-stops a sandbox before our Oban trigger, the DB record still says `state: :active`. The orchestrator detects this on next use via `get_sandbox` and calls `restore/2` to restart it.

### State Mapping

| Daytona State | Our State | Cost |
|---------------|-----------|------|
| started | active | CPU + RAM + disk |
| stopped | suspended | Disk only |
| archived (7d after stop) | suspended | None (cold storage) |
| error | active (will fail, reprovision) | - |

## Differences from Other Providers

| Feature | Sprites | Northflank | Daytona |
|---------|---------|------------|---------|
| Custom Docker images | No | Yes | Yes (via `buildInfo`) |
| Port exposure | Any (WS tunnel) | 8080 only | Any (preview URLs) |
| File persistence | Auto-hibernate | Explicit volumes | Native (filesystem survives stop/start) |
| Auto-resume | Yes (auto-wake) | Manual (our orchestrator) | Manual (our orchestrator) |
| Exec protocol | Binary WS | JSON WS | REST (sync) + WS (streaming) |
| stderr separation | Combined | Separate | Combined |
| Network policy | Domain allowlist | Not supported | Not supported |
| Cold start | Sub-second | ~60-120s | ~5-30s (cached image) |
| Isolation | Firecracker MicroVM | Container | Sysbox container |

## Service Management

Daytona kills background processes when an exec session ends, so the generic `cmd &` approach used by Northflank and the fallback does not work. Instead, `do_start_service` for Daytona creates a persistent Daytona session and runs the command async within it.

```
do_start_service(:daytona)
    |
    +---> Daytona.start_service(sprite_id, command, name: name)
    |       |
    |       +---> create_session("svc-{name}")
    |       +---> exec_in_session(session_id, command, runAsync: true)
    |
    v
    Session keeps the process alive indefinitely
```

The `do_stop_service` falls through to the generic `pkill -f 'PORT='` clause.

## Known Limitations

- **stderr always empty**: Daytona's sync exec endpoint returns combined stdout/stderr in `result`. No separation available.
- **Streaming exit code**: The WebSocket log streaming endpoint does not provide command exit codes. Streaming mode always reports `exit_code: 0`. The sync exec path captures exit codes correctly.
- **No network policy**: Daytona does not have a domain allowlist. Tier 3+ accounts have full internet access.
- **Image cache expiry**: Declarative images (via `buildInfo`) are cached for 24 hours. After expiry, the next sandbox creation rebuilds the image (~20-30s). Use Daytona snapshots for permanent caching.
- **Resource limits**: Max 4 vCPU, 8GB RAM, 10GB disk per sandbox without contacting Daytona support.
- **Background processes**: Regular `exec` kills background processes when the session ends. Long-running services must use persistent sessions (handled automatically by `start_service`).
