# Signup Abuse Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turnstile captcha on signup paths, rate limiting on all auth endpoints, and retention (gate + reaper + admin visibility) for unconfirmed accounts.

**Architecture:** Three independently landable pieces sharing two bits of plumbing (an atomic ETS fixed-window limiter and a client-IP resolver). Captcha verification sits on the HTTP transport that creates users (plug) plus the LiveView socket events; rate limits are enforced at plug, LiveView, and Ash-action layers per endpoint threat; retention gates agent use in the existing preflight and reaps via an AshOban trigger with a conditional DELETE.

**Tech Stack:** Elixir/Phoenix/LiveView, Ash 3 + AshAuthentication, AshOban, `phoenix_turnstile` 1.2, ETS.

**Spec:** `docs/superpowers/specs/2026-08-16-signup-abuse-hardening-design.md` — read it before starting any task; it explains every "why" and documents accepted tradeoffs (do not re-litigate them).

## Global Constraints

- Everything defaults **off** in core config; the existing 7000+-test suite must stay green with zero config changes.
- NEVER run `mix ash.reset`. No schema migrations are expected in this plan (no new DB attributes); if you believe you need one, stop and re-read the spec.
- All user-facing strings go through `gettext(...)`; add German translations in `priv/gettext/de/LC_MESSAGES/` using informal address (du/dein, imperative).
- Pass `actor:` in app-code Ash calls; `authorize?: false` is allowed ONLY where the spec explicitly says so (reaper internals, auth-action wrappers) and in tests.
- Quality gate per task: `mix compile --warnings-as-errors` and the task's test files pass. Run `mix precommit` at the end of Tasks 3, 5, and 7.
- Commit messages follow repo style (`feat(...)`, `fix(...)`, `test(...)`), end with the Co-Authored-By line used in recent history.

---

### Task 1: Atomic fixed-window limiter + auth rate limiter

**Files:**
- Create: `lib/magus/rate_limiting/fixed_window.ex`
- Create: `lib/magus/accounts/auth_rate_limiter.ex`
- Modify: `lib/magus/integrations/rate_limiter.ex` (swap racy check for FixedWindow; keep public API + table + limits identical)
- Modify: `lib/magus/application.ex:98` (add `Magus.Accounts.AuthRateLimiter` next to `Magus.Integrations.RateLimiter`)
- Modify: `config/config.exs` (add `:auth_rate_limits` defaults)
- Test: `test/magus/rate_limiting/fixed_window_test.exs`, `test/magus/accounts/auth_rate_limiter_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Magus.RateLimiting.FixedWindow.check(table, scope, key, {limit, window_ms}) :: :ok | {:error, :rate_limited}`; `FixedWindow.sweep(table) :: non_neg_integer()`; `Magus.Accounts.AuthRateLimiter.check(scope :: atom(), key :: term()) :: :ok | {:error, :rate_limited}` where scope ∈ `:register | :sign_in | :magic_link | :magic_link_global | :password_reset | :password_reset_global | :resend_confirmation`. Disabled config (`enabled: false`, the default) always returns `:ok`.

- [ ] **Step 1: Write failing tests**

`test/magus/rate_limiting/fixed_window_test.exs`:

```elixir
defmodule Magus.RateLimiting.FixedWindowTest do
  use ExUnit.Case, async: true

  alias Magus.RateLimiting.FixedWindow

  setup do
    table = :ets.new(:fw_test, [:set, :public])
    {:ok, table: table}
  end

  test "allows up to limit then rejects", %{table: table} do
    for _ <- 1..3, do: assert(:ok == FixedWindow.check(table, :s, "k", {3, 60_000}))
    assert {:error, :rate_limited} == FixedWindow.check(table, :s, "k", {3, 60_000})
  end

  test "keys are independent per scope and key", %{table: table} do
    assert :ok == FixedWindow.check(table, :a, "k", {1, 60_000})
    assert :ok == FixedWindow.check(table, :b, "k", {1, 60_000})
    assert :ok == FixedWindow.check(table, :a, "k2", {1, 60_000})
  end

  test "atomic under concurrency: exactly limit succeed", %{table: table} do
    results =
      1..50
      |> Task.async_stream(fn _ -> FixedWindow.check(table, :c, "k", {10, 60_000}) end,
        max_concurrency: 50
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 10
  end

  test "sweep deletes only expired buckets", %{table: table} do
    # a tiny window that has certainly passed, and a live one-hour window
    assert :ok == FixedWindow.check(table, :s, "old", {5, 1})
    Process.sleep(5)
    assert :ok == FixedWindow.check(table, :s, "new", {5, 3_600_000})
    assert FixedWindow.sweep(table) == 1
    assert :ets.info(table, :size) == 1
  end
end
```

`test/magus/accounts/auth_rate_limiter_test.exs` (async: false — mutates app env):

```elixir
defmodule Magus.Accounts.AuthRateLimiterTest do
  use ExUnit.Case, async: false

  alias Magus.Accounts.AuthRateLimiter

  setup do
    original = Application.get_env(:magus, :auth_rate_limits)
    on_exit(fn -> Application.put_env(:magus, :auth_rate_limits, original) end)
    :ok
  end

  test "disabled config always allows" do
    Application.put_env(:magus, :auth_rate_limits, enabled: false, register: {1, :hour})
    assert :ok == AuthRateLimiter.check(:register, {127, 0, 0, 1})
    assert :ok == AuthRateLimiter.check(:register, {127, 0, 0, 1})
  end

  test "enabled config enforces the scope limit" do
    Application.put_env(:magus, :auth_rate_limits, enabled: true, register: {2, :hour})
    key = {10, 0, 0, System.unique_integer([:positive])}
    assert :ok == AuthRateLimiter.check(:register, key)
    assert :ok == AuthRateLimiter.check(:register, key)
    assert {:error, :rate_limited} == AuthRateLimiter.check(:register, key)
  end
end
```

- [ ] **Step 2: Run tests, verify failure** — `mix test test/magus/rate_limiting/fixed_window_test.exs test/magus/accounts/auth_rate_limiter_test.exs`; expect module-not-found failures.

- [ ] **Step 3: Implement**

`lib/magus/rate_limiting/fixed_window.ex`:

```elixir
defmodule Magus.RateLimiting.FixedWindow do
  @moduledoc """
  Atomic fixed-window counters on ETS.

  Key layout: `{scope, key, window_ms, bucket_index}` with
  `bucket_index = div(now_ms, window_ms)`. `:ets.update_counter/4` performs
  check-and-increment in a single atomic op, so concurrent callers cannot
  lose increments (the lookup-then-insert race the old integrations limiter
  had). The window_ms in the key lets `sweep/1` compute expiry across mixed
  window sizes sharing one table.
  """

  @spec check(:ets.table(), atom(), term(), {pos_integer(), pos_integer()}) ::
          :ok | {:error, :rate_limited}
  def check(table, scope, key, {limit, window_ms}) do
    now = System.system_time(:millisecond)
    bucket = div(now, window_ms)
    ets_key = {scope, key, window_ms, bucket}
    count = :ets.update_counter(table, ets_key, {2, 1}, {ets_key, 0})
    if count > limit, do: {:error, :rate_limited}, else: :ok
  end

  @doc "Deletes rows whose window has fully passed. Returns the delete count."
  @spec sweep(:ets.table()) :: non_neg_integer()
  def sweep(table) do
    now = System.system_time(:millisecond)

    match_spec = [
      {{{:_, :_, :"$1", :"$2"}, :_}, [{:"=<", {:*, {:+, :"$2", 1}, :"$1"}, now}], [true]}
    ]

    :ets.select_delete(table, match_spec)
  end
end
```

`lib/magus/accounts/auth_rate_limiter.ex`:

```elixir
defmodule Magus.Accounts.AuthRateLimiter do
  @moduledoc """
  Rate limits for unauthenticated auth endpoints (see the signup-abuse
  spec). Disabled unless `config :magus, :auth_rate_limits, enabled: true`.
  Scopes and `{limit, :minute | :hour}` pairs come from that config.
  """

  use GenServer

  alias Magus.RateLimiting.FixedWindow

  @table :auth_rate_limits
  @sweep_interval :timer.minutes(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec check(atom(), term()) :: :ok | {:error, :rate_limited}
  def check(scope, key) do
    config = Application.get_env(:magus, :auth_rate_limits, [])

    with true <- Keyword.get(config, :enabled, false),
         {limit, window} <- Keyword.get(config, scope) do
      FixedWindow.check(@table, scope, key, {limit, window_ms(window)})
    else
      _ -> :ok
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    FixedWindow.sweep(@table)
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
  defp window_ms(:minute), do: 60_000
  defp window_ms(:hour), do: 3_600_000
end
```

`config/config.exs` (near the other `:magus` blocks):

```elixir
# Auth endpoint rate limits (signup-abuse spec). Off by default; the cloud
# edition enables in prod. Sign-in note: a successful UI sign-in consumes
# 2 units (LiveView check + triggered POST), failed attempts consume 1.
config :magus, :auth_rate_limits,
  enabled: false,
  register: {5, :hour},
  sign_in: {20, :minute},
  magic_link: {3, :hour},
  magic_link_global: {100, :hour},
  password_reset: {3, :hour},
  password_reset_global: {100, :hour},
  resend_confirmation: {3, :hour}
```

Add `Magus.Accounts.AuthRateLimiter,` directly after `Magus.Integrations.RateLimiter,` in `lib/magus/application.ex`.

Then refactor `lib/magus/integrations/rate_limiter.ex`: replace the body of `check/3` (currently a non-atomic `:ets.lookup` + `:ets.insert`) with a call to `FixedWindow.check(:integration_rate_limits, provider_key, {user_id, operation}, {limit, window_ms})`, keeping `get_limit/2` and the window conversion. Update its cleanup timer handler to call `FixedWindow.sweep(:integration_rate_limits)` instead of its hand-rolled expiry scan, and make sure the table is created with `write_concurrency: true`. Public API (`check/3`), table name, config override key, and `@default_limits` stay byte-identical.

- [ ] **Step 4: Run tests + existing integrations limiter tests** — `mix test test/magus/rate_limiting/ test/magus/accounts/auth_rate_limiter_test.exs test/magus/integrations/`; all pass. `mix compile --warnings-as-errors` clean.

- [ ] **Step 5: Commit** — `feat(rate-limiting): atomic fixed-window limiter + auth rate limiter scaffold`

---

### Task 2: Client IP plumbing + rate-limit enforcement on auth endpoints

**Files:**
- Create: `lib/magus_web/client_ip.ex`
- Create: `lib/magus_web/plugs/capture_client_ip.ex`
- Create: `lib/magus_web/plugs/auth_rate_limit.ex`
- Create: `lib/magus/accounts/user/actions/rate_limited_magic_link_request.ex`
- Create: `lib/magus/accounts/user/actions/rate_limited_password_reset_request.ex`
- Modify: `lib/magus_web/core_router.ex` (`core_pipelines` browser pipeline ~line 119: add `CaptureClientIP` after `:fetch_session`; new `:auth_abuse_guards` pipeline; pipe the `auth_routes` scope at ~line 364 through it)
- Modify: `lib/magus_web/onboarding/sign_in_live.ex` (`mount` ~line 30, `handle_event("password_sign_in", ...)` line 177, `handle_event("request_magic_link", ...)` line 198)
- Modify: `lib/magus/accounts/user.ex` (`:request_magic_link` line 856, `:request_password_reset_token` line 766: swap `run` targets to the wrappers)
- Modify: `config/config.exs` (add `config :magus, :client_ip_header, nil`)
- Test: `test/magus_web/plugs/auth_rate_limit_test.exs`, `test/magus_web/client_ip_test.exs`, extend `test/magus_web/onboarding/sign_in_live_test.exs` (find the existing file; mirror its setup)

**Interfaces:**
- Consumes: `Magus.Accounts.AuthRateLimiter.check/2` (Task 1).
- Produces: `MagusWeb.ClientIP.from_conn(conn) :: :inet.ip_address()`; `MagusWeb.ClientIP.to_string(ip) :: String.t()`; `MagusWeb.ClientIP.from_session(session_map) :: :inet.ip_address() | nil` (reads key `"client_ip"`). Session key `"client_ip"` is set on every browser request. Wrapper modules delegate to the AshAuthentication implementations unchanged when under limits; on limit they return `{:error, :rate_limited}` from the action.

- [ ] **Step 1: Write failing tests**

`test/magus_web/client_ip_test.exs`:

```elixir
defmodule MagusWeb.ClientIPTest do
  use MagusWeb.ConnCase, async: false

  alias MagusWeb.ClientIP

  setup do
    original = Application.get_env(:magus, :client_ip_header)
    on_exit(fn -> Application.put_env(:magus, :client_ip_header, original) end)
    :ok
  end

  test "defaults to conn.remote_ip", %{conn: conn} do
    Application.put_env(:magus, :client_ip_header, nil)
    assert ClientIP.from_conn(conn) == conn.remote_ip
  end

  test "uses the configured header, first value, parsed", %{conn: conn} do
    Application.put_env(:magus, :client_ip_header, "fly-client-ip")
    conn = Plug.Conn.put_req_header(conn, "fly-client-ip", "203.0.113.7")
    assert ClientIP.from_conn(conn) == {203, 0, 113, 7}
  end

  test "malformed header falls back to remote_ip", %{conn: conn} do
    Application.put_env(:magus, :client_ip_header, "fly-client-ip")
    conn = Plug.Conn.put_req_header(conn, "fly-client-ip", "not-an-ip")
    assert ClientIP.from_conn(conn) == conn.remote_ip
  end

  test "to_string/from_session round-trip" do
    assert ClientIP.to_string({203, 0, 113, 7}) == "203.0.113.7"
    assert ClientIP.from_session(%{"client_ip" => "203.0.113.7"}) == {203, 0, 113, 7}
    assert ClientIP.from_session(%{}) == nil
  end
end
```

`test/magus_web/plugs/auth_rate_limit_test.exs` (async: false; enable limits per-test as in Task 1's test, restore on exit; use `build_conn/0` + `Phoenix.ConnTest`; POST through the router with `post(conn, ~p"/auth/user/password/register", %{})`):

```elixir
defmodule MagusWeb.Plugs.AuthRateLimitTest do
  use MagusWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:magus, :auth_rate_limits)
    on_exit(fn -> Application.put_env(:magus, :auth_rate_limits, original) end)
    :ok
  end

  test "register POSTs over the limit redirect to /register with a flash", %{conn: conn} do
    Application.put_env(:magus, :auth_rate_limits, enabled: true, register: {0, :hour})
    conn = post(conn, ~p"/auth/user/password/register", %{"user" => %{}})
    assert redirected_to(conn) == "/register"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many"
  end

  test "disabled limits do not interfere", %{conn: conn} do
    Application.put_env(:magus, :auth_rate_limits, enabled: false)
    conn = post(conn, ~p"/auth/user/password/register", %{"user" => %{}})
    # falls through to the auth controller (no redirect to /register from the plug)
    refute conn.halted and redirected_to(conn) == "/register"
  end
end
```

SignInLive additions (append to the existing sign-in LiveView test module, reusing its fixtures): a test that with `sign_in: {0, :minute}` enabled, submitting the password form renders the "Too many attempts" flash and does NOT call the sign-in action; and one that with `magic_link: {0, :hour}` the magic-link form submit shows an error flash instead of "link sent".

- [ ] **Step 2: Run tests, verify failure.**

- [ ] **Step 3: Implement**

`lib/magus_web/client_ip.ex`:

```elixir
defmodule MagusWeb.ClientIP do
  @moduledoc """
  Resolves the client IP. When `config :magus, :client_ip_header` names a
  trusted proxy header (cloud prod: "fly-client-ip"), its FIRST value is
  parsed; absence or garbage falls back to `conn.remote_ip`. Never trust a
  header that is not explicitly configured — attackers pick their own
  rate-limit key otherwise. LiveViews get the IP via the session (the
  CaptureClientIP plug stores it), because `connect_info` x_headers only
  carries `x-`-prefixed names.
  """

  @session_key "client_ip"

  def session_key, do: @session_key

  @spec from_conn(Plug.Conn.t()) :: :inet.ip_address()
  def from_conn(conn) do
    case Application.get_env(:magus, :client_ip_header) do
      header when is_binary(header) ->
        conn
        |> Plug.Conn.get_req_header(header)
        |> List.first()
        |> parse()
        |> case do
          nil -> conn.remote_ip
          ip -> ip
        end

      _ ->
        conn.remote_ip
    end
  end

  @spec to_string(:inet.ip_address()) :: String.t()
  def to_string(ip), do: ip |> :inet.ntoa() |> Kernel.to_string()

  @spec from_session(map()) :: :inet.ip_address() | nil
  def from_session(session), do: session |> Map.get(@session_key) |> parse()

  defp parse(nil), do: nil

  defp parse(value) when is_binary(value) do
    value = value |> String.split(",") |> hd() |> String.trim()

    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _} -> nil
    end
  end
end
```

`lib/magus_web/plugs/capture_client_ip.ex`:

```elixir
defmodule MagusWeb.Plugs.CaptureClientIP do
  @moduledoc "Stores the resolved client IP in the session for LiveViews."
  @behaviour Plug

  alias MagusWeb.ClientIP

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.put_session(conn, ClientIP.session_key(), ClientIP.to_string(ClientIP.from_conn(conn)))
  end
end
```

`lib/magus_web/plugs/auth_rate_limit.ex`:

```elixir
defmodule MagusWeb.Plugs.AuthRateLimit do
  @moduledoc """
  IP-keyed rate limits on the auth POST endpoints (signup-abuse spec).
  302 + flash on limit (browser form flow, not a bare 429). Ordered before
  captcha verification so hammering never costs a siteverify call.
  """
  @behaviour Plug

  use Gettext, backend: MagusWeb.Gettext

  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]
  import Plug.Conn

  alias Magus.Accounts.AuthRateLimiter
  alias MagusWeb.ClientIP

  @routes %{
    ["auth", "user", "password", "register"] => {:register, "/register"},
    ["auth", "user", "password", "sign_in"] => {:sign_in, "/sign-in"},
    ["auth", "user", "magic_link", "request"] => {:magic_link_http, "/sign-in"}
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    case Map.fetch(@routes, conn.path_info) do
      {:ok, {scope, redirect_to}} -> enforce(conn, scope, redirect_to)
      :error -> conn
    end
  end

  def call(conn, _opts), do: conn

  # The HTTP magic-link route shares the register budget shape but is
  # dominated by the action-level per-email + global limits (Task 2
  # wrappers); IP limiting here reuses the :register scope numbers.
  defp enforce(conn, :magic_link_http, redirect_to), do: enforce(conn, :register, redirect_to)

  defp enforce(conn, scope, redirect_to) do
    case AuthRateLimiter.check(scope, ClientIP.from_conn(conn)) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: redirect_to)
        |> halt()
    end
  end
end
```

Router (`lib/magus_web/core_router.ex`): inside `core_pipelines`, add `plug MagusWeb.Plugs.CaptureClientIP` immediately after `plug :fetch_session`... no — it needs the flash-capable session, so place it right after `plug :fetch_live_flash`. Then define:

```elixir
pipeline :auth_abuse_guards do
  plug MagusWeb.Plugs.AuthRateLimit
  plug MagusWeb.Plugs.VerifyCaptcha  # added in Task 3; leave this line commented until then
end
```

and change the scope containing `auth_routes AuthController, Magus.Accounts.User, path: "/auth"` (line ~364) to `pipe_through [:browser, :auth_abuse_guards]` (read its current `pipe_through` first and extend it, don't replace other pipelines it lists).

Action wrappers — `lib/magus/accounts/user/actions/rate_limited_magic_link_request.ex`:

```elixir
defmodule Magus.Accounts.User.Actions.RateLimitedMagicLinkRequest do
  @moduledoc """
  Per-email + global (per-node) rate limits in front of the library
  magic-link request. Global is consumed on EVERY request because the
  library sends mail for unknown addresses too (registration_enabled?).
  """
  use Ash.Resource.Actions.Implementation

  alias Magus.Accounts.AuthRateLimiter

  @impl true
  def run(input, opts, context) do
    email = input |> Ash.ActionInput.get_argument(:email) |> to_string() |> String.downcase()

    with :ok <- AuthRateLimiter.check(:magic_link, email),
         :ok <- AuthRateLimiter.check(:magic_link_global, :global) do
      AshAuthentication.Strategy.MagicLink.Request.run(input, opts, context)
    end
  end
end
```

`lib/magus/accounts/user/actions/rate_limited_password_reset_request.ex`:

```elixir
defmodule Magus.Accounts.User.Actions.RateLimitedPasswordResetRequest do
  @moduledoc """
  Reset-request wrapper. Looks the account up FIRST: the library sends
  nothing for unknown addresses, so consuming the global budget for them
  would let an attacker exhaust it with garbage addresses (denying resets
  to real users). Unknown -> silent :ok, budgets untouched. The external
  response is identical either way (anti-enumeration preserved).
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Magus.Accounts.AuthRateLimiter

  @impl true
  def run(input, _opts, context) do
    email = Ash.ActionInput.get_argument(input, :email)

    user =
      Magus.Accounts.User
      |> Ash.Query.for_read(:get_by_email, %{email: email})
      |> Ash.read_one!(authorize?: false)

    key = email |> to_string() |> String.downcase()

    with %{} <- user,
         :ok <- AuthRateLimiter.check(:password_reset, key),
         :ok <- AuthRateLimiter.check(:password_reset_global, :global) do
      AshAuthentication.Strategy.Password.RequestPasswordReset.run(
        input,
        [action: :get_by_email],
        context
      )
    else
      # unknown address: mimic the library's silent success
      nil -> :ok
      # over limit: also silent — the library reset UI swallows errors
      # anyway (spec: "silent by design"), and silence leaks nothing
      {:error, :rate_limited} -> :ok
    end
  end
end
```

In `lib/magus/accounts/user.ex` swap the two `run` lines: line 766's action body becomes `run Magus.Accounts.User.Actions.RateLimitedPasswordResetRequest` and line 856's becomes `run Magus.Accounts.User.Actions.RateLimitedMagicLinkRequest`.

`SignInLive` changes: in `mount/3` add `|> assign(:client_ip, MagusWeb.ClientIP.from_session(session))`. In `handle_event("password_sign_in", ...)` (line 177), before `Form.submit/2`:

```elixir
case Magus.Accounts.AuthRateLimiter.check(:sign_in, socket.assigns.client_ip) do
  {:error, :rate_limited} ->
    {:noreply, put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

  :ok ->
    # ... existing Form.validate + Form.submit flow unchanged ...
end
```

In `handle_event("request_magic_link", ...)` (line 198), replace the ignored `Ash.run_action` with:

```elixir
result =
  Magus.Accounts.User
  |> Ash.ActionInput.for_action(:request_magic_link, %{email: email})
  |> Ash.run_action(authorize?: false)

case result do
  :ok ->
    {:noreply, socket |> assign(:magic_link_sent, true) |> assign(:magic_link_email, email)}

  {:error, _} ->
    {:noreply, put_flash(socket, :error, gettext("Too many requests. Please try again later."))}
end
```

- [ ] **Step 4: Run tests** — new files + the full `test/magus_web/onboarding/` and `test/magus/accounts/` directories; then `mix compile --warnings-as-errors`. Also run `mix gettext.extract --merge` and fill the new msgids in `priv/gettext/de/LC_MESSAGES/default.po` (informal German, e.g. "Zu viele Versuche. Bitte versuche es später erneut.").

- [ ] **Step 5: Commit** — `feat(auth): rate limit register, sign-in, magic-link and reset endpoints`

---

### Task 3: Turnstile captcha

**Files:**
- Modify: `mix.exs:42` deps (add `{:phoenix_turnstile, "~> 1.2"}`), run `mix deps.get`
- Modify: `assets/package.json` + `assets/js/app.js` (npm dep + hook registration)
- Create: `lib/magus/captcha.ex`
- Create: `lib/magus_web/components/captcha_components.ex`
- Create: `lib/magus_web/plugs/verify_captcha.ex`
- Modify: `lib/magus/application.ex` (`Magus.Captcha.validate_config!()` first line of `start/2`)
- Modify: `lib/magus_web/core_router.ex` (uncomment `VerifyCaptcha` in `:auth_abuse_guards`)
- Modify: `lib/magus_web/onboarding/register_live.ex` (widget in form, before the submit button ~line 210)
- Modify: `lib/magus_web/onboarding/sign_in_live.ex` (widget in magic-link form line 146; verify in the `request_magic_link` handler; `Turnstile.refresh/1` on every non-success)
- Modify: `config/config.exs` (`config :magus, :captcha, impl: Turnstile, site_key: nil, secret_key: nil`)
- Create: `test/support/mocks.ex` addition — `Mox.defmock(Magus.CaptchaImplMock, for: Turnstile.Behaviour)` (add to the existing mocks file if one exists; grep `defmock` first)
- Test: `test/magus/captcha_test.exs`, `test/magus_web/plugs/verify_captcha_test.exs`, extend register/sign-in LiveView tests

**Interfaces:**
- Consumes: `MagusWeb.ClientIP` (Task 2), `:auth_abuse_guards` pipeline (Task 2).
- Produces: `Magus.Captcha.enabled?() :: boolean`; `Magus.Captcha.verify(params :: map, remote_ip :: :inet.ip_address() | nil) :: :ok | {:error, :missing_token | :invalid_token | :verification_unavailable}`; `Magus.Captcha.validate_config!() :: :ok` (raises on half-config); `MagusWeb.CaptchaComponents.captcha/1` component (renders nothing when disabled).

- [ ] **Step 1: Write failing tests**

`test/magus/captcha_test.exs` (async: false, mutates env; set `impl: Magus.CaptchaImplMock` + both keys per test, restore on exit):

```elixir
defmodule Magus.CaptchaTest do
  use ExUnit.Case, async: false

  import Mox

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:magus, :captcha)
    on_exit(fn -> Application.put_env(:magus, :captcha, original) end)
    :ok
  end

  defp enable! do
    Application.put_env(:magus, :captcha,
      impl: Magus.CaptchaImplMock,
      site_key: "sk",
      secret_key: "sec"
    )
  end

  test "disabled means :ok without calling the impl" do
    Application.put_env(:magus, :captcha, impl: Magus.CaptchaImplMock)
    assert :ok == Magus.Captcha.verify(%{}, nil)
  end

  test "missing token" do
    enable!()
    assert {:error, :missing_token} == Magus.Captcha.verify(%{}, {1, 2, 3, 4})
  end

  test "valid token" do
    enable!()
    expect(Magus.CaptchaImplMock, :verify, fn %{"cf-turnstile-response" => "tok"}, _ip ->
      {:ok, %{"success" => true}}
    end)
    assert :ok == Magus.Captcha.verify(%{"cf-turnstile-response" => "tok"}, {1, 2, 3, 4})
  end

  test "cloudflare rejection maps to invalid_token" do
    enable!()
    expect(Magus.CaptchaImplMock, :verify, fn _, _ -> {:error, %{"success" => false}} end)
    assert {:error, :invalid_token} == Magus.Captcha.verify(%{"cf-turnstile-response" => "x"}, nil)
  end

  test "transport failure maps to verification_unavailable (fail closed)" do
    enable!()
    expect(Magus.CaptchaImplMock, :verify, fn _, _ -> {:error, :timeout} end)
    assert {:error, :verification_unavailable} ==
             Magus.Captcha.verify(%{"cf-turnstile-response" => "x"}, nil)
  end

  test "half-configuration raises at validate_config!" do
    Application.put_env(:magus, :captcha, site_key: "sk", secret_key: nil)
    assert_raise RuntimeError, ~r/half-configured/, &Magus.Captcha.validate_config!/0
  end
end
```

`test/magus_web/plugs/verify_captcha_test.exs`: with captcha enabled (mock impl), a tokenless `POST ~p"/auth/user/password/register"` redirects to `/register` with a flash and creates no user (`refute Magus.Accounts.User |> Ash.Query.filter(email == "x@y.z") |> Ash.exists?(authorize?: false)` style — mirror how existing register tests assert); a tokenless `POST ~p"/auth/user/magic_link/request"` redirects to `/sign-in`; with captcha disabled both POSTs pass through untouched; a non-matched `/auth` path is untouched even when enabled.

- [ ] **Step 2: Run tests, verify failure.**

- [ ] **Step 3: Implement**

`lib/magus/captcha.ex`:

```elixir
defmodule Magus.Captcha do
  @moduledoc """
  Captcha gate (Cloudflare Turnstile via phoenix_turnstile). Disabled unless
  BOTH :site_key and :secret_key are set in `config :magus, :captcha` — the
  library's own config defaults to Cloudflare's always-pass TEST keys, so
  enablement is decided exclusively here, never by the library.
  """

  def enabled? do
    config = config()
    is_binary(config[:site_key]) and is_binary(config[:secret_key])
  end

  @doc "Called from Magus.Application.start/2. Half-config fails the boot."
  def validate_config! do
    config = config()

    case {config[:site_key], config[:secret_key]} do
      {site, secret} when is_binary(site) and is_binary(secret) ->
        Application.put_env(:phoenix_turnstile, :site_key, site)
        Application.put_env(:phoenix_turnstile, :secret_key, secret)
        :ok

      {nil, nil} ->
        :ok

      _ ->
        raise "captcha half-configured: set both TURNSTILE_SITE_KEY and " <>
                "TURNSTILE_SECRET_KEY, or neither (a missing secret would " <>
                "silently fall back to Cloudflare's always-pass test keys)"
    end
  end

  @spec verify(map(), :inet.ip_address() | nil) ::
          :ok | {:error, :missing_token | :invalid_token | :verification_unavailable}
  def verify(params, remote_ip) do
    cond do
      not enabled?() ->
        :ok

      not match?(%{"cf-turnstile-response" => t} when is_binary(t) and t != "", params) ->
        {:error, :missing_token}

      true ->
        case impl().verify(params, remote_ip) do
          {:ok, _body} -> :ok
          {:error, %{"success" => false}} -> {:error, :invalid_token}
          {:error, _transport_or_http} -> {:error, :verification_unavailable}
        end
    end
  end

  defp impl, do: config()[:impl] || Turnstile
  defp config, do: Application.get_env(:magus, :captcha, [])
end
```

`lib/magus_web/components/captcha_components.ex`:

```elixir
defmodule MagusWeb.CaptchaComponents do
  @moduledoc "Renders the Turnstile widget when captcha is enabled; nothing otherwise."
  use Phoenix.Component

  def captcha(assigns) do
    assigns = assign(assigns, :enabled?, Magus.Captcha.enabled?())

    ~H"""
    <div :if={@enabled?} class="flex justify-center">
      <Turnstile.script />
      <Turnstile.widget theme="auto" />
    </div>
    """
  end
end
```

`lib/magus_web/plugs/verify_captcha.ex`:

```elixir
defmodule MagusWeb.Plugs.VerifyCaptcha do
  @moduledoc """
  Captcha verification for the two POST routes that create accounts / send
  signup mail. Fail closed: an unreachable siteverify rejects the submit.
  """
  @behaviour Plug

  use Gettext, backend: MagusWeb.Gettext

  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]
  import Plug.Conn

  alias MagusWeb.ClientIP

  @routes %{
    ["auth", "user", "password", "register"] => "/register",
    ["auth", "user", "magic_link", "request"] => "/sign-in"
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    case Map.fetch(@routes, conn.path_info) do
      {:ok, redirect_to} -> enforce(conn, redirect_to)
      :error -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp enforce(conn, redirect_to) do
    case Magus.Captcha.verify(conn.params, ClientIP.from_conn(conn)) do
      :ok ->
        conn

      {:error, :verification_unavailable} ->
        deny(conn, redirect_to, gettext("Verification is temporarily unavailable. Please try again."))

      {:error, _missing_or_invalid} ->
        deny(conn, redirect_to, gettext("Captcha verification failed. Please try again."))
    end
  end

  defp deny(conn, redirect_to, message) do
    conn |> put_flash(:error, message) |> redirect(to: redirect_to) |> halt()
  end
end
```

Assets: `cd assets && npm install phoenix-turnstile --save`. In `assets/js/app.js`, add `import Turnstile from "phoenix-turnstile";` next to the other hook imports (~line 38) and add `Turnstile,` to the hooks object passed to the LiveSocket (find where `colocatedHooks`/`BrainHooks` are merged).

LiveViews: in `RegisterLive`'s form, immediately before the submit button, add `<MagusWeb.CaptchaComponents.captcha />`. In `SignInLive`'s magic-link `<form>` (line 146), same. Extend the Task-2 `request_magic_link` handler to verify first — full final shape:

```elixir
def handle_event("request_magic_link", %{"email" => email} = params, socket) do
  with :ok <- Magus.Captcha.verify(params, socket.assigns.client_ip),
       :ok <-
         Magus.Accounts.User
         |> Ash.ActionInput.for_action(:request_magic_link, %{email: email})
         |> Ash.run_action(authorize?: false) do
    {:noreply, socket |> assign(:magic_link_sent, true) |> assign(:magic_link_email, email)}
  else
    {:error, reason} when reason in [:missing_token, :invalid_token, :verification_unavailable] ->
      {:noreply,
       socket
       |> put_flash(:error, gettext("Captcha verification failed. Please try again."))
       |> Turnstile.refresh()}

    {:error, _} ->
      {:noreply,
       socket
       |> put_flash(:error, gettext("Too many requests. Please try again later."))
       # token was consumed by the successful verify; reset for retry
       |> Turnstile.refresh()}
  end
end
```

Uncomment `plug MagusWeb.Plugs.VerifyCaptcha` in the `:auth_abuse_guards` pipeline. Add `Magus.Captcha.validate_config!()` as the first expression of `Magus.Application.start/2`.

- [ ] **Step 4: Run tests + full precommit** — new tests, the register/sign-in LiveView suites (assert widget absent when disabled — the default — and present when enabled), then `mix precommit`. Gettext-extract + German translations for the three new strings.

- [ ] **Step 5: Commit** — `feat(auth): Turnstile captcha on registration and magic-link request`

---

### Task 4: Confirmation gate + resend + SPA banner

**Files:**
- Modify: `lib/magus/agents/plugins/support/preflight.ex` (spend-gate region ~line 196; add helper next to `handle_limit_exceeded/3` at line 433)
- Modify: `lib/magus/accounts/user.ex` (public calculation; `:resend_confirmation` action; policy)
- Create: `lib/magus/accounts/user/changes/resend_confirmation_email.ex`
- Modify: `lib/magus/accounts/accounts.ex` (`rpc_action :resend_confirmation, :resend_confirmation` in the `typescript_rpc` user block ~line 11)
- Modify: `config/config.exs` (`config :magus, :require_confirmed_email_for_agent_use, false`)
- Modify: SPA — regenerate types (`mix ash_typescript.codegen`; verify exact task with `mix help --search typescript`), then add the banner where the workbench shell renders global notices: grep `frontend/src` for an existing global banner/announcement component and mount alongside it
- Test: `test/magus/agents/plugins/support/preflight_confirmation_test.exs` (mirror the setup of the existing preflight/limit tests — find them via `grep -rl "usage limit exceeded" test/`), `test/magus/accounts/resend_confirmation_test.exs`

**Interfaces:**
- Consumes: `AuthRateLimiter.check(:resend_confirmation, email)` (Task 1); existing `Helpers.acting_user_id/2`, `load_user_for_limits/1`, `settle_blocked_run/2`, `handle_limit_exceeded/3` shape in Preflight.
- Produces: `User.email_confirmed?` public boolean calculation (SPA reads `emailConfirmed` on currentUser); `:resend_confirmation` update action (RPC, self-only). Gate config key `:require_confirmed_email_for_agent_use`.

- [ ] **Step 1: Write failing tests**

Preflight test essentials (reuse the existing preflight test scaffolding for building `data`/state; do not invent new fixtures):
- gate enabled + unconfirmed acting user → returns `{:ok, {:override, Jido.Actions.Control.Noop}}`, persists an event message mentioning email confirmation, no LLM signal;
- gate enabled + confirmed acting user → normal `{:ok, {:continue, signal}}`;
- gate disabled (default) → normal continue for unconfirmed user;
- shared conversation: unconfirmed member + confirmed owner → blocked (subject is the acting member).

Resend test:

```elixir
defmodule Magus.Accounts.ResendConfirmationTest do
  use Magus.DataCase, async: false

  import Swoosh.TestAssertions

  test "unconfirmed user gets a confirmation email" do
    user = unconfirmed_user_fixture()  # use the existing generator; grep test/support/generators.ex
    assert {:ok, _} = Ash.update(Ash.Changeset.for_update(user, :resend_confirmation, %{}, actor: user))
    assert_email_sent(to: [{nil, to_string(user.email)}])
  end

  test "confirmed user is a silent no-op (no welcome-email replay)" do
    user = confirmed_user_fixture()
    assert {:ok, _} = Ash.update(Ash.Changeset.for_update(user, :resend_confirmation, %{}, actor: user))
    assert_no_email_sent()
  end

  test "another actor is forbidden" do
    user = unconfirmed_user_fixture()
    other = confirmed_user_fixture()
    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(Ash.Changeset.for_update(user, :resend_confirmation, %{}, actor: other))
  end
end
```

(Adapt fixture names and the email assertion to the repo's actual helpers — check `test/support/generators.ex` and an existing sender test for the mail-assertion idiom before writing.)

- [ ] **Step 2: Run tests, verify failure.**

- [ ] **Step 3: Implement**

Preflight — in the spend-gate region where `user = load_user_for_limits(acting_user_id)` already exists, add before the LimitEnforcer check:

```elixir
if confirmation_required?() and is_nil(user.confirmed_at) do
  handle_confirmation_required(conversation_id, message_id)
  settle_blocked_run(data, "email confirmation required")
  {:ok, {:override, Jido.Actions.Control.Noop}}
else
  # existing limit-check + signal-build flow, unchanged
end
```

with private helpers:

```elixir
defp confirmation_required? do
  Application.get_env(:magus, :require_confirmed_email_for_agent_use, false)
end

defp handle_confirmation_required(conversation_id, message_id) do
  # Mirror handle_limit_exceeded/3 (line 433): persist one :event message on
  # the conversation and broadcast it, with text:
  # gettext("Please confirm your email address to start chatting. Check your inbox for the confirmation link.")
end
```

(Copy `handle_limit_exceeded/3`'s persistence + broadcast shape exactly; only the message text and reason differ. Do NOT touch `build_resume_react_signal/2` — the spec explains why resumes are exempt.)

User resource — calculation (place next to the existing public calculations, grep `calculate :` in user.ex):

```elixir
calculate :email_confirmed?, :boolean, expr(not is_nil(confirmed_at)) do
  public? true
end
```

Action + policy:

```elixir
update :resend_confirmation do
  description "Re-send the confirmation email. Silent no-op when already confirmed."
  accept []
  require_atomic? false
  change Magus.Accounts.User.Changes.ResendConfirmationEmail
end

# in policies, next to the select_workspace policy:
policy action(:resend_confirmation) do
  authorize_if expr(id == ^actor(:id))
end
```

`lib/magus/accounts/user/changes/resend_confirmation_email.ex`:

```elixir
defmodule Magus.Accounts.User.Changes.ResendConfirmationEmail do
  @moduledoc """
  Generates a fresh confirmation token (outside the monitored-field flow,
  via the public AshAuthentication API) and sends it. Guarded to
  unconfirmed users: a confirmed user re-running :confirm would replay
  SendWelcomeEmail. Rate-limited per email.
  """
  use Ash.Resource.Change

  alias Magus.Accounts.AuthRateLimiter

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      with nil <- user.confirmed_at,
           :ok <- AuthRateLimiter.check(:resend_confirmation, String.downcase(to_string(user.email))) do
        strategy = AshAuthentication.Info.strategy!(Magus.Accounts.User, :confirm_new_user)

        token_changeset =
          user
          |> Ash.Changeset.new()
          |> Ash.Changeset.force_change_attribute(:email, user.email)

        case AshAuthentication.AddOn.Confirmation.confirmation_token(
               strategy,
               token_changeset,
               user
             ) do
          {:ok, token} ->
            Magus.Accounts.User.Senders.SendNewUserConfirmationEmail.send(user, token, [])
            {:ok, user}

          {:error, reason} ->
            {:error, reason}
        end
      else
        # already confirmed, or rate limited: silent no-op either way
        _ -> {:ok, user}
      end
    end)
  end
end
```

(Verify `confirmation_token/3` vs `/4` arity against `deps/ash_authentication/lib/ash_authentication/add_ons/confirmation.ex:150-174` and adjust the call — the opts argument may be required.)

RPC: add `rpc_action :resend_confirmation, :resend_confirmation` to the user block in `lib/magus/accounts/accounts.ex`. Run the typescript codegen and commit generated output.

SPA banner (keep minimal): in the workbench shell, when `currentUser.emailConfirmed === false`, render a dismissable top banner: text "Confirm your email to start chatting — check your inbox." plus a "Resend email" button calling the generated `resendConfirmation` RPC and disabling itself afterward. Follow whatever banner/notice component pattern already exists in `frontend/src`; build with `mix magus.build_spa` and verify no build errors.

- [ ] **Step 4: Run tests** — the two new files + full `test/magus/agents/plugins/` + `mix compile --warnings-as-errors`; gettext-extract + German for the event-message string.

- [ ] **Step 5: Commit** — `feat(accounts): gate agent use on email confirmation + resend flow`

---

### Task 5: Unconfirmed-account reaper

**Files:**
- Create: `lib/magus/accounts/unconfirmed_retention.ex`
- Modify: `lib/magus/accounts/account_deletion.ex` (`execute/1` → `execute/2` with `require_unconfirmed: boolean` option; conditional final user delete)
- Modify: `lib/magus/accounts/user.ex` (add `read :read_for_reaping`, `update :reap_if_unconfirmed`, oban trigger — all mirroring the `:consolidate_memories` / `:trigger_memory_consolidation` pattern at lines 124-159)
- Modify: `lib/magus/application.ex` (`Magus.Accounts.UnconfirmedRetention.validate_config!()` next to the captcha validation)
- Modify: `config/config.exs` (`config :magus, :unconfirmed_account_ttl_days, nil`)
- Test: `test/magus/accounts/unconfirmed_retention_test.exs`

**Interfaces:**
- Consumes: `Magus.Accounts.AccountDeletion.execute/2` (this task extends it); existing `DeleteExpiredTestAccounts` worker as the Oban-calls-AccountDeletion precedent.
- Produces: `UnconfirmedRetention.ttl_days() :: pos_integer() | nil`; `UnconfirmedRetention.validate_config!()` (raises unless nil or integer >= 1); `UnconfirmedRetention.reap(user) :: :deleted | :skipped | :noop`.

- [ ] **Step 1: Write failing tests**

```elixir
defmodule Magus.Accounts.UnconfirmedRetentionTest do
  use Magus.DataCase, async: false

  alias Magus.Accounts.UnconfirmedRetention

  setup do
    original = Application.get_env(:magus, :unconfirmed_account_ttl_days)
    on_exit(fn -> Application.put_env(:magus, :unconfirmed_account_ttl_days, original) end)
    Application.put_env(:magus, :unconfirmed_account_ttl_days, 7)
    :ok
  end

  defp age!(user, days) do
    # push inserted_at into the past via Repo.update_all (no Ash action touches it)
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    Magus.Repo.update_all(
      from(u in "users", where: u.id == type(^user.id, :binary_id)),
      set: [inserted_at: cutoff]
    )
    user
  end

  test "past-TTL unconfirmed user with no structure is deleted" do
    user = unconfirmed_user_fixture() |> age!(8)
    assert :deleted == UnconfirmedRetention.reap(user)
    refute user_exists?(user.id)
  end

  test "recent unconfirmed user survives" do
    user = unconfirmed_user_fixture() |> age!(2)
    assert :noop == UnconfirmedRetention.reap(user)
    assert user_exists?(user.id)
  end

  test "confirmed user survives regardless of age" do
    user = confirmed_user_fixture() |> age!(30)
    assert :noop == UnconfirmedRetention.reap(user)
    assert user_exists?(user.id)
  end

  test "nil TTL disables reaping" do
    Application.put_env(:magus, :unconfirmed_account_ttl_days, nil)
    user = unconfirmed_user_fixture() |> age!(30)
    assert :noop == UnconfirmedRetention.reap(user)
  end

  test "organization owner is skipped" do
    user = unconfirmed_user_fixture() |> age!(30)
    _org = organization_fixture(owner: user)
    assert :skipped == UnconfirmedRetention.reap(user)
    assert user_exists?(user.id)
  end

  test "sole-admin workspace holder is skipped" do
    user = unconfirmed_user_fixture() |> age!(30)
    _ws = workspace_fixture(owner: user)
    assert :skipped == UnconfirmedRetention.reap(user)
  end

  test "user confirmed between scheduling and delete: transaction rolls back, data intact" do
    user = unconfirmed_user_fixture() |> age!(30)
    # simulate the race: confirm AFTER reap decided to delete, by calling
    # AccountDeletion directly with the precondition against a now-confirmed row
    confirm!(user)
    assert {:error, :precondition_failed} =
             Magus.Accounts.AccountDeletion.execute(user, require_unconfirmed: true)
    assert user_exists?(user.id)
  end

  test "validate_config! rejects zero and negatives" do
    Application.put_env(:magus, :unconfirmed_account_ttl_days, 0)
    assert_raise RuntimeError, ~r/unconfirmed_account_ttl_days/, &UnconfirmedRetention.validate_config!/0
  end
end
```

(Fixture names: check `test/support/generators.ex` for user/organization/workspace generators and the idiomatic way to set `confirmed_at`; `confirm!/1` can be a direct `Repo.update_all` setting `confirmed_at`. `user_exists?/1` = `Repo.exists?` on the users table with `authorize?: false` equivalent.)

- [ ] **Step 2: Run, verify failure.**

- [ ] **Step 3: Implement**

`lib/magus/accounts/unconfirmed_retention.ex`:

```elixir
defmodule Magus.Accounts.UnconfirmedRetention do
  @moduledoc """
  Reaps password-signup accounts that never confirmed their email
  (spec: signup-abuse-hardening, section C). v1 deliberately reaps ONLY
  users with no owned structure — org owners and sole-admin workspace
  holders are skipped with a warning (magus-xjc3 tracks teardown). All
  internal lookups run authorize?: false: there is no actor in the Oban
  context and user-facing policies would hide exactly the rows we check.
  """

  require Logger

  import Ecto.Query

  alias Magus.Accounts.AccountDeletion
  alias Magus.Repo

  def ttl_days, do: Application.get_env(:magus, :unconfirmed_account_ttl_days)

  def validate_config! do
    case ttl_days() do
      nil -> :ok
      days when is_integer(days) and days >= 1 -> :ok
      other ->
        raise "unconfirmed_account_ttl_days must be nil or an integer >= 1 " <>
                "(the reaper's scheduler floor is 1 day), got: #{inspect(other)}"
    end
  end

  @spec reap(Magus.Accounts.User.t()) :: :deleted | :skipped | :noop
  def reap(user) do
    with days when is_integer(days) <- ttl_days(),
         true <- is_nil(user.confirmed_at) or :noop,
         true <- past_ttl?(user, days) or :noop,
         false <- owns_structure?(user) or :structure do
      case AccountDeletion.execute(user, require_unconfirmed: true) do
        :ok ->
          Logger.info("reaped unconfirmed account #{user.id}")
          :deleted

        {:error, reason} ->
          Logger.warning("reap of #{user.id} did not delete: #{inspect(reason)}")
          :skipped
      end
    else
      :structure ->
        Logger.warning("skipping reap of #{user.id}: owns an organization or is sole workspace admin")
        :skipped

      _ ->
        :noop
    end
  end

  defp past_ttl?(user, days) do
    DateTime.compare(user.inserted_at, DateTime.add(DateTime.utc_now(), -days * 86_400, :second)) == :lt
  end

  defp owns_structure?(user) do
    owns_org? =
      Repo.exists?(from(o in "organizations", where: o.owner_id == type(^user.id, :binary_id)))

    owns_org? or sole_admin_of_any_workspace?(user)
  end

  defp sole_admin_of_any_workspace?(user) do
    # Reuse AccountDeletion's preflight query if it is extractable; else
    # replicate: any workspace where this user is an active admin and no
    # OTHER active admin exists. Read AccountDeletion.preflight/1 first
    # and extract a shared helper rather than duplicating the SQL.
    AccountDeletion.sole_admin_workspace_ids(user) != []
  end
end
```

(Note the `with` uses `or :noop` sentinels for readability of the three-way result; feel free to rewrite as a `cond` — behavior over style. Extract `sole_admin_workspace_ids/1` from `AccountDeletion.preflight/1`'s existing query as a public function.)

`AccountDeletion.execute/2`: change the signature to `def execute(user, opts \\ [])`. Thread `opts[:require_unconfirmed]` down to the final user-row delete inside the existing repo transaction (region ~lines 217-228 / 541-555 — read it first; the cleanup is raw-SQL based). The conditional delete:

```elixir
defp delete_user_row(user, true = _require_unconfirmed) do
  {count, _} =
    Repo.delete_all(
      from(u in "users",
        where: u.id == type(^user.id, :binary_id) and is_nil(u.confirmed_at)
      )
    )

  if count == 0 do
    # user confirmed since the reaper scheduled this — roll back EVERYTHING
    raise Magus.Accounts.AccountDeletion.PreconditionFailed
  end

  :ok
end

defp delete_user_row(user, _), do: # the existing unconditional delete, unchanged
```

with `defmodule PreconditionFailed do defexception message: "delete precondition failed" end` and a `rescue` in `execute/2` mapping it to `{:error, :precondition_failed}` AFTER the transaction rolled back. The exception must be raised INSIDE `Repo.transaction` so the whole cleanup rolls back.

User resource — mirror the `:consolidate_memories` pattern exactly:

```elixir
read :read_for_reaping do
  description "Scheduler read for the unconfirmed-account reaper"
  pagination keyset?: true, required?: false
end

update :reap_if_unconfirmed do
  description "AshOban target: reap this user if still unconfirmed past TTL"
  accept []
  transaction? false
  require_atomic? false

  change fn changeset, _context ->
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      Magus.Accounts.UnconfirmedRetention.reap(user)
      {:ok, user}
    end)
  end
end
```

Trigger (inside the existing `oban do triggers do ... end` block in user.ex):

```elixir
trigger :reap_unconfirmed do
  scheduler_cron "0 * * * *"
  action :reap_if_unconfirmed
  read_action :read_for_reaping
  worker_read_action :read_for_reaping
  stream_with :full_read
  where expr(is_nil(confirmed_at) and inserted_at < ago(1, :day))
  worker_module_name Magus.Accounts.User.Workers.ReapUnconfirmed
  scheduler_module_name Magus.Accounts.User.Schedulers.ReapUnconfirmed
end
```

(If the trigger's queue needs declaring, mirror how the memory-consolidation trigger's queue is configured — grep the Oban queue config. The action returns `{:ok, user}` even after deletion; AshOban tolerates the row being gone at reload only if it doesn't reload — if the worker errors post-delete on reload, return the user struct via the after_action as shown, which avoids a re-fetch.)

Config default + `validate_config!` call in application.ex.

- [ ] **Step 4: Run** — new test file, plus `test/magus/accounts/` (account-deletion suite must stay green — the `execute/1` arity keeps working via the default arg), `mix compile --warnings-as-errors`, and `mix ash_postgres.generate_migrations --check` (must report NO migrations needed; if it wants one, something is wrong — see Global Constraints).

- [ ] **Step 5: Commit** — `feat(accounts): reap unconfirmed accounts past TTL (skip structure owners)`

---

### Task 6: Admin confirmed column + filter

**Files:**
- Modify: `lib/magus/usage/admin_stats.ex` (`list_users/1` at line 235: add `confirmed_at: u.confirmed_at` to the select; `filtered_users/2` case: add the two clauses)
- Modify: `lib/magus_web/admin/users_live.ex` (line 19 `@filters`; filter select ~line 183; table header + row cell)
- Test: extend the existing admin users tests (`grep -rl "non_admins" test/` to find them)

**Interfaces:**
- Consumes: `AdminStats.list_users/1` (existing), `confirmed_at` attribute.
- Produces: filter values `"confirmed"` / `"unconfirmed"`; each user row map gains `confirmed_at`.

- [ ] **Step 1: Write failing tests** — in the existing AdminStats/users_live test files: `list_users(filter: "unconfirmed")` returns only users with `confirmed_at == nil` and the row maps include `confirmed_at`; `list_users(filter: "confirmed")` the inverse; LiveView test: the select renders the two new options and patching `?filter=unconfirmed` shows only unconfirmed rows (mirror how the existing `demo` filter is tested).

- [ ] **Step 2: Run, verify failure.**

- [ ] **Step 3: Implement**

`admin_stats.ex` — in `filtered_users/2`'s case:

```elixir
"confirmed" -> where(query, [u], not is_nil(u.confirmed_at))
"unconfirmed" -> where(query, [u], is_nil(u.confirmed_at))
```

and add `confirmed_at: u.confirmed_at,` to the `select` map. Update the `@doc` options line.

`users_live.ex`: `@filters ~w(all admins non_admins demo confirmed unconfirmed)`; two `<option>`s in the select (labels `Confirmed` / `Unconfirmed`, no gettext — the admin UI is English like its neighbors); a `<th>` "Confirmed" and a row cell:

```heex
<td>
  <span :if={user.confirmed_at} class="badge badge-success badge-sm" title={user.confirmed_at}>
    {gettext("confirmed")}
  </span>
  <span :if={is_nil(user.confirmed_at)} class="badge badge-ghost badge-sm">
    {gettext("unconfirmed")}
  </span>
</td>
```

(Match the badge classes used elsewhere in this table — read the existing admin/demo badges first and copy their style. If the rest of the table skips gettext, skip it here too for consistency.)

- [ ] **Step 4: Run** — the admin test files + `mix compile --warnings-as-errors`.

- [ ] **Step 5: Commit** — `feat(admin): confirmed column and confirmed/unconfirmed filter on the users list`

---

### Task 7: Cloud wiring (magus-cloud repo)

**Files (all in `/Users/daniel/Development/magus-cloud`):**
- Modify: `config/runtime.exs` (prod env reads)
- Modify: `config/config.exs` (mirrored-config note block ~line 390: add the new keys with core defaults)
- Modify: `fly.toml` (`MAGUS_CORE_REF` bump after core lands)
- Test: the mirrored core suite runs green (`mix test`)

**Interfaces:** consumes every config key produced above; produces nothing new.

- [ ] **Step 1: Mirror config defaults** — in the cloud `config/config.exs` mirrored block, add (keeping the existing "Keep in sync when bumping MAGUS_CORE_REF" comment discipline):

```elixir
config :magus, :auth_rate_limits, enabled: false
config :magus, :captcha, impl: Turnstile, site_key: nil, secret_key: nil
config :magus, :client_ip_header, nil
config :magus, :require_confirmed_email_for_agent_use, false
config :magus, :unconfirmed_account_ttl_days, nil
```

- [ ] **Step 2: Prod runtime config** — in `config/runtime.exs` under the prod section:

```elixir
if config_env() == :prod do
  config :magus, :captcha,
    impl: Turnstile,
    site_key: System.get_env("TURNSTILE_SITE_KEY"),
    secret_key: System.get_env("TURNSTILE_SECRET_KEY")

  config :magus, :auth_rate_limits, enabled: System.get_env("AUTH_RATE_LIMITS_ENABLED", "true") == "true"
  config :magus, :client_ip_header, "fly-client-ip"

  config :magus, :require_confirmed_email_for_agent_use,
    System.get_env("REQUIRE_CONFIRMED_EMAIL", "true") == "true"

  config :magus, :unconfirmed_account_ttl_days,
    case System.get_env("UNCONFIRMED_ACCOUNT_TTL_DAYS") do
      nil -> nil
      days -> String.to_integer(days)
    end
end
```

(Adapt to the actual runtime.exs structure — read it first; merge the `:auth_rate_limits` enable with the limits from the shared config rather than clobbering the tuple list: use `config :magus, :auth_rate_limits, enabled: ...` which Elixir config deep-merges by key.)

- [ ] **Step 3: Bump + verify** — set `MAGUS_CORE_REF` in fly.toml to the core SHA containing Tasks 1-6, run `MIX_ENV=test mix compile --warnings-as-errors` and `mix test` in the cloud repo. Per rollout: set the Fly secrets (`fly secrets set TURNSTILE_SITE_KEY=... TURNSTILE_SECRET_KEY=...`) BEFORE deploying — the half-config boot error will (correctly) crash the release otherwise. Do NOT set `UNCONFIRMED_ACCOUNT_TTL_DAYS` yet; per the spec's rollout section the reaper waits one TTL window after the gate ships.

- [ ] **Step 4: Commit + push** — `build: enable signup abuse hardening (captcha, auth limits, confirmation gate)` — and follow the repo's session-completion push protocol.

---

## Self-review notes

- Spec coverage: captcha (Task 3 + plug scope both routes), rate limits incl. LiveView sign-in path and wrapper asymmetry (Task 2), gate + resend + SPA (Task 4), reaper with conditional delete + structure skip (Task 5), admin filter (Task 6), cloud config + rollout ordering (Task 7). FixedWindow refactor of the integrations limiter (Task 1). German gettext folded into Tasks 2-4.
- Deliberately absent, per spec: captcha on password sign-in or reset; resume-path gate; org teardown (magus-xjc3); warning emails; distributed limiter store.
- Verify-at-implementation flags called out inline: `confirmation_token` arity (Task 4), AshOban queue declaration (Task 5), runtime.exs merge semantics (Task 7).
