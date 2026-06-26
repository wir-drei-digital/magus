defmodule Magus.Agents.Tools.Sandbox.FileEditTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Sandbox.FileEdit
  alias Magus.Chat

  setup do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    context = %{
      user_id: user.id,
      conversation_id: conversation.id
    }

    %{user: user, conversation: conversation, context: context}
  end

  describe "display_name/0" do
    test "returns display name" do
      assert FileEdit.display_name() == "Editing file..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes single replacement" do
      assert FileEdit.summarize_output(%{path: "/workspace/test.py", replacements: 1}) ==
               "Edited test.py (1 replacement)"
    end

    test "summarizes multiple replacements" do
      assert FileEdit.summarize_output(%{path: "/workspace/test.py", replacements: 3}) ==
               "Edited test.py (3 replacements)"
    end

    test "summarizes line range replacement" do
      assert FileEdit.summarize_output(%{path: "/workspace/test.py", lines_replaced: "5-10"}) ==
               "Edited test.py (lines 5-10)"
    end

    test "summarizes error" do
      assert FileEdit.summarize_output(%{error: "not found"}) == "Error"
    end

    test "summarizes unknown" do
      assert FileEdit.summarize_output(%{}) == "Completed"
    end
  end

  describe "run/2 - context validation" do
    test "returns error with empty context" do
      params = %{"path" => "/workspace/test.py", "old_string" => "a", "new_string" => "b"}
      assert {:ok, result} = FileEdit.run(params, %{})
      assert result.error =~ "Missing required context"
    end
  end

  describe "run/2 - mode dispatch" do
    test "rejects identical old_string and new_string", %{context: context} do
      params = %{"path" => "/workspace/test.py", "old_string" => "same", "new_string" => "same"}
      assert {:ok, result} = FileEdit.run(params, context)
      assert result.error =~ "identical"
    end

    test "rejects missing mode params", %{context: context} do
      params = %{"path" => "/workspace/test.py"}
      assert {:ok, result} = FileEdit.run(params, context)
      assert result.error =~ "Provide either"
    end

    test "rejects end_line < start_line", %{context: context} do
      params = %{
        "path" => "/workspace/test.py",
        "start_line" => 10,
        "end_line" => 5,
        "new_content" => "replacement"
      }

      assert {:ok, result} = FileEdit.run(params, context)
      assert result.error =~ "must be >="
    end
  end
end
