defmodule Magus.Brain.Locks do
  @moduledoc """
  Postgres advisory-lock helpers for serializing concurrent writes that
  share a logical scope.

  When the agent emits multiple tool calls in one turn, the ReAct
  runner executes them in parallel (default `max_concurrency: 4`).
  Two parallel writes that read-then-write against the same logical
  row (e.g. `SELECT MAX(position)` then `INSERT`, or "find page or
  create it") race: both readers see the pre-write state, both
  writers proceed, and you end up with duplicate rows or colliding
  positions.

  Advisory locks are the standard tool here: a transaction-scoped
  named lock that serializes only the contending writers, not
  unrelated work. The lock auto-releases at COMMIT/ROLLBACK (or at
  connection drop), so there's no leak risk.

  Uncontended acquires are sub-millisecond. Contended waits are
  bounded by the holder's transaction time (single INSERT, ~5–20ms).
  """

  @doc """
  Acquires a Postgres transaction-scoped advisory lock keyed on the
  given string. Must be called inside an open transaction — either an
  Ash `before_action` callback or a `Repo.transaction/1` block.
  Outside a transaction this still returns `:ok` but the lock is
  immediately released, defeating the purpose.

  The key is hashed to a 64-bit integer via `hashtext`. Hash
  collisions cause unnecessary serialization on unrelated keys but
  never incorrect behavior.
  """
  @spec xact_lock!(String.t()) :: :ok
  def xact_lock!(key) when is_binary(key) do
    Magus.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end
end
