defmodule Magus.Organizations.OrganizationMember.Changes.FireSeatSync do
  @moduledoc "Fire the SeatSync seam after a membership becomes active or removed."
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    event = Keyword.fetch!(opts, :event)

    Ash.Changeset.after_action(changeset, fn _changeset, member ->
      case event do
        :activated -> Magus.Organizations.SeatSync.on_member_activated(member.id)
        :removed -> Magus.Organizations.SeatSync.on_member_removed(member.id)
      end

      {:ok, member}
    end)
  end
end
