defmodule Magus.SuperBrain.AccessorLockTest do
  @moduledoc """
  The advisory-lock key derivation MUST be deterministic for the same
  accessor and MUST fit the signed 64-bit `bigint` range that
  `pg_advisory_xact_lock/1` expects. Pre-Wave-2 the formula was
  inlined in two workers behind matching long comments; the test
  pins the contract.

  Iter5 Task 3.1 added session-scoped acquire/release helpers used by
  `BuildSuperFull` to hold the lock across its multi-minute staged
  build without pinning a Postgres connection inside a transaction.
  """

  # Session-scoped acquire/release tests run real `pg_advisory_lock`
  # calls against Postgres; sharing the test pool with async sibling
  # tests would interfere.
  use Magus.DataCase, async: false

  alias Magus.SuperBrain.AccessorLock

  describe "key_for/1" do
    test "deterministic for the same accessor" do
      accessor = %{type: :user, user_id: "u1", workspace_id: nil}
      assert AccessorLock.key_for(accessor) == AccessorLock.key_for(accessor)
    end

    test "differs across accessor type" do
      a = AccessorLock.key_for(%{type: :user, user_id: "u1", workspace_id: nil})
      b = AccessorLock.key_for(%{type: :workspace, user_id: "u1", workspace_id: nil})
      refute a == b
    end

    test "differs across user_id" do
      a = AccessorLock.key_for(%{type: :user, user_id: "u1", workspace_id: nil})
      b = AccessorLock.key_for(%{type: :user, user_id: "u2", workspace_id: nil})
      refute a == b
    end

    test "differs across workspace_id" do
      a = AccessorLock.key_for(%{type: :workspace, user_id: "u1", workspace_id: "ws1"})
      b = AccessorLock.key_for(%{type: :workspace, user_id: "u1", workspace_id: "ws2"})
      refute a == b
    end

    test "key fits the signed bigint range" do
      key = AccessorLock.key_for(%{type: :user, user_id: "u1", workspace_id: nil})
      assert key >= 0
      assert key <= 0x7FFFFFFFFFFFFFFF
    end
  end

  describe "session-scoped lock (iter5 Task 3.1)" do
    test "acquire_session and release_session round-trip cleanly" do
      accessor = %{type: :user, user_id: "u-session-1", workspace_id: nil}

      assert :ok = AccessorLock.acquire_session(accessor)
      assert :ok = AccessorLock.release_session(accessor)
    end

    test "release_session is safe to call without a prior acquire" do
      # `pg_advisory_unlock` returns false when nothing is held; the
      # helper swallows that so a `try/after` cleanup path is safe to
      # run unconditionally (even when an exception fires before the
      # acquire).
      accessor = %{type: :user, user_id: "u-session-2", workspace_id: nil}

      assert :ok = AccessorLock.release_session(accessor)
    end
  end
end
