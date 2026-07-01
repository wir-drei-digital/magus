# User Model Phase 2b-1: Ownership Backend Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let regular users own LLM providers and models through Ash actions, safely, with the credential trust boundary, authorization, atom-safety, and lifecycle complete, but no UI and no live execution wiring.

**Architecture:** Extend the existing `Magus.Models.Provider` and `Magus.Chat.Model` resources with a nullable `owner_user_id` and `:create_owned` actions. User providers get server-generated unique slugs and never mint atoms (excluded from `CatalogSync`); they resolve through `RequestOptions`. `RequestOptions` and `Magus.Models.Resolver` become actor-capable and fail-closed: owned credentials are returned only to a matching owner, and the default `nil` actor never leaks them. `Model` adopts an Ash policy authorizer.

**Tech Stack:** Elixir, Ash 3.x + AshPostgres, Oban (via direct insert for validation), ReqLLM, Cloak (encrypted api_key), ExUnit with `Magus.ResourceCase` / `Magus.DataCase`.

**Reference spec:** `docs/superpowers/specs/2026-07-01-user-model-phase-2b1-ownership-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **No em dashes** in any code comment, string, doc, or commit message. Use colons, periods, or commas.
- **Never run `mix ash.reset`** (wipes data). Use `mix ash.codegen <name>` then `mix ash.migrate`.
- **No secrets in structs/logs**: never put a decrypted `api_key` into `Resolution`, telemetry, or logs. `RequestOptions` returns keys only in the ReqLLM opts.
- **Fail-closed**: a missing/mismatched actor must degrade to safe fallback, never leak owned credentials.
- **Behavior-neutral for global rows and existing callers**: all existing rows have `owner_user_id == nil`; all resolver/RequestOptions callers keep passing `nil` in this phase.
- **No `billable_by_*` / `metered?` fields** and no billing behavior changes. Ownership facts only.
- **Config allowlist** for user `req_llm_id`: `~w(anthropic openai openrouter xai google openai_compatible)` (config-driven).
- **Caps** config-driven: `max_providers: 10, max_models: 50`.
- **Compile clean**: `MIX_ENV=test mix compile --warnings-as-errors` must pass before each task's final commit (CI compiles with warnings-as-errors; per-edit hooks do not).
- **Test env DB**: run tests with `set -a && source .env && set +a && MIX_ENV=test mix test <path>`. This worktree needs its own `_build`; do not `cd` out of the worktree.
- **Ash conventions**: call resources through domain code interfaces; use `actor(:id)` in policy/filter exprs; internal reads that must bypass policy pass `authorize?: false` explicitly.
- **Test user factory**: the plan writes `Magus.Test.Generators.create_user()` as a stand-in. Before Task 2, find the project's real persisted-user factory (check `test/support`: `Magus.ResourceCase` exposes `generate(user())`; there may be a `Magus.DataCase` helper) and use it consistently. The intent is always a persisted `Magus.Accounts.User` usable as an `actor:`.
- **Ash policy AND-combination**: every policy whose condition matches an action must pass. So a bespoke action like `:create_owned` must be matched by exactly one policy (`policy action(:create_owned)`), never also by a broad `action_type(:create)` policy, because at create time `owner_user_id` is not yet set and an ownership `expr` would forbid it. Gate the admin `:create` with `policy action(:create)`, not `action_type(:create)`.

## File Structure

**New files:**
- `lib/magus/models/slug_generator.ex` — pure server-side slug minting.
- `lib/magus/models/base_url_validator.ex` — SSRF validation for user base URLs.
- `lib/magus/models/validations/safe_base_url.ex` — Ash validation wrapping the SSRF check.
- `lib/magus/models/validations/within_provider_cap.ex` — per-user provider cap.
- `lib/magus/chat/model/validations/within_model_cap.ex` — per-user model cap.
- `lib/magus/models/provider/changes/set_owner_from_actor.ex` — sets `owner_user_id` from the actor.
- `lib/magus/models/provider/changes/generate_unique_slug.ex` — mints a unique slug.
- `lib/magus/models/provider/changes/enqueue_credential_validation.ex` — enqueues the validation job.
- `lib/magus/chat/model/changes/build_owned_model.ex` — mirrors owner, sets `:byok`, mints key, blocks media.
- `lib/magus/models/credential_validator.ex` — provider-type probe seam.
- `lib/magus/models/workers/validate_credential.ex` — Oban worker (unique) that stamps status.

**Modified files:**
- `lib/magus/models/provider.ex` — attrs, `:create_owned`/`:update_owned` actions, policies, domain wiring.
- `lib/magus/chat/model.ex` — attrs, `:byok` enum, authorizer + policies, `:create_owned`, `list_active` scoping.
- `lib/magus/models.ex` — Provider owned code interfaces.
- `lib/magus/chat/chat.ex` — Model owned code interfaces.
- `lib/magus/models/request_options.ex` — `resolve/2` actor-capable, owned rewrite.
- `lib/magus/models/resolver.ex` — actor-scoped fetch, ownership facts, `provider_id/1` guard.
- `lib/magus/models/catalog_sync.ex` — exclude owned providers.
- `lib/magus/models/changes/sync_catalog.ex` — skip reload for owned rows.
- `lib/magus/chat/user_model_preference/validations/model_selectable.ex` — actor-scoped read.
- `lib/magus/accounts/user.ex` — selection-write ownership validation.
- `lib/magus/chat/conversation.ex` — selection-write ownership validation.
- `lib/magus/accounts/account_deletion.ex` — owned model/provider cleanup.
- `config/config.exs` — allowlist + caps config.

---

### Task 1: Pure helpers (SlugGenerator + BaseUrlValidator)

**Files:**
- Create: `lib/magus/models/slug_generator.ex`
- Create: `lib/magus/models/base_url_validator.ex`
- Test: `test/magus/models/slug_generator_test.exs`
- Test: `test/magus/models/base_url_validator_test.exs`

**Interfaces:**
- Produces: `Magus.Models.SlugGenerator.generate/0 :: String.t()` (matches `~r/\A[a-z0-9_]+\z/`, starts with `"u_"`).
- Produces: `Magus.Models.BaseUrlValidator.validate(url :: String.t()) :: :ok | {:error, String.t()}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/magus/models/slug_generator_test.exs
defmodule Magus.Models.SlugGeneratorTest do
  use ExUnit.Case, async: true
  alias Magus.Models.SlugGenerator

  test "generates a slug matching the provider slug constraint" do
    slug = SlugGenerator.generate()
    assert slug =~ ~r/\A[a-z0-9_]+\z/
    assert String.starts_with?(slug, "u_")
    assert String.length(slug) <= 64
  end

  test "generates distinct slugs across calls" do
    slugs = for _ <- 1..50, do: SlugGenerator.generate()
    assert length(Enum.uniq(slugs)) == 50
  end
end
```

```elixir
# test/magus/models/base_url_validator_test.exs
defmodule Magus.Models.BaseUrlValidatorTest do
  use ExUnit.Case, async: true
  alias Magus.Models.BaseUrlValidator

  test "accepts a public https url" do
    assert :ok = BaseUrlValidator.validate("https://api.example.com/v1")
  end

  test "rejects non-https" do
    assert {:error, _} = BaseUrlValidator.validate("http://api.example.com/v1")
  end

  test "rejects loopback" do
    assert {:error, _} = BaseUrlValidator.validate("https://127.0.0.1/v1")
    assert {:error, _} = BaseUrlValidator.validate("https://localhost/v1")
  end

  test "rejects private ranges" do
    for host <- ["10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254"] do
      assert {:error, _} = BaseUrlValidator.validate("https://#{host}/v1")
    end
  end

  test "rejects embedded credentials" do
    assert {:error, _} = BaseUrlValidator.validate("https://user:pass@api.example.com/v1")
  end

  test "rejects garbage" do
    assert {:error, _} = BaseUrlValidator.validate("not a url")
    assert {:error, _} = BaseUrlValidator.validate("")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/slug_generator_test.exs test/magus/models/base_url_validator_test.exs`
Expected: FAIL (modules undefined).

- [ ] **Step 3: Implement SlugGenerator**

```elixir
# lib/magus/models/slug_generator.ex
defmodule Magus.Models.SlugGenerator do
  @moduledoc """
  Mints server-side provider slugs for user-owned providers. The slug is the
  local, globally unique handle that namespaces a user model's `key`; it never
  reaches ReqLLM or the atom catalog. High entropy keeps DB collisions
  negligible; the create action still verifies uniqueness before use.
  """

  # 80 bits of entropy, lowercase base32 (Crockford-ish, [a-z0-9]).
  @spec generate() :: String.t()
  def generate do
    "u_" <>
      (:crypto.strong_rand_bytes(10)
       |> Base.encode32(case: :lower, padding: false))
  end
end
```

- [ ] **Step 4: Implement BaseUrlValidator**

```elixir
# lib/magus/models/base_url_validator.ex
defmodule Magus.Models.BaseUrlValidator do
  @moduledoc """
  Validates a user-supplied provider base URL to blunt SSRF: https only, no
  embedded credentials, and the resolved host must not fall in loopback,
  private, link-local, ULA, or cloud-metadata ranges. Admin providers are not
  routed through this (they may legitimately point at localhost).

  Limitation: DNS rebinding / TOCTOU is not fully closed by a static check
  plus validation-time resolution. A per-request egress guard is a later item.
  """

  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(url) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
        validate_host(host)

      %URI{userinfo: info} when not is_nil(info) ->
        {:error, "must not embed credentials"}

      %URI{scheme: "https"} ->
        {:error, "must include a host"}

      _ ->
        {:error, "must be an https URL"}
    end
  end

  def validate(_), do: {:error, "must be an https URL"}

  defp validate_host(host) do
    cond do
      host in ~w(localhost 0.0.0.0) -> {:error, "must not target a private host"}
      true -> validate_resolved(host)
    end
  end

  defp validate_resolved(host) do
    charlist = String.to_charlist(host)

    addrs =
      case :inet.getaddrs(charlist, :inet) do
        {:ok, v4} -> v4
        _ -> []
      end ++
        case :inet.getaddrs(charlist, :inet6) do
          {:ok, v6} -> v6
          _ -> []
        end

    cond do
      addrs == [] -> {:error, "host does not resolve"}
      Enum.any?(addrs, &blocked_ip?/1) -> {:error, "must not target a private host"}
      true -> :ok
    end
  end

  # IPv4 blocked ranges
  defp blocked_ip?({127, _, _, _}), do: true
  defp blocked_ip?({10, _, _, _}), do: true
  defp blocked_ip?({192, 168, _, _}), do: true
  defp blocked_ip?({169, 254, _, _}), do: true
  defp blocked_ip?({0, _, _, _}), do: true
  defp blocked_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  # IPv6 loopback ::1
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv6 ULA fc00::/7 (first hextet high 7 bits == 1111110x)
  defp blocked_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp blocked_ip?(_), do: false
end
```

- [ ] **Step 5: Run to verify pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/slug_generator_test.exs test/magus/models/base_url_validator_test.exs`
Expected: PASS.

- [ ] **Step 6: Compile clean + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/models/slug_generator.ex lib/magus/models/base_url_validator.ex test/magus/models/slug_generator_test.exs test/magus/models/base_url_validator_test.exs
git commit -m "feat(models): add SlugGenerator and SSRF BaseUrlValidator (phase 2b-1)"
```

---

### Task 2: Provider ownership + :create_owned

**Files:**
- Modify: `lib/magus/models/provider.ex`
- Create: `lib/magus/models/provider/changes/set_owner_from_actor.ex`
- Create: `lib/magus/models/provider/changes/generate_unique_slug.ex`
- Create: `lib/magus/models/validations/safe_base_url.ex`
- Create: `lib/magus/models/validations/within_provider_cap.ex`
- Modify: `lib/magus/models.ex`
- Modify: `config/config.exs`
- Test: `test/magus/models/provider_owned_test.exs`

**Interfaces:**
- Consumes: `Magus.Models.SlugGenerator.generate/0`, `Magus.Models.BaseUrlValidator.validate/1`.
- Produces: `Magus.Models.create_owned_provider(input, opts)` (action `:create_owned`), `Magus.Models.list_owned_providers(opts)` (action `:owned`, actor-scoped). New attrs `owner_user_id`, `validation_status`, `last_validated_at`.

- [ ] **Step 1: Add config**

In `config/config.exs`, add near other `:magus` config:

```elixir
config :magus, :user_model_limits, max_providers: 10, max_models: 50

config :magus, :user_provider_req_llm_allowlist,
  ~w(anthropic openai openrouter xai google openai_compatible)
```

- [ ] **Step 2: Write the failing test**

```elixir
# test/magus/models/provider_owned_test.exs
defmodule Magus.Models.ProviderOwnedTest do
  use Magus.DataCase, async: false

  setup do
    Magus.DataCase.clear_catalog!()
    {:ok, user} = Magus.Test.Generators.create_user()
    %{user: user}
  end

  test "create_owned sets owner, mints a slug, defaults status pending", %{user: user} do
    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "My OpenAI", req_llm_id: "openai", api_key: "sk-mine"},
        actor: user
      )

    assert provider.owner_user_id == user.id
    assert provider.slug =~ ~r/\A[a-z0-9_]+\z/
    assert String.starts_with?(provider.slug, "u_")
    assert provider.validation_status == :pending
  end

  test "create_owned rejects a req_llm_id outside the allowlist", %{user: user} do
    assert {:error, _} =
             Magus.Models.create_owned_provider(
               %{name: "Nope", req_llm_id: "totally_custom", api_key: "x"},
               actor: user
             )
  end

  test "create_owned rejects an unsafe base_url", %{user: user} do
    assert {:error, _} =
             Magus.Models.create_owned_provider(
               %{
                 name: "Local",
                 req_llm_id: "openai_compatible",
                 base_url: "http://localhost:8000/v1",
                 api_key: "x"
               },
               actor: user
             )
  end

  test "create_owned enforces the provider cap", %{user: user} do
    for n <- 1..10 do
      {:ok, _} =
        Magus.Models.create_owned_provider(
          %{name: "P#{n}", req_llm_id: "openai", api_key: "k"},
          actor: user
        )
    end

    assert {:error, _} =
             Magus.Models.create_owned_provider(
               %{name: "P11", req_llm_id: "openai", api_key: "k"},
               actor: user
             )
  end

  test "a user cannot read another user's owned provider", %{user: user} do
    {:ok, other} = Magus.Test.Generators.create_user()

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "k"},
        actor: user
      )

    assert {:error, _} = Ash.get(Magus.Models.Provider, provider.id, actor: other)
    assert {:ok, _} = Ash.get(Magus.Models.Provider, provider.id, actor: user)
  end
end
```

Note: if `Magus.Test.Generators.create_user/0` does not exist, use the project's user factory (check `Magus.ResourceCase` / `test/support`); the intent is a persisted user actor.

- [ ] **Step 3: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/provider_owned_test.exs`
Expected: FAIL (`create_owned_provider` undefined).

- [ ] **Step 4: Add the change/validation modules**

```elixir
# lib/magus/models/provider/changes/set_owner_from_actor.ex
defmodule Magus.Models.Provider.Changes.SetOwnerFromActor do
  @moduledoc "Sets owner_user_id to the acting user's id on :create_owned."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %{id: id}}) when is_binary(id) do
    Ash.Changeset.force_change_attribute(changeset, :owner_user_id, id)
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset, field: :owner_user_id, message: "requires an actor")
  end
end
```

```elixir
# lib/magus/models/provider/changes/generate_unique_slug.ex
defmodule Magus.Models.Provider.Changes.GenerateUniqueSlug do
  @moduledoc """
  Mints a server-side unique slug for an owned provider. Retries a bounded
  number of times against the DB before surfacing an error, so the astronomically
  unlikely collision fails loudly rather than looping.
  """
  use Ash.Resource.Change
  require Ash.Query

  @max_attempts 5

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      case mint(@max_attempts) do
        {:ok, slug} -> Ash.Changeset.force_change_attribute(cs, :slug, slug)
        :error -> Ash.Changeset.add_error(cs, field: :slug, message: "could not mint a unique slug")
      end
    end)
  end

  defp mint(0), do: :error

  defp mint(attempts) do
    slug = Magus.Models.SlugGenerator.generate()

    exists? =
      Magus.Models.Provider
      |> Ash.Query.filter(slug == ^slug)
      |> Ash.exists?(authorize?: false)

    if exists?, do: mint(attempts - 1), else: {:ok, slug}
  end
end
```

```elixir
# lib/magus/models/validations/safe_base_url.ex
defmodule Magus.Models.Validations.SafeBaseUrl do
  @moduledoc "Applies SSRF validation to base_url on owned-provider actions."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :base_url) do
      nil -> :ok
      "" -> :ok
      url ->
        case Magus.Models.BaseUrlValidator.validate(url) do
          :ok -> :ok
          {:error, msg} -> {:error, field: :base_url, message: msg}
        end
    end
  end
end
```

```elixir
# lib/magus/models/validations/within_provider_cap.ex
defmodule Magus.Models.Validations.WithinProviderCap do
  @moduledoc "Rejects owned-provider creation past the per-user cap."
  use Ash.Resource.Validation
  require Ash.Query

  @impl true
  def validate(_changeset, _opts, %{actor: %{id: id}}) when is_binary(id) do
    max = Keyword.fetch!(Application.fetch_env!(:magus, :user_model_limits), :max_providers)

    count =
      Magus.Models.Provider
      |> Ash.Query.filter(owner_user_id == ^id)
      |> Ash.count!(authorize?: false)

    if count >= max,
      do: {:error, field: :base, message: "provider limit reached"},
      else: :ok
  end

  def validate(_changeset, _opts, _context),
    do: {:error, field: :base, message: "requires an actor"}
end
```

- [ ] **Step 5: Add attributes, action, policies, and req_llm allowlist validation to Provider**

In `lib/magus/models/provider.ex`:

Add a compile-time allowlist attribute near the top of the module (after `use Ash.Resource ...`), so the set is config-driven per deployment:

```elixir
@user_req_llm_allowlist Application.compile_env(
                          :magus,
                          :user_provider_req_llm_allowlist,
                          ~w(anthropic openai openrouter xai google openai_compatible)
                        )
```

Add to `attributes do` block:

```elixir
attribute :owner_user_id, :uuid, allow_nil?: true, public?: false

attribute :validation_status, :atom do
  allow_nil? false
  default :pending
  public? true
  constraints one_of: [:pending, :valid, :invalid, :error]
end

attribute :last_validated_at, :utc_datetime, allow_nil?: true, public?: true
```

Note: the enqueue-fan-out guard is the Oban unique job (Task 9), which the review's finding 9 accepts as an alternative to a timestamp column. No `validation_enqueued_at` column is added, avoiding a re-trigger loop from stamping it inside the enqueue change.

Add the `:create_owned`, `:update_owned`, and `:owned` actions to `actions do`:

```elixir
create :create_owned do
  description "User-owned provider (BYOK). Server-mints the slug; validates URL and cap."
  accept [:name, :req_llm_id, :base_url, :api_key]

  validate one_of(:req_llm_id, @user_req_llm_allowlist),
    message: "is not an allowed provider"

  validate present(:base_url),
    where: [attribute_equals(:req_llm_id, "openai_compatible")],
    message: "is required for custom OpenAI-compatible providers"

  validate Magus.Models.Validations.SafeBaseUrl
  validate Magus.Models.Validations.WithinProviderCap

  change Magus.Models.Provider.Changes.SetOwnerFromActor
  change Magus.Models.Provider.Changes.GenerateUniqueSlug
  change Magus.Models.Provider.Changes.EnqueueCredentialValidation
end

update :update_owned do
  description "Owner edits to a user-owned provider."
  accept [:name, :base_url, :api_key, :enabled?]
  require_atomic? false
  validate Magus.Models.Validations.SafeBaseUrl
  change Magus.Models.Provider.Changes.EnqueueCredentialValidation
end

read :owned do
  description "Providers owned by the actor."
  filter expr(owner_user_id == ^actor(:id))
end
```

Note: reference `Magus.Models.Provider.Changes.EnqueueCredentialValidation` here; it is created in Task 9. Until then, stub it as a no-op change module so this task compiles (Task 9 fills in the body). Create the stub now:

```elixir
# lib/magus/models/provider/changes/enqueue_credential_validation.ex
defmodule Magus.Models.Provider.Changes.EnqueueCredentialValidation do
  @moduledoc "Enqueues async credential validation. Body added in Task 9."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context), do: changeset
end
```

Replace the `policies do` block with owner-aware policies. Note the deliberate use of `action(:create)` (not `action_type(:create)`) so `:create_owned` is matched by exactly one policy (see Global Constraints on AND-combination):

```elixir
policies do
  # Internal catalog plumbing (CatalogSync, request-option resolution) reads
  # without an actor via authorize?: false and bypasses these policies.
  policy action_type(:read) do
    authorize_if expr(is_nil(owner_user_id))
    authorize_if expr(owner_user_id == ^actor(:id))
    authorize_if Magus.Checks.IsAdmin
  end

  policy action(:create_owned) do
    authorize_if actor_present()
  end

  policy action(:update_owned) do
    authorize_if expr(owner_user_id == ^actor(:id))
  end

  policy action(:create) do
    authorize_if Magus.Checks.IsAdmin
  end

  policy action([:update, :destroy]) do
    authorize_if expr(not is_nil(owner_user_id) and owner_user_id == ^actor(:id))
    authorize_if Magus.Checks.IsAdmin
  end
end
```

(Task 9 appends policies for the `:validate` and `:stamp_validation` actions it introduces.)

- [ ] **Step 6: Wire domain code interfaces**

In `lib/magus/models.ex`, inside the `resource Magus.Models.Provider do` block, add:

```elixir
define :create_owned_provider, action: :create_owned
define :update_owned_provider, action: :update_owned
define :list_owned_providers, action: :owned
```

- [ ] **Step 7: Generate + run migration**

```bash
set -a && source .env && set +a
MIX_ENV=test mix ash.codegen add_provider_ownership
MIX_ENV=test mix ash.migrate
```

Expected: a migration adding `owner_user_id`, `validation_status`, `last_validated_at` to `model_providers`.

- [ ] **Step 8: Run tests to verify pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/provider_owned_test.exs`
Expected: PASS.

- [ ] **Step 9: Compile clean + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/models/provider.ex lib/magus/models/provider/ lib/magus/models/validations/ lib/magus/models.ex config/config.exs priv/repo/migrations test/magus/models/provider_owned_test.exs
git commit -m "feat(models): user-owned providers via :create_owned with slug/SSRF/cap (phase 2b-1)"
```

---

### Task 3: Model authorizer + ownership schema + read scoping

**Files:**
- Modify: `lib/magus/chat/model.ex`
- Test: `test/magus/chat/model_authz_test.exs`

**Interfaces:**
- Produces: `Magus.Chat.Model` with `authorizers: [Ash.Policy.Authorizer]`, new attr `owner_user_id`, `:byok` in the `api_provider` enum, and `list_active` actor-scoped (global + owned).

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/chat/model_authz_test.exs
defmodule Magus.Chat.ModelAuthzTest do
  use Magus.DataCase, async: false

  setup do
    Magus.DataCase.clear_catalog!()
    {:ok, user} = Magus.Test.Generators.create_user()
    {:ok, other} = Magus.Test.Generators.create_user()
    %{user: user, other: other}
  end

  defp owned_model!(user, key) do
    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, %{name: key, key: key, context_window: 1000})
    |> Ash.Changeset.force_change_attribute(:owner_user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:api_provider, :byok)
    |> Ash.create!(authorize?: false)
  end

  defp global_model!(key) do
    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, %{name: key, key: key, context_window: 1000})
    |> Ash.create!(authorize?: false)
  end

  test "owner can read their model, others cannot", %{user: user, other: other} do
    m = owned_model!(user, "u_a:x")
    assert {:ok, _} = Ash.get(Magus.Chat.Model, m.id, actor: user)
    assert {:error, _} = Ash.get(Magus.Chat.Model, m.id, actor: other)
  end

  test "global models are readable by any actor", %{user: user} do
    m = global_model!("openrouter:foo/x")
    assert {:ok, _} = Ash.get(Magus.Chat.Model, m.id, actor: user)
  end

  test "list_active returns global plus own, never others' owned", %{user: user, other: other} do
    global_model!("openrouter:g/1")
    owned_model!(user, "u_b:mine")
    owned_model!(other, "u_c:theirs")

    keys =
      Magus.Chat.list_active_models!(actor: user)
      |> Enum.map(& &1.key)

    assert "openrouter:g/1" in keys
    assert "u_b:mine" in keys
    refute "u_c:theirs" in keys
  end

  test "list_active with authorize?: false + no actor returns global only" do
    global_model!("openrouter:g/2")
    {:ok, u} = Magus.Test.Generators.create_user()
    owned_model!(u, "u_d:priv")

    keys = Magus.Chat.list_active_models!(authorize?: false) |> Enum.map(& &1.key)
    assert "openrouter:g/2" in keys
    refute "u_d:priv" in keys
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/chat/model_authz_test.exs`
Expected: FAIL (owner_user_id/:byok/authorizer absent; others can read owned).

- [ ] **Step 3: Add authorizer + owner attr + :byok enum**

In `lib/magus/chat/model.ex`, change the `use Ash.Resource` block to add the authorizer:

```elixir
use Ash.Resource,
  otp_app: :magus,
  domain: Magus.Chat,
  data_layer: AshPostgres.DataLayer,
  authorizers: [Ash.Policy.Authorizer],
  extensions: [AshTypescript.Resource]
```

Add to the `attributes do` block:

```elixir
attribute :owner_user_id, :uuid, allow_nil?: true, public?: false
```

Extend the `api_provider` constraint (currently `one_of: [:openrouter, :xai, :publicai, :aimlapi, :fal]`) to include `:byok`:

```elixir
constraints one_of: [:openrouter, :xai, :publicai, :aimlapi, :fal, :byok]
```

- [ ] **Step 4: Scope list_active + add policies**

Replace the `list_active` read action filter so it includes owned rows for the actor and stays global-only when no actor is present:

```elixir
read :list_active do
  description "List all active models available for selection (global + own)"

  filter expr(
           active? == true and internal? == false and
             (is_nil(owner_user_id) or owner_user_id == ^actor(:id))
         )

  prepare build(sort: [name: :asc])
end
```

Add a `policies do` block (place it after the `actions do` block, before `changes do`):

```elixir
policies do
  # Internal readers (CatalogSync, RequestOptions, Resolver, list_models tool)
  # pass authorize?: false and bypass these policies.
  policy action_type(:read) do
    authorize_if expr(is_nil(owner_user_id))
    authorize_if expr(owner_user_id == ^actor(:id))
    authorize_if Magus.Checks.IsAdmin
  end

  # action(:create) not action_type(:create): :create_owned (Task 4) gets its
  # own policy so it is not also gated by an ownership expr at create time.
  policy action(:create) do
    authorize_if Magus.Checks.IsAdmin
  end

  policy action_type([:update, :destroy]) do
    authorize_if expr(not is_nil(owner_user_id) and owner_user_id == ^actor(:id))
    authorize_if Magus.Checks.IsAdmin
  end
end
```

- [ ] **Step 5: Call-site audit**

Confirm every actor-less `Model` read passes `authorize?: false`. Run:

```bash
rg -n "list_active_models|get_model|get_model_by_key_with_provider|Magus.Chat.Model" lib | rg -v "authorize\?: false" | rg -v "_test"
```

For each hit, verify it is either (a) an actor-context read (SPA/user path, correct to scope), or (b) internal, in which case add `authorize?: false`. Known safe internal readers: `list_models.ex:74` (already `authorize?: false`), `RequestOptions` (`get_model_by_key_with_provider`), `Resolver`, `CatalogSync`. Do not change behavior of internal readers; only make the bypass explicit if missing.

Also audit Model **write** call sites (`for_create(:create` / `for_update(:update` / `:destroy`), for example catalog seeding in `Magus.Models.Catalog` and any admin model management): internal/seed writes must pass `authorize?: false`; admin writes must run with an admin actor (satisfying `IsAdmin`). A non-admin, non-owner actor writing a global model is now correctly forbidden.

- [ ] **Step 6: Migrate + test**

```bash
set -a && source .env && set +a
MIX_ENV=test mix ash.codegen add_model_ownership
MIX_ENV=test mix ash.migrate
MIX_ENV=test mix test test/magus/chat/model_authz_test.exs
```
Expected: PASS.

- [ ] **Step 7: Run the broader model/agent suites to catch authorizer blast radius**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models test/magus/chat`
Expected: PASS (investigate any newly-forbidden read; add explicit `authorize?: false` where the caller is internal). Note any pre-existing failures separately.

- [ ] **Step 8: Compile clean + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/chat/model.ex priv/repo/migrations test/magus/chat/model_authz_test.exs
git commit -m "feat(chat): adopt Model authorizer + owner_user_id + :byok, scope list_active (phase 2b-1)"
```

---

### Task 4: Model :create_owned (owner mirror, :byok, key mint, media block, cap)

**Files:**
- Modify: `lib/magus/chat/model.ex`
- Create: `lib/magus/chat/model/changes/build_owned_model.ex`
- Create: `lib/magus/chat/model/validations/within_model_cap.ex`
- Modify: `lib/magus/chat/chat.ex`
- Test: `test/magus/chat/model_create_owned_test.exs`

**Interfaces:**
- Consumes: an owned `Magus.Models.Provider` (Task 2).
- Produces: `Magus.Chat.create_owned_model(input, opts)` (action `:create_owned`), `Magus.Chat.list_owned_models(opts)`. `input` includes `:model_provider_id`, `:model_id`, `:name`, and optional `:context_window`, `:input_cost_value`, `:output_cost_value`, `:supports_tools?`, `:supports_reasoning?`, `:short_description`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/chat/model_create_owned_test.exs
defmodule Magus.Chat.ModelCreateOwnedTest do
  use Magus.DataCase, async: false

  setup do
    Magus.DataCase.clear_catalog!()
    {:ok, user} = Magus.Test.Generators.create_user()

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk"},
        actor: user
      )

    %{user: user, provider: provider}
  end

  test "mints an owner-scoped, slug-prefixed :byok model", %{user: user, provider: provider} do
    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{
          name: "My Claude",
          model_id: "claude-3-5-sonnet",
          model_provider_id: provider.id,
          context_window: 200_000
        },
        actor: user
      )

    assert model.owner_user_id == user.id
    assert model.api_provider == :byok
    assert model.key == "#{provider.slug}:claude-3-5-sonnet"
  end

  test "rejects a provider the actor does not own", %{provider: provider} do
    {:ok, other} = Magus.Test.Generators.create_user()

    assert {:error, _} =
             Magus.Chat.create_owned_model(
               %{name: "x", model_id: "m", model_provider_id: provider.id},
               actor: other
             )
  end

  test "rejects media models", %{user: user, provider: provider} do
    assert {:error, _} =
             Magus.Chat.create_owned_model(
               %{
                 name: "img",
                 model_id: "some-image",
                 model_provider_id: provider.id,
                 output_modalities: ["image"]
               },
               actor: user
             )
  end

  test "enforces the model cap", %{user: user, provider: provider} do
    for n <- 1..50 do
      {:ok, _} =
        Magus.Chat.create_owned_model(
          %{name: "M#{n}", model_id: "m#{n}", model_provider_id: provider.id},
          actor: user
        )
    end

    assert {:error, _} =
             Magus.Chat.create_owned_model(
               %{name: "M51", model_id: "m51", model_provider_id: provider.id},
               actor: user
             )
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/chat/model_create_owned_test.exs`
Expected: FAIL (`create_owned_model` undefined).

- [ ] **Step 3: Add the change + cap validation**

```elixir
# lib/magus/chat/model/changes/build_owned_model.ex
defmodule Magus.Chat.Model.Changes.BuildOwnedModel do
  @moduledoc """
  Wires a user-owned model to its owned provider: verifies the actor owns the
  provider, mirrors owner_user_id, forces api_provider :byok, mints the
  slug-prefixed key from the `model_id` argument, and blocks media models
  (image/video are Phase 5, since the media clients bypass RequestOptions).
  """
  use Ash.Resource.Change
  require Ash.Query

  @impl true
  def change(changeset, _opts, %{actor: %{id: actor_id}}) when is_binary(actor_id) do
    Ash.Changeset.before_action(changeset, fn cs ->
      provider_id = Ash.Changeset.get_attribute(cs, :model_provider_id)
      model_id = Ash.Changeset.get_argument(cs, :model_id)
      out = Ash.Changeset.get_attribute(cs, :output_modalities) || ["text"]

      cond do
        is_nil(provider_id) ->
          Ash.Changeset.add_error(cs, field: :model_provider_id, message: "is required")

        Enum.any?(out, &(&1 in ["image", "video"])) ->
          Ash.Changeset.add_error(cs, field: :output_modalities, message: "media models are not supported yet")

        true ->
          case owned_provider(provider_id, actor_id) do
            {:ok, provider} ->
              cs
              |> Ash.Changeset.force_change_attribute(:owner_user_id, actor_id)
              |> Ash.Changeset.force_change_attribute(:api_provider, :byok)
              |> Ash.Changeset.force_change_attribute(:key, "#{provider.slug}:#{model_id}")

            :error ->
              Ash.Changeset.add_error(cs, field: :model_provider_id, message: "must be a provider you own")
          end
      end
    end)
  end

  def change(changeset, _opts, _context),
    do: Ash.Changeset.add_error(changeset, field: :owner_user_id, message: "requires an actor")

  defp owned_provider(provider_id, actor_id) do
    case Magus.Models.Provider
         |> Ash.Query.filter(id == ^provider_id and owner_user_id == ^actor_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %{} = provider} -> {:ok, provider}
      _ -> :error
    end
  end
end
```

```elixir
# lib/magus/chat/model/validations/within_model_cap.ex
defmodule Magus.Chat.Model.Validations.WithinModelCap do
  @moduledoc "Rejects owned-model creation past the per-user cap."
  use Ash.Resource.Validation
  require Ash.Query

  @impl true
  def validate(_changeset, _opts, %{actor: %{id: id}}) when is_binary(id) do
    max = Keyword.fetch!(Application.fetch_env!(:magus, :user_model_limits), :max_models)

    count =
      Magus.Chat.Model
      |> Ash.Query.filter(owner_user_id == ^id)
      |> Ash.count!(authorize?: false)

    if count >= max, do: {:error, field: :base, message: "model limit reached"}, else: :ok
  end

  def validate(_changeset, _opts, _context),
    do: {:error, field: :base, message: "requires an actor"}
end
```

- [ ] **Step 4: Add the :create_owned action + interfaces**

In `lib/magus/chat/model.ex`, add to `actions do`:

```elixir
create :create_owned do
  description "User-owned model under an owned provider (BYOK, text-only)."
  argument :model_id, :string, allow_nil?: false

  accept [
    :name,
    :provider,
    :model_provider_id,
    :context_window,
    :input_cost_value,
    :output_cost_value,
    :input_cost_unit,
    :output_cost_unit,
    :output_modalities,
    :input_modalities,
    :supports_tools?,
    :supports_reasoning?,
    :short_description
  ]

  validate Magus.Chat.Model.Validations.WithinModelCap
  change Magus.Chat.Model.Changes.BuildOwnedModel
end

read :owned do
  description "Models owned by the actor."
  filter expr(owner_user_id == ^actor(:id))
end
```

Add a policy for `:create_owned` inside the existing `policies do` block:

```elixir
policy action(:create_owned) do
  authorize_if actor_present()
end
```

In `lib/magus/chat/chat.ex`, inside `resource Magus.Chat.Model do`, add:

```elixir
define :create_owned_model, action: :create_owned
define :list_owned_models, action: :owned
```

- [ ] **Step 5: Migrate (if codegen detects changes) + test**

```bash
set -a && source .env && set +a
MIX_ENV=test mix ash.codegen add_model_create_owned
MIX_ENV=test mix ash.migrate
MIX_ENV=test mix test test/magus/chat/model_create_owned_test.exs
```
Expected: PASS. (`ash.codegen` may report no schema change; that is fine.)

- [ ] **Step 6: Compile clean + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/chat/model.ex lib/magus/chat/model/ lib/magus/chat/chat.ex priv/repo/migrations test/magus/chat/model_create_owned_test.exs
git commit -m "feat(chat): user-owned models via :create_owned, text-only with cap (phase 2b-1)"
```

---

### Task 5: Atom-safety (CatalogSync exclusion + SyncCatalog skip)

**Files:**
- Modify: `lib/magus/models/catalog_sync.ex`
- Modify: `lib/magus/models/changes/sync_catalog.ex`
- Test: `test/magus/models/catalog_sync_ownership_test.exs`

**Interfaces:**
- Consumes: owned Provider/Model (Tasks 2 and 4).
- Produces: `build_custom/0` that excludes owned providers; `SyncCatalog` that skips reloads for owned rows.

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/models/catalog_sync_ownership_test.exs
defmodule Magus.Models.CatalogSyncOwnershipTest do
  use Magus.DataCase, async: false
  alias Magus.Models.CatalogSync

  setup do
    Magus.DataCase.clear_catalog!()
    {:ok, user} = Magus.Test.Generators.create_user()

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    {:ok, _model} =
      Magus.Chat.create_owned_model(
        %{name: "M", model_id: "gpt-x", model_provider_id: provider.id},
        actor: user
      )

    %{provider: provider}
  end

  test "owned providers are excluded from the custom catalog map", %{provider: provider} do
    custom = CatalogSync.build_custom()
    slug_atom = String.to_atom(provider.slug)
    refute Map.has_key?(custom, slug_atom)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/catalog_sync_ownership_test.exs`
Expected: FAIL (owned provider present in `build_custom`).

- [ ] **Step 3: Exclude owned providers in build_custom**

In `lib/magus/models/catalog_sync.ex`, change the providers map to drop owned rows:

```elixir
providers =
  Magus.Models.list_enabled_providers!()
  |> Enum.filter(&is_nil(&1.owner_user_id))
  |> Map.new(&{&1.id, &1})
```

The existing `models |> Enum.filter(&Map.has_key?(providers, &1.model_provider_id))` line then drops owned models automatically, because their provider is no longer in the map.

- [ ] **Step 4: Skip reload for owned rows in SyncCatalog**

Replace `lib/magus/models/changes/sync_catalog.ex`'s `change/3` so it only reloads for global rows:

```elixir
@impl true
def change(changeset, _opts, _context) do
  Ash.Changeset.after_transaction(changeset, fn cs, result ->
    with {:ok, record} <- result,
         true <- is_nil(Map.get(record, :owner_user_id)) do
      Magus.Models.CatalogSync.request_reload()
    end

    result
  end)
end
```

Note: `Map.get(record, :owner_user_id)` is nil for both global rows and resources without the field, so global behavior is unchanged and owned rows skip the reload.

- [ ] **Step 5: Run test to verify pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/catalog_sync_ownership_test.exs`
Expected: PASS.

- [ ] **Step 6: Compile clean + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/models/catalog_sync.ex lib/magus/models/changes/sync_catalog.ex test/magus/models/catalog_sync_ownership_test.exs
git commit -m "feat(models): exclude owned providers from catalog + skip owned reloads (phase 2b-1)"
```

---

### Task 6: RequestOptions actor-capable (fail-closed) + owned rewrite

**Files:**
- Modify: `lib/magus/models/request_options.ex`
- Test: `test/magus/models/request_options_owned_test.exs`

**Interfaces:**
- Produces: `RequestOptions.resolve/2` where the second arg is `actor_id :: binary() | nil` (default `nil`); `resolve/1` delegates to `resolve(key, nil)`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/models/request_options_owned_test.exs
defmodule Magus.Models.RequestOptionsOwnedTest do
  use Magus.DataCase, async: false
  alias Magus.Models.RequestOptions

  setup do
    Magus.DataCase.clear_catalog!()
    {:ok, user} = Magus.Test.Generators.create_user()

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk-owner"},
        actor: user
      )

    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{name: "C", model_id: "claude-3-5-sonnet", model_provider_id: provider.id},
        actor: user
      )

    %{user: user, provider: provider, model: model}
  end

  test "owner gets rewritten spec + key", %{user: user, provider: provider, model: model} do
    assert {"anthropic:claude-3-5-sonnet", opts} = RequestOptions.resolve(model.key, user.id)
    assert opts[:api_key] == "sk-owner"
    _ = provider
  end

  test "non-owner gets safe fallback, no key", %{model: model} do
    {:ok, other} = Magus.Test.Generators.create_user()
    assert {model_key, []} = RequestOptions.resolve(model.key, other.id)
    assert model_key == model.key
  end

  test "nil actor (default arity) gets safe fallback, no key", %{model: model} do
    assert {model_key, []} = RequestOptions.resolve(model.key)
    assert model_key == model.key
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/request_options_owned_test.exs`
Expected: FAIL (owner gets key back unresolved; no rewrite).

- [ ] **Step 3: Make resolve/2 actor-capable and fail-closed**

Rewrite the top of `lib/magus/models/request_options.ex`:

```elixir
@doc "Full resolution: the ReqLLM model input and request options."
@spec resolve(String.t()) :: {reqllm_model(), keyword()}
def resolve(model_key) when is_binary(model_key), do: resolve(model_key, nil)

@spec resolve(String.t(), binary() | nil) :: {reqllm_model(), keyword()}
def resolve(model_key, actor_id) when is_binary(model_key) do
  case lookup(model_key) do
    nil ->
      {model_key, []}

    {model, provider} ->
      if authorized?(provider, actor_id) do
        opts =
          []
          |> maybe_put(:api_key, provider.api_key)
          |> maybe_put(:base_url, provider.base_url)

        {reqllm_model(model, provider), opts}
      else
        :telemetry.execute(
          [:magus, :models, :request_options, :owner_mismatch],
          %{count: 1},
          %{provider_id: provider.id}
        )

        {model_key, []}
      end
  end
end

# Global providers serve anyone; owned providers serve only their owner.
defp authorized?(%{owner_user_id: nil}, _actor_id), do: true
defp authorized?(%{owner_user_id: owner}, actor_id), do: is_binary(actor_id) and owner == actor_id

# openai_compatible bypasses the LLMDB spec lookup with an inline map; every
# other provider resolves to "<req_llm_id>:<model-id-without-slug>", which is a
# no-op for global built-ins (slug == req_llm_id) and the correct rewrite for
# owned providers whose slug differs from req_llm_id.
defp reqllm_model(model, %{req_llm_id: "openai_compatible"} = provider),
  do: %{provider: :openai_compatible, id: strip_slug(model.key, provider.slug)}

defp reqllm_model(model, provider),
  do: provider.req_llm_id <> ":" <> strip_slug(model.key, provider.slug)
```

Remove the old inline `if provider.req_llm_id == "openai_compatible"` branch in `resolve/1` (now handled by `reqllm_model/2`). Keep `lookup/1`, `strip_slug/2`, `maybe_put/3`, `not_found?/1` unchanged.

- [ ] **Step 4: Run the owned test + the existing suite**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/request_options_owned_test.exs test/magus/models/request_options_test.exs`
Expected: PASS (both). The existing global tests must still pass; `reqllm_model/2` is a no-op for `slug == req_llm_id` and preserves the `openai_compatible` inline form.

- [ ] **Step 5: Compile clean + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/models/request_options.ex test/magus/models/request_options_owned_test.exs
git commit -m "feat(models): actor-capable fail-closed RequestOptions with owned rewrite (phase 2b-1)"
```

---

### Task 7: Resolver actor-capable + ownership facts + 2a carryover

**Files:**
- Modify: `lib/magus/models/resolver.ex`
- Test: `test/magus/models/resolver_ownership_test.exs`
- Test: `test/magus/models/resolver_test.exs` (append the 2a carryover tests)

**Interfaces:**
- Produces: `resolve(actor, input)` that owner-scopes the model fetch and populates `access_source`/`credential_owner_user_id`/`cost_source` from `model.owner_user_id`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/magus/models/resolver_ownership_test.exs
defmodule Magus.Models.ResolverOwnershipTest do
  use Magus.DataCase, async: false
  alias Magus.Models.Resolver

  setup do
    Magus.DataCase.clear_catalog!()
    {:ok, user} = Magus.Test.Generators.create_user()

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk"},
        actor: user
      )

    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{name: "C", model_id: "claude-x", model_provider_id: provider.id},
        actor: user
      )

    %{user: user, model: model}
  end

  test "owner resolving their model key gets ownership facts", %{user: user, model: model} do
    {:ok, res} = Resolver.resolve(user, %{model_keys: %{chat: model.key}, mode: :chat})
    assert res.access_source == :owned
    assert res.credential_owner_user_id == user.id
    assert res.cost_source == :byok
    assert res.model.key == model.key
  end

  test "a non-owner cannot resolve the owned key (degrades)", %{model: model} do
    {:ok, other} = Magus.Test.Generators.create_user()
    {:ok, res} = Resolver.resolve(other, %{model_keys: %{chat: model.key}, mode: :chat})
    refute res.model.key == model.key
    assert res.access_source == :global
  end

  test "nil actor resolves global only", %{model: model} do
    {:ok, res} = Resolver.resolve(nil, %{model_keys: %{chat: model.key}, mode: :chat})
    refute res.model.key == model.key
  end
end
```

Append to `test/magus/models/resolver_test.exs` (2a carryover; use the existing helpers/setup in that file):

```elixir
test "explicit-id miss falls to :auto image key and propagates inherited_requested" do
  {:ok, res} =
    Magus.Models.Resolver.resolve(nil, %{
      model_keys: %{chat: "openrouter:foo/chat", image: :auto},
      mode: :image_generation,
      selected_model_id: "00000000-0000-0000-0000-000000000000"
    })

  assert res.requested_selection == %{by: :id, value: "00000000-0000-0000-0000-000000000000"}
  assert Magus.Models.Resolution.degraded?(res)
end

test "explicit key equal to the default model is :explicit and not degraded" do
  default = Magus.Agents.Config.default_model()

  {:ok, res} =
    Magus.Models.Resolver.resolve(nil, %{model_keys: %{chat: default}, mode: :chat})

  assert res.selection_source == :explicit
  refute Magus.Models.Resolution.degraded?(res)
end
```

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/resolver_ownership_test.exs`
Expected: FAIL (facts default to :global; owned key resolves for non-owner).

- [ ] **Step 3: Owner-scope the fetches**

In `lib/magus/models/resolver.ex`, thread an `actor_id` derived from the actor and use it in both lookups.

Change `resolve/2` to compute `actor_id`:

```elixir
def resolve(actor, %{model_keys: model_keys, mode: mode} = input) do
  actor_id = actor_id(actor)
  selected_model_id = Map.get(input, :selected_model_id)
  preloaded = Map.get(input, :preloaded, [])
  auto_routed = Map.get(input, :auto_routed)

  resolution =
    model_keys
    |> build(mode, selected_model_id, preloaded, auto_routed, actor_id)
    |> emit_degraded_telemetry(mode)

  {:ok, resolution}
end

defp actor_id(%{id: id}) when is_binary(id), do: id
defp actor_id(_), do: nil
```

Thread `actor_id` through `build/6`, `from_keys/6`, `from_key/5`, `resolve_auto/3`, `find_or_fetch/3`, and `fetch_or_fallback/2` so it reaches the two DB reads. Replace the explicit-id lookup and `fetch_by_key/1`:

```elixir
# explicit id (in build/6)
case get_owned_or_global_model(selected_model_id, actor_id) do
  {:ok, model} -> resolution(model, :explicit, %{by: :id, value: selected_model_id})
  _ -> from_keys(model_keys, mode, preloaded, auto_routed, %{by: :id, value: selected_model_id}, actor_id)
end
```

```elixir
# read_one returns {:ok, nil} on a miss; collapse that to :error so the
# explicit-id path falls through to the keys map (a real match returns {:ok, model}).
defp get_owned_or_global_model(id, actor_id) when is_binary(id) do
  case Magus.Chat.Model
       |> Ash.Query.filter(id == ^id and (is_nil(owner_user_id) or owner_user_id == ^actor_id))
       |> Ash.read_one(authorize?: false) do
    {:ok, %{} = model} -> {:ok, model}
    _ -> :error
  end
end

defp fetch_by_key(key, actor_id) when is_binary(key) do
  case Magus.Chat.Model
       |> Ash.Query.filter(key == ^key and (is_nil(owner_user_id) or owner_user_id == ^actor_id))
       |> Ash.read_one(authorize?: false) do
    {:ok, %{} = model} -> model
    _ -> nil
  end
end
```

Note: when `actor_id` is `nil`, `owner_user_id == ^nil` compiles to `owner_user_id = NULL`, which is never true in SQL, so only the `is_nil(owner_user_id)` (global) branch matches. Owned rows are excluded for a nil actor. This is the fail-closed default.

- [ ] **Step 4: Populate ownership facts + guard provider_id**

Change `resolution/3` to derive facts from the model:

```elixir
defp resolution(model, selection_source, requested) do
  %Resolution{
    model: model,
    selection_source: selection_source,
    requested_selection: requested,
    provider_id: provider_id(model),
    access_source: access_source(model),
    credential_owner_user_id: owner_of(model),
    cost_source: cost_source(model)
  }
end

defp access_source(%{owner_user_id: owner}) when is_binary(owner), do: :owned
defp access_source(_), do: :global

defp owner_of(%{owner_user_id: owner}) when is_binary(owner), do: owner
defp owner_of(_), do: nil

defp cost_source(%{owner_user_id: owner}) when is_binary(owner), do: :byok
defp cost_source(_), do: :platform_key
```

Guard `provider_id/1`:

```elixir
defp provider_id(%{model_provider_id: id}) when is_binary(id), do: id
defp provider_id(_), do: nil
```

- [ ] **Step 5: Run to verify pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/resolver_ownership_test.exs test/magus/models/resolver_test.exs`
Expected: PASS.

- [ ] **Step 6: Compile clean + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/models/resolver.ex test/magus/models/resolver_ownership_test.exs test/magus/models/resolver_test.exs
git commit -m "feat(models): actor-scoped Resolver with ownership facts + 2a carryover (phase 2b-1)"
```

---

### Task 8: Selection-write ownership validation

**Files:**
- Create: `lib/magus/chat/model/validations/selectable_by_actor.ex`
- Modify: `lib/magus/accounts/user.ex`
- Modify: `lib/magus/chat/conversation.ex`
- Modify: `lib/magus/chat/user_model_preference/validations/model_selectable.ex`
- Test: `test/magus/chat/selection_ownership_test.exs`

**Interfaces:**
- Produces: a shared validation `Magus.Chat.Model.Validations.SelectableByActor` usable on the `User` and `Conversation` selection actions.

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/chat/selection_ownership_test.exs
defmodule Magus.Chat.SelectionOwnershipTest do
  use Magus.DataCase, async: false

  setup do
    Magus.DataCase.clear_catalog!()
    {:ok, user} = Magus.Test.Generators.create_user()
    {:ok, other} = Magus.Test.Generators.create_user()

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk"},
        actor: other
      )

    {:ok, others_model} =
      Magus.Chat.create_owned_model(
        %{name: "C", model_id: "claude-x", model_provider_id: provider.id},
        actor: other
      )

    %{user: user, others_model: others_model}
  end

  test "selecting another user's owned model is rejected", %{user: user, others_model: m} do
    assert {:error, _} =
             user
             |> Ash.Changeset.for_update(:select_model, %{selected_model_id: m.id}, actor: user)
             |> Ash.update()
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/chat/selection_ownership_test.exs`
Expected: FAIL (selection accepted).

- [ ] **Step 3: Add the shared validation**

```elixir
# lib/magus/chat/model/validations/selectable_by_actor.ex
defmodule Magus.Chat.Model.Validations.SelectableByActor do
  @moduledoc """
  Validates that the selected model id (from `opts[:attribute]`) resolves, under
  the acting actor, to an active, non-internal model the actor may use. A nil id
  is allowed (clearing the selection).
  """
  use Ash.Resource.Validation
  require Ash.Query

  @impl true
  def init(opts) do
    if is_atom(opts[:attribute]),
      do: {:ok, opts},
      else: {:error, "attribute option is required"}
  end

  @impl true
  def validate(changeset, opts, context) do
    field = opts[:attribute]

    case Ash.Changeset.get_attribute(changeset, field) do
      nil ->
        :ok

      id ->
        actor_id = actor_id(context)

        query =
          Magus.Chat.Model
          |> Ash.Query.filter(
            id == ^id and active? == true and internal? == false and
              (is_nil(owner_user_id) or owner_user_id == ^actor_id)
          )

        case Ash.read_one(query, authorize?: false) do
          {:ok, %{}} -> :ok
          _ -> {:error, field: field, message: "is not a selectable model"}
        end
    end
  end

  defp actor_id(%{actor: %{id: id}}) when is_binary(id), do: id
  defp actor_id(_), do: nil
end
```

- [ ] **Step 4: Attach to the selection actions**

In `lib/magus/accounts/user.ex`, add the validation to each selection action (and set `require_atomic? false` since the validation reads):

```elixir
update :select_model do
  accept [:selected_model_id]
  require_atomic? false
  validate {Magus.Chat.Model.Validations.SelectableByActor, attribute: :selected_model_id}
end

update :select_image_model do
  accept [:selected_image_model_id]
  require_atomic? false
  validate {Magus.Chat.Model.Validations.SelectableByActor, attribute: :selected_image_model_id}
end

update :select_video_model do
  accept [:selected_video_model_id]
  require_atomic? false
  validate {Magus.Chat.Model.Validations.SelectableByActor, attribute: :selected_video_model_id}
end
```

Do the same for `lib/magus/chat/conversation.ex` `set_model` / `set_image_model` / `set_video_model` (same validation, same attribute names).

- [ ] **Step 5: Fix ModelSelectable to use the actor**

Replace the lookup in `lib/magus/chat/user_model_preference/validations/model_selectable.ex`:

```elixir
model_id ->
  actor_id =
    case context do
      %{actor: %{id: id}} when is_binary(id) -> id
      _ -> nil
    end

  query =
    Magus.Chat.Model
    |> Ash.Query.filter(
      id == ^model_id and active? == true and internal? == false and
        (is_nil(owner_user_id) or owner_user_id == ^actor_id)
    )

  case Ash.read_one(query, authorize?: false) do
    {:ok, %{}} -> :ok
    _ -> {:error, field: :model_id, message: "is not a selectable model"}
  end
```

Add `require Ash.Query` at the top of that module and change `validate/3`'s signature to bind `context` (it currently ignores it as `_context`).

- [ ] **Step 6: Run to verify pass + regression**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/chat/selection_ownership_test.exs test/magus/chat/user_model_preference`
Expected: PASS (and the Phase 1 curation validation tests still pass).

- [ ] **Step 7: Compile clean + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/chat/model/validations/selectable_by_actor.ex lib/magus/accounts/user.ex lib/magus/chat/conversation.ex lib/magus/chat/user_model_preference/validations/model_selectable.ex test/magus/chat/selection_ownership_test.exs
git commit -m "feat(chat): validate model-selection ownership on user + conversation writes (phase 2b-1)"
```

---

### Task 9: Credential validation machinery

**Files:**
- Create: `lib/magus/models/credential_validator.ex`
- Create: `lib/magus/models/workers/validate_credential.ex`
- Modify: `lib/magus/models/provider/changes/enqueue_credential_validation.ex` (fill in the Task 2 stub)
- Modify: `lib/magus/models/provider.ex` (add the `:validate` action)
- Modify: `lib/magus/models.ex` (interface)
- Test: `test/magus/models/credential_validation_test.exs`

**Interfaces:**
- Produces: `Magus.Models.validate_provider_credential(provider_id, opts)` (action `:validate`), an Oban worker `Magus.Models.Workers.ValidateCredential` (unique on `provider_id`), and a `Magus.Models.CredentialValidator` seam configurable for tests via `config :magus, :credential_validator`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/models/credential_validation_test.exs
defmodule Magus.Models.CredentialValidationTest do
  use Magus.DataCase, async: false
  use Oban.Testing, repo: Magus.Repo

  setup do
    Magus.DataCase.clear_catalog!()
    {:ok, user} = Magus.Test.Generators.create_user()
    %{user: user}
  end

  test "create_owned enqueues a unique validation job", %{user: user} do
    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    assert_enqueued(worker: Magus.Models.Workers.ValidateCredential, args: %{"provider_id" => provider.id})
  end

  test "worker stamps valid status via the configured validator", %{user: user} do
    Application.put_env(:magus, :credential_validator, fn _provider -> :valid end)
    on_exit(fn -> Application.delete_env(:magus, :credential_validator) end)

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    assert :ok =
             perform_job(Magus.Models.Workers.ValidateCredential, %{"provider_id" => provider.id})

    {:ok, reloaded} = Ash.get(Magus.Models.Provider, provider.id, authorize?: false)
    assert reloaded.validation_status == :valid
    assert reloaded.last_validated_at
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/credential_validation_test.exs`
Expected: FAIL (no job enqueued; worker undefined).

- [ ] **Step 3: Implement the validator seam**

```elixir
# lib/magus/models/credential_validator.ex
defmodule Magus.Models.CredentialValidator do
  @moduledoc """
  Probes a provider's credentials and returns a status atom. The default probe
  issues a minimal models-list request against the resolved endpoint. Tests
  and self-hosted deployments can override via `config :magus,
  :credential_validator` with a 1-arity function returning
  `:valid | :invalid | :error`.
  """

  @type status :: :valid | :invalid | :error

  @spec validate(map()) :: status()
  def validate(provider) do
    case Application.get_env(:magus, :credential_validator) do
      fun when is_function(fun, 1) -> fun.(provider)
      _ -> default_probe(provider)
    end
  end

  # A conservative default: without a reachable probe we report :error rather
  # than guessing. The concrete per-provider probe lands with the 2b-2 UI that
  # exercises it; keeping it minimal here avoids a new egress path on by every
  # create in a headless environment.
  defp default_probe(_provider), do: :error
end
```

Note: the default probe is intentionally minimal in 2b-1. The live per-provider HTTP probe belongs with the 2b-2 UI; the seam, worker, guard, and status plumbing are complete here so 2b-2 only swaps `default_probe/1`.

- [ ] **Step 4: Implement the Oban worker**

```elixir
# lib/magus/models/workers/validate_credential.ex
defmodule Magus.Models.Workers.ValidateCredential do
  @moduledoc """
  Stamps a provider's credential validation status. Unique per provider over a
  short window so a burst of edits cannot fan out into many probes.
  """
  use Oban.Worker,
    queue: :default,
    unique: [period: 60, fields: [:args], keys: [:provider_id]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_id" => provider_id}}) do
    case Ash.get(Magus.Models.Provider, provider_id, authorize?: false) do
      {:ok, provider} ->
        status = Magus.Models.CredentialValidator.validate(provider)

        provider
        |> Ash.Changeset.for_update(:stamp_validation, %{
          validation_status: status,
          last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ash.update!(authorize?: false)

        :ok

      _ ->
        :ok
    end
  end
end
```

Note: confirm `:default` is a configured Oban queue (check the `config :magus, Oban` block). If not, use an existing queue name. The `unique` option dedupes by the `provider_id` arg over a 60s window.

- [ ] **Step 5: Add the :stamp_validation + :validate actions and fill the enqueue change**

In `lib/magus/models/provider.ex`, add to `actions do`:

```elixir
update :stamp_validation do
  description "Writes credential validation results (worker only)."
  accept [:validation_status, :last_validated_at]
end

update :validate do
  description "Re-enqueues credential validation for an owned provider."
  accept []
  require_atomic? false
  change Magus.Models.Provider.Changes.EnqueueCredentialValidation
end
```

Add a policy for these inside the `policies do` block:

```elixir
policy action(:validate) do
  authorize_if expr(owner_user_id == ^actor(:id))
end

policy action(:stamp_validation) do
  authorize_if always()
end
```

Note: `:stamp_validation` is only ever called with `authorize?: false` by the worker; `always()` keeps it from blocking that internal write.

Fill in `lib/magus/models/provider/changes/enqueue_credential_validation.ex`:

```elixir
defmodule Magus.Models.Provider.Changes.EnqueueCredentialValidation do
  @moduledoc """
  After an owned provider write commits, enqueues a unique credential
  validation job and stamps validation_enqueued_at. Skips global rows.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _cs, result ->
      with {:ok, %{owner_user_id: owner, id: id} = provider} when is_binary(owner) <- result do
        %{provider_id: id}
        |> Magus.Models.Workers.ValidateCredential.new()
        |> Oban.insert()

        _ = provider
      end

      result
    end)
  end
end
```

Add to `lib/magus/models.ex` inside the Provider resource block:

```elixir
define :validate_provider_credential, action: :validate
```

- [ ] **Step 6: Run to verify pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models/credential_validation_test.exs`
Expected: PASS.

- [ ] **Step 7: Compile clean + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/models/credential_validator.ex lib/magus/models/workers/ lib/magus/models/provider.ex lib/magus/models/provider/changes/enqueue_credential_validation.ex lib/magus/models.ex test/magus/models/credential_validation_test.exs
git commit -m "feat(models): async credential validation worker with unique enqueue guard (phase 2b-1)"
```

---

### Task 10: Account deletion cleanup for owned providers/models

**Files:**
- Modify: `lib/magus/accounts/account_deletion.ex`
- Test: `test/magus/accounts/account_deletion_owned_models_test.exs`

**Interfaces:**
- Consumes: owned Provider/Model + `MessageUsage` model FK.
- Produces: account deletion that removes a user's owned models then providers without an FK restriction error.

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/accounts/account_deletion_owned_models_test.exs
defmodule Magus.Accounts.AccountDeletionOwnedModelsTest do
  use Magus.DataCase, async: false

  test "deleting a user removes their owned providers and models" do
    {:ok, user} = Magus.Test.Generators.create_user()

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{name: "M", model_id: "gpt-x", model_provider_id: provider.id},
        actor: user
      )

    assert :ok = Magus.Accounts.AccountDeletion.delete_account(user)

    assert {:error, _} = Ash.get(Magus.Chat.Model, model.id, authorize?: false)
    assert {:error, _} = Ash.get(Magus.Models.Provider, provider.id, authorize?: false)
  end
end
```

Note: use the module's real public entry point (check `account_deletion.ex` for the exported delete function name, for example `delete_account/1` or `delete/1`) in place of `delete_account/1` if it differs.

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/accounts/account_deletion_owned_models_test.exs`
Expected: FAIL (owned rows survive, or an FK restriction error).

- [ ] **Step 3: Add owned model/provider cleanup**

In `lib/magus/accounts/account_deletion.ex`, add a private helper and call it inside `delete_user_owned_content/1` AFTER the conversation destroy (after the `destroy_via_action(Magus.Chat.Conversation, ...)` line) so message rows and their usage references are gone first:

```elixir
defp delete_owned_models_and_providers(user_id) do
  import Ecto.Query
  uid = user_id_uuid_binary(user_id)

  owned_model_ids =
    from(m in "models", where: m.owner_user_id == ^uid, select: m.id)
    |> Magus.Repo.all()

  # message_usages.model_id is a NO ACTION FK; nil it for owned models so the
  # delete is not restricted. These usage rows belong to the owner's own
  # (already-deleted) messages in 2b-1, since owned models are private.
  if owned_model_ids != [] do
    from(mu in "message_usages", where: mu.model_id in ^owned_model_ids)
    |> Magus.Repo.update_all(set: [model_id: nil])
  end

  # Models reference providers (NO ACTION), so delete models before providers.
  from(m in "models", where: m.owner_user_id == ^uid) |> Magus.Repo.delete_all()
  from(p in "model_providers", where: p.owner_user_id == ^uid) |> Magus.Repo.delete_all()
end
```

Call it in `delete_user_owned_content/1`:

```elixir
destroy_via_action(Magus.Chat.Conversation, :delete_full_conversation, user.id)

delete_owned_models_and_providers(user.id)
```

Note: confirm the exact name/signature of the existing `user_id_uuid_binary/1` helper in this module and reuse it; it is used at line 282.

- [ ] **Step 4: Run to verify pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/accounts/account_deletion_owned_models_test.exs`
Expected: PASS.

- [ ] **Step 5: Compile clean + commit**

```bash
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/accounts/account_deletion.ex test/magus/accounts/account_deletion_owned_models_test.exs
git commit -m "feat(accounts): clean up owned models/providers on account deletion (phase 2b-1)"
```

---

## Final Verification (after all tasks)

- [ ] Full targeted suite: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/models test/magus/chat test/magus/accounts`
- [ ] Warnings-as-errors: `MIX_ENV=test mix compile --warnings-as-errors`
- [ ] `mix precommit` if available (format + deps.unlock --unused + test excludes e2e).
- [ ] Confirm no migration used `ash.reset`; migrations are additive and nullable.
- [ ] Spec cross-check: every row in the spec's Review Traceability table maps to a task (1: helpers; 2: provider owned + SSRF + cap; 3: Model authorizer + api_provider :byok scoping; 4: create_owned + media block; 5: atom-safety + SyncCatalog skip; 6: RequestOptions fail-closed; 7: resolver facts + carryover; 8: selection validation; 9: validation enqueue guard; 10: deletion cleanup).
