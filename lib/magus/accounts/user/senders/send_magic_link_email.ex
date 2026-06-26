defmodule Magus.Accounts.User.Senders.SendMagicLinkEmail do
  @moduledoc """
  Sends a magic link email via Postmark template.
  """

  use AshAuthentication.Sender
  use MagusWeb, :verified_routes

  @impl true
  def send(user_or_email, token, _) do
    action_url = url(~p"/magic_link/#{token}")
    Magus.Mail.send_magic_link(user_or_email, action_url)
    :ok
  end
end
