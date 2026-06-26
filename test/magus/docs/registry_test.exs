defmodule Magus.Docs.RegistryTest do
  use ExUnit.Case, async: true

  alias Magus.Docs.Registry

  describe "categories/1" do
    test "returns ordered categories with labels for English" do
      categories = Registry.categories("en")
      assert length(categories) >= 3

      keys = Enum.map(categories, & &1.key)
      assert "getting-started" in keys
      assert "conversations" in keys
      assert "agents" in keys
      assert "integrations" in keys

      # Verify ordering
      gs_idx = Enum.find_index(categories, &(&1.key == "getting-started"))
      conv_idx = Enum.find_index(categories, &(&1.key == "conversations"))
      agents_idx = Enum.find_index(categories, &(&1.key == "agents"))
      int_idx = Enum.find_index(categories, &(&1.key == "integrations"))
      assert gs_idx < conv_idx
      assert conv_idx < agents_idx
      assert agents_idx < int_idx
    end

    test "returns German labels for de locale" do
      categories = Registry.categories("de")
      gs = Enum.find(categories, &(&1.key == "getting-started"))
      assert gs.label == "Erste Schritte"
    end

    test "falls back to English for unknown locale" do
      categories = Registry.categories("fr")
      gs = Enum.find(categories, &(&1.key == "getting-started"))
      assert gs.label == "Getting Started"
    end
  end

  describe "list_docs/1" do
    test "returns docs grouped by category for English" do
      docs = Registry.list_docs("en")
      assert is_list(docs)

      # Each entry has required fields
      first = hd(docs)
      assert Map.has_key?(first, :slug)
      assert Map.has_key?(first, :title)
      assert Map.has_key?(first, :description)
      assert Map.has_key?(first, :category)
    end

    test "docs are ordered by category order then doc order" do
      docs = Registry.list_docs("en")
      categories = Enum.map(docs, & &1.category)

      # Categories should appear in the defined order
      unique_cats = Enum.uniq(categories)
      category_order = Registry.categories("en") |> Enum.map(& &1.key)
      assert unique_cats == Enum.filter(category_order, &(&1 in unique_cats))
    end
  end

  describe "get_doc/2" do
    test "returns a doc with rendered HTML for English" do
      doc = Registry.get_doc("en", "overview")
      assert doc != nil
      assert doc.slug == "overview"
      assert doc.title == "Overview"
      assert is_binary(doc.html)
      assert doc.html =~ "<"
    end

    test "returns German doc for de locale" do
      doc = Registry.get_doc("de", "overview")
      assert doc != nil
      assert doc.title != nil
    end

    test "falls back to English when locale doc not found" do
      doc = Registry.get_doc("fr", "overview")
      assert doc != nil
      assert doc == Registry.get_doc("en", "overview")
    end

    test "returns nil for unknown slug" do
      assert Registry.get_doc("en", "nonexistent") == nil
    end
  end
end
