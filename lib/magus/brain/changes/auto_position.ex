defmodule Magus.Brain.Changes.AutoPosition do
  @moduledoc """
  Automatically assigns a fractional position to a new record based on
  the max position among its siblings.

  ## Options

    * `:resource` - The Ash resource module to query (required)
    * `:scope_attribute` - The attribute that scopes siblings, e.g. `:brain_id` or `:page_id` (required)
    * `:parent_attribute` - Optional parent grouping attribute, e.g. `:parent_block_id`.
      When set, siblings are further scoped by this attribute (nil-aware).
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def init(opts) do
    unless opts[:resource], do: raise("AutoPosition requires :resource option")
    unless opts[:scope_attribute], do: raise("AutoPosition requires :scope_attribute option")
    {:ok, opts}
  end

  @impl true
  def change(changeset, opts, _context) do
    resource = opts[:resource]
    scope_attr = opts[:scope_attribute]
    parent_attr = opts[:parent_attribute]

    scope_id = Ash.Changeset.get_attribute(changeset, scope_attr)

    if scope_id do
      Ash.Changeset.before_action(changeset, fn changeset ->
        parent_id =
          if parent_attr, do: Ash.Changeset.get_attribute(changeset, parent_attr), else: nil

        # Serialize position assignment on this scope+parent so two
        # parallel inserts don't both read the same max position and
        # both write max+1. The lock is transaction-scoped (releases
        # at COMMIT/ROLLBACK) and only contends with other inserts on
        # the SAME logical sibling list. See Magus.Brain.Locks.
        Magus.Brain.Locks.xact_lock!(position_lock_key(resource, scope_id, parent_id))

        query =
          resource
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(^ref(scope_attr) == ^scope_id)

        query =
          cond do
            parent_attr && parent_id ->
              Ash.Query.filter(query, ^ref(parent_attr) == ^parent_id)

            parent_attr ->
              Ash.Query.filter(query, is_nil(^ref(parent_attr)))

            true ->
              query
          end

        max_position =
          query
          |> Ash.Query.sort(position: :desc)
          |> Ash.Query.limit(1)
          |> Ash.read!(authorize?: false)
          |> case do
            [record] -> record.position
            [] -> 0.0
          end

        Ash.Changeset.force_change_attribute(changeset, :position, max_position + 1.0)
      end)
    else
      changeset
    end
  end

  defp position_lock_key(resource, scope_id, parent_id) do
    "auto_pos:#{inspect(resource)}:#{scope_id}:#{parent_id || "root"}"
  end
end
