defmodule Magus.Workspaces.Calculations do
  @moduledoc """
  Shared calculations for workspace-scoped resources.

  Use inside a resource's `calculations do ... end` block:

      calculations do
        import Magus.Workspaces.Calculations
        is_shared_to_workspace(:file)
      end

  The macro expands to the same boolean calc that previously lived
  inline in each workspace-scoped resource, parameterized only by
  the `:resource_type` atom that ResourceAccess uses to discriminate.
  """

  # Build the calc body AST manually so attribute references like
  # `workspace_id` and the `Magus.Workspaces.ResourceAccess` reference
  # don't get captured by the macro's hygienic context. Ash's `expr/1`
  # macro evaluates these inside the resource module at compile time.
  defp calc_expr(resource_type) do
    workspace_id_ref = {:workspace_id, [], nil}
    ra_resource_type_ref = {:resource_type, [], nil}
    ra_resource_id_ref = {:resource_id, [], nil}
    ra_grantee_type_ref = {:grantee_type, [], nil}
    ra_grantee_id_ref = {:grantee_id, [], nil}

    is_nil_call = {:is_nil, [], [workspace_id_ref]}
    not_nil_call = {:not, [], [is_nil_call]}

    parent_id = {:parent, [], [{:id, [], nil}]}
    parent_workspace_id = {:parent, [], [workspace_id_ref]}

    type_match = {:==, [], [ra_resource_type_ref, resource_type]}
    id_match = {:==, [], [ra_resource_id_ref, parent_id]}
    grantee_type_match = {:==, [], [ra_grantee_type_ref, :workspace]}
    grantee_id_match = {:==, [], [ra_grantee_id_ref, parent_workspace_id]}

    inner_and_1 = {:and, [], [type_match, id_match]}
    inner_and_2 = {:and, [], [inner_and_1, grantee_type_match]}
    inner_and_3 = {:and, [], [inner_and_2, grantee_id_match]}

    exists_call =
      {:exists, [],
       [
         {:__aliases__, [alias: false], [:Magus, :Workspaces, :ResourceAccess]},
         inner_and_3
       ]}

    outer_and = {:and, [], [not_nil_call, exists_call]}

    quote do
      Ash.Expr.expr(unquote(outer_and))
    end
  end

  defmacro is_shared_to_workspace(resource_type) when is_atom(resource_type) do
    description =
      "True when a workspace-level ResourceAccess grant exists for this #{resource_type}"

    calc_ast = calc_expr(resource_type)

    quote do
      calculate :is_shared_to_workspace, :boolean do
        description unquote(description)
        # Selectable through API layers (AshTypescript field selection).
        public? true
        calculation unquote(calc_ast)
      end
    end
  end
end
