defmodule Magus.Chat.ConversationInvitation.Senders.SendInvitationEmail do
  @moduledoc """
  Sends an invitation email to join a multiplayer conversation.
  """

  use MagusWeb, :verified_routes

  import Swoosh.Email
  use Gettext, backend: MagusWeb.Gettext
  alias Magus.Mailer

  def send(invitation, conversation, invited_by) do
    # For invitations, we default to English since the user may not exist yet
    Gettext.put_locale(MagusWeb.Gettext, "en")

    inviter_name = display_name(invited_by)

    new()
    |> from({"Magus", "noreply@magus.digital"})
    |> to(to_string(invitation.email))
    |> subject(gettext("%{name} invited you to a conversation", name: inviter_name))
    |> html_body(body(invitation, conversation, invited_by))
    |> put_provider_option(:message_stream, "outbound")
    |> Mailer.deliver!()
  end

  defp body(invitation, conversation, invited_by) do
    # User-controlled values are HTML-escaped before interpolation into the raw
    # HTML body below, so a crafted display name or conversation title cannot
    # inject markup (stored-XSS guard).
    invite_url = esc(url(~p"/chat/invite/#{invitation.token}"))
    conversation_title = esc(conversation.title || gettext("Untitled conversation"))
    inviter_name = esc(display_name(invited_by))

    hello = gettext("Hello,")

    invitation_msg =
      gettext("%{inviter} has invited you to join the conversation \"%{title}\" as a %{role}.",
        inviter: inviter_name,
        title: conversation_title,
        role: invitation.role
      )

    click_to_join = gettext("Click this link to join:")

    no_account_msg =
      gettext(
        "If you don't have an account yet, you'll be able to create one when you click the link."
      )

    best = gettext("Best,")
    team = gettext("The Omni Team")

    """
    <p>#{hello}</p>

    <p>#{invitation_msg}</p>

    <p>#{click_to_join} <a href="#{invite_url}">#{invite_url}</a></p>

    <p>#{no_account_msg}</p>

    <p>#{best}<br>#{team}</p>
    """
  end

  defp display_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{email: email}), do: email
  defp display_name(_), do: gettext("Someone")

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
