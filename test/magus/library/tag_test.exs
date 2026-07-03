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

  describe "scoped tags" do
    test "a tag created with an actor is personal to that user" do
      owner = generate(user())
      other = generate(user())

      {:ok, tag} = Library.create_tag(%{name: "scoped-#{unique()}"}, actor: owner)
      assert tag.user_id == owner.id
      assert tag.workspace_id == nil

      {:ok, owner_tags} = Library.list_tags(actor: owner)
      assert tag.id in Enum.map(owner_tags, & &1.id)

      {:ok, other_tags} = Library.list_tags(actor: other)
      refute tag.id in Enum.map(other_tags, & &1.id)
    end

    test "a workspace tag is visible to active members only" do
      owner = generate(user())
      member = generate(user())
      outsider = generate(user())
      workspace = generate(workspace(actor: owner, slug: "tagtest-#{Ash.UUID.generate()}"))
      workspace_member(user_id: member.id, workspace_id: workspace.id)

      {:ok, tag} =
        Library.create_tag(%{name: "ws-#{unique()}", workspace_id: workspace.id}, actor: owner)

      assert tag.workspace_id == workspace.id
      assert tag.user_id == nil

      {:ok, member_tags} = Library.list_tags(actor: member)
      assert tag.id in Enum.map(member_tags, & &1.id)

      {:ok, outsider_tags} = Library.list_tags(actor: outsider)
      refute tag.id in Enum.map(outsider_tags, & &1.id)
    end

    test "non-members cannot create workspace tags" do
      owner = generate(user())
      outsider = generate(user())
      workspace = generate(workspace(actor: owner, slug: "tagtest-#{Ash.UUID.generate()}"))

      assert {:error, %Ash.Error.Invalid{}} =
               Library.create_tag(
                 %{name: "ws-#{unique()}", workspace_id: workspace.id},
                 actor: outsider
               )
    end

    test "the same name can exist per user, per workspace, and globally" do
      user_a = generate(user())
      user_b = generate(user())
      workspace = generate(workspace(actor: user_a, slug: "tagtest-#{Ash.UUID.generate()}"))
      name = "dup-#{unique()}"

      {:ok, global} = Library.create_tag(%{name: name}, authorize?: false)
      {:ok, personal_a} = Library.create_tag(%{name: name}, actor: user_a)
      {:ok, personal_b} = Library.create_tag(%{name: name}, actor: user_b)

      {:ok, ws_tag} =
        Library.create_tag(%{name: name, workspace_id: workspace.id}, actor: user_a)

      assert Enum.uniq([global.id, personal_a.id, personal_b.id, ws_tag.id]) |> length() == 4

      # But within one scope the name stays unique (upsert returns the original).
      {:ok, again} = Library.get_or_create_tag(%{name: name}, actor: user_a)
      assert again.id == personal_a.id

      {:ok, ws_again} =
        Library.get_or_create_tag(%{name: name, workspace_id: workspace.id}, actor: user_a)

      assert ws_again.id == ws_tag.id
    end

    test "legacy global tags stay readable by everyone" do
      viewer = generate(user())
      {:ok, tag} = Library.create_tag(%{name: "global-#{unique()}"}, authorize?: false)

      {:ok, tags} = Library.list_tags(actor: viewer)
      assert tag.id in Enum.map(tags, & &1.id)
    end

    test "only the owner can destroy a personal tag" do
      owner = generate(user())
      other = generate(user())
      {:ok, tag} = Library.create_tag(%{name: "mine-#{unique()}"}, actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} = Library.destroy_tag(tag, actor: other)
      assert :ok = Library.destroy_tag(tag, actor: owner)
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
