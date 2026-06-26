defmodule Magus.Chat.ConversationInvitation.Senders.SendInvitationEmailTest do
  @moduledoc """
  Guards against HTML/script injection through user-controlled fields in the
  multiplayer-invitation email body.
  """
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias Magus.Chat.ConversationInvitation.Senders.SendInvitationEmail

  test "escapes the inviter name and conversation title in the HTML body" do
    invitation = %{email: "invitee@example.com", token: "tok-123", role: :viewer}
    conversation = %{title: "<img src=x onerror=alert(1)>"}
    invited_by = %{display_name: "<script>alert('xss')</script>"}

    SendInvitationEmail.send(invitation, conversation, invited_by)

    assert_email_sent(fn email ->
      # User-controlled values must NOT appear as live markup...
      refute email.html_body =~ "<script>alert"
      refute email.html_body =~ "<img src=x onerror"
      # ...they must be HTML-escaped.
      assert email.html_body =~ "&lt;script&gt;"
      assert email.html_body =~ "&lt;img src=x onerror"
      assert [{"", "invitee@example.com"}] = email.to
    end)
  end
end
