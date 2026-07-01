defmodule Magus.Accounts.TestAccounts do
  @moduledoc """
  Bulk creation of workshop/demo test accounts.

  Test accounts are real users with:

    * an email synthesised from a memorable username under a fixed domain
      (`demo1@magus.digital`),
    * an auto-generated, easy-to-type password (returned to the admin so it
      can be handed out),
    * NO Stripe connection and an `:exemption` usage override so they have no
      usage restrictions,
    * an expiry timestamp after which the daily cleanup worker
      (`Magus.Accounts.Workers.DeleteExpiredTestAccounts`) hard-deletes them.

  Creation goes through the `:admin_create_test_user` action on
  `Magus.Accounts.User`, which sends no confirmation/welcome emails.
  """

  require Ash.Query
  require Logger

  alias Magus.Accounts
  alias Magus.Accounts.User

  @domain "magus.digital"

  # Simple, unambiguous words so generated passwords are easy to dictate and
  # type for non-technical workshop participants. Format: "adj-noun-NN".
  @adjectives ~w(blue green happy sunny brave calm clever quick gentle bright
                 lucky merry swift bold cosy jolly kind neat proud warm)
  @nouns ~w(tiger river cloud forest mango panda eagle lemon ocean planet
            garden meadow falcon maple pebble willow comet harbor cedar otter)

  @doc "The fixed email domain used for all test accounts."
  def domain, do: @domain

  @doc "Builds the login email for a username, e.g. `demo1` -> `demo1@magus.digital`."
  def email_for(username), do: "#{sanitize_username(username)}@#{@domain}"

  @doc """
  Generates an easy-to-type password like `sunny-tiger-42`.

  Always >= 8 characters, lowercase letters/digits/hyphens only — no ambiguous
  characters to misread or mistype.
  """
  def generate_password do
    adjective = Enum.random(@adjectives)
    noun = Enum.random(@nouns)
    number = Enum.random(10..99)
    "#{adjective}-#{noun}-#{number}"
  end

  @doc """
  Lowercases and strips a username down to characters valid in an email local
  part (`a-z`, `0-9`, `.`, `_`, `-`).
  """
  def sanitize_username(username) do
    username
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]/, "")
  end

  @doc """
  Generates `count` usernames of the form `<base><n>` that do NOT already
  exist as test-account emails, starting at the lowest free index.
  """
  def generate_usernames(base, count) when is_integer(count) and count > 0 do
    base = sanitize_username(base)
    taken = existing_indices(base)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.reject(&MapSet.member?(taken, &1))
    |> Enum.take(count)
    |> Enum.map(&"#{base}#{&1}")
  end

  @doc """
  Creates many test accounts. `usernames` is a list of either bare usernames
  (a password is generated) or `{username, password}` tuples.

  Returns a list of per-row results in input order, each either
  `{:ok, credentials_map}` or `{:error, %{username:, email:, reason:}}`, so a
  single bad row never aborts the batch.

  Options:

    * `:actor` (required) — the admin performing the action
    * `:language` — `:en` (default) or `:de`
    * `:expires_at` — `DateTime` after which accounts are deleted (required)
  """
  def create_many(usernames, opts) do
    Enum.map(usernames, fn
      {username, password} -> create_one(username, Keyword.put(opts, :password, password))
      username -> create_one(username, opts)
    end)
  end

  @doc """
  Creates a single test account + its usage exemption override.

  See `create_many/2` for options. Returns `{:ok, credentials}` or
  `{:error, %{username:, email:, reason:}}`.
  """
  def create_one(username, opts) do
    actor = Keyword.fetch!(opts, :actor)
    expires_at = Keyword.fetch!(opts, :expires_at)
    language = Keyword.get(opts, :language, :en)
    username = sanitize_username(username)
    email = email_for(username)
    password = opts[:password] |> blank_to_nil() || generate_password()

    attrs = %{
      email: email,
      password: password,
      display_name: username,
      language: language,
      test_account_expires_at: expires_at
    }

    case Accounts.create_test_user(attrs, actor: actor) do
      {:ok, user} ->
        exempt? = grant_exemption(user, expires_at, actor)

        {:ok,
         %{
           username: username,
           email: email,
           password: password,
           user_id: user.id,
           expires_at: expires_at,
           exempt: exempt?
         }}

      {:error, error} ->
        {:error, %{username: username, email: email, reason: error_message(error)}}
    end
  end

  # Grants an :exemption override so the account has no usage restrictions.
  # The override expires with the account. A failure here is logged but does
  # not fail the whole row: the account still exists (on the free plan) and an
  # admin can re-grant the exemption manually.
  defp grant_exemption(user, expires_at, actor) do
    params = %{
      user_id: user.id,
      override_type: :exemption,
      exempt_from_limits: true,
      reason: "Workshop/demo test account — unlimited usage, no Stripe.",
      expires_at: expires_at
    }

    case Magus.Usage.create_usage_override(params, actor: actor) do
      {:ok, _override} ->
        true

      {:error, reason} ->
        Logger.warning(
          "TestAccounts: failed to grant exemption to #{user.email}: #{inspect(reason)}"
        )

        false
    end
  end

  defp existing_indices(base) do
    suffix = "@#{@domain}"
    regex = ~r/^#{Regex.escape(base)}(\d+)#{Regex.escape(suffix)}$/

    # All test-account emails share the fixed domain; fetch those and pick out
    # the numeric suffixes already used for this base. Test accounts are
    # workshop-scale, so reading the matching rows is cheap.
    User
    |> Ash.Query.filter(contains(email, ^suffix))
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(MapSet.new(), fn user, acc ->
      case Regex.run(regex, to_string(user.email)) do
        [_, digits] -> MapSet.put(acc, String.to_integer(digits))
        _ -> acc
      end
    end)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp error_message(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    errors
    |> Enum.map(&safe_message/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> case do
      [] -> "could not be created"
      messages -> Enum.join(messages, "; ")
    end
  end

  defp error_message(other), do: safe_message(other) || "could not be created"

  defp safe_message(error) do
    Exception.message(error)
  rescue
    _ -> inspect(error)
  end
end
