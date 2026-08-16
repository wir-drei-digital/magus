defmodule Magus.Accounts.User.Actions.RateLimitedPasswordResetRequestTest do
  @moduledoc """
  Exercises `request_password_reset_token` (wired to the wrapper in Task 2)
  through the actual resource action, since no LiveView/controller test in
  this repo hits the reset-request flow otherwise.
  """
  use Magus.ResourceCase, async: false

  import Swoosh.TestAssertions

  alias Magus.Accounts.User

  setup do
    original = Application.get_env(:magus, :auth_rate_limits)
    on_exit(fn -> Application.put_env(:magus, :auth_rate_limits, original) end)
    :ok
  end

  defp request_reset(email) do
    User
    |> Ash.ActionInput.for_action(:request_password_reset_token, %{email: email})
    |> Ash.run_action(authorize?: false)
  end

  # User generation sends its own confirmation email; drain it so
  # `refute_email_sent/0`/`assert_email_sent/1` only see the reset attempt.
  defp drain_mailbox do
    receive do
      {:email, _} -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  test "unknown email returns :ok silently and sends no email (anti-enumeration)" do
    Application.put_env(:magus, :auth_rate_limits, enabled: false)

    assert :ok == request_reset("nobody-#{System.unique_integer([:positive])}@example.com")
    refute_email_sent()
  end

  test "known email under the limit sends the reset email" do
    Application.put_env(:magus, :auth_rate_limits, enabled: false)
    email = unique_email()
    generate(user(email: email))
    drain_mailbox()

    assert :ok == request_reset(email)
    assert_email_sent(to: email)
  end

  test "known email over the per-email limit is silent (no email sent, same :ok)" do
    Application.put_env(:magus, :auth_rate_limits, enabled: true, password_reset: {0, :hour})
    email = unique_email()
    generate(user(email: email))
    drain_mailbox()

    assert :ok == request_reset(email)
    refute_email_sent()
  end
end
