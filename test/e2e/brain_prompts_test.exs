defmodule MagusWeb.E2E.BrainPromptsTest do
  @moduledoc """
  Browser-based E2E tests for the Brain/Prompt system.

  Tests creating, activating, and deactivating system prompts, as well as
  verifying that active prompts are used during chat and that the prompts
  library page displays prompts correctly.

  All LLM calls are mocked -- no API keys needed.
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  describe "activate system prompt" do
    test "activating a system prompt shows indicator in chat input", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      # Create a system prompt for this user
      prompt =
        generate(
          prompt(
            actor: user,
            name: "Helpful Assistant",
            content: "You are a helpful assistant.",
            type: :system
          )
        )

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Got it!")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # The right sidebar shows the library by default on desktop.
      # The prompts section is collapsed by default -- expand it.
      |> click("#prompts-section [phx-click='toggle_prompts']")
      # Verify the prompt appears in the sidebar list
      |> assert_has("#prompt-#{prompt.id}")
      # Click the activate button (play icon) on the system prompt
      |> click("#prompt-#{prompt.id} button[title='Activate']")
      # Verify the active system prompt indicator appears in the chat input area
      |> assert_has("#chat-input-area", text: "Helpful Assistant")
      # Also verify the active indicator appears in the sidebar
      |> assert_has(".bg-primary\\/10", text: "Helpful Assistant")
    end
  end

  describe "deactivate system prompt" do
    test "deactivating a system prompt removes the indicator", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      prompt =
        generate(
          prompt(
            actor: user,
            name: "Code Expert",
            content: "You are a code expert.",
            type: :system
          )
        )

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Got it!")
      end)

      conn =
        conn
        |> authenticate(user)
        |> visit(~p"/chat/#{conversation.id}")
        |> assert_has("body .phx-connected")
        # Expand prompts section and activate
        |> click("#prompts-section [phx-click='toggle_prompts']")
        |> click("#prompt-#{prompt.id} button[title='Activate']")
        # Confirm the indicator is present
        |> assert_has("#chat-input-area", text: "Code Expert")

      # Now deactivate -- click the X button on the active prompt indicator in the sidebar
      conn
      |> click("button[title='Deactivate']")
      # Verify the indicator is gone from the chat input area
      |> refute_has("#chat-input-area", text: "Code Expert")
    end
  end

  describe "chat with active prompt" do
    test "AI receives system prompt context when prompt is active", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      prompt =
        generate(
          prompt(
            actor: user,
            name: "Pirate Persona",
            content: "You are a pirate. Always respond in pirate speak.",
            type: :system
          )
        )

      # Track whether the system prompt content was received by the LLM
      test_pid = self()

      stub(LLMMock, :stream_text, fn _model, context, _opts ->
        send(test_pid, {:llm_context, context})
        MockResponses.stream_text_response("Ahoy matey! I be a pirate!")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # Activate the system prompt
      |> click("#prompts-section [phx-click='toggle_prompts']")
      |> click("#prompt-#{prompt.id} button[title='Activate']")
      |> assert_has("#chat-input-area", text: "Pirate Persona")
      # Send a message
      |> type("#chat-textarea", "Hello!")
      |> click("button[title='Send message']")
      |> assert_has(".prose", text: "Ahoy matey! I be a pirate!")

      # Verify the LLM received the system prompt in the context
      assert_receive {:llm_context, context}, 10_000
      context_text = inspect(context)
      assert context_text =~ "pirate"
    end
  end

  describe "create prompt" do
    test "creating a new prompt via the sidebar form", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("Response!")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      # Expand prompts section
      |> click("#prompts-section [phx-click='toggle_prompts']")
      # Click the "New Prompt" button (the + icon in the prompts section header)
      |> click("button[title='New Prompt']")
      # The prompt form modal should appear
      |> assert_has("#prompt-form-modal")
      # Fill in the prompt form
      |> fill_in("Name", with: "My Custom Prompt")
      |> fill_in("Content", with: "This is my custom system prompt content.")
      # Submit the form
      |> click("#prompt-form-modal button[type='submit']")
      # After saving, the prompt should appear in the sidebar list
      |> assert_has("#prompts-list", text: "My Custom Prompt")
    end
  end

  describe "browse prompt library" do
    test "visiting /prompts page shows listed prompts", %{conn: conn} do
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)

      # Create some prompts -- one public, one private
      public_prompt =
        generate(
          prompt(
            actor: user,
            name: "Public Brainstorm Prompt",
            content: "Help me brainstorm ideas.",
            type: :user
          )
        )

      # Publish the prompt so it appears in the public library
      Magus.Library.publish_prompt!(public_prompt, %{is_public: true}, actor: user)

      _private_prompt =
        generate(
          prompt(
            actor: user,
            name: "Private Helper Prompt",
            content: "A private helper prompt.",
            type: :system
          )
        )

      conn
      |> authenticate(user)
      |> visit(~p"/prompts")
      |> assert_has("body .phx-connected")
      # Verify the page header is present
      |> assert_has("h1", text: "Prompts Library")
      # Verify the public prompt is visible (default filter is "all" for logged in users)
      |> assert_has("h3", text: "Public Brainstorm Prompt")
      # Verify the private prompt is also visible (user owns it, and default filter is "all")
      |> assert_has("h3", text: "Private Helper Prompt")
    end
  end
end
