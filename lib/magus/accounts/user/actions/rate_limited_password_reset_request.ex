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
