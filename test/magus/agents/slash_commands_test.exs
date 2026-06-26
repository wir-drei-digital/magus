defmodule Magus.Agents.SlashCommandsTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.SlashCommands

  describe "list/0" do
    test "returns global commands" do
      commands = SlashCommands.list()
      assert is_list(commands)
      assert length(commands) > 0

      reminder = Enum.find(commands, &(&1.name == "reminder"))
      assert reminder
      assert reminder.title
      assert reminder.instruction
    end
  end

  describe "get/2" do
    test "finds a global command by name" do
      assert %{name: "reminder"} = SlashCommands.get("reminder")
    end

    test "finds an agent command by name" do
      agent_commands = [
        %{
          name: "research",
          title: "Research a topic",
          instruction: "Research the following topic thoroughly.",
          icon: nil
        }
      ]

      assert %{name: "research"} = SlashCommands.get("research", agent_commands)
    end

    test "agent command overrides global command with same name" do
      agent_commands = [
        %{
          name: "reminder",
          title: "Custom reminder",
          instruction: "Custom instruction.",
          icon: nil
        }
      ]

      result = SlashCommands.get("reminder", agent_commands)
      assert result.instruction == "Custom instruction."
    end

    test "returns nil for unknown command" do
      assert nil == SlashCommands.get("nonexistent")
    end
  end

  describe "parse/2" do
    test "parses a known global command at start of message" do
      {instruction, text} = SlashCommands.parse("/reminder pick up milk tomorrow")

      assert instruction =~ "<instruction>"
      assert instruction =~ "</instruction>"
      assert text == "pick up milk tomorrow"
    end

    test "returns nil instruction for unknown command" do
      {instruction, text} = SlashCommands.parse("/unknown do something")

      assert instruction == nil
      assert text == "/unknown do something"
    end

    test "returns nil instruction for message without slash command" do
      {instruction, text} = SlashCommands.parse("hello world")

      assert instruction == nil
      assert text == "hello world"
    end

    test "handles slash command with no trailing text" do
      {instruction, text} = SlashCommands.parse("/reminder")

      assert instruction =~ "<instruction>"
      assert text == ""
    end

    test "handles slash command with only whitespace after" do
      {instruction, text} = SlashCommands.parse("/reminder   ")

      assert instruction =~ "<instruction>"
      assert text == ""
    end

    test "parses /council command" do
      {instruction, remaining} = SlashCommands.parse("/council Should we use Redis or Postgres?")
      assert instruction =~ "<instruction>"
      assert instruction =~ "council"
      assert remaining == "Should we use Redis or Postgres?"
    end

    test "parses /council with no argument" do
      {instruction, remaining} = SlashCommands.parse("/council")
      assert instruction =~ "<instruction>"
      assert remaining == ""
    end

    test "does not parse slash command in middle of message" do
      {instruction, text} = SlashCommands.parse("please /reminder me")

      assert instruction == nil
      assert text == "please /reminder me"
    end

    test "parses agent-specific commands" do
      agent_commands = [
        %{name: "research", title: "Research", instruction: "Do research.", icon: nil}
      ]

      {instruction, text} = SlashCommands.parse("/research quantum computing", agent_commands)

      assert instruction =~ "Do research."
      assert text == "quantum computing"
    end

    test "handles empty message" do
      {instruction, text} = SlashCommands.parse("")

      assert instruction == nil
      assert text == ""
    end

    test "handles nil message" do
      {instruction, text} = SlashCommands.parse(nil)

      assert instruction == nil
      assert text == ""
    end
  end

  describe "merge/1" do
    test "merges global and agent commands, agent takes precedence" do
      agent_commands = [
        %{name: "reminder", title: "Custom", instruction: "Custom.", icon: nil},
        %{name: "research", title: "Research", instruction: "Research.", icon: nil}
      ]

      merged = SlashCommands.merge(agent_commands)

      # Agent's reminder overrides global
      reminder = Enum.find(merged, &(&1.name == "reminder"))
      assert reminder.instruction == "Custom."

      # Agent's research is included
      assert Enum.find(merged, &(&1.name == "research"))

      # Global draft is still present
      assert Enum.find(merged, &(&1.name == "draft"))
    end

    test "returns global commands when agent has none" do
      assert SlashCommands.merge([]) == SlashCommands.list()
    end
  end

  describe "title/1" do
    test "resolves English title by default" do
      assert SlashCommands.title(%{en: "Search the web", de: "Im Web suchen"}) ==
               "Search the web"
    end

    test "resolves German title when locale is de" do
      Gettext.put_locale(MagusWeb.Gettext, "de")

      assert SlashCommands.title(%{en: "Search the web", de: "Im Web suchen"}) ==
               "Im Web suchen"

      Gettext.put_locale(MagusWeb.Gettext, "en")
    end

    test "falls back to English for unknown locale" do
      Gettext.put_locale(MagusWeb.Gettext, "fr")

      assert SlashCommands.title(%{en: "Search the web", de: "Im Web suchen"}) ==
               "Search the web"

      Gettext.put_locale(MagusWeb.Gettext, "en")
    end

    test "handles plain string title" do
      assert SlashCommands.title("My command") == "My command"
    end
  end
end
