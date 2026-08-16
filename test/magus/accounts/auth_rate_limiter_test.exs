defmodule Magus.Accounts.AuthRateLimiterTest do
  use ExUnit.Case, async: false

  alias Magus.Accounts.AuthRateLimiter

  setup do
    original = Application.get_env(:magus, :auth_rate_limits)
    on_exit(fn -> Application.put_env(:magus, :auth_rate_limits, original) end)
    :ok
  end

  test "disabled config always allows" do
    Application.put_env(:magus, :auth_rate_limits, enabled: false, register: {1, :hour})
    assert :ok == AuthRateLimiter.check(:register, {127, 0, 0, 1})
    assert :ok == AuthRateLimiter.check(:register, {127, 0, 0, 1})
  end

  test "enabled config enforces the scope limit" do
    Application.put_env(:magus, :auth_rate_limits, enabled: true, register: {2, :hour})
    key = {10, 0, 0, System.unique_integer([:positive])}
    assert :ok == AuthRateLimiter.check(:register, key)
    assert :ok == AuthRateLimiter.check(:register, key)
    assert {:error, :rate_limited} == AuthRateLimiter.check(:register, key)
  end
end
