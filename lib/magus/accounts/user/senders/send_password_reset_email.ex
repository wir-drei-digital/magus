defmodule Magus.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset email via Postmark template.
  """

  use AshAuthentication.Sender
  use MagusWeb, :verified_routes

  @impl true
  def send(user, token, _) do
    action_url = url(~p"/password-reset/#{token}")
    Magus.Mail.send_password_recovery(user, action_url)
    :ok
  end
end
