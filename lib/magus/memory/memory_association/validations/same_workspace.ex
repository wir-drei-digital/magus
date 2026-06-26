defmodule Magus.Memory.MemoryAssociation.Validations.SameWorkspace do
  @moduledoc """
  Hebbian edges between memories must live in the same workspace bucket.
  Treats nil == nil as the same bucket (personal context).
  """
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    a_id =
      Ash.Changeset.get_argument(changeset, :memory_a_id) ||
        Ash.Changeset.get_attribute(changeset, :memory_a_id)

    b_id =
      Ash.Changeset.get_argument(changeset, :memory_b_id) ||
        Ash.Changeset.get_attribute(changeset, :memory_b_id)

    case {load(a_id), load(b_id)} do
      {%{workspace_id: a_ws}, %{workspace_id: b_ws}} when a_ws == b_ws ->
        :ok

      {%{}, %{}} ->
        {:error, field: :memory_b_id, message: "must be in the same workspace as memory_a_id"}

      _ ->
        :ok
    end
  end

  defp load(nil), do: nil

  defp load(id) do
    case Magus.Memory.Memory
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.select([:id, :workspace_id])
         |> Ash.read_one(authorize?: false) do
      {:ok, m} -> m
      _ -> nil
    end
  end
end
