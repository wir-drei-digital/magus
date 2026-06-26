# Sandbox Execution Pipeline

How agents execute commands in isolated sandbox containers, with output streaming, secret injection, and failure handling.

## Architecture Overview

```
Agent calls exec_command tool
    |
    v
ExecCommand.run/2 (Jido Action)
    |
    +---> validate_context (requires conversation_id, user_id)
    |
    v
execute_command/4
    |
    +---> maybe_inject_secrets/2
    |       - Loads conversation -> custom_agent_id
    |       - Queries AgentSecret (scope: :sandbox_env)
    |       - Writes /workspace/.env via Orchestrator.write_file
    |       - Silently no-ops if no agent or no secrets
    |
    +---> build_exec_opts/2
    |       - Converts timeout seconds -> milliseconds
    |       - Attaches on_output streaming callback (if event metadata present)
    |
    v
Orchestrator.exec_command/3
    |
    +---> ensure_sandbox (provision if needed, advisory lock)
    +---> setup_workspace_or_reprovision (dead sandbox -> new one)
    +---> create_command_execution (Ash record for tracking)
    |
    v
CommandRunner.run/3
    |
    +---> Forwards timeout + on_output to provider
    |
    v
Provider.exec/3 (Sprites or Daytona)
    |
    +---> WebSocket connection (TLS)
    +---> Streams output frames incrementally
    +---> Calls on_output({:stdout | :stderr, chunk}) per frame
    |
    v
Results flow back:
    Provider -> CommandRunner -> Orchestrator -> ExecCommand -> Agent
    |
    +---> enrich_with_workspace_files (list /workspace after execution)
    +---> finalize_result (update execution record, record cost)
    +---> format_success/format_timeout/format_oom/format_error
```

## Key Components

### ExecCommand Tool

**File:** `lib/magus/agents/tools/sandbox/exec_command.ex`

The Jido Action that agents call. Schema parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `command` | string | required | Shell command to execute |
| `working_dir` | string | `/workspace` | Working directory inside sandbox |
| `timeout` | integer | 300 | Timeout in seconds. No upper cap. |

**Key functions:**
- `build_exec_opts/2` — converts schema params to orchestrator keyword opts, attaches streaming callback
- `build_env_file_content/1` — formats secret map as `export KEY='value'` lines with shell escaping
- `maybe_inject_secrets/2` — loads agent secrets from DB, writes `.env` to sandbox

### Orchestrator

**File:** `lib/magus/sandbox/orchestrator.ex`

Central coordinator for all sandbox operations. Handles:
- Sandbox lifecycle (provision, ensure, reprovision on death)
- Advisory locks (`pg_advisory_xact_lock`) to prevent concurrent provisioning
- Execution record tracking (cost estimation: CPU + memory)
- File operations (`write_file`, `read_file`, `list_files`)

### CommandRunner

**File:** `lib/magus/sandbox/command_runner.ex`

Dispatches commands to the correct provider client. Forwards `timeout` and `on_output` callback. Escapes working directory paths.

### Provider Clients

**Sprites:** `lib/magus/sandbox/clients/sprites.ex`
- Binary WebSocket frames via `:gun`
- `on_output` callback already supported — fires `{:stdout, payload}` tuples
- `max_run_after_disconnect` derived from timeout (timeout + 60s buffer)
- Retries up to 3x on transient WebSocket failures

**Daytona:** `lib/magus/sandbox/clients/daytona.ex`
- Two API surfaces: Control Plane (lifecycle) and Toolbox (execution/files)
- Sync exec via `POST /process/execute` (no `on_output`) — returns combined stdout/stderr in `result` field
- Streaming exec via session + WebSocket log streaming (with `on_output`)
- Custom images via `buildInfo.dockerfileContent` (not the `image` field, which is for snapshots)
- Native file persistence across stop/start (no volumes needed)
- Any port exposed via preview URLs
- See [Daytona Provider](10a-daytona-provider.md) for details

The active provider is config-swapped via `SANDBOX_PROVIDER` (default `daytona`).
A self-host without provider credentials leaves the sandbox capability gated
off — `Magus.Sandbox.Provider.configured?/0` returns `false` and the agent
tools (`run_code`, `exec_command`, `sandbox_*`, `start_service`) are not
offered.

## Output Streaming

When `ExecCommand` has event metadata in its context (`__conversation_id__`, `__event_id__`, `__tool_name__`), it attaches an `on_output` callback that emits `tool.progress` events via PubSub.

```
Provider WebSocket frame arrives
    |
    v
on_output.({:stdout, chunk})    # callback created in build_exec_opts
    |
    v
Signals.emit_tool_progress(context, :output, %{chunk: chunk})
    |
    v
PubSub broadcast to "agents:{conversation_id}"
    |
    v
LiveView handle_info -> PubSubHandlers.handle_tool_progress
    |
    v
Accumulated in tool_event[:accumulated_output] (capped at 100KB)
    |
    v
ToolCallComponent renders <pre> block with live terminal output
```

**Output cap:** Accumulated output is capped at 100KB in the LiveView process. When exceeded, earlier output is truncated with a `[earlier output truncated]` marker, keeping the most recent 90KB.

## Secret Injection (AgentSecret)

### Resource

**File:** `lib/magus/agents/agent_secret.ex`

Per-agent encrypted secrets stored with AES-256-GCM via the Cloak vault. Identity: unique `(custom_agent_id, key)`.

| Field | Type | Description |
|-------|------|-------------|
| `key` | string | Env var name (validated: `^[A-Za-z_][A-Za-z0-9_]*$`) |
| `value` | EncryptedString | AES-256-GCM encrypted, never in LLM context |
| `scope` | atom | `:sandbox_env` (injected as env var) or `:tool_config` |
| `description` | string | Optional, for UI display |

**Policies:**
- Read: `IsAiAgent` bypass (for tool injection) + `relates_to_actor_via([:custom_agent, :user])`
- Create: `AgentBelongsToActor` custom check (verifies agent ownership via DB lookup)
- Update/Destroy: `relates_to_actor_via([:custom_agent, :user])`

**Cascade:** `on_delete: :delete_all` — deleting a CustomAgent cascades to its secrets.

### Encryption

**File:** `lib/magus/agents/agent_secret/encrypted_string.ex`

Custom Ash type that encrypts/decrypts via `Magus.Integrations.Vault`:
- `cast_input` — accepts plaintext string
- `dump_to_native` — encrypts with `Vault.encrypt!` → stored as binary in PostgreSQL
- `cast_stored` — decrypts with `Vault.decrypt` → returns plaintext string

Uses the same Cloak vault and AES-256-GCM cipher as the `Credential` resource in Integrations.

### Injection Flow

```
ExecCommand.execute_command
    |
    v
maybe_inject_secrets(conversation_id, context)
    |
    +---> Chat.get_conversation(id, actor: ai_actor())
    +---> Check conversation.custom_agent_id (nil -> skip)
    +---> Magus.Agents.sandbox_env_map_for_agent(agent_id, actor: ai_actor())
    |       Returns %{"GITHUB_TOKEN" => "ghp_...", "API_KEY" => "sk_..."}
    +---> build_env_file_content(env_map)
    |       Returns "export API_KEY='sk_...'\nexport GITHUB_TOKEN='ghp_...'"
    +---> Orchestrator.write_file(conv_id, "/workspace/.env", content)
    |
    v
Agent instructions: source /workspace/.env before git operations
```

**Security:**
- Values single-quoted with shell escaping (`'it'\''s a secret'`)
- Keys validated against `^[A-Za-z_][A-Za-z0-9_]*$` at creation time (prevents shell injection)
- Secrets never appear in LLM context — only written to sandbox filesystem
- `.env` file written idempotently on every command execution

## Failure Modes

| Failure | Behavior | Agent sees |
|---------|----------|------------|
| Command timeout | All streamed output preserved, structured error returned | `{success: false, error_type: "timeout", stdout: "partial...", hint: "..."}` |
| OOM kill | Structured error with memory hint | `{success: false, error_type: "oom", hint: "Try less data..."}` |
| Non-zero exit code | Not treated as error — full stdout/stderr returned | `{success: false, exit_code: N, stdout: "...", stderr: "..."}` |
| Sandbox dead | Auto-reprovision, retry transparently | Transparent (may add latency) |
| WebSocket failure | Provider retries 3x with backoff | Error after retries exhausted |
| Provider API down | Clear error message | `{success: false, error_type: "configuration_error"}` |
| Secrets not configured | `maybe_inject_secrets` silently no-ops | Empty `.env`, auth errors in commands |
| Secret injection fails | Silently continues (write_file error swallowed) | Commands run without secrets |

## Domain Interfaces

```elixir
# Create a secret for a custom agent
Magus.Agents.create_agent_secret(%{
  custom_agent_id: agent.id,
  key: "GITHUB_TOKEN",
  value: "ghp_abc123",
  scope: :sandbox_env,
  description: "GitHub PAT for repo access"
}, actor: user)

# List all secrets for an agent
Magus.Agents.list_agent_secrets(agent.id, actor: user)

# Get secrets as env var map (for injection)
Magus.Agents.sandbox_env_map_for_agent(agent.id, actor: ai_actor())
# => {:ok, %{"GITHUB_TOKEN" => "ghp_abc123"}}
```

## Dev Agent Skill

**File:** `priv/skills/dev_agent.md`

Markdown skill that teaches agents how to compose sandbox tools for code work:
1. Set up workspace (source `.env`, clone repo from agent instructions)
2. Work on objective (analysis, bug fixes, PRs, dependency installation)
3. Report results (PR URLs, findings, error reports)
4. Error handling (retry limits, auth failure guidance, test-before-push)

The skill is loaded via `load_skill("dev_agent")` or pre-loaded on a CustomAgent via `pre_loaded_skills: ["dev_agent"]`.
