defmodule Magus.SuperBrain.AccessorLock do
  @moduledoc """
  Derives the advisory-lock key used by `BuildSuperFull` and
  `BuildSuperIncremental` to serialize concurrent builds for the same
  accessor tuple, and exposes helpers for acquiring both
  transaction-scoped (`pg_advisory_xact_lock`) and session-scoped
  (`pg_advisory_lock`) variants.

  `pg_advisory_xact_lock(bigint)` takes a signed 64-bit integer; we
  derive the key from a sha256 of the accessor tuple, take the first
  8 bytes, and mask the sign bit so the value fits the signed range
  without sign-extension surprises. The `super_build|` namespace
  prefix protects against collisions with other features that might
  lock on the same accessor tuple.

  Both workers used to inline the formula behind the same long comment;
  hoisting it here gives a single edit point and ensures the two
  workers cannot drift apart on the key derivation.

  ## Transaction-scoped vs session-scoped

  `BuildSuperIncremental` runs inside a single `Repo.transaction` and
  acquires the lock via `acquire_xact/1` (auto-released on commit or
  rollback). `BuildSuperFull` (iter5 Task 3.1) does the heavy work
  OUTSIDE any database transaction so it does not pin a Postgres
  connection for the multi-minute build; it acquires the lock via
  `acquire_session/1` and pairs it with a matching `release_session/1`
  in an `after` block so a crash cannot deadlock the next build.
  """

  import Bitwise

  @namespace "super_build"

  @typedoc "Accessor tuple owned by the Super Brain build pipeline."
  @type accessor :: %{
          required(:type) => :user | :workspace,
          required(:user_id) => String.t() | nil,
          required(:workspace_id) => String.t() | nil
        }

  @doc """
  Compute the advisory-lock key for the given accessor.

  Returns a non-negative 63-bit integer (top bit masked off) suitable
  for passing as the `$1` parameter to
  `SELECT pg_advisory_xact_lock($1)` or
  `SELECT pg_advisory_lock($1)`.
  """
  @spec key_for(accessor()) :: non_neg_integer()
  def key_for(%{type: type, user_id: uid, workspace_id: ws}) do
    :crypto.hash(:sha256, "#{@namespace}|#{type}|#{uid}|#{ws}")
    |> binary_part(0, 8)
    |> :binary.decode_unsigned(:big)
    |> band(0x7FFFFFFFFFFFFFFF)
  end

  @doc """
  Acquire a transaction-scoped advisory lock for the accessor.

  Must be called INSIDE a `Repo.transaction`. The lock is released
  automatically when the surrounding transaction commits or rolls
  back. Used by `BuildSuperIncremental`.
  """
  @spec acquire_xact(accessor()) :: :ok
  def acquire_xact(accessor) do
    Magus.Repo.query!("SELECT pg_advisory_xact_lock($1)", [key_for(accessor)])
    :ok
  end

  @doc """
  Acquire a session-scoped advisory lock for the accessor.

  Held until `release_session/1` is called (or the database
  connection is closed). Used by `BuildSuperFull` (iter5 Task 3.1)
  so the multi-minute staged build does not pin a Postgres connection
  inside a long-running transaction.

  Callers MUST pair this with `release_session/1` in an `after` block
  to avoid leaking the lock on crash.
  """
  @spec acquire_session(accessor()) :: :ok
  def acquire_session(accessor) do
    Magus.Repo.query!("SELECT pg_advisory_lock($1)", [key_for(accessor)])
    :ok
  end

  @doc """
  Try to acquire the session-scoped advisory lock WITHOUT blocking.

  Returns `true` if the lock was acquired, `false` if another session
  already holds it.

  MUST run on a pinned connection (inside `Repo.checkout/2`) so the paired
  `release_session/1` releases the lock on the SAME connection. Acquiring
  on one pooled connection and releasing on another leaks the lock and
  deadlocks every later acquirer; the non-blocking variant exists precisely
  so a caller that loses the race returns immediately instead of blocking a
  pinned connection until its checkout deadline fires.
  """
  @spec try_acquire_session(accessor()) :: boolean()
  def try_acquire_session(accessor) do
    %{rows: [[acquired]]} =
      Magus.Repo.query!("SELECT pg_try_advisory_lock($1)", [key_for(accessor)])

    acquired
  end

  @doc """
  Release the session-scoped advisory lock acquired by
  `acquire_session/1`.

  Returns `:ok` regardless of whether the lock was held. We swallow
  the boolean result of `pg_advisory_unlock/1`: a `false` result
  means the lock was not held by this session, which is fine in an
  `after` block where the matching `acquire_session/1` may not have
  run (for example, when an earlier exception fired before the
  acquire).
  """
  @spec release_session(accessor()) :: :ok
  def release_session(accessor) do
    Magus.Repo.query!("SELECT pg_advisory_unlock($1)", [key_for(accessor)])
    :ok
  end
end
