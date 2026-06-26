defmodule Magus.Agents.CustomAgent.Changes.GenerateHandle do
  @moduledoc """
  Auto-generates a handle from the agent's name on create.

  Converts name to lowercase, replaces non-alphanumeric chars with hyphens,
  and strips leading/trailing hyphens. Uniqueness scoping mirrors the DB
  identities:

    * Workspace agents (`workspace_id` set): unique within the workspace.
    * Personal agents (`workspace_id` nil): unique within the user.

  If the chosen handle already exists in the relevant scope, appends `-2`,
  `-3`, etc.
  """

  use Ash.Resource.Change

  require Ash.Query

  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :name) do
      Ash.Changeset.before_action(changeset, fn changeset ->
        name = Ash.Changeset.get_attribute(changeset, :name)
        handle = Ash.Changeset.get_attribute(changeset, :handle)

        if handle && handle != "" do
          changeset
        else
          base_handle = name_to_handle(name)
          unique_handle = ensure_unique_handle(base_handle, scope_for(changeset))
          Ash.Changeset.force_change_attribute(changeset, :handle, unique_handle)
        end
      end)
    else
      changeset
    end
  end

  @doc false
  def name_to_handle(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^\w]+/, "-")
    |> String.replace(~r/^-|-$/, "")
    |> case do
      "" -> "agent"
      handle -> handle
    end
  end

  def name_to_handle(_), do: "agent"

  defp scope_for(changeset) do
    case Ash.Changeset.get_attribute(changeset, :workspace_id) do
      nil ->
        user_id = Ash.Changeset.get_attribute(changeset, :user_id)
        {:personal, user_id}

      workspace_id ->
        {:workspace, workspace_id}
    end
  end

  defp ensure_unique_handle(base_handle, {_, nil}), do: base_handle

  defp ensure_unique_handle(base_handle, scope) do
    if handle_taken?(base_handle, scope) do
      find_available_handle(base_handle, scope, 2)
    else
      base_handle
    end
  end

  defp find_available_handle(base_handle, scope, n) when n <= 100 do
    candidate = "#{base_handle}-#{n}"

    if handle_taken?(candidate, scope) do
      find_available_handle(base_handle, scope, n + 1)
    else
      candidate
    end
  end

  defp find_available_handle(base_handle, _scope, _n) do
    "#{base_handle}-#{System.unique_integer([:positive])}"
  end

  defp handle_taken?(candidate, {:workspace, workspace_id}) do
    Magus.Agents.CustomAgent
    |> Ash.Query.filter(workspace_id == ^workspace_id and handle == ^candidate)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> false
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp handle_taken?(candidate, {:personal, user_id}) do
    Magus.Agents.CustomAgent
    |> Ash.Query.filter(user_id == ^user_id and is_nil(workspace_id) and handle == ^candidate)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> false
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
