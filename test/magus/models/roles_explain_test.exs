defmodule Magus.Models.RolesExplainTest do
  use Magus.DataCase, async: false

  setup do
    original = Application.get_env(:magus, :agents, [])
    on_exit(fn -> Application.put_env(:magus, :agents, original) end)
    :ok
  end

  test "explain reports the winning source" do
    # config wins (test env sets summary_model in config.exs)
    assert {value, :config} = Magus.Models.Roles.explain(:summary)
    assert is_binary(value)

    # assignment wins
    model =
      Magus.Chat.Model
      |> Ash.Changeset.for_create(:create, %{
        name: "X",
        key: "openrouter:explain/x",
        provider: "T",
        context_window: 1_000
      })
      |> Ash.create!(authorize?: false)

    {:ok, _} =
      Magus.Models.assign_role(%{role: "summary", model_id: model.id}, authorize?: false)

    assert {"openrouter:explain/x", :assignment} = Magus.Models.Roles.explain(:summary)
  end

  test "explain reports default and disabled" do
    agents = Application.get_env(:magus, :agents, []) |> Keyword.delete(:title_model)
    Application.put_env(:magus, :agents, agents)
    assert {_value, :default} = Magus.Models.Roles.explain(:title_generation)

    {:ok, _} =
      Magus.Models.assign_role(
        %{role: "intent_classification", disabled?: true},
        authorize?: false
      )

    assert {nil, :disabled} = Magus.Models.Roles.explain(:intent_classification)
  end

  test "explain reports fallback source with the chained role" do
    agents =
      Application.get_env(:magus, :agents, [])
      |> Keyword.delete(:extraction_model)

    Application.put_env(:magus, :agents, agents)
    assert {_value, {:fallback, :summary}} = Magus.Models.Roles.explain(:memory_extraction)
  end

  test "explain reports none then assignment for chat_default" do
    # chat_default has no code default and no fallback; with no config
    # and no assignment, the chain exhausts to :none.
    agents =
      Application.get_env(:magus, :agents, [])
      |> Keyword.delete(:default_model)

    Application.put_env(:magus, :agents, agents)
    assert {nil, :none} = Magus.Models.Roles.explain(:chat_default)

    # A DB role assignment makes the :assignment source win.
    model =
      Magus.Chat.Model
      |> Ash.Changeset.for_create(:create, %{
        name: "Default Chat",
        key: "openrouter:db/default-chat",
        provider: "Test",
        context_window: 1_000
      })
      |> Ash.create!(authorize?: false)

    {:ok, _} =
      Magus.Models.assign_role(%{role: "chat_default", model_id: model.id},
        authorize?: false
      )

    assert {key, :assignment} = Magus.Models.Roles.explain(:chat_default)
    assert key == model.key
  end
end
