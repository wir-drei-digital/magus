defmodule MagusWeb.E2E.MultiplayerTest do
  @moduledoc """
  Browser-based E2E tests for multiplayer/collaborative chat features.

  Since Playwright E2E tests use a single browser session, we test multiplayer
  from ONE user's perspective but set up the data for multiple users
  programmatically.

  All LLM calls are mocked -- no API keys needed.
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  describe "multiplayer" do
    test "owner can enable multiplayer via share modal", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      stub(LLMMock, :stream_text, fn _m, _c, _o ->
        MockResponses.stream_text_response("ok")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # Open the share modal via the Share button in the conversation info sidebar
      |> click("button[phx-click='show_share_modal']")
      # The share modal should now be visible with the "Enable Multiplayer" button
      |> assert_has("#share-modal", timeout: 5_000)
      |> assert_has("button[phx-click='enable_multiplayer']", text: "Enable Multiplayer")
      # Click "Enable Multiplayer"
      |> click("button[phx-click='enable_multiplayer']")
      # After enabling, the multiplayer badge should appear in the conversation info
      |> assert_has(".badge-primary", text: "Multiplayer", timeout: 5_000)
    end

    test "multiplayer conversation shows participants sidebar with owner listed", %{conn: conn} do
      model = create_default_model()
      user = generate(user(name: "Owner User")) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      # Enable multiplayer programmatically so we start with it already on
      {:ok, conversation} =
        Magus.Chat.enable_multiplayer(conversation, actor: user)

      stub(LLMMock, :stream_text, fn _m, _c, _o ->
        MockResponses.stream_text_response("ok")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # The multiplayer badge should be visible
      |> assert_has(".badge-primary", text: "Multiplayer", timeout: 5_000)
      # Click the Participants button to open the participants sidebar
      |> click("button[phx-click='toggle_participants_sidebar']")
      # The participants sidebar should appear with the header
      |> assert_has("#participants-sidebar", timeout: 5_000)
      |> assert_has("#participants-sidebar", text: "Participants")
      # The owner should be listed as a member (the badge shows participant count)
      |> assert_has("#participants-sidebar .badge", text: "1")
    end

    test "add member programmatically and verify participants count updates", %{conn: conn} do
      model = create_default_model()
      owner = generate(user(name: "MP Owner")) |> confirm_user()
      member = generate(user(name: "MP Member")) |> confirm_user()
      setup_subscription_for_user(owner)
      setup_subscription_for_user(member)
      conversation = generate(conversation(actor: owner, selected_model_id: model.id))

      # Enable multiplayer programmatically
      {:ok, conversation} =
        Magus.Chat.enable_multiplayer(conversation, actor: owner)

      # Add the second user as a member programmatically
      {:ok, _membership} =
        Magus.Chat.add_conversation_member(
          conversation.id,
          member.id,
          %{role: :member},
          authorize?: false
        )

      # Accept the membership so they show in the accepted members list
      # The add_member action sets invited_at but not accepted_at, so we need to
      # set accepted_at for the member to appear in the participants list
      membership =
        Magus.Chat.get_conversation_members!(conversation.id, authorize?: false)
        |> Enum.find(fn m -> m.user_id == member.id end)

      if membership && is_nil(membership.accepted_at) do
        Ash.update!(
          Ash.Changeset.for_update(membership, :accept_invitation, %{}),
          authorize?: false
        )
      end

      stub(LLMMock, :stream_text, fn _m, _c, _o ->
        MockResponses.stream_text_response("ok")
      end)

      conn
      |> authenticate(owner)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # Open participants sidebar
      |> click("button[phx-click='toggle_participants_sidebar']")
      |> assert_has("#participants-sidebar", timeout: 5_000)
      # Should show 2 participants (owner + member)
      |> assert_has("#participants-sidebar .badge", text: "2")
    end

    test "observer cannot send messages and sees read-only indicator", %{conn: conn} do
      model = create_default_model()
      owner = generate(user(name: "Chat Owner")) |> confirm_user()
      observer = generate(user(name: "Chat Observer")) |> confirm_user()
      setup_subscription_for_user(owner)
      setup_subscription_for_user(observer)
      conversation = generate(conversation(actor: owner, selected_model_id: model.id))

      # Enable multiplayer programmatically
      {:ok, conversation} =
        Magus.Chat.enable_multiplayer(conversation, actor: owner)

      # Add the observer
      {:ok, _membership} =
        Magus.Chat.add_conversation_member(
          conversation.id,
          observer.id,
          %{role: :observer},
          authorize?: false
        )

      # Accept the membership
      membership =
        Magus.Chat.get_conversation_members!(conversation.id, authorize?: false)
        |> Enum.find(fn m -> m.user_id == observer.id end)

      if membership && is_nil(membership.accepted_at) do
        Ash.update!(
          Ash.Changeset.for_update(membership, :accept_invitation, %{}),
          authorize?: false
        )
      end

      stub(LLMMock, :stream_text, fn _m, _c, _o ->
        MockResponses.stream_text_response("ok")
      end)

      # Authenticate as the observer and visit the conversation
      conn
      |> authenticate(observer)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # The observer should see the read-only mode indicator instead of the textarea
      |> assert_has("#chat-input-area", text: "read-only", timeout: 5_000)
      # The textarea should not be present
      |> refute_has("#chat-textarea")
      # The send button should not be present
      |> refute_has("button[title='Send message']")
    end
  end
end
