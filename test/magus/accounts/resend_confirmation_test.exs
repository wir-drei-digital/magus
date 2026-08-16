defmodule Magus.Accounts.ResendConfirmationTest do
  @moduledoc """
  Task 4 (signup-abuse-hardening): `:resend_confirmation` re-sends the
  confirmation email for an unconfirmed user, is a silent no-op for an
  already-confirmed user (so it can't be abused to replay the welcome
  email), and is self-only.
  """
  use Magus.DataCase, async: false

  import Magus.Generators
  import Swoosh.TestAssertions

  # `unconfirmed_user_fixture/0` registers via `:register_with_password`,
  # which itself sends the initial confirmation email — drain that first so
  # assertions below only see the :resend_confirmation attempt.
  defp drain_mailbox do
    receive do
      {:email, _} -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  defp resend(user, actor) do
    user
    |> Ash.Changeset.for_update(:resend_confirmation, %{}, actor: actor)
    |> Ash.update()
  end

  test "unconfirmed user gets a confirmation email" do
    user = unconfirmed_user_fixture()
    drain_mailbox()

    assert {:ok, _} = resend(user, user)
    assert_email_sent(to: to_string(user.email))
  end

  test "confirmed user is a silent no-op (no welcome-email replay)" do
    user = confirmed_user_fixture()
    drain_mailbox()

    assert {:ok, _} = resend(user, user)
    refute_email_sent()
  end

  test "another actor is forbidden" do
    user = unconfirmed_user_fixture()
    other = unconfirmed_user_fixture()
    drain_mailbox()

    assert {:error, %Ash.Error.Forbidden{}} = resend(user, other)
  end
end
