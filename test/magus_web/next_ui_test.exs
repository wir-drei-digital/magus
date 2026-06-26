defmodule MagusWeb.NextUiTest do
  use ExUnit.Case, async: true

  alias MagusWeb.NextUi

  describe "migrated_route?/1" do
    test "no routes are migrated in iteration 0" do
      refute NextUi.migrated_route?("/chat")
      refute NextUi.migrated_route?("/chat/123")
      refute NextUi.migrated_route?("/files")
    end
  end

  describe "enabled_for?/1" do
    test "false for anonymous users" do
      refute NextUi.enabled_for?(nil)
    end

    test "false without an explicit opt-in" do
      refute NextUi.enabled_for?(%{ui_preferences: nil})
      refute NextUi.enabled_for?(%{ui_preferences: %{}})
      refute NextUi.enabled_for?(%{ui_preferences: %{"workbench_ui" => "classic"}})
    end

    test "true when opted into the next UI" do
      assert NextUi.enabled_for?(%{ui_preferences: %{"workbench_ui" => "next"}})
    end
  end
end
