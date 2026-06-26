defmodule Magus.Chat.ObserverRoleTest do
  use Magus.ResourceCase, async: true

  describe "observer role" do
    test "observer cannot send messages to a multiplayer conversation" do
      owner = generate(user())
      observer_user = generate(user())

      {:ok, conversation} = Chat.create_conversation(%{title: "Shared"}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, member} =
        Chat.add_conversation_member(
          conversation.id,
          observer_user.id,
          %{role: :observer},
          authorize?: false
        )

      # Accept the invitation so accepted_at is set (required for the check to evaluate the role)
      {:ok, _} = Chat.accept_conversation_invitation(member, actor: observer_user)

      result =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(
          :send_user_message,
          %{
            text: "hi",
            conversation_id: conversation.id
          },
          actor: observer_user
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "regular member can send messages" do
      owner = generate(user())
      member_user = generate(user())

      {:ok, conversation} = Chat.create_conversation(%{title: "Shared"}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, member} =
        Chat.add_conversation_member(
          conversation.id,
          member_user.id,
          %{},
          authorize?: false
        )

      {:ok, _} = Chat.accept_conversation_invitation(member, actor: member_user)

      result =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(
          :send_user_message,
          %{
            text: "hi",
            conversation_id: conversation.id
          },
          actor: member_user
        )
        |> Ash.create()

      assert {:ok, _} = result
    end
  end
end
