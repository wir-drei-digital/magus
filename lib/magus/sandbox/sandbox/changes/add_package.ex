defmodule Magus.Sandbox.Sandbox.Changes.AddPackage do
  @moduledoc """
  Adds a package to the sandbox's installed_packages list if not already present.

  This change is idempotent - adding a package that already exists is a no-op.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    current = Ash.Changeset.get_attribute(changeset, :installed_packages) || []
    package = Ash.Changeset.get_argument(changeset, :package)

    if package in current do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :installed_packages, [package | current])
    end
  end
end
