# Signup Abuse Hardening: Captcha, Auth Rate Limiting, Unconfirmed-Account Retention

Date: 2026-08-16
Status: draft, pending review
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
   create accounts or enumerate. Its only abuse is mail-bombing a known
   address.

The only rate limiting in the codebase is `Magus.Integrations.RateLimiter`
(ETS sliding window, keyed `{user_id, provider_key, operation}`), which never
touches auth.

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
  password-reset request (per-address rate limiting protects the victim;
  a captcha adds one solve per send and real friction for locked-out users).
- No change to magic-link auto-confirmation (see Problem, item 2).
- No warning/reminder emails before reaping (explicit product decision:
  every mail costs money).
- No distributed rate-limit store. ETS per node matches prod topology
  (single Fly machine, seconds-long blue/green overlap).

Everything is **config-gated off by default** in core. Self-hosters opt in;
`magus-cloud` turns things on in prod. This keeps the existing test suite
green and imposes no third-party accounts on OSS users.

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
the enclosing form, so both paths get the token with no extra plumbing.
Tokens are single-use; after a failed submit the widget must be reset.

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

**`Magus.Captcha.Turnstile`** (new): POSTs `secret`, `response`, and
`remoteip` to `https://challenges.cloudflare.com/turnstile/v0/siteverify`
via `Req`, short timeout (5s). `success: true` maps to `:ok`. Network
failure or non-200 maps to `{:error, :verification_unavailable}`.

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
LiveViews can trigger via `push_event` after a failed submit. No CSP exists
in the app today, so no CSP change is needed.

**`MagusWeb.Plugs.VerifyCaptcha`** (new): mounted so it runs only for
`POST /auth/user/password/register` (a dedicated pipeline wrapping the auth
scope, matching on method + path; the rest of `/auth` is untouched). Reads
`cf-turnstile-response` from `conn.params`, calls `Magus.Captcha.verify/2`
with the resolved client IP (see B). On failure: redirect to `/register`
with a flash, halt; no user is created. No-op when captcha is disabled.

### LiveView changes

- `RegisterLive`: add `<CaptchaComponents.captcha />` inside the form. The
  plug does the enforcement; the LiveView only hosts the widget.
- `SignInLive` (magic-link form): add the widget inside the magic-link form;
  `handle_event("request_magic_link", ...)` calls `Captcha.verify/2` before
  invoking `:request_magic_link`, and pushes the reset event on failure.
  The client IP is not available on the LiveView socket today; pass `nil`
  as `remoteip` (the Turnstile `remoteip` parameter is optional).

## B. Auth rate limiting

### Two keying strategies, matched to what each endpoint threatens

- **IP-keyed** where the request is a plain HTTP POST and the threat is
  volume from one origin: registration, password sign-in.
- **Email-keyed, enforced inside the Ash action** where the endpoint sends
  mail to a target address and the transport varies: magic-link request and
  password-reset request. Action-level enforcement covers every caller,
  including the library reset LiveView we do not control; this is why the
  reset path needs no custom LiveView (dropping the one genuinely new
  surface from the earlier captcha-everything design). The victim of mail
  bombing is the target address, so per-address limits protect them
  regardless of how many IPs the attacker has.

### Components

**`Magus.RateLimiting.SlidingWindow`** (new): the generic ETS sliding-window
mechanics extracted from `Magus.Integrations.RateLimiter`, parameterised by
table name, key, and `{limit, window}`. `Integrations.RateLimiter` is
refactored to use it with behaviour unchanged; its public API and limits
stay as they are.

**`Magus.Accounts.AuthRateLimiter`** (new GenServer, own ETS table): thin
wrapper exposing `check(scope, key) :: :ok | {:error, :rate_limited}` with
limits from config:

```elixir
config :magus, :auth_rate_limits,
  enabled: false,
  register: {5, :hour},          # per IP
  sign_in: {10, :minute},        # per IP
  magic_link: {3, :hour},        # per email
  password_reset: {3, :hour},    # per email
  resend_confirmation: {3, :hour} # per email (see C)
```

**`MagusWeb.ClientIP`** (new helper): resolves the client IP for both the
plug and the captcha `remoteip`. Reads a configured trusted header
(`config :magus, :client_ip_header`, default `nil` meaning use
`conn.remote_ip`). No proxy-IP rewriting exists in the endpoint today, and
prod runs behind Fly's edge, so `conn.remote_ip` is the Fly proxy;
`magus-cloud` sets the header to `"fly-client-ip"`. Only the first value of
the header is used, and only when the config opts in (trusting
`x-forwarded-for` unconditionally would let attackers spoof their key).

**`MagusWeb.Plugs.AuthRateLimit`** (new): on the same wrapping pipeline as
`VerifyCaptcha`, matching `POST /auth/user/password/register` (scope
`:register`) and `POST /auth/user/password/sign_in` (scope `:sign_in`),
keyed by resolved client IP. On limit: 429 with a flash redirect back to
the originating form. Ordering: rate limit before captcha, so hammering
costs the attacker before we spend a siteverify call.

**Action-level enforcement**: `:request_magic_link` and
`:request_password_reset_token` currently `run` the library implementations
directly. Each gets a small wrapper implementation
(`Magus.Accounts.User.Actions.RateLimited{MagicLinkRequest,PasswordResetRequest}`)
that checks `AuthRateLimiter.check(scope, email)` and then delegates to the
library module unchanged. On limit they return an error the calling
LiveViews surface as a "too many requests, try again later" flash. This is
deliberate honest feedback: the limit fires whether or not the account
exists, so it leaks nothing about account existence.

## C. Unconfirmed-account retention

### What `confirmed_at` means after this change

- Magic-link signups: confirmed at creation (unchanged).
- Password signups: unconfirmed until the emailed link is clicked
  (unchanged mechanically), but now with consequences: no agent use while
  unconfirmed (gate) and deletion after a TTL (reaper).
- `confirmed_at IS NULL` therefore means exactly "password signup that never
  proved its address", which is the set to reap.

### The gate

`config :magus, :require_confirmed_email_for_agent_use, false` (cloud sets
`true`).

Enforcement in the agent pre-flight
(`Magus.Agents.Plugins.Support.Preflight`, alongside the existing gates in
`build_react_signal_after_gates/…`): when enabled and the conversation
owner's `confirmed_at` is `nil`, the turn is blocked and a persisted event
message tells the user to confirm their email. Preflight is the right
choke point: it is transport-agnostic (SPA, RPC, integrations all funnel
through the agent pipeline) and already has the blocked-turn machinery
(`settle_blocked_run/2`, persisted event messages).

UI: the SPA workbench shows a banner when the current user is unconfirmed
("Confirm your email to start chatting"), with a resend button backed by a
new `:resend_confirmation` action on `User` (rate-limited per email, see B).
The action generates a fresh confirmation token for the `:confirm_new_user`
add-on and invokes the existing sender
`SendNewUserConfirmationEmail`. Signed-in browsing, settings, and reading
existing content stay available; only agent turns are blocked.

### The reaper

AshOban trigger on `User` (per project convention, `ash_oban` rather than a
bare Oban worker):

```elixir
trigger :reap_unconfirmed do
  scheduler_cron "0 * * * *"   # hourly
  action :reap_if_unconfirmed
  where expr(is_nil(confirmed_at))
  worker_module_name __MODULE__.ReapUnconfirmed.Worker
  scheduler_module_name __MODULE__.ReapUnconfirmed.Scheduler
end
```

Config: `config :magus, :unconfirmed_account_ttl_days, nil`. `nil` disables
reaping entirely (core default; self-hosters must opt in). Cloud sets `7`.
No warning emails at any point.

`:reap_if_unconfirmed` (generic/update action) re-checks everything at
execution time rather than trusting the trigger filter: TTL configured,
`confirmed_at` still `nil`, `inserted_at` older than the TTL. It then
delegates deletion to `Magus.Accounts.AccountDeletion.execute/1`, the
existing hard-delete path, which already runs the billing lifecycle hook
before the transaction and cleans up owned resources.

**Sole-admin guard interaction**: `AccountDeletion` refuses to delete a user
who is the sole admin of any workspace, and the `create_org` signup flag
means an unconfirmed user can be exactly that. The reaper handles the case
explicitly: if every workspace the user solely administers has no other
active member, delete those workspaces first, then the account. If any such
workspace has other active members (should not happen for a never-confirmed
account), skip the user and log a warning; never orphan a shared workspace.

## Config summary

| Key | Core default | Cloud prod |
|---|---|---|
| `:captcha` site/secret | `nil` (off) | Fly secrets `TURNSTILE_SITE_KEY` / `TURNSTILE_SECRET_KEY` |
| `:auth_rate_limits` `enabled` | `false` | `true` |
| `:client_ip_header` | `nil` | `"fly-client-ip"` |
| `:require_confirmed_email_for_agent_use` | `false` | `true` |
| `:unconfirmed_account_ttl_days` | `nil` (off) | `7` |

All runtime-configurable via `runtime.exs` env vars. `magus-cloud` changes
are limited to `runtime.exs` entries, Fly secrets, and the `MAGUS_CORE_REF`
bump; the wrapper's mirrored-config note in `config/config.exs` gains the
new keys.

## Testing

- `Magus.Captcha`: disabled means `:ok`; stub adapter pass/fail/unavailable;
  fail-closed on `:verification_unavailable`.
- `VerifyCaptcha` plug: tokenless POST to the register path creates no user
  and redirects with flash; other `/auth` paths untouched; no-op when
  disabled.
- `AuthRateLimiter`: window mechanics via the extracted `SlidingWindow`
  (existing `Integrations.RateLimiter` tests keep passing after the
  extraction).
- Action wrappers: magic-link and reset requests over the limit return the
  rate-limit error and send nothing; under the limit behave identically to
  the library implementations.
- Preflight gate: unconfirmed owner with gate on produces a blocked event
  message and no LLM call; gate off unchanged; confirmed users unchanged.
- Reaper: past-TTL unconfirmed user is deleted (with solo workspace);
  confirmed or recent users untouched; TTL `nil` deletes nothing;
  shared-workspace edge case skips and logs.
- LiveView: widget renders only when enabled; magic-link submit without a
  valid token is rejected and the widget reset event is pushed.

Everything defaults off, so the existing suite (7116 tests) runs unchanged.

## Rollout

1. Land in core, bump `MAGUS_CORE_REF` in `magus-cloud`, mirror the new
   config keys.
2. Set Fly secrets, flip the cloud config flags.
3. Watch: registration conversion (captcha too aggressive?), 429 rates
   (limits too tight?), reaper logs for the first TTL window.
4. Reaper goes last: enable only after the gate has been live for at least
   one TTL window, so existing dormant unconfirmed accounts get one chance
   to confirm via the gate banner before deletion starts.

## Claims to verify in review

1. Turnstile siteverify request/response shape and the exact hidden-input
   name (`cf-turnstile-response`).
2. Mechanism for generating a fresh confirmation token for an
   AshAuthentication confirmation add-on outside the monitored-field flow
   (the `:resend_confirmation` action's feasibility as described).
3. Password and magic link are the only registration paths on `User` (the
   OAuth routes in the router serve workbench integrations and MCP, not
   sign-up).
4. The library reset form (`AshAuthentication.Phoenix.SignInLive :reset`)
   funnels through `:request_password_reset_token`, so the action-level
   wrapper covers it.
5. `phx-trigger-action` submits the full form including hidden inputs added
   by third-party scripts (the Turnstile token reaches the plug).
6. AshOban trigger + generic action shape for the reaper matches the
   `ash_oban` usage rules (`where` expr on a scheduler, per-record worker).
7. `AccountDeletion.execute/1` is safe to call from an Oban worker context
   (no LiveView/session assumptions).
