defmodule Magus.Brain.Checks.ActorOwnsBrain do
  @moduledoc """
  Checks if the actor owns the brain or has a `Magus.Workspaces.ResourceAccess`
  grant on the brain with sufficient role.

  Parameterized via opts to support different relationship paths:
  - `strategy: :brain_id_argument` - brain_id is an action argument (Page create)
  - `strategy: :via_page` - resolves brain_id through page_id attribute (Block create)
  - `strategy: :via_block` - resolves brain_id through source_block_id attribute (Connection create)

  Also supports `min_role` option (default `:editor`) with role hierarchy:
  viewer < editor < owner
  """
  use Ash.Policy.SimpleCheck

  require Ash.Query

  @impl true
  def describe(opts) do
    min_role = opts[:min_role] || :editor

    case opts[:strategy] do
      :brain_id_argument ->
        "actor owns brain or has #{min_role}+ access (via brain_id argument)"

      :via_page ->
        "actor owns brain or has #{min_role}+ access (via page)"

      :via_block ->
        "actor owns brain or has #{min_role}+ access (via source block -> page)"
    end
  end

  @impl true
  def match?(actor, %{changeset: changeset}, opts) when not is_nil(actor) do
    min_role = opts[:min_role] || :editor

    brain_id =
      case opts[:strategy] do
        :brain_id_argument ->
          Ash.Changeset.get_argument(changeset, :brain_id)

        :via_page ->
          resolve_brain_id_via_page(Ash.Changeset.get_attribute(changeset, :page_id))

        :via_block ->
          resolve_brain_id_via_block(Ash.Changeset.get_attribute(changeset, :source_block_id))
      end

    cond do
      is_nil(brain_id) -> false
      owns_brain?(brain_id, actor) -> true
      workspace_admin_for_brain?(brain_id, actor) -> true
      Magus.Workspaces.AccessCheck.has_access?(:brain, brain_id, actor, min_role) -> true
      true -> false
    end
  end

  def match?(_, _, _), do: false

  defp owns_brain?(brain_id, %{id: actor_id}) when not is_nil(actor_id) do
    case Magus.Brain.BrainResource
         |> Ash.Query.filter(id == ^brain_id and user_id == ^actor_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> false
      {:ok, _brain} -> true
      {:error, _} -> false
    end
  end

  defp owns_brain?(_, _), do: false

  defp workspace_admin_for_brain?(brain_id, actor) do
    actor_id = actor_user_id(actor)

    if is_nil(actor_id) do
      false
    else
      case Magus.Brain.BrainResource
           |> Ash.Query.filter(id == ^brain_id)
           |> Ash.Query.select([:id, :workspace_id])
           |> Ash.read_one(authorize?: false) do
        {:ok, %{workspace_id: nil}} ->
          false

        {:ok, %{workspace_id: ws_id}} ->
          case Magus.Workspaces.WorkspaceMember
               |> Ash.Query.filter(
                 user_id == ^actor_id and workspace_id == ^ws_id and
                   is_active == true and role == :admin
               )
               |> Ash.read_one(authorize?: false) do
            {:ok, %{}} -> true
            _ -> false
          end

        _ ->
          false
      end
    end
  end

  defp actor_user_id(%Magus.Accounts.User{id: id}), do: id
  defp actor_user_id(%Magus.Agents.Support.AiAgent{user_id: id}), do: id
  defp actor_user_id(_), do: nil

  defp resolve_brain_id_via_page(nil), do: nil

  defp resolve_brain_id_via_page(page_id) do
    case Magus.Brain.Page
         |> Ash.Query.filter(id == ^page_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %{brain_id: brain_id}} when not is_nil(brain_id) -> brain_id
      _ -> nil
    end
  end

  defp resolve_brain_id_via_block(nil), do: nil

  defp resolve_brain_id_via_block(source_block_id) do
    case Magus.Brain.Block
         |> Ash.Query.filter(id == ^source_block_id)
         |> Ash.Query.load(:page)
         |> Ash.read_one(authorize?: false) do
      {:ok, %{page: %{brain_id: brain_id}}} when not is_nil(brain_id) -> brain_id
      _ -> nil
    end
  end
end
