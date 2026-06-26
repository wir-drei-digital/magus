defmodule Magus.Files.StorageTracking do
  @moduledoc """
  Helpers for keeping cached storage counters in sync with file lifecycle.

  The single source of truth is `Magus.Files.File.file_size`. Both the owning
  user's subscription and (if set) the workspace have denormalized
  `storage_usage_bytes` counters that must be kept in sync on create, update
  and destroy.

  The functions here are best-effort: they return `:ok` and log on failure
  rather than propagating errors, because storage counter drift is recoverable
  via `recalculate_storage` while a failed file mutation is not.
  """
  require Logger

  @doc """
  Record a delta in bytes against user and (optionally) workspace counters.

  Positive deltas increment, negative deltas decrement. A zero delta is a
  no-op.
  """
  def track_delta(_file, 0), do: :ok

  def track_delta(%{user_id: user_id, workspace_id: workspace_id}, delta)
      when is_integer(delta) and delta > 0 and not is_nil(user_id) do
    Magus.Usage.increment_storage_usage(user_id, delta, authorize?: false)

    if workspace_id do
      Magus.Workspaces.increment_workspace_storage(workspace_id, delta, authorize?: false)
    end

    :ok
  end

  def track_delta(%{user_id: user_id, workspace_id: workspace_id}, delta)
      when is_integer(delta) and delta < 0 and not is_nil(user_id) do
    amount = abs(delta)
    Magus.Usage.decrement_storage_usage(user_id, amount, authorize?: false)

    if workspace_id do
      Magus.Workspaces.decrement_workspace_storage(workspace_id, amount, authorize?: false)
    end

    :ok
  end

  def track_delta(_file, _delta), do: :ok

  @doc """
  Record a file creation: increments user and optional workspace counters by
  `file.file_size`.
  """
  def track_create(%{file_size: nil}), do: :ok
  def track_create(%{file_size: size} = file), do: track_delta(file, size)

  @doc """
  Record a file destroy: decrements user and optional workspace counters. The
  file struct passed in is the pre-destroy record (since `changeset.data` is
  the only handle after destroy).
  """
  def track_destroy(%{file_size: nil}), do: :ok
  def track_destroy(%{file_size: size} = file), do: track_delta(file, -size)

  @doc """
  Record an update where the file's size and/or workspace_id may have
  changed. Compares `old` (pre-update) to `new` (post-update) and issues the
  right mix of increment/decrement calls to the old and new owners.
  """
  def track_update(old, new) do
    old_size = old.file_size || 0
    new_size = new.file_size || 0

    cond do
      old.workspace_id == new.workspace_id ->
        track_delta(new, new_size - old_size)

      true ->
        # workspace_id changed: unwind the old allocation, allocate on the new
        track_delta(old, -old_size)
        track_delta(new, new_size)
    end
  end
end
