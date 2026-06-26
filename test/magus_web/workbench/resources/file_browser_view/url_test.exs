defmodule MagusWeb.Workbench.Resources.FileBrowserView.UrlTest do
  use ExUnit.Case, async: true

  alias MagusWeb.Workbench.Resources.FileBrowserView.Url

  describe "build_primary/3" do
    test "returns the canonical primary shape" do
      params = %{"type" => "image", "modified" => "today", "sort" => "name:asc", "q" => "cat"}

      assert Url.build_primary("my_files", nil, params) == %{
               "type" => "file_browser",
               "scope" => "my_files",
               "id" => nil,
               "filters" => %{
                 "type" => "image",
                 "modified" => "today",
                 "source" => nil
               },
               "sort" => "name:asc",
               "q" => "cat"
             }
    end

    test "applies defaults when params are sparse" do
      assert Url.build_primary("trash", nil, %{}) == %{
               "type" => "file_browser",
               "scope" => "trash",
               "id" => nil,
               "filters" => %{"type" => nil, "modified" => nil, "source" => nil},
               "sort" => "updated_at:desc",
               "q" => ""
             }
    end
  end

  describe "base_path/1" do
    test "folder scope renders /files/folder/:id" do
      assert Url.base_path(%{"scope" => "folder", "id" => "abc"}) == "/files/folder/abc"
    end

    test "knowledge scope renders /files/knowledge/:id" do
      assert Url.base_path(%{"scope" => "knowledge", "id" => "abc"}) == "/files/knowledge/abc"
    end

    test "my_files renders /files" do
      assert Url.base_path(%{"scope" => "my_files"}) == "/files"
    end

    test "other scopes append ?scope=" do
      assert Url.base_path(%{"scope" => "shared"}) == "/files?scope=shared"
    end
  end

  describe "url_params/1" do
    test "drops default sort and empty q" do
      primary = %{
        "filters" => %{"type" => "image", "modified" => nil, "source" => nil},
        "sort" => "updated_at:desc",
        "q" => ""
      }

      assert Url.url_params(primary) == %{
               "type" => "image",
               "modified" => nil,
               "source" => nil,
               "sort" => nil,
               "q" => nil
             }
    end
  end

  describe "drop_nil_or_empty/1" do
    test "removes nil and empty-string values" do
      assert Url.drop_nil_or_empty(%{"a" => "x", "b" => nil, "c" => ""}) == %{"a" => "x"}
    end
  end
end
