defmodule Magus.Chat.ModelDeniedProvidersTest do
  use Magus.DataCase, async: true

  test "denied_providers defaults to [] and is updatable" do
    model =
      Ash.create!(
        Magus.Chat.Model,
        %{name: "T", key: "openrouter:test/t", api_provider: :openrouter},
        action: :create,
        authorize?: false
      )

    assert model.denied_providers == []

    updated =
      Ash.update!(model, %{denied_providers: ["deepseek"]},
        action: :update,
        authorize?: false
      )

    assert updated.denied_providers == ["deepseek"]

    reloaded = Magus.Chat.get_model!(model.id, authorize?: false)
    assert reloaded.denied_providers == ["deepseek"]
  end
end
