# Knowledge-Source OAuth Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make cloud-storage (Google Drive) RAG sync survive expired/revoked OAuth tokens without stranding sources, silently retrying forever, or leaking tokens through the browser.

**Architecture:** Introduce one shared `Magus.Knowledge.OAuth` module (credential lookup + Google token refresh with a real `invalid_grant` taxonomy) and a `Magus.Knowledge.TokenManager` that proactively refreshes a source's access token before each sync and persists rotations immediately. When a refresh token is dead, the source is flagged `needs_reauth`, its collections stop being scheduled, and the owner is notified. The SPA reconnect path heals the existing source in place instead of creating duplicates, and the session cookie is encrypted so stashed tokens are never browser-readable.

**Tech Stack:** Elixir, Ash 3.x + AshPostgres, AshOban triggers, Req (HTTP), Cloak (`EncryptedMap`), Bypass (test HTTP server), Phoenix `Plug.Session`.

## Global Constraints

- No em dashes in code comments, docs, or copy. Use colons/periods/commas.
- Never run `mix ash.reset`. Use `mix ash.codegen` + `mix ash.migrate` for schema changes.
- Nullable NimbleOptions/action arg types must be `{:or, [<type>, nil]}`, never a bare type with `default: nil`.
- Call resources through domain code interfaces (`Magus.Knowledge.*`), not `Ash.read/4` directly.
- AshOban sync triggers run with `authorize?: false` (bypass policies); app-facing calls pass `actor:`.
- Before pushing Elixir: `MIX_ENV=test mix compile --warnings-as-errors` must be clean.
- Google's standard OAuth clients do not rotate refresh tokens, so concurrent proactive refreshes across a source's collections are benign. Do NOT introduce a DB-transaction-held advisory lock around the refresh HTTP call (holding a transaction across network I/O exhausts the pool). Persist-immediately + last-write-wins is the intended concurrency model here.

---

## File Structure

**New files:**
- `lib/magus/knowledge/oauth.ex` — credential lookup + Google refresh HTTP with `invalid_grant` → `:reauth_required` taxonomy. No DB, no Ash. Pure + testable.
- `lib/magus/knowledge/token_manager.ex` — `ensure_fresh/1` (proactive refresh + persist + clear/needs_reauth) and `mark_source_reauth_required/1` (flag + notify). Bridges OAuth module ↔ `KnowledgeSource`.
- `test/magus/knowledge/oauth_test.exs`
- `test/magus/knowledge/token_manager_test.exs`

**Modified files:**
- `lib/magus/knowledge/knowledge_source.ex` — add `needs_reauth` attribute + `mark_needs_reauth` / `clear_reauth` actions + reconnect helper.
- `lib/magus/knowledge/knowledge.ex` — expose new source actions via code interface.
- `lib/magus/knowledge/knowledge_collection.ex` — incremental_sync trigger `where` excludes reauth-blocked sources.
- `lib/magus/knowledge/connectors/google_drive.ex` — reactive 401 refresh delegates to `Magus.Knowledge.OAuth`, propagates `:reauth_required`.
- `lib/magus/knowledge/knowledge_collection/changes/full_sync.ex` — call `TokenManager.ensure_fresh/1` before connect; mark source on `:reauth_required`.
- `lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex` — same wiring as full_sync.
- `lib/magus/integrations/providers/google_drive_knowledge/provider.ex` — `oauth_config/0` reads credentials via `Magus.Knowledge.OAuth`.
- `lib/magus_web/rpc/rpc_controller.ex` — `knowledge_oauth_finalize` heals existing source (update-or-create).
- `lib/magus/knowledge/connect.ex` — add `reconnect_or_create/3`.
- `lib/magus_web/endpoint.ex` — encrypt the session cookie.
- `config/test.exs` — point Google token URL at a per-test Bypass override.

---

### Task 1: `Magus.Knowledge.OAuth` — credentials + Google refresh taxonomy

**Files:**
- Create: `lib/magus/knowledge/oauth.ex`
- Create: `test/magus/knowledge/oauth_test.exs`
- Modify: `config/test.exs` (add configurable token URL)

**Interfaces:**
- Produces:
  - `Magus.Knowledge.OAuth.google_credentials/0 :: {:ok, {client_id :: String.t(), client_secret :: String.t()}} | {:error, :missing_oauth_config}`
  - `Magus.Knowledge.OAuth.refresh_google_token(refresh_token :: String.t()) :: {:ok, %{"access_token" => String.t(), "refresh_token" => String.t(), "expires_at" => String.t() | nil}} | {:error, :reauth_required} | {:error, :missing_oauth_config} | {:error, {:refresh_failed, integer(), term()}} | {:error, {:network_error, term()}}`
  - The returned `"refresh_token"` is always present: the caller's token if Google did not issue a new one.

- [ ] **Step 1: Make the Google token URL overridable in tests**

Add to `config/test.exs` (near other `config :magus, ...` lines):

```elixir
# Overridden per-test to a Bypass endpoint; unset in prod so the real URL is used.
config :magus, :google_token_url, "https://oauth2.googleapis.com/token"
```

- [ ] **Step 2: Write the failing test**

Create `test/magus/knowledge/oauth_test.exs`:

```elixir
defmodule Magus.Knowledge.OAuthTest do
  use ExUnit.Case, async: false

  alias Magus.Knowledge.OAuth

  setup do
    bypass = Bypass.open()
    prev_url = Application.get_env(:magus, :google_token_url)
    Application.put_env(:magus, :google_token_url, "http://localhost:#{bypass.port}/token")

    prev_id = System.get_env("GOOGLE_CLIENT_ID")
    prev_secret = System.get_env("GOOGLE_CLIENT_SECRET")
    System.put_env("GOOGLE_CLIENT_ID", "test-client")
    System.put_env("GOOGLE_CLIENT_SECRET", "test-secret")

    on_exit(fn ->
      Application.put_env(:magus, :google_token_url, prev_url)
      if prev_id, do: System.put_env("GOOGLE_CLIENT_ID", prev_id), else: System.delete_env("GOOGLE_CLIENT_ID")

      if prev_secret,
        do: System.put_env("GOOGLE_CLIENT_SECRET", prev_secret),
        else: System.delete_env("GOOGLE_CLIENT_SECRET")
    end)

    {:ok, bypass: bypass}
  end

  describe "refresh_google_token/1" do
    test "returns rotated tokens on success, keeping the old refresh token when none is issued",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"access_token" => "new-access", "expires_in" => 3600}))
      end)

      assert {:ok, tokens} = OAuth.refresh_google_token("old-refresh")
      assert tokens["access_token"] == "new-access"
      assert tokens["refresh_token"] == "old-refresh"
      assert is_binary(tokens["expires_at"])
    end

    test "classifies invalid_grant as :reauth_required", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        Plug.Conn.resp(conn, 400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      assert {:error, :reauth_required} = OAuth.refresh_google_token("dead-refresh")
    end

    test "returns a transient error for a 500 from the token endpoint", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        Plug.Conn.resp(conn, 500, Jason.encode!(%{"error" => "server_error"}))
      end)

      assert {:error, {:refresh_failed, 500, _body}} = OAuth.refresh_google_token("some-refresh")
    end
  end

  describe "google_credentials/0" do
    test "errors when env is missing" do
      System.delete_env("GOOGLE_CLIENT_ID")
      assert {:error, :missing_oauth_config} = OAuth.google_credentials()
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/oauth_test.exs`
Expected: FAIL with `Magus.Knowledge.OAuth.__struct__/1 is undefined` / module not available.

- [ ] **Step 4: Implement the module**

Create `lib/magus/knowledge/oauth.ex`:

```elixir
defmodule Magus.Knowledge.OAuth do
  @moduledoc """
  Google OAuth credential lookup and token refresh for knowledge sources.

  This is the single place that reads `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`
  and talks to Google's token endpoint. It classifies an `invalid_grant`
  response (revoked or expired refresh token) as `{:error, :reauth_required}` so
  callers can stop retrying and prompt the user to reconnect, distinct from
  transient network or 5xx failures which are safe to retry.
  """

  require Logger

  @default_token_url "https://oauth2.googleapis.com/token"

  @doc """
  Returns `{:ok, {client_id, client_secret}}` or `{:error, :missing_oauth_config}`.
  """
  def google_credentials do
    client_id = System.get_env("GOOGLE_CLIENT_ID")
    client_secret = System.get_env("GOOGLE_CLIENT_SECRET")

    if is_binary(client_id) and client_id != "" and is_binary(client_secret) and
         client_secret != "" do
      {:ok, {client_id, client_secret}}
    else
      {:error, :missing_oauth_config}
    end
  end

  @doc """
  Exchanges a refresh token for a fresh access token.

  On success returns a map with `"access_token"`, `"refresh_token"` (the newly
  issued one, or the caller's if Google did not rotate it), and `"expires_at"`
  (ISO8601). See the moduledoc for the error taxonomy.
  """
  def refresh_google_token(refresh_token) when is_binary(refresh_token) do
    with {:ok, {client_id, client_secret}} <- google_credentials() do
      body = [
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: client_id,
        client_secret: client_secret
      ]

      case Req.post(token_url(), form: body, receive_timeout: 10_000, max_retries: 0) do
        {:ok, %Req.Response{status: 200, body: %{"access_token" => access} = tokens}} ->
          Logger.info("Knowledge OAuth: refreshed Google access token")

          {:ok,
           %{
             "access_token" => access,
             "refresh_token" => tokens["refresh_token"] || refresh_token,
             "expires_at" => calculate_expiry(tokens["expires_in"])
           }}

        {:ok, %Req.Response{status: 400, body: %{"error" => "invalid_grant"}}} ->
          Logger.warning("Knowledge OAuth: refresh token revoked/expired (invalid_grant)")
          {:error, :reauth_required}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:refresh_failed, status, body}}

        {:error, reason} ->
          {:error, {:network_error, reason}}
      end
    end
  end

  defp token_url do
    Application.get_env(:magus, :google_token_url, @default_token_url)
  end

  defp calculate_expiry(expires_in) when is_integer(expires_in) do
    DateTime.utc_now() |> DateTime.add(expires_in, :second) |> DateTime.to_iso8601()
  end

  defp calculate_expiry(_), do: nil
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/oauth_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Point the provider config at the shared credential lookup**

In `lib/magus/integrations/providers/google_drive_knowledge/provider.ex`, replace the two raw `System.get_env` reads in `oauth_config/0` so credentials come from one place:

```elixir
  @impl true
  def oauth_config do
    {client_id, client_secret} =
      case Magus.Knowledge.OAuth.google_credentials() do
        {:ok, creds} -> creds
        {:error, _} -> {nil, nil}
      end

    %{
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      scopes: ["https://www.googleapis.com/auth/drive.readonly"],
      client_id: client_id,
      client_secret: client_secret
    }
  end
```

- [ ] **Step 7: Commit**

```bash
git add lib/magus/knowledge/oauth.ex test/magus/knowledge/oauth_test.exs \
  config/test.exs lib/magus/integrations/providers/google_drive_knowledge/provider.ex
git commit -m "feat(knowledge): add OAuth module with invalid_grant taxonomy"
```

---

### Task 2: Route the Google Drive connector's reactive refresh through `Magus.Knowledge.OAuth`

**Files:**
- Modify: `lib/magus/knowledge/connectors/google_drive.ex:418-497`
- Test: `test/magus/knowledge/connectors/google_drive_test.exs`

**Interfaces:**
- Consumes: `Magus.Knowledge.OAuth.refresh_google_token/1` (Task 1).
- Produces: On a 401 whose refresh yields `invalid_grant`, `get/4` returns `{:error, :reauth_required}`, which propagates out of `list_items/3`, `detect_changes/3`, and `fetch_content/2` unchanged.

- [ ] **Step 1: Write the failing test**

Append to `test/magus/knowledge/connectors/google_drive_test.exs` a describe block. The connector's `@base_url` is hardcoded, so drive this through the token endpoint only: assert that `list_items` on a 401 with a dead refresh token surfaces `:reauth_required`. Make the Drive base URL configurable first (Step 3 adds that), then:

```elixir
  describe "reactive refresh classifies a dead refresh token" do
    setup do
      drive = Bypass.open()
      token = Bypass.open()
      prev_base = Application.get_env(:magus, :google_drive_base_url)
      prev_token = Application.get_env(:magus, :google_token_url)
      Application.put_env(:magus, :google_drive_base_url, "http://localhost:#{drive.port}")
      Application.put_env(:magus, :google_token_url, "http://localhost:#{token.port}/token")
      System.put_env("GOOGLE_CLIENT_ID", "id")
      System.put_env("GOOGLE_CLIENT_SECRET", "secret")

      on_exit(fn ->
        Application.put_env(:magus, :google_drive_base_url, prev_base)
        Application.put_env(:magus, :google_token_url, prev_token)
      end)

      {:ok, drive: drive, token: token}
    end

    test "returns :reauth_required when refresh yields invalid_grant", %{drive: drive, token: token} do
      Bypass.expect(drive, "GET", "/files", fn conn -> Plug.Conn.resp(conn, 401, "{}") end)

      Bypass.expect_once(token, "POST", "/token", fn conn ->
        Plug.Conn.resp(conn, 400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      {:ok, conn} =
        Magus.Knowledge.Connectors.GoogleDrive.connect(%{
          "access_token" => "expired",
          "refresh_token" => "dead"
        })

      assert {:error, :reauth_required} =
               Magus.Knowledge.Connectors.GoogleDrive.list_items(conn, %{external_id: "root"}, %{
                 "folders" => ["root"]
               })
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/connectors/google_drive_test.exs`
Expected: FAIL (base URL not configurable / returns `:token_refresh_failed`, not `:reauth_required`).

- [ ] **Step 3: Make the Drive base URL configurable**

In `lib/magus/knowledge/connectors/google_drive.ex`, replace the module attribute usage. Change line 27 area and the `do_get` URL build. Replace:

```elixir
  @base_url "https://www.googleapis.com/drive/v3"
```

with:

```elixir
  @default_base_url "https://www.googleapis.com/drive/v3"

  defp base_url, do: Application.get_env(:magus, :google_drive_base_url, @default_base_url)
```

In `get/4`, replace `url = @base_url <> path` with `url = base_url() <> path`.

- [ ] **Step 4: Delegate refresh and propagate `:reauth_required`**

In `get/4` (around line 424-438), replace the 401 branch:

```elixir
    case do_get(url, token, params, max_size, timeout) do
      {:error, {:drive_api_error, 401, _}} when is_binary(refresh_token) ->
        case Magus.Knowledge.OAuth.refresh_google_token(refresh_token) do
          {:ok, %{"access_token" => new_token, "refresh_token" => new_refresh}} ->
            cache_refreshed_token(refresh_token, new_token, new_refresh)
            do_get(url, new_token, params, max_size, timeout)

          {:error, :reauth_required} ->
            {:error, :reauth_required}

          {:error, reason} ->
            Logger.error("Google Drive token refresh failed: #{inspect(reason)}")
            {:error, :token_refresh_failed}
        end

      result ->
        result
    end
```

Delete the now-unused private `refresh_access_token/1` (lines 464-497) since `Magus.Knowledge.OAuth` owns it. Keep `cache_refreshed_token/3`, `get_current_token/1`, and `refreshed_auth_config/1` as-is.

- [ ] **Step 5: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/connectors/google_drive_test.exs`
Expected: PASS.

- [ ] **Step 6: Compile clean and commit**

```bash
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/knowledge/connectors/google_drive.ex test/magus/knowledge/connectors/google_drive_test.exs
git commit -m "feat(knowledge): Drive connector surfaces :reauth_required on dead refresh token"
```

---

### Task 3: `KnowledgeSource` reauth state (attribute + actions + migration)

**Files:**
- Modify: `lib/magus/knowledge/knowledge_source.ex`
- Modify: `lib/magus/knowledge/knowledge.ex:22-30`
- Test: `test/magus/knowledge/knowledge_source_test.exs`

**Interfaces:**
- Produces:
  - Attribute `needs_reauth :: boolean` (default `false`, `public? true`) on `KnowledgeSource`.
  - Action `:mark_needs_reauth` (sets `needs_reauth: true`, `status: :error`, accepts `:last_error`).
  - Action `:clear_reauth` (sets `needs_reauth: false`, `status: :active`).
  - Code interfaces `Magus.Knowledge.mark_source_needs_reauth/2` and `Magus.Knowledge.clear_source_reauth/2`.

- [ ] **Step 1: Write the failing test**

Append to `test/magus/knowledge/knowledge_source_test.exs`:

```elixir
  describe "reauth state" do
    test "mark_needs_reauth flags the source and records the error" do
      user = generate(user())

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{name: "GD", provider: :google_drive, auth_config: %{"access_token" => "a"}},
          actor: user
        )

      {:ok, source} = Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, flagged} =
        Magus.Knowledge.mark_source_needs_reauth(
          source,
          %{last_error: "reauth_required"},
          authorize?: false
        )

      assert flagged.needs_reauth == true
      assert flagged.status == :error

      {:ok, cleared} = Magus.Knowledge.clear_source_reauth(flagged, authorize?: false)
      assert cleared.needs_reauth == false
      assert cleared.status == :active
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/knowledge_source_test.exs`
Expected: FAIL (`mark_source_needs_reauth` undefined).

- [ ] **Step 3: Add the attribute**

In `lib/magus/knowledge/knowledge_source.ex`, inside `attributes do`, after the `status` attribute block (line 163), add:

```elixir
    attribute :needs_reauth, :boolean do
      allow_nil? false
      default false
      public? true
      description "Set when the OAuth refresh token is dead and the user must reconnect. Pauses scheduling."
    end
```

- [ ] **Step 4: Add the actions**

In the `actions do` block, after `update :update_auth_config` (line 44), add:

```elixir
    update :mark_needs_reauth do
      accept [:last_error]
      require_atomic? false
      change set_attribute(:needs_reauth, true)
      change set_attribute(:status, :error)
    end

    update :clear_reauth do
      accept []
      require_atomic? false
      change set_attribute(:needs_reauth, false)
      change set_attribute(:status, :active)
    end
```

- [ ] **Step 5: Expose code interfaces**

In `lib/magus/knowledge/knowledge.ex`, inside the `resource Magus.Knowledge.KnowledgeSource do` block (after line 28), add:

```elixir
      define :mark_source_needs_reauth, action: :mark_needs_reauth
      define :clear_source_reauth, action: :clear_reauth
```

- [ ] **Step 6: Generate and run the migration**

Run:

```bash
set -a && source .env && set +a && mix ash.codegen add_knowledge_source_needs_reauth
set -a && source .env && set +a && mix ash.migrate
```

Expected: a new migration adding a `needs_reauth boolean NOT NULL DEFAULT false` column to `knowledge_sources`. Confirm the file appears under `priv/repo/migrations/`.

- [ ] **Step 7: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/knowledge_source_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/magus/knowledge/knowledge_source.ex lib/magus/knowledge/knowledge.ex \
  test/magus/knowledge/knowledge_source_test.exs priv/repo/migrations
git commit -m "feat(knowledge): add needs_reauth state + actions to KnowledgeSource"
```

---

### Task 4: `Magus.Knowledge.TokenManager` — proactive refresh, persist, notify

**Files:**
- Create: `lib/magus/knowledge/token_manager.ex`
- Create: `test/magus/knowledge/token_manager_test.exs`

**Interfaces:**
- Consumes: `Magus.Knowledge.OAuth.refresh_google_token/1`, `Magus.Knowledge.update_source_auth_config/3`, `Magus.Knowledge.mark_source_needs_reauth/3`, `Magus.Knowledge.clear_source_reauth/2`, `Magus.Notifications.create_notification/2`.
- Produces:
  - `Magus.Knowledge.TokenManager.ensure_fresh(source) :: {:ok, source} | {:error, :reauth_required}` — returns the source with a possibly-refreshed `auth_config`. On a transient refresh failure returns `{:ok, source}` unchanged (the connector's reactive path retries). Providers without token refresh return `{:ok, source}` immediately.
  - `Magus.Knowledge.TokenManager.mark_source_reauth_required(source) :: :ok` — flags the source and notifies its owner once.

- [ ] **Step 1: Write the failing test**

Create `test/magus/knowledge/token_manager_test.exs`:

```elixir
defmodule Magus.Knowledge.TokenManagerTest do
  use Magus.ResourceCase, async: false

  alias Magus.Knowledge
  alias Magus.Knowledge.TokenManager

  setup do
    bypass = Bypass.open()
    prev = Application.get_env(:magus, :google_token_url)
    Application.put_env(:magus, :google_token_url, "http://localhost:#{bypass.port}/token")
    System.put_env("GOOGLE_CLIENT_ID", "id")
    System.put_env("GOOGLE_CLIENT_SECRET", "secret")
    on_exit(fn -> Application.put_env(:magus, :google_token_url, prev) end)
    {:ok, bypass: bypass}
  end

  defp gdrive_source(user, auth_config) do
    {:ok, source} =
      Knowledge.create_source(
        %{name: "GD", provider: :google_drive, auth_config: auth_config},
        actor: user
      )

    {:ok, source} = Knowledge.update_source_status(source, %{status: :active}, actor: user)
    source
  end

  defp expired_iso, do: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
  defp future_iso, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

  test "refreshes and persists when the access token is expired", %{bypass: bypass} do
    user = generate(user())
    source = gdrive_source(user, %{"access_token" => "old", "refresh_token" => "r", "expires_at" => expired_iso()})

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"access_token" => "fresh", "expires_in" => 3600}))
    end)

    assert {:ok, refreshed} = TokenManager.ensure_fresh(source)
    assert refreshed.auth_config["access_token"] == "fresh"

    {:ok, reloaded} = Knowledge.get_source(source.id, actor: user)
    assert reloaded.auth_config["access_token"] == "fresh"
  end

  test "does not call the token endpoint when the token is still valid" do
    user = generate(user())
    source = gdrive_source(user, %{"access_token" => "ok", "refresh_token" => "r", "expires_at" => future_iso()})
    # No Bypass.expect => any HTTP call fails the test.
    assert {:ok, ^source} = TokenManager.ensure_fresh(source)
  end

  test "returns :reauth_required on invalid_grant", %{bypass: bypass} do
    user = generate(user())
    source = gdrive_source(user, %{"access_token" => "old", "refresh_token" => "dead", "expires_at" => expired_iso()})

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      Plug.Conn.resp(conn, 400, Jason.encode!(%{"error" => "invalid_grant"}))
    end)

    assert {:error, :reauth_required} = TokenManager.ensure_fresh(source)
  end

  test "non-refresh providers pass through untouched" do
    user = generate(user())

    {:ok, source} =
      Knowledge.create_source(
        %{name: "NC", provider: :nextcloud, auth_config: %{"base_url" => "https://x", "username" => "u", "password" => "p"}},
        actor: user
      )

    assert {:ok, ^source} = TokenManager.ensure_fresh(source)
  end

  test "mark_source_reauth_required flags the source and creates a notification" do
    user = generate(user())
    source = gdrive_source(user, %{"access_token" => "x", "refresh_token" => "r"})

    assert :ok = TokenManager.mark_source_reauth_required(source)

    {:ok, reloaded} = Knowledge.get_source(source.id, actor: user)
    assert reloaded.needs_reauth == true

    {:ok, notes} = Magus.Notifications.list_unread_notifications(actor: user)
    assert Enum.any?(notes, &(&1.metadata["knowledge_source_id"] == source.id))
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/token_manager_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 3: Implement the TokenManager**

Create `lib/magus/knowledge/token_manager.ex`:

```elixir
defmodule Magus.Knowledge.TokenManager do
  @moduledoc """
  Owns "give me a valid access token for this knowledge source".

  Before each sync the sync jobs call `ensure_fresh/1`, which proactively
  refreshes a soon-to-expire Google access token and persists the result
  (including a rotated refresh token) immediately, so a later job never races on
  a stale token. A dead refresh token surfaces as `{:error, :reauth_required}`;
  the sync jobs then call `mark_source_reauth_required/1`, which flags the source
  (pausing its scheduled syncs, see the incremental_sync trigger) and notifies
  the owner once.

  Concurrency: Google's standard OAuth clients do not rotate refresh tokens, so
  concurrent refreshes across a source's collections are benign and we persist
  last-write-wins rather than holding a DB lock across the refresh HTTP call.
  """

  require Logger

  alias Magus.Knowledge
  alias Magus.Knowledge.OAuth

  # Refresh when the access token expires within this window.
  @refresh_skew_seconds 300

  @doc "Returns the source with a valid access token, or `{:error, :reauth_required}`."
  def ensure_fresh(%{provider: :google_drive} = source) do
    auth = source.auth_config || %{}
    refresh_token = auth["refresh_token"]

    cond do
      not is_binary(refresh_token) ->
        {:ok, source}

      not expiring_soon?(auth["expires_at"]) ->
        {:ok, source}

      true ->
        do_refresh(source, refresh_token)
    end
  end

  # Providers without an OAuth refresh (notion, nextcloud, affine, web).
  def ensure_fresh(source), do: {:ok, source}

  @doc "Flags the source as needing reconnection and notifies the owner once."
  def mark_source_reauth_required(source) do
    already_flagged = Map.get(source, :needs_reauth, false)

    case Knowledge.mark_source_needs_reauth(source, %{last_error: "reauth_required"},
           authorize?: false
         ) do
      {:ok, _} ->
        unless already_flagged, do: notify_owner(source)
        :ok

      {:error, reason} ->
        Logger.warning(
          "TokenManager: failed to flag source #{source.id} for reauth: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp do_refresh(source, refresh_token) do
    case OAuth.refresh_google_token(refresh_token) do
      {:ok, new_auth} ->
        persist(source, new_auth)

      {:error, :reauth_required} = err ->
        err

      {:error, reason} ->
        # Transient (network / 5xx / missing config): let the sync proceed and
        # rely on the connector's reactive 401 refresh rather than blocking.
        Logger.warning("TokenManager: transient refresh failure for #{source.id}: #{inspect(reason)}")
        {:ok, source}
    end
  end

  defp persist(source, new_auth) do
    merged = Map.merge(source.auth_config || %{}, new_auth)

    case Knowledge.update_source_auth_config(source, %{auth_config: merged}, authorize?: false) do
      {:ok, updated} ->
        if Map.get(source, :needs_reauth, false) do
          Knowledge.clear_source_reauth(updated, authorize?: false)
        end

        {:ok, updated}

      {:error, reason} ->
        Logger.warning("TokenManager: failed to persist refreshed token for #{source.id}: #{inspect(reason)}")
        # Still return the in-memory refreshed config so this sync uses it.
        {:ok, %{source | auth_config: merged}}
    end
  end

  defp expiring_soon?(nil), do: false

  defp expiring_soon?(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        DateTime.compare(DateTime.utc_now(), DateTime.add(dt, -@refresh_skew_seconds, :second)) != :lt

      _ ->
        false
    end
  end

  defp notify_owner(source) do
    Magus.Notifications.create_notification(
      %{
        user_id: source.user_id,
        notification_type: :system,
        title: "Reconnect #{source.name}",
        body: "#{source.name} lost access and stopped syncing. Reconnect it to resume.",
        metadata: %{"knowledge_source_id" => source.id}
      },
      authorize?: false
    )
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/token_manager_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/magus/knowledge/token_manager.ex test/magus/knowledge/token_manager_test.exs
git commit -m "feat(knowledge): add TokenManager for proactive refresh + reauth flagging"
```

---

### Task 5: Wire sync jobs to `ensure_fresh` + stop scheduling reauth-blocked sources

**Files:**
- Modify: `lib/magus/knowledge/knowledge_collection/changes/full_sync.ex:74-104`
- Modify: `lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex:53-83`
- Modify: `lib/magus/knowledge/knowledge_collection.ex:26`
- Test: `test/magus/knowledge/knowledge_collection_test.exs`

**Interfaces:**
- Consumes: `Magus.Knowledge.TokenManager.ensure_fresh/1`, `mark_source_reauth_required/1`.
- Produces: after this task a full sync against a dead refresh token flags the source `needs_reauth` and the incremental trigger no longer schedules that source's collections.

- [ ] **Step 1: Write the failing test**

Append to `test/magus/knowledge/knowledge_collection_test.exs` (uses `Magus.ResourceCase`):

```elixir
  describe "sync reauth handling" do
    setup do
      bypass = Bypass.open()
      prev = Application.get_env(:magus, :google_token_url)
      Application.put_env(:magus, :google_token_url, "http://localhost:#{bypass.port}/token")
      System.put_env("GOOGLE_CLIENT_ID", "id")
      System.put_env("GOOGLE_CLIENT_SECRET", "secret")
      on_exit(fn -> Application.put_env(:magus, :google_token_url, prev) end)
      {:ok, bypass: bypass}
    end

    test "a dead refresh token during full sync flags the source for reauth", %{bypass: bypass} do
      user = generate(user())
      expired = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{
            name: "GD",
            provider: :google_drive,
            auth_config: %{"access_token" => "old", "refresh_token" => "dead", "expires_at" => expired}
          },
          actor: user
        )

      {:ok, source} = Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "Folder", external_id: "root", external_path: "/root"},
          actor: user
        )

      Bypass.expect(bypass, "POST", "/token", fn conn ->
        Plug.Conn.resp(conn, 400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      Magus.Knowledge.KnowledgeCollection.Changes.FullSync.do_full_sync(collection)

      {:ok, reloaded} = Magus.Knowledge.get_source(source.id, actor: user)
      assert reloaded.needs_reauth == true
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/knowledge_collection_test.exs`
Expected: FAIL (`needs_reauth` stays `false`; source not flagged).

- [ ] **Step 3: Wire FullSync**

In `lib/magus/knowledge/knowledge_collection/changes/full_sync.ex`, alias the TokenManager near the other aliases (after line 17):

```elixir
  alias Magus.Knowledge.TokenManager
```

Replace `run_full_sync/1` (lines 74-104) so it refreshes before connecting and passes the refreshed source down:

```elixir
  defp run_full_sync(collection) do
    source = collection.knowledge_source
    cid = collection.id

    case SyncHelpers.check_rate_limit(source) do
      {:error, :rate_limited} ->
        SyncLogger.warn(cid, "Rate limited, skipping sync")
        {:error, :rate_limited}

      :ok ->
        case TokenManager.ensure_fresh(source) do
          {:error, :reauth_required} ->
            {:error, :reauth_required}

          {:ok, source} ->
            case Connector.connector_for(source.provider) do
              {:error, _} = error ->
                SyncLogger.error(cid, "Unsupported provider: #{source.provider}")
                {:error, error}

              connector ->
                SyncLogger.info(cid, "Connecting to #{source.provider}")

                case apply(connector, :connect, [source.auth_config]) do
                  {:ok, conn} ->
                    result = sync_all_items(conn, connector, collection, source)
                    SyncHelpers.maybe_persist_refreshed_token(conn, connector, source)
                    result

                  {:error, reason} ->
                    SyncLogger.error(cid, "Connection failed: #{inspect(reason)}")
                    {:error, reason}
                end
            end
        end
    end
  end
```

In `do_full_sync/1`, extend the error branch (lines 58-71) to flag the source when the failure is a reauth failure. Replace that branch:

```elixir
      {:error, reason} ->
        Logger.error("FullSync failed for collection #{cid}: #{inspect(reason)}")
        SyncLogger.error(cid, "Full sync failed: #{inspect(reason)}")

        if reason == :reauth_required do
          TokenManager.mark_source_reauth_required(collection.knowledge_source)
        end

        Magus.Knowledge.update_sync_status(
          collection,
          %{
            sync_status: :error,
            last_error: inspect(reason),
            error_count: (collection.error_count || 0) + 1
          },
          authorize?: false
        )
    end
```

- [ ] **Step 4: Wire IncrementalSync the same way**

In `lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex`, alias the TokenManager (after line 21):

```elixir
  alias Magus.Knowledge.TokenManager
```

Replace `run_incremental_sync/1` (lines 53-83):

```elixir
  defp run_incremental_sync(collection) do
    source = collection.knowledge_source
    cid = collection.id

    case SyncHelpers.check_rate_limit(source) do
      {:error, :rate_limited} ->
        SyncLogger.warn(cid, "Rate limited, skipping sync")
        {:ok, collection}

      :ok ->
        case TokenManager.ensure_fresh(source) do
          {:error, :reauth_required} ->
            TokenManager.mark_source_reauth_required(source)
            update_sync_error(collection, :reauth_required)

          {:ok, source} ->
            case Connector.connector_for(source.provider) do
              {:error, _} = error ->
                update_sync_error(collection, error)

              connector ->
                SyncLogger.info(cid, "Connecting to #{source.provider}")

                case apply(connector, :connect, [source.auth_config]) do
                  {:ok, conn} ->
                    actor = Ash.get!(Magus.Accounts.User, source.user_id, authorize?: false)
                    result = do_sync(conn, connector, collection, source, actor)
                    SyncHelpers.maybe_persist_refreshed_token(conn, connector, source)
                    maybe_flag_reauth(result, source)
                    result

                  {:error, reason} ->
                    SyncLogger.error(cid, "Connection failed: #{inspect(reason)}")
                    update_sync_error(collection, reason)
                end
            end
        end
    end
  end

  # A mid-sync reactive refresh can also surface :reauth_required.
  defp maybe_flag_reauth({:error, :reauth_required}, source),
    do: TokenManager.mark_source_reauth_required(source)

  defp maybe_flag_reauth(_result, _source), do: :ok
```

Note: `do_sync/*` returns `{:ok, collection}` on success and `update_sync_error/2` returns `{:ok, collection}`, so `maybe_flag_reauth/2` inspects the connector call results that propagate `:reauth_required` through `do_sync`. If `do_sync` swallows the error into `update_sync_error` (returning `{:ok, _}`), extend `do_sync`'s `{:error, reason}` branch (line 102-105) to pass the reason through unchanged so `maybe_flag_reauth` can see `:reauth_required`. Change that branch to:

```elixir
      {:error, :reauth_required} ->
        update_sync_error(collection, :reauth_required)
        {:error, :reauth_required}

      {:error, reason} ->
        SyncLogger.error(cid, "detect_changes failed: #{inspect(reason)}")
        update_sync_error(collection, reason)
    end
```

- [ ] **Step 5: Stop scheduling reauth-blocked sources**

In `lib/magus/knowledge/knowledge_collection.ex`, change the incremental_sync trigger `where` (line 26) to exclude collections whose source needs reauth:

```elixir
        where expr(sync_status != :pending and sync_strategy != :manual and knowledge_source.needs_reauth == false)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/knowledge_collection_test.exs`
Expected: PASS.

- [ ] **Step 7: Compile clean and commit**

```bash
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/knowledge/knowledge_collection/changes/full_sync.ex \
  lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex \
  lib/magus/knowledge/knowledge_collection.ex \
  test/magus/knowledge/knowledge_collection_test.exs
git commit -m "feat(knowledge): refresh tokens before sync, flag + pause reauth-blocked sources"
```

---

### Task 6: SPA reconnect heals the existing source instead of duplicating it

**Files:**
- Modify: `lib/magus/knowledge/connect.ex`
- Modify: `lib/magus_web/rpc/rpc_controller.ex:44-71`
- Test: `test/magus/knowledge/connect_test.exs`

**Interfaces:**
- Consumes: `Magus.Knowledge.list_sources_for_user/1`, `update_source_auth_config/3`, `clear_source_reauth/2`, `update_source_status/3`.
- Produces: `Magus.Knowledge.Connect.reconnect_or_create(provider, auth_config, opts) :: {:ok, source} | {:error, message}` — updates the caller's existing source for that provider (clearing reauth, reactivating) if one exists, else creates a new one.

- [ ] **Step 1: Write the failing test**

Append to `test/magus/knowledge/connect_test.exs`:

```elixir
  describe "reconnect_or_create/3" do
    test "updates the existing source for the provider instead of creating a duplicate" do
      user = generate(user())

      {:ok, first} = Connect.connect_and_create("nextcloud", @nextcloud, actor: user)

      {:ok, second} =
        Connect.reconnect_or_create(
          "nextcloud",
          Map.put(@nextcloud, "password", "rotated-token"),
          actor: user
        )

      assert second.id == first.id
      assert {:ok, [_only_one]} = Knowledge.list_sources_for_user(actor: user)
    end

    test "creates a source when none exists for the provider" do
      user = generate(user())

      assert {:ok, source} = Connect.reconnect_or_create("nextcloud", @nextcloud, actor: user)
      assert source.provider == :nextcloud
      assert source.status == :active
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/connect_test.exs`
Expected: FAIL (`reconnect_or_create/3` undefined).

- [ ] **Step 3: Implement `reconnect_or_create/3`**

In `lib/magus/knowledge/connect.ex`, add after `connect_and_create/3` (line 48):

```elixir
  @doc """
  Reconnect flow: if the actor already has a source for this provider, validate
  the new credentials and update it in place (clearing any reauth flag and
  reactivating it). Otherwise behaves like `connect_and_create/3`. This is what
  the OAuth finalize endpoint uses so re-authorizing an expired connection heals
  the existing source and its collections instead of stranding them behind a
  duplicate.
  """
  def reconnect_or_create(provider, auth_config, opts)
      when is_binary(provider) and is_map(auth_config) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, provider_atom} <- parse_provider(provider),
         module <- Connector.connector_for(provider_atom),
         {:ok, _conn} <- module.connect(auth_config) do
      case existing_source(provider_atom, actor) do
        nil ->
          connect_and_create(provider, auth_config, opts)

        source ->
          update_existing(source, auth_config, actor)
      end
    else
      :error -> {:error, "Unknown provider"}
      {:error, reason} -> {:error, friendly_error(reason)}
    end
  end

  defp existing_source(provider_atom, actor) do
    case Knowledge.list_sources_for_user(actor: actor) do
      {:ok, sources} -> Enum.find(sources, &(&1.provider == provider_atom))
      _ -> nil
    end
  end

  defp update_existing(source, auth_config, actor) do
    with {:ok, source} <-
           Knowledge.update_source_auth_config(source, %{auth_config: auth_config}, actor: actor),
         {:ok, source} <- Knowledge.update_source_status(source, %{status: :active}, actor: actor) do
      # Clear any reauth flag so scheduled syncs resume. Best-effort: a source
      # that was never flagged still ends up active from the status update above.
      case Knowledge.clear_source_reauth(source, authorize?: false) do
        {:ok, cleared} -> {:ok, cleared}
        {:error, _} -> {:ok, source}
      end
    else
      {:error, reason} -> {:error, friendly_error(reason)}
    end
  end
```

- [ ] **Step 4: Route the finalize endpoint through it**

In `lib/magus_web/rpc/rpc_controller.ex`, in `knowledge_oauth_finalize/2`, change the create call (line 56) from `connect_and_create` to `reconnect_or_create`:

```elixir
        case Magus.Knowledge.Connect.reconnect_or_create(provider, tokens, actor: user) do
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge/connect_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/magus/knowledge/connect.ex lib/magus_web/rpc/rpc_controller.ex \
  test/magus/knowledge/connect_test.exs
git commit -m "feat(knowledge): SPA reconnect heals existing source in place"
```

---

### Task 7: Encrypt the session cookie so stashed OAuth tokens are not browser-readable

**Files:**
- Modify: `lib/magus_web/endpoint.ex:7-12`

**Interfaces:**
- No code interface. Behavioral: the session cookie switches from signed-only to encrypted+signed, so `:knowledge_oauth_tokens` (and everything else in the session) is opaque to the browser.

**Caveat (call out in the commit body):** adding `encryption_salt` invalidates all existing signed-only cookies, so every user is logged out once on deploy. This is a one-time cost and acceptable. There is no data migration.

- [ ] **Step 1: Add the encryption salt**

In `lib/magus_web/endpoint.ex`, update `@session_options` (lines 7-12):

```elixir
  @session_options [
    store: :cookie,
    key: "_magus_key",
    signing_salt: "2nsWBZN0",
    encryption_salt: "kn0wl3dg3-oauth-enc",
    same_site: "Lax"
  ]
```

- [ ] **Step 2: Verify the app boots and sessions round-trip**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus_web --max-failures 1`
Expected: PASS (auth/session-dependent controller and LiveView tests still sign in and round-trip the session).

- [ ] **Step 3: Compile clean and commit**

```bash
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus_web/endpoint.ex
git commit -m "feat(web): encrypt session cookie so stashed OAuth tokens are opaque

Adds encryption_salt to the cookie session store. One-time effect: existing
signed-only cookies no longer validate, so all users are logged out once on
deploy. No data migration."
```

---

### Task 8: Full regression pass

**Files:** none (verification only).

- [ ] **Step 1: Run the knowledge + web suites**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/knowledge test/magus_web/rpc`
Expected: PASS. Investigate any failure before proceeding.

- [ ] **Step 2: Warnings-as-errors gate**

Run: `set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean, no warnings.

- [ ] **Step 3: Format**

Run: `mix format` then `git diff --stat` to confirm only intended files changed formatting.

- [ ] **Step 4: Final commit if format touched anything**

```bash
git add -A
git commit -m "chore(knowledge): mix format after OAuth hardening"
```

---

## Self-Review Notes

- **Spec coverage:** finding 1 (invalid_grant terminal + stop scheduling + notify) → Tasks 1, 4, 5. Finding 2 (SPA reconnect duplicates) → Task 6. Finding 3 (refresh results lost outside sync) → Task 4 (proactive `ensure_fresh` persists immediately; browse path can adopt it later). Finding 4 (tokens in readable cookie) → Task 7. Finding 5 (reactive-only, racy) → Task 4 (proactive refresh; concurrency documented as benign per Global Constraints). Finding 6 sub-items: DRY credential reads → Task 1 Step 6; the remaining 6-items (PKCE, state nonce, grant revocation on delete, agent-path first-integration write) are intentionally out of scope for this plan and left as follow-ups.
- **Type consistency:** `ensure_fresh/1` returns `{:ok, source} | {:error, :reauth_required}` everywhere it is called (Tasks 4, 5). `refresh_google_token/1` return shape matches its consumers in Task 2 (`{:ok, %{"access_token" => _, "refresh_token" => _}}`) and Task 4. `mark_source_needs_reauth` accepts `%{last_error: ...}`; callers pass exactly that.
- **Follow-ups not in this plan (surface to the user):** replace the session-stash handoff with a server-side nonce record for defense beyond cookie encryption; revoke the Google grant on source delete; adopt `ensure_fresh` in the folder-browsing path (`Connect.list_folders`); PKCE + one-time state nonce on the authorize flow.
