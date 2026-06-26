defmodule MagusWeb.Workbench.Live.TabActionsTest do
  use ExUnit.Case, async: true

  alias MagusWeb.Workbench.Live.TabActions

  describe "find_tab/2" do
    test "returns nil for nil id" do
      assert TabActions.find_tab([], nil) == nil
    end

    test "matches by id" do
      tabs = [%{"id" => "a"}, %{"id" => "b"}]
      assert TabActions.find_tab(tabs, "b") == %{"id" => "b"}
    end
  end

  describe "normalize_label/1" do
    test "passes through non-empty strings" do
      assert TabActions.normalize_label("hello") == "hello"
    end

    test "rejects empty string" do
      assert TabActions.normalize_label("") == nil
    end

    test "rejects non-strings" do
      assert TabActions.normalize_label(nil) == nil
      assert TabActions.normalize_label(:atom) == nil
    end
  end
end
