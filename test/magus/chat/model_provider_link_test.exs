defmodule Magus.Chat.ModelProviderLinkTest do
  use Magus.DataCase, async: true

  setup do
    # Clear seeded catalog rows (and their referencing rows) so the "openrouter"
    # slug is free. Rolled back after the test.
    Magus.DataCase.clear_catalog!()
    :ok
  end

  test "model can be created with a provider link and llm_metadata" do
    {:ok, provider} =
      Magus.Models.create_provider(
        %{name: "OpenRouter", slug: "openrouter", req_llm_id: "openrouter"},
        authorize?: false
      )

    assert {:ok, model} =
             Magus.Chat.Model
             |> Ash.Changeset.for_create(:create, %{
               name: "Test Model",
               key: "openrouter:test/model-1",
               provider: "TestCorp",
               context_window: 100_000,
               model_provider_id: provider.id,
               llm_metadata: %{"output_limit" => 16_000, "cache_read" => 0.5}
             })
             |> Ash.create()

    assert model.model_provider_id == provider.id
    assert model.llm_metadata["output_limit"] == 16_000
  end

  test "llm_metadata defaults to empty map" do
    assert {:ok, model} =
             Magus.Chat.Model
             |> Ash.Changeset.for_create(:create, %{
               name: "Bare Model",
               key: "openrouter:test/bare",
               provider: "TestCorp",
               context_window: 1_000
             })
             |> Ash.create()

    assert model.llm_metadata == %{}
  end
end
