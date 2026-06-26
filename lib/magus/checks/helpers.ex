defmodule Magus.Checks.Helpers do
  @moduledoc false

  require Ash.Query

  alias Magus.Workspaces.WorkspaceMember

  @doc """
  Extracts `field` from a policy context. Looks first at changeset arguments,
  then attributes, then falls back to `changeset.data` (existing record) or the
  record at `context.subject`/`context.data` for update/destroy flows.
  """
  def value_from_context(%{changeset: %Ash.Changeset{} = changeset}, field) when is_atom(field) do
    Ash.Changeset.get_argument(changeset, field) ||
      Ash.Changeset.get_attribute(changeset, field) ||
      record_value(changeset.data, field)
  end

  def value_from_context(%{query: %Ash.Query{} = query}, field) when is_atom(field) do
    Ash.Query.get_argument(query, field)
  end

  def value_from_context(%{subject: subject}, field), do: value_from_context(subject, field)
  def value_from_context(%{data: data}, field) when is_struct(data), do: record_value(data, field)

  def value_from_context(%_{} = record, field) when is_atom(field),
    do: record_value(record, field)

  def value_from_context(_, _field), do: nil

  @doc """
  Returns true when the given user has an active membership in the workspace.

  Pass `admin_only?: true` to require the `:admin` role.
  """
  def active_workspace_member?(workspace_id, user_id, opts \\ [])
  def active_workspace_member?(nil, _user_id, _opts), do: false
  def active_workspace_member?(_workspace_id, nil, _opts), do: false

  def active_workspace_member?(workspace_id, user_id, opts) do
    admin_only? = Keyword.get(opts, :admin_only?, false)

    WorkspaceMember
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and
        user_id == ^user_id and
        is_active == true and
        workspace.is_active == true
    )
    |> maybe_filter_admin(admin_only?)
    |> Ash.count!(authorize?: false) > 0
  end

  defp maybe_filter_admin(query, true), do: Ash.Query.filter(query, role == :admin)
  defp maybe_filter_admin(query, false), do: query

  defp record_value(nil, _field), do: nil
  defp record_value(record, field) when is_struct(record), do: Map.get(record, field)
  defp record_value(_, _field), do: nil
end
