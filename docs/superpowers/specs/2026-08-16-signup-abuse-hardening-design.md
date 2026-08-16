# Signup Abuse Hardening: Captcha, Auth Rate Limiting, Unconfirmed-Account Retention

Date: 2026-08-16
Status: reviewed (4 Codex rounds folded), pending user approval
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
  `conn.remote_ip`). When set, takes the **first** value of the named
  header, converts the binary with `String.to_charlist/1` and parses via
  `:inet.parse_address/1` (which takes charlists, not binaries; same as
  `Plug.RewriteOn`), falling back to `conn.remote_ip` on absence or
  malformed input. Returns an `:inet.ip_address()` tuple; callers needing a
  string (the Turnstile `remoteip` form field, session storage) use
  `to_string(:inet.ntoa(ip))`, since `:inet.ntoa/1` returns a charlist.
  The header is only trusted when explicitly configured;
  trusting `x-forwarded-for` unconditionally would let attackers pick their
  own rate-limit key. No proxy-IP rewriting exists in the endpoint today,
  and prod runs behind Fly's edge, so `magus-cloud` sets `"fly-client-ip"`.
- LiveView: `connect_info` cannot deliver the Fly header (`:x_headers` only
  passes `x-`-prefixed names, and `fly-client-ip` is not one), and
  `:peer_data` would only yield the proxy address. Instead, a
  `MagusWeb.Plugs.CaptureClientIP` plug in the `:browser` pipeline,
  **placed after `:fetch_session`** (`put_session/3` raises on an
  unfetched session), resolves the IP on the initial HTTP request and
  stores it in the session;
  LiveViews read it from the session in `mount` and keep it in an assign.
  The value is the IP at page load rather than at event time, which is fine
  for rate-limit keying. No endpoint `connect_info` changes needed.

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

### Library: `phoenix_turnstile` instead of a hand-rolled adapter

The widget/hook/verify layer is not built here; the
[`phoenix_turnstile`](https://hex.pm/packages/phoenix_turnstile) dependency
(MIT, ~55k downloads, `phoenix_live_view ~> 1.0`, deps only castore +
jason, verified against its source at v1.2.0) provides:

- `Turnstile.widget/1` — the widget component, already `phx-update="ignore"`
  with a `phx-hook`, exactly the shape this spec previously described by
  hand; `Turnstile.script/1` for the API script tag; the JS hook ships as
  the `phoenix-turnstile` npm package (registered in `app.js`).
- `Turnstile.verify/2` — server-side siteverify over `:httpc` with proper
  peer verification (castore), accepting the params map (reads
  `"cf-turnstile-response"`, which also settles that open question) and an
  optional remote IP as a tuple, charlist, or string.
- `Turnstile.refresh/2` — `push_event`-based widget reset, covering the
  single-use-token reset requirement on failed submits.
- `Turnstile.Behaviour` — ready-made mocking seam for Mox, which the test
  suite already uses.

**One hazard the wrapper must neutralize**: the library's `site_key/0` and
`secret_key/0` **default to Cloudflare's always-pass test keys** when
unconfigured. Deployed with a missing secret, every verification would
silently succeed. So `Magus.Captcha.enabled?/0` is decided by OUR config
(`:magus, :captcha`), never by the library's; the library config is set
from ours at runtime only when both keys are present, and the existing
boot validation (raise on half-configuration) is what stands between a
missing Fly secret and a silently open signup.

### Components

**`Magus.Captcha`** (new, `lib/magus/captcha.ex`): thin wrapper — public
API, enabled-gating, and error classification.

```elixir
@callback verify(params :: map(), remote_ip :: :inet.ip_address() | nil) ::
            :ok | {:error, :missing_token | :invalid_token | :verification_unavailable}

def enabled?()   # true iff OUR site_key and secret_key are both configured
def site_key()
def verify(params, remote_ip)  # :ok when disabled; else classify Turnstile.verify/2
```

Config:

```elixir
config :magus, :captcha,
  impl: Turnstile,   # swapped for a Mox mock of Turnstile.Behaviour in tests
  site_key: nil,     # from TURNSTILE_SITE_KEY in runtime.exs
  secret_key: nil    # from TURNSTILE_SECRET_KEY in runtime.exs
```

**Partial configuration is a boot error**: `runtime.exs` raises when exactly
one of the two keys is set. A silently half-configured captcha would fail
open in production, which is worse than failing loudly at deploy time (and
doubly important given the library's always-pass default keys). When both
keys are present, `runtime.exs` also sets `:phoenix_turnstile`'s
`site_key`/`secret_key` from the same values.

`verify/2` returns `:ok` when disabled; when enabled it delegates to
`Turnstile.verify/2` (passing the raw params map, from which the library
reads `"cf-turnstile-response"`) and classifies the result: `success: true`
maps to `:ok`, a Cloudflare error body to `{:error, :invalid_token}`, and
an `:httpc` transport error or non-200 to
`{:error, :verification_unavailable}`.

**Fail closed.** `:verification_unavailable` rejects the submit with a
"please try again" flash. Signup is not latency-critical, and failing open
hands a bypass to anyone who can induce a timeout. Tests swap `Turnstile`
for a Mox mock of `Turnstile.Behaviour` via the `:impl` config key.

**`MagusWeb.CaptchaComponents.captcha/1`** (new function component):
renders nothing when `Captcha.enabled?()` is false; when enabled, renders
`Turnstile.script/1` + `Turnstile.widget/1` (the library component already
handles `phx-update="ignore"` and the hook; the hook itself is imported
from the `phoenix-turnstile` npm package in `app.js`). Widget reset after
a failed submit is the library's `Turnstile.refresh/2`. The browser
pipeline's `put_secure_browser_headers` CSP sets only `base-uri` and
`frame-ancestors` (no `script-src`), so the Turnstile script is not blocked
and no CSP change is required.

**`MagusWeb.Plugs.VerifyCaptcha`** (new): mounted so it runs only for
`POST /auth/user/password/register` (a dedicated pipeline wrapping the auth
scope, matching on method + path; the rest of `/auth` is untouched). Passes
`conn.params` and the `ClientIP` output to `Magus.Captcha.verify/2` (the
library reads `"cf-turnstile-response"` from the params map itself). On
failure: 302 redirect to `/register` with a
flash, halt; no user is created. No-op when captcha is disabled.

### LiveView changes

- `RegisterLive`: add `<CaptchaComponents.captcha />` inside the form. The
  plug does the enforcement; the LiveView only hosts the widget.
- `SignInLive` (magic-link form): add the widget inside the magic-link form;
  `handle_event("request_magic_link", ...)` calls `Captcha.verify/2` (with
  the IP captured at mount) before invoking `:request_magic_link`. The
  widget-reset event is pushed on **every** non-success outcome, not just
  captcha failure: a valid token followed by a rate-limit error from the
  action wrapper is also consumed (tokens are single-use), and without a
  reset the retry would fail on a stale token.

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

Because the window bucket is part of the key, expired buckets accumulate:
every distinct (key, bucket) pair an attacker touches is a row. So the
table lifecycle is explicit: each owning GenServer creates its named public
table and runs a periodic sweep (5 min) deleting expired rows, the same
shape as `Integrations.RateLimiter`'s existing cleanup timer. One table
mixes minute and hour windows, so a bare bucket index cannot tell the
sweeper what "expired" means; the key is
`{scope, key, window_ms, bucket_index}`, and a row is expired when
`(bucket_index + 1) * window_ms <= now`.

**`Magus.Accounts.AuthRateLimiter`** (new GenServer, own ETS table,
supervised in `Magus.Application` alongside `Integrations.RateLimiter`):
exposes `check(scope, key) :: :ok | {:error, :rate_limited}` with limits
from config:

```elixir
config :magus, :auth_rate_limits,
  enabled: false,
  register: {5, :hour},              # per IP
  sign_in: {20, :minute},            # per IP; see double-count note below
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
same budget. Known double-count: a *successful* UI sign-in consumes two
units (the LiveView check plus the triggered POST hitting the plug); failed
attempts, the case that matters, consume one. Distinguishing "the POST that
LiveView itself triggered" from a scripted POST would need a signed
one-shot marker, which is not worth it; the limit is sized ({20, :minute})
so ten successful logins per minute per IP still fit (relevant for NATed
offices).

**Action-level enforcement**: `:request_magic_link` and
`:request_password_reset_token` currently `run` the library implementations
directly. Each gets a small wrapper implementation
(`Magus.Accounts.User.Actions.RateLimited{MagicLinkRequest,PasswordResetRequest}`)
that checks the per-email scope and the global scope, then delegates to the
library module unchanged. One asymmetry: the **magic-link** wrapper consumes
the global budget on every request, because the library sends mail for
unknown addresses too (`registration_enabled?`). The **reset** wrapper must
NOT: the library sends nothing for unknown addresses, so consuming the
global budget up front would let an attacker exhaust it with arbitrary
nonexistent emails and deny resets to real users. The reset wrapper
therefore performs its own `get_by_email` lookup first; unknown address
means return `:ok` silently without touching the global counter (identical
external response, and the library does the same lookup anyway), known
address means consume per-email + global, then delegate.

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
(`Magus.Agents.Plugins.Support.Preflight`), in `build_react_signal/3` (new
turns), alongside the existing spend-gate block. The subject is the
**acting member** already computed there (`Helpers.acting_user_id/2`, the
triggering member with owner fallback, per magus-k3at), NOT the
conversation owner: in a shared conversation an unconfirmed member must not
ride on a confirmed owner's status, and the spend gate already uses exactly
this subject.

The resume path (`build_resume_react_signal/2`) deliberately gets **no**
gate: resume signals carry no acting-user identity (only reason and task
counts, see `SubAgent.Resumer`), so a resume-path check could only test the
state owner, which is the wrong subject in shared conversations. And it is
unnecessary: an unconfirmed member's turn is blocked at `build_react_signal`
before any work starts, so there is never a gated user's turn in flight to
resume. A turn that is resumable already passed the gate at initiation;
letting it finish after a mid-turn config flip is the correct behaviour
anyway.

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
  (`:resend_confirmation` scope). **Guarded to unconfirmed users only**
  (validation: `confirmed_at` is nil, otherwise a no-op success): without
  the guard, an already-confirmed user could mint a fresh confirmation
  token and re-run `:confirm`, whose change chain includes
  `SendWelcomeEmail`.
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
  # Time-dependent filter: the matching set changes between batches, which
  # is exactly the case ash_oban documents for :full_read over keyset.
  stream_with :full_read
  # 1-day floor keeps fresh signups from generating hourly job churn; the
  # configured TTL (>= 1 day) is re-checked in the action.
  where expr(is_nil(confirmed_at) and inserted_at < ago(1, :day))
  worker_module_name Magus.Accounts.User.Workers.ReapUnconfirmed
  scheduler_module_name Magus.Accounts.User.Schedulers.ReapUnconfirmed
end
```

The action follows the `:trigger_memory_consolidation` shape:
`accept []`, `transaction? false`, `require_atomic? false`, with the work
in an `after_action` hook. The transaction opt-out matters, not just the
shape: `AccountDeletion.execute/1` runs external cleanup (billing lifecycle
hook) *before* opening its own repo transaction, and wrapping the whole
action in Ash's default update transaction would pull that external call
and the nested delete inside an outer transaction.

**The reap race and the claim lease.** `transaction? false` also means no
work transaction and no `FOR UPDATE` lock, so between the worker reading
`confirmed_at == nil` and the delete, the user could click their
confirmation link; deleting a just-confirmed account is unacceptable. The
claim must be a CAS **on both sides**, and it must be releasable:

1. New attribute `reap_claimed_at :: utc_datetime_usec` (internal, not
   public). After the ownership skip-checks pass, the worker claims via a
   filtered atomic update: set `reap_claimed_at = now()` where
   `confirmed_at IS NULL AND (reap_claimed_at IS NULL OR reap_claimed_at <
   now() - lease)` with a 15-minute lease. Zero rows claimed means the
   user confirmed (or another claim is live): exit as a no-op.
2. The `:confirm` guard is NOT a pre-write validation: AshAuthentication
   loads the user before writing, so a validation would check a stale
   read and pass. The guard is a **database-level update filter on the
   confirm write itself** (`Ash.Changeset.filter/2`-style, matching
   `confirmed_at IS NULL`-era semantics: the UPDATE carries
   `WHERE reap_claimed_at IS NULL OR reap_claimed_at < now() - lease`).
   A confirm racing a fresh claim matches zero rows and surfaces as
   "this confirmation link has expired"; a confirm racing a *stale*
   claim (crashed worker) succeeds. Both interleavings of claim-vs-confirm
   are then correct, whichever UPDATE commits first.
3. **Release on every non-deleted outcome**: if `AccountDeletion` refuses
   (preflight), the lifecycle hook aborts, or the delete transaction
   fails, the worker clears `reap_claimed_at` in a rescue/after so the
   user can confirm again and later runs can re-evaluate. If the worker
   crashes before releasing, the lease expiry (point 1 and 2) restores
   both confirmability and reclaimability after 15 minutes; no janitor
   process needed.

Config: `config :magus, :unconfirmed_account_ttl_days, nil`. `nil` disables
reaping (core default; self-hosters opt in), `magus-cloud` sets `7`.
Validated at boot in `runtime.exs`: `nil` or an integer `>= 1` (the `where`
floor makes smaller values silently behave as 1 day, so they are rejected
loudly instead). No warning emails. Note the scheduler still enqueues no-op
jobs for day-old unconfirmed rows when the TTL is `nil`; the population is
small and the action exits immediately, which we accept for config
simplicity.

`:reap_if_unconfirmed` re-checks everything at execution time rather than
trusting the trigger filter: TTL configured, `confirmed_at` still `nil`,
`inserted_at` older than the TTL. Deletion goes through
`Magus.Accounts.AccountDeletion.execute/1`, the existing hard-delete path
(already proven Oban-safe: `DeleteExpiredTestAccounts` calls it today),
which runs the billing lifecycle hook before the transaction.

**Ownership guards** (the `create_org` signup flag means an unconfirmed user
can own real structure): **v1 reaps only users with no owned structure.**
The reaper skips, with a log warning, any user who:

- *owns an organization*: `organizations.owner_id` is a non-null FK to
  users that `AccountDeletion` does not clean up (it removes
  `organization_members` rows only), so an owned org would abort the user
  delete at the FK. No hard-delete path for organizations exists to
  delegate to: `Organization` exposes only the soft-delete `:archive`, and
  the archived row keeps its `owner_id`.
- *is sole admin of any workspace*: this is exactly the condition
  `AccountDeletion.preflight/1` refuses. Earlier revisions tried to
  tear such workspaces down inside the reaper; review showed every
  variant of that either races member activation (an invite accepted
  between the "no other members" check and the hard delete destroys a
  now-shared workspace), commits workspace deletion outside the account
  delete transaction (org-FK abort then leaves a user without their
  workspaces), or requires restructuring `AccountDeletion`'s
  hook-before-any-write guarantee. Deleting other people's potential
  data on a background job is the wrong place to be clever.

The skip means such rows are never reaped in v1; a beads follow-up tracks
proper structure teardown. With the agent-use gate on, unconfirmed users
are largely inert, so the skipped population should be near zero; if the
logs show volume, unconfirmed structure creation is a product problem,
not a reaper problem. `AccountDeletion.execute/1` is used **unchanged**,
and its sole-admin preflight refusal doubles as the definitive
last-moment guard behind the advisory skip-checks. All of the reaper's
ownership and membership lookups run with `authorize?: false`: there is
no human actor in the Oban context, and the user-facing policies (e.g.
organization reads require an active member actor) would silently hide
exactly the rows the guards must see. This matches how
`AccountDeletion`'s own preflight already queries.

## Config summary

| Key | Core default | Cloud prod |
|---|---|---|
| `:captcha` site/secret | `nil` (off; boot error if half-set) | Fly secrets `TURNSTILE_SITE_KEY` / `TURNSTILE_SECRET_KEY` |
| `:auth_rate_limits` `enabled` | `false` | `true` |
| `:client_ip_header` | `nil` | `"fly-client-ip"` |
| `:require_confirmed_email_for_agent_use` | `false` | `true` |
| `:unconfirmed_account_ttl_days` | `nil` (off) | `7` |

All runtime-configurable via `runtime.exs` env vars. `magus-cloud` changes
are limited to `runtime.exs` entries, Fly secrets, and the
`MAGUS_CORE_REF` bump; the wrapper's mirrored-config note in
`config/config.exs` gains the new keys.

## Testing

- `Magus.Captcha`: disabled means `:ok`; Mox mock pass/fail/unavailable;
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
  LiveView surfaces the limit flash; reset stays silent by design; reset
  requests for nonexistent addresses do NOT consume the global budget.
- Preflight gate: unconfirmed acting member blocked on new turns with a
  persisted event message and no LLM call; confirmed member in a shared
  conversation with an unconfirmed owner is NOT blocked (and vice versa:
  unconfirmed member with confirmed owner IS blocked); resume path
  unaffected; gate off unchanged.
- `:resend_confirmation`: sends via the existing sender; self-only policy;
  rate-limited; no-op for already-confirmed users (no welcome-email
  replay).
- Reaper: past-TTL unconfirmed user with no owned structure deleted;
  confirmed or recent users untouched; TTL `nil` no-ops; org owners and
  sole-admin workspace holders skip and log; TTL `0` rejected at boot.
- Claim lease: confirm-vs-claim CAS in both orders (fresh claim rejects
  confirm at the UPDATE filter; committed confirm defeats the claim);
  stale lease is confirmable AND reclaimable; claim released on preflight
  refusal / hook abort / delete failure.
- LiveView: widget renders only when enabled; magic-link submit without a
  valid token is rejected and the widget reset event is pushed.

Everything defaults off, so the existing suite (7116 tests) runs unchanged.

## Rollout

1. Land in core, bump `MAGUS_CORE_REF` in `magus-cloud`, mirror the new
   config keys.
2. Set Fly secrets, flip the cloud config flags (captcha + rate limits +
   gate first).
3. Watch: registration conversion (captcha too aggressive?), rate-limit
   flash rates (limits too tight?), preflight block events.
4. Reaper goes last: enable only after the gate has been live for at least
   one TTL window, so existing dormant unconfirmed accounts get one chance
   to confirm via the gate banner before deletion starts.

## Remaining external checks at implementation time

Everything codebase-internal was verified across the four review rounds
(see Review log). Two externals remain, both implementation details rather
than design risks:

1. ~~Turnstile siteverify request/response field names and the exact
   hidden-input name~~ — resolved by adopting `phoenix_turnstile` v1.2.0,
   whose source implements the siteverify contract and reads
   `"cf-turnstile-response"` (verified 2026-08-16).
2. The exact Ash 3 API for attaching a database-level filter to the
   confirm UPDATE (the CAS in the claim-lease design); the capability
   exists (optimistic-lock-style filtered updates), the call shape should
   be confirmed against the installed Ash version.

## Review log

Library check (2026-08-16, post-review): hex.pm searched for existing
Turnstile integrations before building one. `phoenix_turnstile` v1.2.0
(jsonmaur, MIT, ~55k downloads, `phoenix_live_view ~> 1.0`, deps castore +
jason only) adopted after source verification: it provides the widget
component (already `phx-update="ignore"` + hook), the siteverify call
(`:httpc` with castore peer verification), the refresh push-event for
single-use-token reset, and a `Turnstile.Behaviour` Mox seam — replacing
the previously specced hand-rolled `Magus.Captcha.Turnstile` adapter,
custom component, and colocated hook. `Magus.Captcha` remains as a thin
enabled-gating/classification wrapper; notably the library defaults to
Cloudflare's always-pass test keys when unconfigured, so enablement is
decided exclusively by our config and the half-config boot error stays.
Alternatives rejected: `ex_turnstile` 0.1.0 (verification only, 290
downloads), `omni_captcha` 0.0.4 (602 downloads, pre-1.0).

Round 4 (Codex, 2026-08-16, final): five blockers, all in the reaper's
workspace-teardown machinery; resolved by simplification rather than more
machinery. v1 reaper scope narrowed to users with no owned structure
(skip org owners AND sole-admin workspace holders), which deletes the
`after_lifecycle_hook` restructuring, the workspace teardown, and their
three races (member-activation vs hard-delete, teardown outside the
delete transaction, preflight-refusal ordering) outright;
`AccountDeletion.execute/1` is now used unchanged. The confirm guard was
strengthened from a pre-write validation (checks a stale load, per
AshAuthentication's read-then-write) to a database-level filter on the
confirm UPDATE, making claim-vs-confirm a two-sided CAS; the claim
became a 15-minute lease, released on every non-deleted outcome and
expiring on worker crash, so no user is ever left permanently
unconfirmable.

Round 3 (Codex, 2026-08-16): all round-2 folds confirmed; CSP pushback
accepted (round-2 #14 cited nonexistent file paths; Phoenix default CSP has
no `script-src`). New findings folded: charlist/binary conversions
specified for `:inet.parse_address/1` and `:inet.ntoa/1`;
`CaptureClientIP` explicitly ordered after `:fetch_session`; obsolete
`connect_info` rollout mention removed; fixed-window keys now carry
`window_ms` so the sweeper can compute expiry across mixed windows; reap
race closed with an atomic `reap_claimed_at` claim plus a `:confirm`
validation (residual org-creation race documented as a benign FK
rollback); workspace teardown moved behind the billing lifecycle hook via
a new `AccountDeletion.execute/2` `after_lifecycle_hook` option; reaper
ownership lookups specified as `authorize?: false` (no human actor in the
Oban context).

Round 2 (Codex, 2026-08-16): 9 of 14 round-1 folds confirmed resolved. New
findings folded: `FixedWindow`/`AuthRateLimiter` ETS lifecycle (owned named
table, supervised, periodic expired-bucket sweep); org teardown claim was
wrong (no `Organization` destroy action exists; v1 now skips org owners
outright with a follow-up for real teardown, and workspace deletion is
ordered before any deactivation with the user as still-active actor);
reaper action declared `transaction? false` / `require_atomic? false`
(external billing hook must not run inside an Ash update transaction);
resume-path gate REMOVED rather than fixed (resume signals carry no acting
user; nothing gated can be in flight to resume); reset wrapper no longer
consumes the global budget for nonexistent addresses (global-cap DoS);
LiveView client IP moved from `connect_info` (`:x_headers` cannot carry
`fly-client-ip`) to a session-capture plug; `stream_with :full_read` on
the time-dependent trigger; widget reset extended to wrapper errors;
resend guarded to unconfirmed users (welcome-email replay); TTL boot
validation (`nil` or `>= 1`); sign-in limit raised to {20, :minute} with
the successful-login double-count documented. Round-2 finding 14 (CSP
`script-src 'self'`) was checked and is a misread: `core_pipelines`
calls `put_secure_browser_headers` with no arguments, so the Phoenix
default applies (no `script-src`), as round 1 correctly found; the spec
text stands.

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
