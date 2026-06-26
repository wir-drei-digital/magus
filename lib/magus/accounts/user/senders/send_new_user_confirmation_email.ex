defmodule Magus.Accounts.User.Senders.SendNewUserConfirmationEmail do
  @moduledoc """
  Sends an email for a new user to confirm their email address via Postmark template.
  """

  use AshAuthentication.Sender
  use MagusWeb, :verified_routes

  @impl true
  def send(user, token, _) do
    action_url = url(~p"/confirm_new_user/#{token}")
    Magus.Mail.send_mail_verification(user, action_url)
    :ok
  end
end
