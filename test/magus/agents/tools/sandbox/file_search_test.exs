defmodule Magus.Agents.Tools.Sandbox.FileSearchTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Sandbox.FileSearch
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
      assert FileSearch.display_name() == "Searching files..."
    end
  end

  describe "summarize_output/1" do
    test "no matches" do
      assert FileSearch.summarize_output(%{total_matches: 0}) == "No matches"
    end

    test "single match in one file" do
      assert FileSearch.summarize_output(%{total_matches: 1, files_matched: 1, truncated: false}) ==
               "1 match in 1 file"
    end

    test "multiple matches in multiple files" do
      assert FileSearch.summarize_output(%{total_matches: 5, files_matched: 3, truncated: false}) ==
               "5 matches in 3 files"
    end

    test "truncated results" do
      assert FileSearch.summarize_output(%{
               total_matches: 250,
               files_matched: 10,
               truncated: true
             }) ==
               "250+ matches in 10 files"
    end

    test "truncated with one file" do
      assert FileSearch.summarize_output(%{total_matches: 250, files_matched: 1, truncated: true}) ==
               "250+ matches in 1 file"
    end

    test "error result" do
      assert FileSearch.summarize_output(%{error: "something went wrong"}) == "Error"
    end

    test "unknown shape" do
      assert FileSearch.summarize_output(%{}) == "Completed"
    end
  end

  describe "run/2 - context validation" do
    test "returns error with empty context" do
      params = %{"pattern" => "hello"}
      assert {:ok, result} = FileSearch.run(params, %{})
      assert result.error =~ "Missing required context"
    end
  end

  describe "build_rg_command/1" do
    test "basic content mode" do
      opts = %{
        pattern: "hello",
        path: "/workspace",
        output_mode: "content",
        max_results: 250
      }

      cmd = FileSearch.build_rg_command(opts)
      assert cmd =~ "rg"
      assert cmd =~ "--max-columns"
      assert cmd =~ "--line-number"
      assert cmd =~ "'hello'"
      assert cmd =~ "'/workspace'"
      assert cmd =~ "| head -n 251"
      refute cmd =~ "--files-with-matches"
      refute cmd =~ "--count"
      refute cmd =~ "--ignore-case"
    end

    test "files_with_matches mode" do
      opts = %{
        pattern: "def foo",
        path: "/workspace/src",
        output_mode: "files_with_matches",
        max_results: 250
      }

      cmd = FileSearch.build_rg_command(opts)
      assert cmd =~ "--files-with-matches"
      refute cmd =~ "--line-number"
      refute cmd =~ "--count"
    end

    test "count mode" do
      opts = %{
        pattern: "TODO",
        path: "/workspace",
        output_mode: "count",
        max_results: 250
      }

      cmd = FileSearch.build_rg_command(opts)
      assert cmd =~ "--count"
      refute cmd =~ "--line-number"
      refute cmd =~ "--files-with-matches"
    end

    test "case insensitive flag" do
      opts = %{
        pattern: "Error",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        case_insensitive: true
      }

      cmd = FileSearch.build_rg_command(opts)
      assert cmd =~ "--ignore-case"
    end

    test "case insensitive false omits flag" do
      opts = %{
        pattern: "Error",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        case_insensitive: false
      }

      cmd = FileSearch.build_rg_command(opts)
      refute cmd =~ "--ignore-case"
    end

    test "context_before adds -B flag in content mode" do
      opts = %{
        pattern: "fail",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        context_before: 3
      }

      cmd = FileSearch.build_rg_command(opts)
      assert cmd =~ "-B 3"
    end

    test "context_after adds -A flag in content mode" do
      opts = %{
        pattern: "fail",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        context_after: 2
      }

      cmd = FileSearch.build_rg_command(opts)
      assert cmd =~ "-A 2"
    end

    test "context lines ignored outside content mode" do
      opts = %{
        pattern: "fail",
        path: "/workspace",
        output_mode: "count",
        max_results: 250,
        context_before: 3,
        context_after: 2
      }

      cmd = FileSearch.build_rg_command(opts)
      refute cmd =~ "-B"
      refute cmd =~ "-A"
    end

    test "include glob adds --glob flag" do
      opts = %{
        pattern: "import",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        include: "*.py"
      }

      cmd = FileSearch.build_rg_command(opts)
      assert cmd =~ "--glob"
      assert cmd =~ "'*.py'"
    end

    test "nil include omits --glob flag" do
      opts = %{
        pattern: "import",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        include: nil
      }

      cmd = FileSearch.build_rg_command(opts)
      refute cmd =~ "--glob"
    end

    test "type filter adds --type flag" do
      opts = %{
        pattern: "fn main",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        type: "rust"
      }

      cmd = FileSearch.build_rg_command(opts)
      assert cmd =~ "--type 'rust'"
    end

    test "nil type omits --type flag" do
      opts = %{
        pattern: "fn main",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        type: nil
      }

      cmd = FileSearch.build_rg_command(opts)
      refute cmd =~ "--type"
    end

    test "multiline flag" do
      opts = %{
        pattern: "foo.*bar",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        multiline: true
      }

      cmd = FileSearch.build_rg_command(opts)
      assert cmd =~ "--multiline"
      assert cmd =~ "--multiline-dotall"
    end

    test "multiline false omits multiline flags" do
      opts = %{
        pattern: "foo",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        multiline: false
      }

      cmd = FileSearch.build_rg_command(opts)
      refute cmd =~ "--multiline"
    end

    test "custom max_results affects head -n" do
      opts = %{
        pattern: "x",
        path: "/workspace",
        output_mode: "content",
        max_results: 50
      }

      cmd = FileSearch.build_rg_command(opts)
      assert cmd =~ "| head -n 51"
    end

    test "special characters in pattern are shell-escaped" do
      opts = %{
        pattern: "it's here",
        path: "/workspace",
        output_mode: "content",
        max_results: 250
      }

      cmd = FileSearch.build_rg_command(opts)
      assert cmd =~ "it'\\''s here"
    end
  end

  describe "build_grep_fallback_command/1" do
    test "basic fallback command" do
      opts = %{
        pattern: "hello",
        path: "/workspace",
        output_mode: "content",
        max_results: 250
      }

      cmd = FileSearch.build_grep_fallback_command(opts)
      assert cmd =~ "grep -rn"
      assert cmd =~ "'hello'"
      assert cmd =~ "'/workspace'"
      assert cmd =~ "| head -n 251"
    end

    test "include glob adds --include flag" do
      opts = %{
        pattern: "import",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        include: "*.js"
      }

      cmd = FileSearch.build_grep_fallback_command(opts)
      assert cmd =~ "--include='*.js'"
    end

    test "nil include omits --include flag" do
      opts = %{
        pattern: "import",
        path: "/workspace",
        output_mode: "content",
        max_results: 250,
        include: nil
      }

      cmd = FileSearch.build_grep_fallback_command(opts)
      refute cmd =~ "--include"
    end
  end
end
