defmodule Magus.Brain.BlockSerializerTest do
  use ExUnit.Case, async: true

  alias Magus.Brain.BlockSerializer

  defp block(attrs) do
    Map.merge(
      %{
        id: "blk_#{System.unique_integer([:positive])}",
        type: :paragraph,
        content: %{},
        position: 1.0,
        depth: 0,
        parent_block_id: nil,
        metadata: %{},
        contributor_type: nil
      },
      attrs
    )
  end

  describe "serialize_blocks/2" do
    test "happy path: serializes a paragraph block to JS shape" do
      blocks = [
        block(%{
          id: "p1",
          type: :paragraph,
          content: %{"text" => "hello"},
          position: 1.0,
          depth: 0,
          contributor_type: :user
        })
      ]

      assert [serialized] = BlockSerializer.serialize_blocks(blocks)

      assert serialized == %{
               id: "p1",
               type: "paragraph",
               content: %{"text" => "hello"},
               position: 1.0,
               depth: 0,
               parent_block_id: nil,
               metadata: %{},
               contributor_type: "user"
             }
    end

    test "stringifies type and contributor_type, defaults nil content/metadata" do
      blocks = [block(%{type: :heading, contributor_type: :agent, content: nil, metadata: nil})]

      assert [serialized] = BlockSerializer.serialize_blocks(blocks)
      assert serialized.type == "heading"
      assert serialized.contributor_type == "agent"
      assert serialized.content == %{}
      assert serialized.metadata == %{}
    end

    test "leaves nil contributor_type as nil" do
      blocks = [block(%{contributor_type: nil})]
      assert [%{contributor_type: nil}] = BlockSerializer.serialize_blocks(blocks)
    end

    test "non-list input returns an empty list" do
      assert BlockSerializer.serialize_blocks(nil) == []
      assert BlockSerializer.serialize_blocks(:not_a_list) == []
    end

    test ":file block injects file summary under content[\"file\"] when present" do
      file = %{
        id: "f1",
        name: "doc.pdf",
        mime_type: "application/pdf",
        type: :document,
        file_size: 1024,
        file_path: nil,
        status: :ready
      }

      blocks = [
        block(%{
          id: "fb1",
          type: :file,
          content: %{"file_id" => "f1", "caption" => "see this"}
        })
      ]

      assert [serialized] = BlockSerializer.serialize_blocks(blocks, %{"f1" => file})
      assert serialized.type == "file"
      assert serialized.content["caption"] == "see this"

      assert serialized.content["file"] == %{
               id: "f1",
               name: "doc.pdf",
               mime_type: "application/pdf",
               type: "document",
               file_size: 1024,
               file_path: nil,
               status: "ready",
               # nil file_path means url is nil; storage is not consulted
               url: nil
             }
    end

    test ":file block sets content[\"file\"] to nil when file is missing or unavailable" do
      blocks = [
        block(%{
          id: "fb1",
          type: :file,
          content: %{"file_id" => "missing"}
        })
      ]

      # Empty map means the file_id key isn't found
      assert [%{content: %{"file" => nil}}] =
               BlockSerializer.serialize_blocks(blocks, %{})

      # Explicit nil for the file_id (matches FileBlockLoader unauthorized result)
      assert [%{content: %{"file" => nil}}] =
               BlockSerializer.serialize_blocks(blocks, %{"missing" => nil})
    end

    test "non-file blocks ignore file_block_files" do
      blocks = [block(%{id: "p1", type: :paragraph, content: %{"text" => "hi"}})]

      assert [serialized] =
               BlockSerializer.serialize_blocks(blocks, %{"f1" => %{id: "f1"}})

      refute Map.has_key?(serialized.content, "file")
    end
  end

  describe "file_summary_for_js/1" do
    test "returns nil for nil" do
      assert BlockSerializer.file_summary_for_js(nil) == nil
    end

    test "shapes the file map and resolves url to nil when file_path is nil" do
      file = %{
        id: "f1",
        name: "n",
        mime_type: "image/png",
        type: :image,
        file_size: 10,
        file_path: nil,
        status: :pending
      }

      assert BlockSerializer.file_summary_for_js(file) == %{
               id: "f1",
               name: "n",
               mime_type: "image/png",
               type: "image",
               file_size: 10,
               file_path: nil,
               status: "pending",
               url: nil
             }
    end
  end

  describe "file_url/1" do
    test "returns nil for nil file_path" do
      assert BlockSerializer.file_url(%{file_path: nil}) == nil
    end

    test "returns nil for non-file maps" do
      assert BlockSerializer.file_url(%{}) == nil
    end
  end
end
