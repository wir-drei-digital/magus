defmodule Magus.Brain.Page.Errors.VersionConflict do
  @moduledoc """
  Raised by `Magus.Brain.Page.Validations.MatchesLockVersion` when the
  `base_version` argument to `update_body` does not match the page's
  current `lock_version`.

  This is the structured error the editor LiveView pattern-matches on to
  drive the LWW (last-write-wins) recovery toast. Carries every field
  the client needs to decide what to do without an extra DB round-trip:

    * `current_body` — the server-side body that overrode the caller's
    * `current_version` — the new `lock_version` to use on retry
    * `current_modified_at` — when the conflicting save landed
    * `conflicting_actor_id` — `contributor_id` of the latest save

  Tagged `class: :invalid` (same as `Ash.Error.Changes.StaleRecord`) so
  callers can pattern-match on `%Ash.Error.Invalid{errors: [%__MODULE__{} | _]}`.
  """

  use Splode.Error,
    fields: [
      :current_body,
      :current_version,
      :current_modified_at,
      :conflicting_actor_id,
      :base_version
    ],
    class: :invalid

  def message(%{base_version: base, current_version: current}) do
    "Page version conflict: client base_version=#{inspect(base)} but current lock_version=#{inspect(current)}"
  end
end

defimpl AshTypescript.Rpc.Error, for: Magus.Brain.Page.Errors.VersionConflict do
  @moduledoc false
  # Surfaces the optimistic-lock conflict to RPC clients (the SvelteKit
  # editor) instead of the generic internal-error envelope. `current_body`
  # is deliberately omitted — the client refetches the page, keeping error
  # payloads small.
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Version conflict",
      type: "version_conflict",
      vars: %{
        base_version: error.base_version,
        current_version: error.current_version,
        current_modified_at: error.current_modified_at,
        conflicting_actor_id: error.conflicting_actor_id
      },
      fields: [:base_version],
      path: []
    }
  end
end
