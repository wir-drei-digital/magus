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

  # NormalizeDeniedProviders strips the admin form's blank sentinel (and
  # whitespace/duplicates) so an all-unchecked submit persists [] not [""].
  defp create(denied_providers) do
    Ash.create!(
      Magus.Chat.Model,
      %{
        name: "T",
        key: "openrouter:test/t",
        api_provider: :openrouter,
        denied_providers: denied_providers
      },
      action: :create,
      authorize?: false
    )
  end

  test "create normalizes the blank sentinel [\"\"] to []" do
    assert create([""]).denied_providers == []
  end

  test "create strips blanks but keeps real slugs" do
    assert create(["deepseek", ""]).denied_providers == ["deepseek"]
  end

  test "create trims whitespace and de-duplicates" do
    assert create(["deepseek", " deepseek ", ""]).denied_providers == ["deepseek"]
  end

  test "update normalizes the blank sentinel [\"\"] to []" do
    updated =
      create(["deepseek"])
      |> Ash.update!(%{denied_providers: [""]}, action: :update, authorize?: false)

    assert updated.denied_providers == []
  end
end
