defmodule Magus.Models.RoleAssignmentTest do
  use Magus.DataCase, async: true

  defp create_model! do
    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, %{
      name: "Role Target",
      key: "openrouter:role/target-#{System.unique_integer([:positive])}",
      provider: "Test",
      context_window: 1_000
    })
    |> Ash.create!()
  end

  test "upsert assignment by role" do
    model = create_model!()

    assert {:ok, assignment} =
             Magus.Models.assign_role(
               %{role: "title_generation", model_id: model.id},
               authorize?: false
             )

    assert assignment.model_id == model.id

    # upsert: same role, new model replaces
    model2 = create_model!()

    assert {:ok, updated} =
             Magus.Models.assign_role(
               %{role: "title_generation", model_id: model2.id},
               authorize?: false
             )

    assert updated.model_id == model2.id
    assert Enum.count(Magus.Models.list_role_assignments!()) == 1
  end

  test "rejects unknown role keys" do
    model = create_model!()

    assert {:error, %Ash.Error.Invalid{}} =
             Magus.Models.assign_role(
               %{role: "not_a_role", model_id: model.id},
               authorize?: false
             )
  end

  test "disabled assignment without model" do
    assert {:ok, assignment} =
             Magus.Models.assign_role(
               %{role: "intent_classification", disabled?: true},
               authorize?: false
             )

    assert assignment.disabled?
    assert assignment.model_id == nil
  end

  test "writes are admin-only" do
    model = create_model!()

    assert {:error, %Ash.Error.Forbidden{}} =
             Magus.Models.assign_role(%{role: "summary", model_id: model.id})
  end

  test "get_role_assignment by role string" do
    model = create_model!()

    {:ok, _} =
      Magus.Models.assign_role(%{role: "summary", model_id: model.id}, authorize?: false)

    assert {:ok, found} = Magus.Models.get_role_assignment("summary")
    assert found.model_id == model.id
  end
end
