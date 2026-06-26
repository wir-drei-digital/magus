defmodule Magus.Models.RolesResolveTest do
  use Magus.DataCase, async: false

  alias Magus.Models.Roles

  # Tests temporarily override :agents config; restore after each test.
  setup do
    original = Application.get_env(:magus, :agents, [])
    on_exit(fn -> Application.put_env(:magus, :agents, original) end)
    %{original: original}
  end

  defp put_agents_config(key, value) do
    current = Application.get_env(:magus, :agents, [])
    Application.put_env(:magus, :agents, Keyword.put(current, key, value))
  end

  defp delete_agents_config(key) do
    current = Application.get_env(:magus, :agents, [])
    Application.put_env(:magus, :agents, Keyword.delete(current, key))
  end

  defp create_model!(key) do
    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, %{
      name: "M #{key}",
      key: key,
      provider: "Test",
      context_window: 1_000
    })
    |> Ash.create!(authorize?: false)
  end

  test "assignment row without model and not disabled counts as no assignment" do
    delete_agents_config(:title_model)

    {:ok, _} =
      Magus.Models.assign_role(
        %{role: "title_generation", model_id: nil, disabled?: false},
        authorize?: false
      )

    assert Roles.resolve(:title_generation) == "openrouter:anthropic/claude-haiku-4.5"
  end

  test "DB assignment wins over config" do
    model = create_model!("openrouter:assigned/title")
    put_agents_config(:title_model, "openrouter:config/title")

    {:ok, _} =
      Magus.Models.assign_role(
        %{role: "title_generation", model_id: model.id},
        authorize?: false
      )

    assert Roles.resolve(:title_generation) == "openrouter:assigned/title"
  end

  test "config wins over code default" do
    delete_agents_config(:title_model)
    put_agents_config(:title_model, "openrouter:config/title")
    assert Roles.resolve(:title_generation) == "openrouter:config/title"
  end

  test "code default when config key absent" do
    delete_agents_config(:title_model)
    assert Roles.resolve(:title_generation) == "openrouter:anthropic/claude-haiku-4.5"
  end

  test "explicitly-nil config disables a nilable role" do
    put_agents_config(:classification_model, nil)
    assert Roles.resolve(:intent_classification) == nil
  end

  test "absent config falls to code default for nilable role" do
    delete_agents_config(:classification_model)
    assert Roles.resolve(:intent_classification) == "openrouter:mistralai/ministral-3b-2512"
  end

  test "disabled assignment turns a nilable role off" do
    delete_agents_config(:classification_model)

    {:ok, _} =
      Magus.Models.assign_role(
        %{role: "intent_classification", disabled?: true},
        authorize?: false
      )

    assert Roles.resolve(:intent_classification) == nil
  end

  test "disabled assignment on non-nilable role continues down the chain" do
    delete_agents_config(:title_model)

    {:ok, _} =
      Magus.Models.assign_role(
        %{role: "title_generation", disabled?: true},
        authorize?: false
      )

    assert Roles.resolve(:title_generation) == "openrouter:anthropic/claude-haiku-4.5"
  end

  test "fallback chain: memory_extraction falls through to summary" do
    delete_agents_config(:extraction_model)
    put_agents_config(:summary_model, "openrouter:config/summary")
    assert Roles.resolve(:memory_extraction) == "openrouter:config/summary"
  end

  test "chat_default resolves to its DB role assignment" do
    delete_agents_config(:default_model)
    model = create_model!("openrouter:db/default-chat")

    {:ok, _} =
      Magus.Models.assign_role(
        %{role: "chat_default", model_id: model.id},
        authorize?: false
      )

    assert Roles.resolve(:chat_default) == "openrouter:db/default-chat"
  end

  test "image_default assignment wins over code default" do
    model = create_model!("openrouter:db/default-image")

    {:ok, _} =
      Magus.Models.assign_role(
        %{role: "image_default", model_id: model.id},
        authorize?: false
      )

    assert Roles.resolve(:image_default) == "openrouter:db/default-image"
  end

  test "image_default code default when no assignment row" do
    assert Roles.resolve(:image_default) ==
             "openrouter:google/gemini-3.1-flash-image-preview"
  end

  test "assignment pointing at a deleted/inactive-path model still resolves by key" do
    model = create_model!("openrouter:assigned/sb")

    {:ok, _} =
      Magus.Models.assign_role(
        %{role: "super_brain_extraction", model_id: model.id},
        authorize?: false
      )

    assert Roles.resolve(:super_brain_extraction) == "openrouter:assigned/sb"
  end
end
