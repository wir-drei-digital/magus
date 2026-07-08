defmodule Magus.Chat.ConversationCompanionTest do
  use Magus.ResourceCase, async: true

  require Ash.Query

  alias Magus.Chat
  alias Magus.Chat.ConversationCompanion

  describe "identities" do
    test "user_id + resource_type + resource_id is unique" do
      user = generate(user())
      {:ok, conv1} = Chat.create_conversation(%{title: "A"}, actor: user)
      {:ok, conv2} = Chat.create_conversation(%{title: "B"}, actor: user)

      attrs = %{
        resource_type: :file,
        resource_id: Ash.UUIDv7.generate(),
        conversation_id: conv1.id
      }

      assert {:ok, _} = Ash.create(ConversationCompanion, attrs, actor: user)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(ConversationCompanion, %{attrs | conversation_id: conv2.id},
                 actor: user
               )
    end

    test "conversation_id is unique" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "A"}, actor: user)

      assert {:ok, _} =
               Ash.create(
                 ConversationCompanion,
                 %{
                   resource_type: :file,
                   resource_id: Ash.UUIDv7.generate(),
                   conversation_id: conv.id
                 },
                 actor: user
               )

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(
                 ConversationCompanion,
                 %{
                   resource_type: :file,
                   resource_id: Ash.UUIDv7.generate(),
                   conversation_id: conv.id
                 },
                 actor: user
               )
    end
  end

  describe "create validation" do
    test "actor cannot create a link pointing at another user's conversation" do
      owner = generate(user())
      attacker = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "owner's"}, actor: owner)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(
                 ConversationCompanion,
                 %{
                   resource_type: :file,
                   resource_id: Ash.UUIDv7.generate(),
                   conversation_id: conv.id
                 },
                 actor: attacker
               )

      # The owner can still claim the link (no row was created by the
      # attacker, so the unique-on-conversation constraint is free).
      assert {:ok, _} =
               Ash.create(
                 ConversationCompanion,
                 %{
                   resource_type: :file,
                   resource_id: Ash.UUIDv7.generate(),
                   conversation_id: conv.id
                 },
                 actor: owner
               )
    end
  end

  describe "policies" do
    test "user A cannot read user B's link" do
      user_a = generate(user())
      user_b = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "A"}, actor: user_a)

      {:ok, _link} =
        Ash.create(
          ConversationCompanion,
          %{resource_type: :file, resource_id: Ash.UUIDv7.generate(), conversation_id: conv.id},
          actor: user_a
        )

      assert {:ok, []} =
               ConversationCompanion
               |> Ash.Query.for_read(:read, %{}, actor: user_b)
               |> Ash.read()
    end
  end

  describe ":by_resource read action" do
    test "returns the actor's link for the given resource" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "Companion"}, actor: user)
      file_id = Ash.UUIDv7.generate()

      {:ok, _link} =
        Ash.create(
          ConversationCompanion,
          %{resource_type: :file, resource_id: file_id, conversation_id: conv.id},
          actor: user
        )

      assert {:ok, %ConversationCompanion{conversation_id: cid}} =
               Chat.get_companion_by_resource(:file, file_id, actor: user)

      assert cid == conv.id
    end

    test "returns :not_found for another user's link" do
      user_a = generate(user())
      user_b = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "X"}, actor: user_a)
      file_id = Ash.UUIDv7.generate()

      {:ok, _} =
        Ash.create(
          ConversationCompanion,
          %{resource_type: :file, resource_id: file_id, conversation_id: conv.id},
          actor: user_a
        )

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Chat.get_companion_by_resource(:file, file_id, actor: user_b)
    end
  end

  describe ":by_conversation_id read action" do
    test "returns the actor's link for the conversation" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "X"}, actor: user)
      file_id = Ash.UUIDv7.generate()

      {:ok, _} =
        Ash.create(
          ConversationCompanion,
          %{resource_type: :file, resource_id: file_id, conversation_id: conv.id},
          actor: user
        )

      assert {:ok, %ConversationCompanion{resource_id: ^file_id}} =
               Chat.get_companion_by_conversation(conv.id, actor: user)
    end

    test "returns :not_found when conversation has no link" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "X"}, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Chat.get_companion_by_conversation(conv.id, actor: user)
    end
  end

  describe "find_or_create_companion_conversation" do
    test "creates a new conversation linked to the resource on first call" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))
      file = file_in_workspace(user, workspace)

      assert {:ok, conv} =
               Chat.find_or_create_companion_conversation(:file, file.id, actor: user)

      assert conv.workspace_id == workspace.id
      assert conv.user_id == user.id

      assert {:ok, link} = Chat.get_companion_by_conversation(conv.id, actor: user)
      assert link.resource_id == file.id
    end

    test "returns the existing conversation on second call" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))
      file = file_in_workspace(user, workspace)

      {:ok, conv1} = Chat.find_or_create_companion_conversation(:file, file.id, actor: user)
      {:ok, conv2} = Chat.find_or_create_companion_conversation(:file, file.id, actor: user)

      assert conv1.id == conv2.id
    end

    test "returns error when actor cannot read the resource" do
      owner = generate(user())
      ensure_workspace_plan(owner)
      stranger = generate(user())
      workspace = generate(workspace(actor: owner))
      file = file_in_workspace(owner, workspace)

      assert {:error, _} =
               Chat.find_or_create_companion_conversation(:file, file.id, actor: stranger)
    end

    test "a brain-page companion inherits the brain's workspace" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      {:ok, brain} =
        Magus.Brain.create_brain(%{title: "WS Brain", workspace_id: workspace.id}, actor: user)

      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      assert {:ok, conv} =
               Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

      # A page has no workspace_id of its own; the companion must inherit the
      # brain's so the chat, the brain, and the agent share one workspace.
      assert conv.workspace_id == workspace.id
    end

    test "a personal brain-page companion has no workspace" do
      user = generate(user())

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Personal Brain"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      assert {:ok, conv} =
               Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

      assert conv.workspace_id == nil
    end
  end

  describe "unlink_companion_for_resource" do
    test "drops links for all users but keeps the conversations" do
      user_a = generate(user())
      user_b = generate(user())
      file_id = Ash.UUIDv7.generate()
      {:ok, conv_a} = Chat.create_conversation(%{title: "A"}, actor: user_a)
      {:ok, conv_b} = Chat.create_conversation(%{title: "B"}, actor: user_b)

      {:ok, _} =
        Ash.create(
          ConversationCompanion,
          %{resource_type: :file, resource_id: file_id, conversation_id: conv_a.id},
          actor: user_a
        )

      {:ok, _} =
        Ash.create(
          ConversationCompanion,
          %{resource_type: :file, resource_id: file_id, conversation_id: conv_b.id},
          actor: user_b
        )

      assert :ok = Chat.unlink_companion_for_resource(:file, file_id)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Chat.get_companion_by_conversation(conv_a.id, actor: user_a)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Chat.get_companion_by_conversation(conv_b.id, actor: user_b)

      assert {:ok, _} = Chat.get_conversation(conv_a.id, actor: user_a)
      assert {:ok, _} = Chat.get_conversation(conv_b.id, actor: user_b)
    end
  end

  defp file_in_workspace(user, workspace) do
    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "ash.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 100,
          file_path: "#{user.id}/#{Ash.UUIDv7.generate()}.pdf",
          workspace_id: workspace.id
        },
        actor: user
      )

    file
  end
end
