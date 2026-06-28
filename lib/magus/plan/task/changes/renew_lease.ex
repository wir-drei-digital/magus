defmodule Magus.Plan.Task.Changes.RenewLease do
  @moduledoc """
  Keeps the invariant "a non-null lease means an active (`:in_progress`) claim".

  Only plan tasks (those with a `brain_page_id`) participate in the
  claim/lease coordination model. Conversation tasks (those with a
  `conversation_id` and a nil `brain_page_id`) are never leased: their lease
  is left untouched so it stays nil and the reaper can never reclaim them.

  For plan tasks, behavior is driven by option `:always` (default `false`) and
  the changeset's resulting `status`:

    * `:always` is `true`: set the lease (used by `:claim`, where the action is
      itself the act of taking the claim).
    * resulting status is `:in_progress`: renew the lease (renew-on-activity for
      `:update` while work proceeds).
    * otherwise: clear the lease. This covers the `:update` path that moves a
      claimed task to a terminal status (e.g. `:done`), which must not leave a
      dangling future lease behind.

  Sets `lease_expires_at = now + :task_lease_ttl_seconds`. Uses
  `force_change_attribute/3` because `lease_expires_at` is not in any action's
  `accept` list (it is server-controlled, never client input).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    cond do
      is_nil(Ash.Changeset.get_attribute(changeset, :brain_page_id)) ->
        # Conversation tasks are not part of the lease/claim model: never lease them.
        changeset

      Keyword.get(opts, :always, false) ->
        set_lease(changeset)

      Ash.Changeset.get_attribute(changeset, :status) == :in_progress ->
        set_lease(changeset)

      true ->
        Ash.Changeset.force_change_attribute(changeset, :lease_expires_at, nil)
    end
  end

  defp set_lease(changeset) do
    ttl = Application.get_env(:magus, :task_lease_ttl_seconds, 900)

    Ash.Changeset.force_change_attribute(
      changeset,
      :lease_expires_at,
      DateTime.add(DateTime.utc_now(), ttl, :second)
    )
  end
end
