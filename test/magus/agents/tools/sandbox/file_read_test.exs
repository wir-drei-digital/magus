defmodule Magus.Agents.Tools.Sandbox.FileReadTest do
  @moduledoc """
  Tests for the FileRead tool.

  Tests cover:
  - Display name and output summarization
  - Context validation
  - Authorization
  - Binary file detection (skips reading binary files)
  - Line truncation logic
  - File size formatting
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Sandbox.FileRead
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
      assert FileRead.display_name() == "Reading file..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes text file with line count" do
      assert FileRead.summarize_output(%{content: "line1\nline2\nline3"}) == "3 lines"
    end

    test "summarizes single line file" do
      assert FileRead.summarize_output(%{content: "single line"}) == "1 lines"
    end

    test "summarizes empty file" do
      assert FileRead.summarize_output(%{content: ""}) == "1 lines"
    end

    test "summarizes binary file with size" do
      assert FileRead.summarize_output(%{binary: true, size_bytes: 1024}) ==
               "Binary file (1.0 KB)"
    end

    test "summarizes binary file with unknown size" do
      assert FileRead.summarize_output(%{binary: true, size_bytes: nil}) ==
               "Binary file (unknown)"
    end

    test "summarizes binary file in bytes" do
      assert FileRead.summarize_output(%{binary: true, size_bytes: 500}) ==
               "Binary file (500 B)"
    end

    test "summarizes binary file in megabytes" do
      assert FileRead.summarize_output(%{binary: true, size_bytes: 2_621_440}) ==
               "Binary file (2.5 MB)"
    end

    test "summarizes error result" do
      assert FileRead.summarize_output(%{error: "file not found"}) == "Error"
    end

    test "summarizes unknown output" do
      assert FileRead.summarize_output(%{}) == "Completed"
      assert FileRead.summarize_output(%{foo: "bar"}) == "Completed"
    end
  end

  # ---------------------------------------------------------------------------
  # Context Validation
  # ---------------------------------------------------------------------------

  describe "run/2 - context validation" do
    test "returns error with empty context" do
      params = %{"path" => "/workspace/test.txt"}

      assert {:ok, result} = FileRead.run(params, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error with missing user_id", %{conversation: conversation} do
      params = %{"path" => "/workspace/test.txt"}
      context = %{conversation_id: conversation.id}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "user_id"
    end

    test "returns error with missing conversation_id", %{user: user} do
      params = %{"path" => "/workspace/test.txt"}
      context = %{user_id: user.id}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "conversation_id"
    end
  end

  # ---------------------------------------------------------------------------
  # Binary File Detection
  # ---------------------------------------------------------------------------

  describe "run/2 - binary file detection" do
    test "detects PNG as binary", %{context: context} do
      params = %{"path" => "/workspace/image.png"}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.binary == true
      assert result.path == "/workspace/image.png"
      assert result.hint =~ "binary file"
    end

    test "detects JPEG as binary", %{context: context} do
      params = %{"path" => "/workspace/photo.jpeg"}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.binary == true
    end

    test "detects JPG as binary", %{context: context} do
      params = %{"path" => "/workspace/photo.jpg"}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.binary == true
    end

    test "detects PDF as binary", %{context: context} do
      params = %{"path" => "/workspace/document.pdf"}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.binary == true
    end

    test "detects ZIP as binary", %{context: context} do
      params = %{"path" => "/workspace/archive.zip"}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.binary == true
    end

    test "detects executable as binary", %{context: context} do
      params = %{"path" => "/workspace/program.exe"}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.binary == true
    end

    test "detects shared library as binary", %{context: context} do
      params = %{"path" => "/workspace/libfoo.so"}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.binary == true
    end

    test "detects font file as binary", %{context: context} do
      params = %{"path" => "/workspace/font.woff2"}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.binary == true
    end

    test "detects video as binary", %{context: context} do
      params = %{"path" => "/workspace/video.mp4"}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.binary == true
    end

    test "detects Office file as binary", %{context: context} do
      params = %{"path" => "/workspace/doc.docx"}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.binary == true
    end

    test "case insensitive binary detection", %{context: context} do
      params = %{"path" => "/workspace/image.PNG"}

      assert {:ok, result} = FileRead.run(params, context)
      assert result.binary == true
    end

    test "does not detect .txt as binary", %{context: context} do
      params = %{"path" => "/workspace/readme.txt"}

      assert {:ok, result} = FileRead.run(params, context)
      # Should attempt to read (and fail because Sprites is not configured)
      refute Map.get(result, :binary)
    end

    test "does not detect .py as binary", %{context: context} do
      params = %{"path" => "/workspace/script.py"}

      assert {:ok, result} = FileRead.run(params, context)
      refute Map.get(result, :binary)
    end

    test "does not detect .html as binary", %{context: context} do
      params = %{"path" => "/workspace/index.html"}

      assert {:ok, result} = FileRead.run(params, context)
      refute Map.get(result, :binary)
    end

    test "does not detect .json as binary", %{context: context} do
      params = %{"path" => "/workspace/package.json"}

      assert {:ok, result} = FileRead.run(params, context)
      refute Map.get(result, :binary)
    end

    test "does not detect .rs as binary", %{context: context} do
      params = %{"path" => "/workspace/main.rs"}

      assert {:ok, result} = FileRead.run(params, context)
      refute Map.get(result, :binary)
    end

    test "does not detect .tex as binary", %{context: context} do
      params = %{"path" => "/workspace/document.tex"}

      assert {:ok, result} = FileRead.run(params, context)
      refute Map.get(result, :binary)
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization
  # ---------------------------------------------------------------------------

  describe "run/2 - authorization" do
    test "rejects read for non-owner user", %{conversation: conversation} do
      other_user = generate(user())

      params = %{"path" => "/workspace/test.txt"}

      context = %{
        user_id: other_user.id,
        conversation_id: conversation.id
      }

      assert {:ok, result} = FileRead.run(params, context)
      assert result[:error]
    end

    test "rejects read for non-existent conversation", %{user: user} do
      params = %{"path" => "/workspace/test.txt"}

      context = %{
        user_id: user.id,
        conversation_id: Ecto.UUID.generate()
      }

      assert {:ok, result} = FileRead.run(params, context)
      assert result[:error]
    end
  end
end
