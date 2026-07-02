defmodule Magus.Chat.ModelWriteFloorTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  setup do
    Magus.DataCase.clear_catalog!()
    %{user: generate(user())}
  end

  test "non-admin cannot use the admin create/update/destroy", %{user: user} do
    assert {:error, %Ash.Error.Forbidden{}} =
             Magus.Chat.Model
             |> Ash.Changeset.for_create(
               :create,
               %{name: "x", key: "openrouter:x/y", context_window: 10},
               actor: user
             )
             |> Ash.create()
  end

  test "reads and owned actions unchanged", %{user: user} do
    assert {:ok, _} = Magus.Chat.list_active_models(actor: user)

    {:ok, provider} =
      Magus.Models.create_owned_provider(%{name: "P", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    assert {:ok, model} =
             Magus.Chat.create_owned_model(
               %{name: "M", model_id: "gpt-x", model_provider_id: provider.id},
               actor: user
             )

    assert :ok = Magus.Chat.destroy_owned_model(model, actor: user)
  end
end
