# Signup Abuse Hardening: Captcha, Auth Rate Limiting, Unconfirmed-Account Retention

Date: 2026-08-16
Status: draft, review round 1 folded in
Repos: `magus` (all implementation), `magus-cloud` (config + secrets only)

## Problem

The three unauthenticated endpoints that create accounts or send email have no
abuse protection at all:

1. **Password registration** (`POST /auth/user/password/register` via
   `MagusWeb.OnboardingLive.RegisterLive`): creates a signed-in account with
   free-plan credits immediately. `confirmed_at` stays `nil` until the
   confirmation link is clicked, but nothing gates on it, so an unconfirmed
   account can chat, spend credits, and generate media indefinitely.
2. **Magic-link request** (`request_magic_link` event in
   `MagusWeb.OnboardingLive.SignInLive`): sends mail to any address. With
   `registration_enabled? true`, clicking the link upserts a user
   (`:sign_in_with_magic_link`, listed in `auto_confirm_actions`), so the
   account is created pre-confirmed at first login. That behaviour is correct
   and stays: for magic link, account creation *is* the email proof.
3. **Password-reset request** (`:request_password_reset_token`, submitted from
   the library `AshAuthentication.Phoenix.SignInLive :reset` view): only sends
   mail when the account exists and returns `:ok` either way, so it cannot
   create accounts or enumerate. Its only abuse is mail volume.

Password sign-in has a subtlety that shapes the rate-limit design:
`SignInLive.handle_event("password_sign_in", ...)` runs the sign-in action
via `Form.submit/2` **over the LiveView socket** and only triggers the real
POST to `/auth/user/password/sign_in` on success. Failed brute-force attempts
therefore never hit the HTTP path; enforcement must live in both places.

The only rate limiting in the codebase is `Magus.Integrations.RateLimiter`
(ETS, keyed `{user_id, provider_key, operation}`), which never touches auth.
Its check is a non-atomic lookup-then-insert with a window anchored at the
first request; the extraction below fixes that.

## Scope

Three pieces, one spec, independent implementation plans possible:

- **A. Captcha** (Cloudflare Turnstile) on password registration and
  magic-link request.
- **B. Auth rate limiting** on registration, password sign-in, magic-link
  request, and password-reset request.
- **C. Unconfirmed-account retention**: a reaper for password signups that
  never confirm, plus a gate blocking unconfirmed accounts from agent use.

Non-goals:

- No captcha on password sign-in (rate limiting is the right tool) or
  password-reset request (per-address plus global rate limiting bounds the
  abuse; a captcha adds real friction for locked-out users).
- No change to magic-link auto-confirmation (see Problem, item 2).
- No warning/reminder emails before reaping (explicit product decision:
  every mail costs money).
- No distributed rate-limit store. ETS per node matches prod topology
  (single Fly machine, seconds-long blue/green overlap).

Everything is **config-gated off by default** in core. Self-hosters opt in;
`magus-cloud` turns things on in prod. This keeps the existing test suite
green and imposes no third-party accounts on OSS users.

## Shared plumbing: client IP

**`MagusWeb.ClientIP`** (new helper) resolves the client IP for plugs,
LiveViews, and the captcha `remoteip` parameter.

- HTTP: reads `config :magus, :client_ip_header` (default `nil` meaning use
  `conn.remote_ip`). When set, takes the **first** value of the named header,
  parses it with `:inet.parse_address/1`, and falls back to `conn.remote_ip`
  on absence or malformed input (mirroring `Plug.RewriteOn` semantics).
  Returns an `:inet.ip_address()` tuple; callers needing a string use
  `:inet.ntoa/1`. The header is only trusted when explicitly configured;
  trusting `x-forwarded-for` unconditionally would let attackers pick their
  own rate-limit key. No proxy-IP rewriting exists in the endpoint today,
  and prod runs behind Fly's edge, so `magus-cloud` sets `"fly-client-ip"`.
- LiveView: the `/live` socket currently has `connect_info: [session: ...]`
  only. Add `:peer_data` and `:x_headers` in `MagusWeb.Endpoint` (and the
  cloud endpoint mirrors it), and `ClientIP.from_socket/1` applies the same
  header-vs-peer logic from `get_connect_info/2`. LiveViews capture the IP
  once in `mount` (inside `connected?/1`) and keep it in an assign.

## A. Captcha (Cloudflare Turnstile)

### Why the design looks like this

`RegisterLive` validates in the LiveView but then uses `phx-trigger-action`
to POST the real form to `/auth/user/password/register`; the user is created
by the AshAuthentication controller, not the LiveView. A captcha checked only
in the LiveView would be bypassed by POSTing directly. So verification lives
on the transport that creates the user:

| Path | Token travels via | Verified in |
|---|---|---|
| Password register | form POST to `/auth/user/password/register` | HTTP plug |
| Magic-link request | LiveView event payload | `SignInLive.handle_event/3` |

Turnstile drops its token into a hidden `cf-turnstile-response` input inside
the enclosing form, so both paths get the token with no extra plumbing
(`phx-trigger-action` submits the live DOM form via native
`HTMLFormElement.submit`, hidden third-party inputs included; verified
against `dom_patch.js`). Tokens are single-use; after a failed submit the
widget must be reset.

### Components

**`Magus.Captcha`** (new, `lib/magus/captcha.ex`): public API and behaviour.

```elixir
@callback verify(token :: String.t() | nil, remote_ip :: :inet.ip_address() | nil) ::
            :ok | {:error, :missing_token | :invalid_token | :verification_unavailable}

def enabled?()   # true iff site_key and secret_key are both configured
def site_key()
def verify(token, remote_ip)  # delegates to the configured adapter; :ok when disabled
```

Config:

```elixir
config :magus, :captcha,
  adapter: Magus.Captcha.Turnstile,
  site_key: nil,     # from TURNSTILE_SITE_KEY in runtime.exs
  secret_key: nil    # from TURNSTILE_SECRET_KEY in runtime.exs
```

**Partial configuration is a boot error**: `runtime.exs` raises when exactly
one of the two keys is set. A silently half-configured captcha would fail
open in production, which is worse than failing loudly at deploy time.

**`Magus.Captcha.Turnstile`** (new): POSTs `secret`, `response`, and
`remoteip` (via `:inet.ntoa/1`) to
`https://challenges.cloudflare.com/turnstile/v0/siteverify` via `Req`, 5s
timeout. `success: true` maps to `:ok`. Network failure or non-200 maps to
`{:error, :verification_unavailable}`. (Exact request/response field names
are Cloudflare's published contract; re-check at implementation time, they
are external to this repo.)

**Fail closed.** `:verification_unavailable` rejects the submit with a
"please try again" flash. Signup is not latency-critical, and failing open
hands a bypass to anyone who can induce a timeout. Tests swap the adapter for
a stub via the `:adapter` config key.

**`MagusWeb.CaptchaComponents.captcha/1`** (new function component):
renders nothing when `Captcha.enabled?()` is false. When enabled, renders a
container with `phx-update="ignore"` (LiveView patching would destroy the
widget) and a colocated hook that injects the Turnstile script
(`https://challenges.cloudflare.com/turnstile/v0/api.js`), calls
`turnstile.render()` with the site key, and exposes a reset handler the
LiveViews can trigger via `push_event` after a failed submit. The browser
pipeline's `put_secure_browser_headers` CSP sets only `base-uri` and
`frame-ancestors` (no `script-src`), so the Turnstile script is not blocked
and no CSP change is required.

**`MagusWeb.Plugs.VerifyCaptcha`** (new): mounted so it runs only for
`POST /auth/user/password/register` (a dedicated pipeline wrapping the auth
scope, matching on method + path; the rest of `/auth` is untouched). Reads
`cf-turnstile-response` from `conn.params`, calls `Magus.Captcha.verify/2`
with `ClientIP` output. On failure: 302 redirect to `/register` with a
flash, halt; no user is created. No-op when captcha is disabled.

### LiveView changes

- `RegisterLive`: add `<CaptchaComponents.captcha />` inside the form. The
  plug does the enforcement; the LiveView only hosts the widget.
- `SignInLive` (magic-link form): add the widget inside the magic-link form;
  `handle_event("request_magic_link", ...)` calls `Captcha.verify/2` (with
  the IP captured at mount) before invoking `:request_magic_link`, and on
  failure shows an error flash and pushes the widget-reset event.

## B. Auth rate limiting

### Keying strategies, matched to what each endpoint threatens

- **IP-keyed** for registration and password sign-in: the threat is volume
  from one origin.
- **Email-keyed, enforced inside the Ash action** for the mail-sending
  requests (magic link, password reset): protects a target address from
  bombing regardless of attacker IPs, and action-level enforcement covers
  every transport, including the library reset LiveView we do not control.
- **Global (per-node) caps** on the mail-sending actions: per-email keys do
  not bound aggregate volume when the attacker varies target addresses, and
  the reset action sends a real mail for every existing account it is aimed
  at. A blunt per-node ceiling (`{N, :hour}`) on total magic-link and reset
  sends caps the damage; legitimate traffic is nowhere near it.

### Components

**`Magus.RateLimiting.FixedWindow`** (new): atomic fixed-window counters on
ETS, parameterised by table, key, and `{limit, window}`. Uses
`:ets.update_counter/4` (single atomic op, no lookup-then-insert race) with
the window bucket in the key. This deliberately replaces the current
`Integrations.RateLimiter` mechanics, whose check is racy under concurrency;
that module is refactored onto `FixedWindow` with its public API and limits
unchanged. Fixed window (not sliding) is accurate enough here and is what
the existing code approximates anyway; the burst-at-boundary weakness is
acceptable for these limits.

**`Magus.Accounts.AuthRateLimiter`** (new, own ETS table): exposes
`check(scope, key) :: :ok | {:error, :rate_limited}` with limits from
config:

```elixir
config :magus, :auth_rate_limits,
  enabled: false,
  register: {5, :hour},              # per IP
  sign_in: {10, :minute},            # per IP
  magic_link: {3, :hour},            # per email
  magic_link_global: {100, :hour},   # per node
  password_reset: {3, :hour},        # per email
  password_reset_global: {100, :hour}, # per node
  resend_confirmation: {3, :hour}    # per email (see C)
```

**`MagusWeb.Plugs.AuthRateLimit`** (new): on the same wrapping pipeline as
`VerifyCaptcha`, matching `POST /auth/user/password/register` (scope
`:register`) and `POST /auth/user/password/sign_in` (scope `:sign_in`),
keyed by `ClientIP`. On limit: 302 redirect back to the originating form
with a "too many attempts" flash (no 429; Phoenix redirects are 302, and a
browser form flow wants the flash, not a bare status page). Ordering: rate
limit before captcha, so hammering costs the attacker before we spend a
siteverify call.

**LiveView sign-in enforcement**: the plug alone cannot see failed password
attempts, because `SignInLive` runs `:sign_in_with_password` via
`Form.submit/2` over the socket and only POSTs on success. So
`handle_event("password_sign_in", ...)` checks
`AuthRateLimiter.check(:sign_in, ip)` (IP from the mount-captured assign)
**before** calling `Form.submit/2`, showing a flash on limit. The plug stays
as the backstop for direct scripted POSTs that bypass LiveView entirely.
Both layers share one scope, so attempts through either path consume the
same budget.

**Action-level enforcement**: `:request_magic_link` and
`:request_password_reset_token` currently `run` the library implementations
directly. Each gets a small wrapper implementation
(`Magus.Accounts.User.Actions.RateLimited{MagicLinkRequest,PasswordResetRequest}`)
that checks the per-email scope and the global scope, then delegates to the
library module unchanged.

**Honest UX limits of the wrappers**: our own `SignInLive` magic-link
handler currently ignores the `Ash.run_action/2` result and always reports
"link sent"; it is updated to inspect the result and show a "too many
requests" flash on limit (this leaks nothing: the limit fires whether or not
the account exists). The library reset component, however, swallows action
errors and always shows its generic "if the account exists..." message, so
reset limiting is **silent** from the user's perspective. That is
acceptable: the mail simply is not sent, and the generic message is already
non-committal. Documented here so nobody expects a reset-side error flash.

## C. Unconfirmed-account retention

### What `confirmed_at` means after this change

- Magic-link signups: confirmed at creation (unchanged).
- Password signups: unconfirmed until the emailed link is clicked
  (unchanged mechanically), but now with consequences: no agent use while
  unconfirmed (gate) and deletion after a TTL (reaper).
- Admin-created test accounts (`:admin_create_test_user`) are in
  `auto_confirm_actions`, so they are confirmed at creation and invisible to
  both gate and reaper.
- `confirmed_at IS NULL` therefore means exactly "password signup that never
  proved its address", which is the set to reap.

### The gate

`config :magus, :require_confirmed_email_for_agent_use, false` (cloud sets
`true`).

Enforcement in the agent pre-flight
(`Magus.Agents.Plugins.Support.Preflight`), in **both** turn paths:

- `build_react_signal/3` (new turns), alongside the existing spend-gate
  block. The subject is the **acting member** already computed there
  (`Helpers.acting_user_id/2`, the triggering member with owner fallback,
  per magus-k3at), NOT the conversation owner: in a shared conversation an
  unconfirmed member must not ride on a confirmed owner's status, and the
  spend gate already uses exactly this subject.
- `build_resume_react_signal/2` (mid-turn recovery/resume), which is a
  separate path that skips the new-turn gates and issues its own LLM signal;
  without the check there, an unconfirmed user's interrupted turn would
  resume past the gate.

When enabled and the subject's `confirmed_at` is `nil`, the turn is blocked
via the existing machinery (`settle_blocked_run/2` plus a persisted event
message telling the user to confirm their email). Preflight is the right
choke point: transport-agnostic (SPA, RPC, integrations all funnel through
the agent pipeline) and already owns blocked-turn semantics.

**SPA wiring** (the banner cannot work without this):

- `confirmed_at` is a non-public attribute, so the `current_user` RPC shape
  cannot see it. Add a public boolean calculation `email_confirmed?`
  (`not is_nil(confirmed_at)`) exposed through the typescript layer.
- New `:resend_confirmation` update action on `User`, policy `actor.id ==
  record.id`, exposed via RPC. It generates a fresh confirmation token with
  `AshAuthentication.AddOn.Confirmation.confirmation_token/4` (public API,
  verified: accepts an explicitly built changeset outside the
  monitored-field flow) and invokes the existing
  `SendNewUserConfirmationEmail` sender. Rate-limited per email
  (`:resend_confirmation` scope).
- Workbench banner for `email_confirmed? == false`: "Confirm your email to
  start chatting" plus the resend button. Signed-in browsing, settings, and
  reading existing content stay available; only agent turns are blocked.

### The reaper

AshOban trigger on `User`, mirroring the existing `:consolidate_memories`
shape (update action + dedicated keyset-paginated read; a generic action
would receive only a `primary_key` input and no loaded record, per the
warning already documented on `User`):

```elixir
read :read_for_reaping do
  description "Scheduler read for the unconfirmed-account reaper"
  pagination keyset?: true, required?: false
end

trigger :reap_unconfirmed do
  scheduler_cron "0 * * * *"   # hourly
  action :reap_if_unconfirmed  # update action, receives the loaded user
  read_action :read_for_reaping
  worker_read_action :read_for_reaping
  # 1-day floor keeps fresh signups from generating hourly job churn; the
  # configured TTL (>= 1 day) is re-checked in the action.
  where expr(is_nil(confirmed_at) and inserted_at < ago(1, :day))
  worker_module_name Magus.Accounts.User.Workers.ReapUnconfirmed
  scheduler_module_name Magus.Accounts.User.Schedulers.ReapUnconfirmed
end
```

Config: `config :magus, :unconfirmed_account_ttl_days, nil`. `nil` disables
reaping (core default; self-hosters opt in), `magus-cloud` sets `7`. The
minimum supported value is 1 day (the `where` floor). No warning emails.
Note the scheduler still enqueues no-op jobs for day-old unconfirmed rows
when the TTL is `nil`; the population is small and the action exits
immediately, which we accept for config simplicity.

`:reap_if_unconfirmed` re-checks everything at execution time rather than
trusting the trigger filter: TTL configured, `confirmed_at` still `nil`,
`inserted_at` older than the TTL. Deletion goes through
`Magus.Accounts.AccountDeletion.execute/1`, the existing hard-delete path
(already proven Oban-safe: `DeleteExpiredTestAccounts` calls it today),
which runs the billing lifecycle hook before the transaction.

**Ownership guards** (the `create_org` signup flag means an unconfirmed user
can own real structure):

- *Sole-admin workspaces*: `AccountDeletion` refuses to delete a sole admin.
  If every workspace the user solely administers has no other active member,
  the reaper deletes those workspaces first, then the account. Any such
  workspace with other active members: skip the user, log a warning, never
  orphan a shared structure.
- *Owned organizations*: `organizations.owner_id` is a non-null FK to users
  that `AccountDeletion` does **not** clean up (it removes
  `organization_members` rows only), so an owned org would abort the user
  delete at the FK. Same rule as workspaces: if the user is the only active
  member of an org they own, the reaper deletes the organization (and its
  shared workspace) before the account, going through the organization's
  own teardown so billing hooks run; if the org has other active members,
  skip and warn. The skip-and-warn cases should be rare enough that a log
  line is the right observability; if the logs show volume, that is a
  product problem, not a reaper problem.

## Config summary

| Key | Core default | Cloud prod |
|---|---|---|
| `:captcha` site/secret | `nil` (off; boot error if half-set) | Fly secrets `TURNSTILE_SITE_KEY` / `TURNSTILE_SECRET_KEY` |
| `:auth_rate_limits` `enabled` | `false` | `true` |
| `:client_ip_header` | `nil` | `"fly-client-ip"` |
| `:require_confirmed_email_for_agent_use` | `false` | `true` |
| `:unconfirmed_account_ttl_days` | `nil` (off) | `7` |

All runtime-configurable via `runtime.exs` env vars. `magus-cloud` changes
are limited to `runtime.exs` entries, Fly secrets, the endpoint
`connect_info` mirror, and the `MAGUS_CORE_REF` bump; the wrapper's
mirrored-config note in `config/config.exs` gains the new keys.

## Testing

- `Magus.Captcha`: disabled means `:ok`; stub adapter pass/fail/unavailable;
  fail-closed on `:verification_unavailable`; boot error on half-config.
- `VerifyCaptcha` plug: tokenless POST to the register path creates no user
  and redirects with flash; other `/auth` paths untouched; no-op when
  disabled.
- `FixedWindow`: atomicity under concurrent checks (spawn N tasks, assert
  exactly `limit` succeed); window rollover. Existing
  `Integrations.RateLimiter` tests keep passing after the refactor.
- Plug + LiveView sign-in limits share one budget: attempts split across
  socket events and direct POSTs still cap at the configured limit.
- Action wrappers: per-email and global scopes both enforced; under the
  limit, behavior is identical to the library implementations; magic-link
  LiveView surfaces the limit flash; reset stays silent by design.
- Preflight gate: unconfirmed acting member blocked (new-turn AND resume
  paths) with a persisted event message and no LLM call; confirmed member
  in a shared conversation with an unconfirmed owner is NOT blocked (and
  vice versa: unconfirmed member with confirmed owner IS blocked); gate off
  unchanged.
- `:resend_confirmation`: sends via the existing sender; self-only policy;
  rate-limited.
- Reaper: past-TTL unconfirmed user deleted (with solo workspace and solo
  owned org variants); confirmed or recent users untouched; TTL `nil`
  no-ops; shared workspace/org cases skip and log.
- LiveView: widget renders only when enabled; magic-link submit without a
  valid token is rejected and the widget reset event is pushed.

Everything defaults off, so the existing suite (7116 tests) runs unchanged.

## Rollout

1. Land in core, bump `MAGUS_CORE_REF` in `magus-cloud`, mirror the new
   config keys and endpoint `connect_info`.
2. Set Fly secrets, flip the cloud config flags (captcha + rate limits +
   gate first).
3. Watch: registration conversion (captcha too aggressive?), rate-limit
   flash rates (limits too tight?), preflight block events.
4. Reaper goes last: enable only after the gate has been live for at least
   one TTL window, so existing dormant unconfirmed accounts get one chance
   to confirm via the gate banner before deletion starts.

## Review log

Round 1 (Codex, 2026-08-16): 7 claims checked (5 confirmed, claim 3 refined:
`:admin_create_test_user` is a third create path, admin-only and
auto-confirmed, now covered in section C; claim 6 refuted: reaper reshaped
to update action + paginated read). 14 design findings; all folded:
sign-in brute-force bypass via `Form.submit` (new LiveView-side check),
atomic `FixedWindow` replacing the racy extraction target, gate subject
changed to acting member, resume-path gate added, org-ownership teardown
added to the reaper, `429` wording fixed to 302+flash, half-configured
captcha now a boot error, global mail caps added, ClientIP parsing
specified, CSP claim corrected, SPA wiring (public `email_confirmed?`
calc + RPC resend action) specified, reset-path silent-limit UX documented,
TTL-nil job churn documented.
