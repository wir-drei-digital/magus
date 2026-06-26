defmodule Magus.Agents.Tools.Sandbox.FileWriteTest do
  @moduledoc """
  Tests for the FileWrite tool.

  Tests cover:
  - Display name and output summarization
  - Context validation
  - Authorization
  - Error handling for unconfigured sandbox
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Sandbox.FileWrite
  alias Magus.Chat

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    context = %{
      user_id: user.id,
      conversation_id: conversation.id
    }

    %{user: user, conversation: conversation, context: context}
  end

  # ---------------------------------------------------------------------------
  # Display Name and Output Summarization
  # ---------------------------------------------------------------------------

  describe "display_name/0" do
    test "provides display name" do
      assert FileWrite.display_name() == "Writing file..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes successful write with basename" do
      assert FileWrite.summarize_output(%{path: "/workspace/hello.py"}) == "Wrote hello.py"
    end

    test "summarizes nested path with basename only" do
      assert FileWrite.summarize_output(%{path: "/workspace/src/main.rs"}) == "Wrote main.rs"
    end

    test "summarizes error result" do
      assert FileWrite.summarize_output(%{error: "write failed"}) == "Error"
    end

    test "summarizes unknown output" do
      assert FileWrite.summarize_output(%{}) == "Completed"
      assert FileWrite.summarize_output(%{foo: "bar"}) == "Completed"
    end
  end

  # ---------------------------------------------------------------------------
  # Context Validation
  # ---------------------------------------------------------------------------

  describe "run/2 - context validation" do
    test "returns error with empty context" do
      params = %{"path" => "/workspace/test.txt", "content" => "hello"}

      assert {:ok, result} = FileWrite.run(params, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error with missing user_id", %{conversation: conversation} do
      params = %{"path" => "/workspace/test.txt", "content" => "hello"}
      context = %{conversation_id: conversation.id}

      assert {:ok, result} = FileWrite.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "user_id"
    end

    test "returns error with missing conversation_id", %{user: user} do
      params = %{"path" => "/workspace/test.txt", "content" => "hello"}
      context = %{user_id: user.id}

      assert {:ok, result} = FileWrite.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "conversation_id"
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization
  # ---------------------------------------------------------------------------

  describe "run/2 - authorization" do
    test "rejects write for non-owner user", %{conversation: conversation} do
      other_user = generate(user())

      params = %{"path" => "/workspace/evil.txt", "content" => "hacked"}

      context = %{
        user_id: other_user.id,
        conversation_id: conversation.id
      }

      assert {:ok, result} = FileWrite.run(params, context)
      assert result[:error]
    end

    test "rejects write for non-existent conversation", %{user: user} do
      params = %{"path" => "/workspace/test.txt", "content" => "hello"}

      context = %{
        user_id: user.id,
        conversation_id: Ecto.UUID.generate()
      }

      assert {:ok, result} = FileWrite.run(params, context)
      assert result[:error]
    end
  end

  # ---------------------------------------------------------------------------
  # Double-Encoding Detection and Unescaping
  # ---------------------------------------------------------------------------

  describe "double-encoded content unescaping (via Helpers.maybe_unescape_content/1)" do
    alias Magus.Agents.Tools.Helpers

    test "unescapes double-encoded LaTeX content" do
      double_encoded =
        "\\\\documentclass{article}\\n\\\\begin{document}\\nHello World\\n\\\\end{document}"

      result = Helpers.maybe_unescape_content(double_encoded)

      assert result == "\\documentclass{article}\n\\begin{document}\nHello World\n\\end{document}"
    end

    test "unescapes tabs and carriage returns" do
      double_encoded =
        "header1\\theader2\\n" <>
          "col1\\tcol2\\n" <>
          "col3\\tcol4\\n" <>
          "col5\\tcol6"

      result = Helpers.maybe_unescape_content(double_encoded)

      assert result == "header1\theader2\ncol1\tcol2\ncol3\tcol4\ncol5\tcol6"
    end

    test "handles escaped backslash followed by n correctly" do
      # \\\\n in the double-encoded string = escaped backslash + literal n
      # Should become \n (single backslash + letter n), NOT a newline
      double_encoded = "line1\\nprint(\\\\n)\\nline3\\nline4"
      result = Helpers.maybe_unescape_content(double_encoded)

      assert result == "line1\nprint(\\n)\nline3\nline4"
    end

    test "preserves normal multi-line content" do
      normal = "line 1\nline 2\nline 3\nline 4\n"
      assert Helpers.maybe_unescape_content(normal) == normal
    end

    test "preserves content with few literal escapes (below threshold)" do
      mixed = "some text\\nwith one escape\\nand another\nbut a real newline too"
      assert Helpers.maybe_unescape_content(mixed) == mixed
    end

    test "preserves single-line content" do
      single = "just a simple string"
      assert Helpers.maybe_unescape_content(single) == single
    end

    test "preserves empty string" do
      assert Helpers.maybe_unescape_content("") == ""
    end

    test "handles nil gracefully" do
      assert Helpers.maybe_unescape_content(nil) == nil
    end
  end
end
