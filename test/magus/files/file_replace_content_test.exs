defmodule Magus.Files.FileReplaceContentTest do
  @moduledoc """
  Tests for the :replace_content action and read_binary helper on
  Magus.Files.File. Verifies that the binary stored on disk and the
  file_size attribute are updated atomically, and that the file's PubSub
  topic receives a :file_updated event.
  """
  use Magus.ResourceCase, async: false

  import Magus.Generators

  alias Magus.Files

  @ai_agent %Magus.Agents.Support.AiAgent{}

  setup do
    user = generate(user())

    {:ok, file} =
      Files.create_file_from_content(
        %{
          name: "sheet.xlsx",
          type: :document,
          mime_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          user_id: user.id,
          content: "initial content"
        },
        actor: @ai_agent
      )

    %{user: user, test_file: file}
  end

  describe "replace_content/4" do
    test "replaces binary content and updates file_size",
         %{user: user, test_file: test_file} do
      new_binary = String.duplicate("x", 4096)

      {:ok, updated} =
        Files.replace_file_content(
          test_file,
          new_binary,
          %{request_id: "req-1", source: :user},
          actor: user
        )

      assert updated.file_size == byte_size(new_binary)
      assert {:ok, ^new_binary} = Files.read_binary(updated, actor: user)
    end

    test "broadcasts {:file_updated, file_id, source, request_id} on PubSub",
         %{user: user, test_file: test_file} do
      Phoenix.PubSub.subscribe(Magus.PubSub, "files:#{test_file.id}")

      {:ok, _} =
        Files.replace_file_content(
          test_file,
          "new binary",
          %{request_id: "abc", source: :agent},
          actor: user
        )

      assert_receive {:file_updated, file_id, :agent, "abc"}
      assert file_id == test_file.id
    end
  end
end
