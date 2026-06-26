defmodule Magus.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Magus.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:magus, :token_signing_secret)
  end
end
