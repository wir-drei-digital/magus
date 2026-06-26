defmodule Magus.Checks.ActorIsActiveWorkspaceMember do
  @moduledoc """
  Verifies that the actor is an active member of the target workspace.

  This is primarily used on create/update actions where the workspace id is
  supplied through action arguments or changes.

  Options:
    * `:field` — attribute/argument name to read (default `:workspace_id`)
    * `:allow_nil?` — when true, passes when the field is nil (default `false`)
    * `:admin_only?` — when true, requires the `:admin` role (default `false`)
  """

  use Ash.Policy.SimpleCheck

  alias Magus.Checks.Helpers

  @impl true
  def describe(opts) do
    field = Keyword.get(opts, :field, :workspace_id)
    "actor is an active member of #{field}"
  end

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    field = Keyword.get(opts, :field, :workspace_id)
    allow_nil? = Keyword.get(opts, :allow_nil?, false)
    admin_only? = Keyword.get(opts, :admin_only?, false)

    case Helpers.value_from_context(context, field) do
      nil ->
        allow_nil?

      workspace_id ->
        Helpers.active_workspace_member?(workspace_id, actor.id, admin_only?: admin_only?)
    end
  end
end
