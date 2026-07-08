defmodule Magus.Memory.WorkspaceLookupTest do
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  describe "fetch_workspace_id_for_conversation/1" do
    test "returns {:ok, workspace_id} for a workspace conversation" do
      user = generate(user())
      workspace = generate(workspace(actor: user))

      {:ok, conversation} =
        Chat.create_conversation(%{workspace_id: workspace.id}, actor: user)

      assert {:ok, workspace_id} =
               Magus.Memory.fetch_workspace_id_for_conversation(conversation.id)

      assert workspace_id == workspace.id
    end

    test "returns {:ok, nil} for a personal conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      assert {:ok, nil} = Magus.Memory.fetch_workspace_id_for_conversation(conversation.id)
    end

    test "returns {:error, :not_found} for an unknown conversation id" do
      assert {:error, :not_found} =
               Magus.Memory.fetch_workspace_id_for_conversation(Ash.UUID.generate())
    end

    test "returns {:error, :not_found} for nil" do
      assert {:error, :not_found} = Magus.Memory.fetch_workspace_id_for_conversation(nil)
    end
  end
end
