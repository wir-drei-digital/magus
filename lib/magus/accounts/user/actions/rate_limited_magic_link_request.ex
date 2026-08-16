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
