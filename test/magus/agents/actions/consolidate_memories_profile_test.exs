defmodule Magus.Agents.Actions.ConsolidateMemoriesProfileTest do
  @moduledoc """
  Tests for the profile distillation step wired into ConsolidateMemories,
  gated by the user's `profile_enabled` setting.
  """

  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.ConsolidateMemories
  alias Magus.Agents.Support.AiAgent
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!
  setup :set_mox_from_context

  @ai %AiAgent{}

  test "daily consolidation distills the profile for each bucket" do
    user =
      generate(user())
      |> Ash.Changeset.for_update(:update_profile_setting, %{profile_enabled: true},
        authorize?: false
      )
      |> Ash.update!()

    {:ok, _} =
      Magus.Memory.create_user_memory(
        user.id,
        nil,
        "Durable Preference",
        %{content: %{}, summary: "Prefers concise, direct answers"},
        actor: @ai
      )

    # ConsolidateMemories makes LLM calls for merge/promote steps too; stub
    # everything generically and return a profile document when the distiller
    # schema is requested (it is the only schema requiring just "document").
    stub(LLMMock, :generate_object, fn _model, _prompt, schema, _opts ->
      if schema["required"] == ["document"] do
        MockResponses.generate_object_response(%{
          "document" => "## Preferences\nConcise answers."
        })
      else
        MockResponses.generate_object_response(%{
          "candidates" => [],
          "merge_groups" => [],
          "extractions" => [],
          "reasoning" => ""
        })
      end
    end)

    assert {:ok, result} = ConsolidateMemories.run(%{user_id: to_string(user.id)}, %{})
    assert result.profiles_distilled == 1

    {:ok, profile} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
    assert profile.document =~ "Concise answers"
  end

  test "profile disabled (default) does not distill a profile" do
    user = generate(user())
    refute user.profile_enabled

    assert {:ok, result} = ConsolidateMemories.run(%{user_id: to_string(user.id)}, %{})
    assert result.profiles_distilled == 0

    assert {:error, _} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
  end

  test "a distillation failure for one bucket logs and does not fail the run" do
    user =
      generate(user())
      |> Ash.Changeset.for_update(:update_profile_setting, %{profile_enabled: true},
        authorize?: false
      )
      |> Ash.update!()

    stub(LLMMock, :generate_object, fn _model, _prompt, schema, _opts ->
      if schema["required"] == ["document"] do
        MockResponses.error_response("distill boom")
      else
        MockResponses.generate_object_response(%{
          "candidates" => [],
          "merge_groups" => [],
          "extractions" => [],
          "reasoning" => ""
        })
      end
    end)

    assert {:ok, result} = ConsolidateMemories.run(%{user_id: to_string(user.id)}, %{})
    assert result.profiles_distilled == 0
  end
end
