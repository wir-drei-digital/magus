defmodule Magus.Workspaces.Policies do
  @moduledoc """
  Shared Ash policy fragments for workspace-scoped resources.

  Use inside a resource's `policies do ... end` block:

      policies do
        import Magus.Workspaces.Policies
        workspace_scoped_policies(resource_type: :folder)
      end

  The macro expands to four policy blocks (read/create/update/destroy) that
  combine creator ownership, workspace admin privileges, and per-grantee
  grants via `Magus.Workspaces.ResourceAccess`.

  ## Options

    * `:resource_type` (required) — atom identifying the resource type in the
      `resource_accesses` table, e.g. `:folder`, `:file`, `:conversation`.
    * `:owner_expr` (optional): a `quote do ... end` wrapping an
      `Ash.Expr.expr/1` that defines creator ownership for this resource.
      Defaults to `expr(user_id == ^actor(:id))`. Use for resources whose
      "creator" is indirect (e.g. `KnowledgeCollection`, where ownership
      lives on the parent `KnowledgeSource`).
    * `:extra_read`, `:extra_create`, `:extra_update`, `:extra_destroy` —
      lists of additional Ash policy AST fragments appended to each standard
      block. Use for resource-specific rules such as multiplayer conversation
      membership or public library prompts.

  ## Role scaling

  The macro maps action types to minimum grant roles:

    * `:read` requires `:viewer` (or higher)
    * `:update` requires `:editor` (or higher)
    * `:destroy` requires `:owner`

  The record's creator (`user_id == actor.id`) always passes, as does an
  active workspace admin on the record's workspace (for update/destroy via
  `Magus.Checks.ActorCanManageWorkspaceResource`).
  """

  # AST for `expr(user_id == ^actor(:id))` without hygiene context.
  # Built manually so that `user_id` is not captured as a macro-local variable
  # when the quote block is spliced into the target resource module.
  defp creator_match do
    user_id_ref = {:user_id, [], nil}
    actor_ref = {:actor, [], [:id]}
    pinned_actor = {:^, [], [actor_ref]}
    eq_call = {:==, [], [user_id_ref, pinned_actor]}

    quote do
      Ash.Expr.expr(unquote(eq_call))
    end
  end

  # Callers commonly pass each extra policy fragment wrapped in `quote do ... end`.
  # That produces an AST node shaped `{:quote, _, [[do: body]]}` in the macro
  # arguments, which would otherwise splice a *runtime* `quote` call into the
  # target module. Unwrap those to the body AST so `unquote_splicing/1` inserts
  # the actual policy fragments.
  defp unwrap_fragments(fragments) do
    Enum.map(List.wrap(fragments), fn
      {:quote, _, [[do: body]]} -> body
      other -> other
    end)
  end

  defmacro workspace_scoped_policies(opts) do
    resource_type =
      Keyword.get(opts, :resource_type) ||
        raise ArgumentError, ":resource_type option is required"

    extra_read = unwrap_fragments(Keyword.get(opts, :extra_read, []))
    extra_create = unwrap_fragments(Keyword.get(opts, :extra_create, []))
    extra_update = unwrap_fragments(Keyword.get(opts, :extra_update, []))
    extra_destroy = unwrap_fragments(Keyword.get(opts, :extra_destroy, []))

    creator =
      case Keyword.get(opts, :owner_expr) do
        nil -> creator_match()
        {:quote, _, [[do: body]]} -> body
        ast -> ast
      end

    quote generated: true do
      policy action_type(:read) do
        authorize_if unquote(creator)

        authorize_if {Magus.Workspaces.AccessCheck,
                      resource_type: unquote(resource_type), min_role: :viewer}

        unquote_splicing(extra_read)
      end

      policy action_type(:create) do
        authorize_if {Magus.Checks.ActorIsActiveWorkspaceMember, allow_nil?: true}
        unquote_splicing(extra_create)
      end

      policy action_type(:update) do
        authorize_if unquote(creator)

        authorize_if {Magus.Workspaces.AccessCheck,
                      resource_type: unquote(resource_type), min_role: :editor}

        authorize_if Magus.Checks.ActorCanManageWorkspaceResource
        unquote_splicing(extra_update)
      end

      policy action_type(:destroy) do
        authorize_if unquote(creator)

        authorize_if {Magus.Workspaces.AccessCheck,
                      resource_type: unquote(resource_type), min_role: :owner}

        authorize_if Magus.Checks.ActorCanManageWorkspaceResource
        unquote_splicing(extra_destroy)
      end
    end
  end
end
