defmodule Magus.Library.TagTest do
  @moduledoc """
  Tests for the Tag resource.

  Note: Tag is a shared system resource without user ownership or authorization policies.
  All operations use authorize?: false as tags are globally accessible.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Library

  describe "create/1" do
    test "creates tag with valid name" do
      # Tag has no authorizer - shared system resource
      {:ok, tag} = Library.create_tag(%{name: "test-tag"}, authorize?: false)

      assert to_string(tag.name) == "test-tag"
    end

    test "tag name is case-insensitive" do
      {:ok, tag1} = Library.create_tag(%{name: "MyTag"}, authorize?: false)
      {:ok, tag2} = Library.get_tag(tag1.id, authorize?: false)

      # CiString preserves original case in display but compares case-insensitively
      assert to_string(tag2.name) == "MyTag"
      # They are equal when compared as CiString
      assert tag1.name == tag2.name
    end
  end

  describe "get_or_create/1" do
    test "creates new tag if not exists" do
      {:ok, tag} = Library.get_or_create_tag(%{name: "new-unique-tag"}, authorize?: false)

      assert to_string(tag.name) == "new-unique-tag"
    end

    test "returns existing tag if name matches" do
      {:ok, original} = Library.create_tag(%{name: "existing-tag"}, authorize?: false)

      {:ok, found} = Library.get_or_create_tag(%{name: "existing-tag"}, authorize?: false)

      assert found.id == original.id
    end

    test "handles case-insensitive matching" do
      {:ok, original} = Library.create_tag(%{name: "CasedTag"}, authorize?: false)

      {:ok, found} = Library.get_or_create_tag(%{name: "casedtag"}, authorize?: false)

      assert found.id == original.id
    end
  end

  describe "destroy/1" do
    test "deletes tag" do
      {:ok, tag} = Library.create_tag(%{name: "deletable"}, authorize?: false)

      :ok = Library.destroy_tag(tag, authorize?: false)

      {:error, _} = Library.get_tag(tag.id, authorize?: false)
    end
  end

  describe "list_tags/1" do
    test "returns all tags" do
      {:ok, tag1} = Library.create_tag(%{name: "list-tag-1"}, authorize?: false)
      {:ok, tag2} = Library.create_tag(%{name: "list-tag-2"}, authorize?: false)

      {:ok, tags} = Library.list_tags(authorize?: false)

      tag_ids = Enum.map(tags, & &1.id)
      assert tag1.id in tag_ids
      assert tag2.id in tag_ids
    end
  end
end
