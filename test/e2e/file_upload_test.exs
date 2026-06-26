defmodule MagusWeb.E2E.FileUploadTest do
  @moduledoc """
  Browser-based E2E tests for file upload functionality in the chat input.

  These tests verify uploading files via the attachment button, seeing previews,
  removing attachments, and sending messages with file attachments.
  All LLM calls are mocked -- no API keys needed.
  """
  use MagusWeb.PlaywrightCase

  alias PlaywrightEx.Frame

  @moduletag :e2e

  setup do
    # Create temporary test files for upload tests
    test_file_path =
      Path.join(System.tmp_dir!(), "test_upload_#{System.unique_integer([:positive])}.txt")

    File.write!(test_file_path, "This is test file content for E2E testing.")

    on_exit(fn ->
      File.rm(test_file_path)
    end)

    %{test_file_path: test_file_path}
  end

  describe "file attachments" do
    test "uploading file shows attachment preview", %{conn: conn, test_file_path: test_file_path} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      file_name = Path.basename(test_file_path)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      # Upload file via the hidden file input using Playwright's set_input_files
      |> unwrap(fn %{frame_id: frame_id} ->
        {:ok, _} =
          Frame.set_input_files(frame_id,
            selector: "input[type='file'][data-phx-hook='Phoenix.LiveFileUpload']",
            local_paths: [test_file_path],
            timeout: 5_000
          )
      end)
      # Verify the attachment preview appears with the file name
      |> assert_has("#chat-input-area", text: file_name, timeout: 5_000)
    end

    test "send message with file attachment", %{conn: conn, test_file_path: test_file_path} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("I received your file and message!")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      # Upload file
      |> unwrap(fn %{frame_id: frame_id} ->
        {:ok, _} =
          Frame.set_input_files(frame_id,
            selector: "input[type='file'][data-phx-hook='Phoenix.LiveFileUpload']",
            local_paths: [test_file_path],
            timeout: 5_000
          )
      end)
      # Wait for attachment preview to confirm upload completed
      |> assert_has("#chat-input-area", text: Path.basename(test_file_path), timeout: 5_000)
      # Type a message and send
      |> type("#chat-textarea", "Please analyze this file")
      |> click("button[title='Send message']")
      # Verify AI response
      |> assert_has(".prose", text: "I received your file and message!")
    end

    test "remove attachment before sending", %{conn: conn, test_file_path: test_file_path} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      file_name = Path.basename(test_file_path)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("#chat-textarea")
      # Upload file
      |> unwrap(fn %{frame_id: frame_id} ->
        {:ok, _} =
          Frame.set_input_files(frame_id,
            selector: "input[type='file'][data-phx-hook='Phoenix.LiveFileUpload']",
            local_paths: [test_file_path],
            timeout: 5_000
          )
      end)
      # Verify attachment preview appears
      |> assert_has("#chat-input-area", text: file_name, timeout: 5_000)
      # Click the remove button (X icon) on the attachment preview
      |> click("button[phx-click='remove_attachment']")
      # Verify attachment preview is gone
      |> refute_has("#chat-input-area", text: file_name)
    end
  end
end
