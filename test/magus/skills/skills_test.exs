defmodule Magus.SkillsTest do
  use ExUnit.Case, async: true

  test "enabled? defaults to true" do
    assert Magus.Skills.enabled?() == true
  end

  test "enabled? respects config override" do
    original = Application.get_env(:magus, Magus.Skills)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:magus, Magus.Skills)
        cfg -> Application.put_env(:magus, Magus.Skills, cfg)
      end
    end)

    Application.put_env(:magus, Magus.Skills, enabled: false)
    assert Magus.Skills.enabled?() == false
  end
end
