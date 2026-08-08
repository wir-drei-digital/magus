defmodule Magus.Emails.SenderUrlsTest do
  @moduledoc """
  Regression tests for the absolute URLs embedded in transactional emails.

  Senders must build links from `Magus.Endpoint` (the open-core / cloud
  endpoint facade), never from `MagusWeb.Endpoint` directly. Under the
  `magus_cloud` split `MagusWeb.Endpoint` is started as an inert
  `server: false` child that only receives `secret_key_base` at runtime, so its
  `:url` stays at the compile-time `[host: "localhost"]` default. Links built
  from it point at `http://localhost` in production.
  """
  # async: false — mutates the global `:magus, :endpoint` app env.
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias Magus.Accounts.User
  alias Magus.Accounts.User.Senders.SendEmailChangeConfirmationEmail
  alias Magus.Accounts.User.Senders.SendMagicLinkEmail
  alias Magus.Accounts.User.Senders.SendNewUserConfirmationEmail
  alias Magus.Accounts.User.Senders.SendPasswordResetEmail
  alias Magus.Chat.Conversation
  alias Magus.Chat.ConversationInvitation
  alias Magus.Chat.ConversationInvitation.Senders.SendInvitationEmail

  @host "https://cloud.example"

  # Stand-in for the cloud endpoint: a host that MagusWeb.Endpoint never
  # reports, so a link containing it proves the sender went through the facade.
  defmodule FakeEndpoint do
    def url, do: "https://cloud.example"
  end

  setup do
    original = Application.get_env(:magus, :endpoint)
    Application.put_env(:magus, :endpoint, FakeEndpoint)

    on_exit(fn ->
      if original do
        Application.put_env(:magus, :endpoint, original)
      else
        Application.delete_env(:magus, :endpoint)
      end
    end)
  end

  defp assert_link_sent(url) do
    assert_email_sent(fn email ->
      assert email.html_body =~ url
      :ok
    end)
  end

  test "magic link email links to the configured endpoint" do
    SendMagicLinkEmail.send("someone@example.com", "tok-magic", [])

    assert_link_sent("#{@host}/magic_link/tok-magic")
  end

  test "new user confirmation email links to the configured endpoint" do
    SendNewUserConfirmationEmail.send("someone@example.com", "tok-confirm", [])

    assert_link_sent("#{@host}/confirm_new_user/tok-confirm")
  end

  test "password reset email links to the configured endpoint" do
    SendPasswordResetEmail.send("someone@example.com", "tok-reset", [])

    assert_link_sent("#{@host}/password-reset/tok-reset")
  end

  test "email change confirmation email links to the configured endpoint" do
    user = %User{email: "old@example.com", display_name: "Alice", language: :en}

    SendEmailChangeConfirmationEmail.send(user, "new@example.com", "tok-change")

    assert_link_sent("#{@host}/settings/confirm-email/tok-change")
  end

  test "conversation invitation email links to the configured endpoint" do
    invitation = %ConversationInvitation{
      email: Ash.CiString.new("invitee@example.com"),
      token: "tok-invite",
      role: :viewer
    }

    conversation = %Conversation{title: "Planning"}
    invited_by = %User{email: "alice@example.com", display_name: "Alice"}

    SendInvitationEmail.send(invitation, conversation, invited_by)

    assert_link_sent("#{@host}/chat/invite/tok-invite")
  end
end
