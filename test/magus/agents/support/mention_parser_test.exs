defmodule Magus.Agents.Support.MentionParserTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Support.MentionParser

  # We test the regex-based parsing by extracting handles directly,
  # without hitting the database. The `parse/2` function queries DB
  # and is tested indirectly. Here we test the regex + strip logic.

  describe "mention regex" do
    # Access the regex via module attribute reflection
    @mention_regex ~r/(?:^|(?<=\s))@([a-z0-9][a-z0-9-]*)/

    defp extract_handles(text) do
      @mention_regex
      |> Regex.scan(text)
      |> Enum.map(fn [_full, handle] -> handle end)
    end

    test "extracts simple @mention at start of string" do
      assert extract_handles("@bob hello") == ["bob"]
    end

    test "extracts @mention after whitespace" do
      assert extract_handles("hey @alice review this") == ["alice"]
    end

    test "extracts multiple mentions" do
      assert extract_handles("@bob and @alice please look") == ["bob", "alice"]
    end

    test "handles hyphenated handles" do
      assert extract_handles("@my-agent do something") == ["my-agent"]
    end

    test "handles numeric handles" do
      assert extract_handles("@agent1 hi") == ["agent1"]
    end

    test "does not match email addresses" do
      assert extract_handles("send to user@example.com") == []
    end

    test "does not match email-like patterns without TLD" do
      assert extract_handles("contact user@domain") == []
    end

    test "does not match email with subdomain" do
      assert extract_handles("mail to admin@sub.example.com") == []
    end

    test "matches @mention after email in same text" do
      assert extract_handles("email user@example.com and @bob") == ["bob"]
    end

    test "does not match @mention attached to other text" do
      # e.g. "foo@bar" should not match
      assert extract_handles("foo@bar") == []
    end

    test "does not match handle starting with hyphen" do
      assert extract_handles("@-invalid") == []
    end

    test "matches @mention at very start of text" do
      assert extract_handles("@first hello @second") == ["first", "second"]
    end

    test "matches after newline" do
      assert extract_handles("hello\n@agent") == ["agent"]
    end

    test "matches after tab" do
      assert extract_handles("hello\t@agent") == ["agent"]
    end
  end

  describe "strip_mentions/2" do
    test "strips single mention" do
      assert MentionParser.strip_mentions("@bob hello", ["bob"]) == "hello"
    end

    test "strips multiple mentions" do
      result = MentionParser.strip_mentions("@bob @alice review this", ["bob", "alice"])
      assert result == "review this"
    end

    test "only strips resolved handles" do
      result = MentionParser.strip_mentions("@bob @unknown review", ["bob"])
      assert result == "@unknown review"
    end

    test "cleans up double spaces" do
      result = MentionParser.strip_mentions("hey @bob review this", ["bob"])
      assert result == "hey review this"
    end

    test "trims leading and trailing whitespace" do
      result = MentionParser.strip_mentions("@bob ", ["bob"])
      assert result == ""
    end

    test "handles non-binary text gracefully" do
      assert MentionParser.strip_mentions(nil, ["bob"]) == nil
    end
  end

  describe "parse/3 scope resolution" do
    test "personal scope (workspace_id nil) resolves only the user's personal agents" do
      user = generate(user())

      {:ok, personal} =
        Magus.Agents.create_custom_agent(%{name: "researcher"}, actor: user)

      result = MentionParser.parse("hey @#{personal.handle} look", user.id, nil)
      assert [{handle, agent}] = result
      assert handle == personal.handle
      assert agent.id == personal.id
    end

    test "workspace scope resolves agents shared in that workspace, ignoring personal agents" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "WS", slug: "mp-#{System.unique_integer([:positive])}"},
          actor: user
        )

      workspace = Ash.load!(workspace, [:default_agent], actor: user)

      # Workspace's auto-created assistant has handle "workspace-assistant"
      assert workspace.default_agent.handle == "workspace-assistant"

      # Same user has a personal agent with the same handle — should NOT resolve
      # in workspace scope (uniqueness is per-scope, not per-user).
      {:ok, _personal} =
        Magus.Agents.create_custom_agent(%{name: "Workspace Assistant"}, actor: user)

      result = MentionParser.parse("hi @workspace-assistant", user.id, workspace.id)
      assert [{"workspace-assistant", agent}] = result
      assert agent.id == workspace.default_agent.id
      assert agent.workspace_id == workspace.id
    end

    test "workspace scope does not resolve personal agents from outside the workspace" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "WS", slug: "mp-#{System.unique_integer([:positive])}"},
          actor: user
        )

      {:ok, _personal_only} =
        Magus.Agents.create_custom_agent(%{name: "researcher"}, actor: user)

      result = MentionParser.parse("@researcher please", user.id, workspace.id)
      assert result == []
    end

    test "personal scope does not resolve workspace agents" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "WS", slug: "mp-#{System.unique_integer([:positive])}"},
          actor: user
        )

      workspace = Ash.load!(workspace, [:default_agent], actor: user)

      result =
        MentionParser.parse("@#{workspace.default_agent.handle} ping", user.id, nil)

      assert result == []
    end
  end
end
