defmodule Magus.Accounts.User.Senders.SendEmailChangeConfirmationEmail do
  @moduledoc """
  Sends an email to confirm an email address change via Postmark template.
  """

  use MagusWeb, :verified_routes

  def send(user, new_email, token) do
    action_url = url(~p"/settings/confirm-email/#{token}")
    Magus.Mail.send_mail_verification_to(new_email, user, action_url)
  end
end
