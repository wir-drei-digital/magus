defmodule Magus.Workspaces.Checks.ActorCanReadResourceAccess do
  @moduledoc """
  Authorizes read actions on ResourceAccess rows other than the actor's own.

  The policy falls back to this check after the "grantee is actor" shortcut has
  been evaluated. This allows: resource creators, workspace admins, and :owner
  grantees to see the full grant list for resources they control.
  """
  use Ash.Policy.SimpleCheck

  alias Magus.Workspaces.Checks.ActorCanGrantResourceAccess

  @impl true
  def describe(_opts), do: "actor can manage grants on the target resource"

  @impl true
  def match?(actor, context, opts),
    do: ActorCanGrantResourceAccess.match?(actor, context, opts)
end
