defmodule Magus.Integrations.RateLimiterTest do
  @moduledoc """
  Covers `status/3` and `reset/3` against the FixedWindow-backed `check/3`
  storage (see lib/magus/integrations/rate_limiter.ex). Both previously
  built the old 3-tuple ETS key/value shape and were silently dead once
  `check/3` moved to `Magus.RateLimiting.FixedWindow`.
  """

  use ExUnit.Case, async: true

  alias Magus.Integrations.RateLimiter

  # Provider/operation pair absent from @default_limits falls back to the
  # {100, :hour} default limit (see RateLimiter.get_limit/2).
  @provider_key :rate_limiter_test_provider
  @operation :rate_limiter_test_op

  setup do
    %{user_id: "rl-test-user-#{System.unique_integer([:positive])}"}
  end

  test "status reflects check calls", %{user_id: user_id} do
    assert {0, 100, _remaining} = RateLimiter.status(user_id, @provider_key, @operation)

    assert :ok == RateLimiter.check(user_id, @provider_key, @operation)
    assert {1, 100, _remaining} = RateLimiter.status(user_id, @provider_key, @operation)

    assert :ok == RateLimiter.check(user_id, @provider_key, @operation)
    assert {2, 100, remaining} = RateLimiter.status(user_id, @provider_key, @operation)
    assert remaining > 0 and remaining <= 3_600_000
  end

  test "reset clears counts so checks pass again", %{user_id: user_id} do
    for _ <- 1..100, do: assert(:ok == RateLimiter.check(user_id, @provider_key, @operation))
    assert {:error, :rate_limited} == RateLimiter.check(user_id, @provider_key, @operation)

    assert :ok == RateLimiter.reset(user_id, @provider_key, @operation)

    assert {0, 100, _remaining} = RateLimiter.status(user_id, @provider_key, @operation)
    assert :ok == RateLimiter.check(user_id, @provider_key, @operation)
  end
end
