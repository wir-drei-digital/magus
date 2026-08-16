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

    lookup =
      Magus.Accounts.User
      |> Ash.Query.for_read(:get_by_email, %{email: email})
      |> Ash.read_one(authorize?: false)

    key = email |> to_string() |> String.downcase()

    with {:ok, %{} = _user} <- lookup,
         :ok <- AuthRateLimiter.check(:password_reset, key),
         :ok <- AuthRateLimiter.check(:password_reset_global, :global) do
      AshAuthentication.Strategy.Password.RequestPasswordReset.run(
        input,
        [action: :get_by_email],
        context
      )
    else
      # unknown address: mimic the library's silent success
      {:ok, nil} -> :ok
      # over limit, or a transient lookup failure (e.g. DB blip) — also
      # silent. The library's own RequestPasswordReset soft-fails the same
      # way (logs and returns :ok) rather than raising, so a lookup error
      # here must not crash the request either; and silence leaks nothing
      # either way (spec: "silent by design").
      {:error, _} -> :ok
    end
  end
end
