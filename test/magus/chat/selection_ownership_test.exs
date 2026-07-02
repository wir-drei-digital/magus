defmodule Magus.Chat.SelectionOwnershipTest do
  @moduledoc "Selection writes must reject models the actor does not own."
  use Magus.DataCase, async: false

  import Magus.Generators

  setup do
    Magus.DataCase.clear_catalog!()
    user = generate(user())
    other = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk"},
        actor: other
      )

    {:ok, others_model} =
      Magus.Chat.create_owned_model(
        %{name: "C", model_id: "claude-x", model_provider_id: provider.id},
        actor: other
      )

    %{user: user, others_model: others_model}
  end

  test "selecting another user's owned model is rejected", %{user: user, others_model: m} do
    assert {:error, _} =
             user
             |> Ash.Changeset.for_update(:select_model, %{selected_model_id: m.id}, actor: user)
             |> Ash.update()
  end

  test "conversation set_model rejects another user's owned model", %{
    user: user,
    others_model: m
  } do
    conversation = generate(conversation(actor: user))

    assert {:error, _} =
             conversation
             |> Ash.Changeset.for_update(:set_model, %{selected_model_id: m.id}, actor: user)
             |> Ash.update()
  end

  test "selecting nil clears the selection", %{user: user} do
    assert {:ok, updated} =
             user
             |> Ash.Changeset.for_update(:select_model, %{selected_model_id: nil}, actor: user)
             |> Ash.update()

    assert is_nil(updated.selected_model_id)
  end

  test "selecting a global active model succeeds", %{user: user} do
    global = generate(model())

    assert {:ok, updated} =
             user
             |> Ash.Changeset.for_update(:select_model, %{selected_model_id: global.id},
               actor: user
             )
             |> Ash.update()

    assert updated.selected_model_id == global.id
  end
end
