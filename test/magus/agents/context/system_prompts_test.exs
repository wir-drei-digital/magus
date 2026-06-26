defmodule Magus.Agents.Context.SystemPromptsTest do
  @moduledoc """
  Tests for the SystemPrompts module.

  Tests cover the modular system prompt composition:
  - Base rules inclusion
  - Mode-specific rules
  - Priority: conversation.system_prompt > system_prompt.content > mode defaults
  """
  use ExUnit.Case, async: true

  alias Magus.Agents.Context.SystemPrompts

  describe "base_rules/0" do
    test "returns base rules string" do
      rules = SystemPrompts.base_rules()

      assert is_binary(rules)
      assert String.contains?(rules, "Magus")
    end
  end

  describe "mode_rules/1" do
    test "returns chat rules for :chat mode" do
      rules = SystemPrompts.mode_rules(:chat)

      assert is_binary(rules)
      assert String.contains?(rules, "Notes on pdf generation")
    end

    test "returns search rules for :search mode" do
      rules = SystemPrompts.mode_rules(:search)

      assert is_binary(rules)
      assert String.contains?(rules, "web search")
      assert String.contains?(rules, "Cite your sources")
    end

    test "returns reasoning rules for :reasoning mode" do
      rules = SystemPrompts.mode_rules(:reasoning)

      assert is_binary(rules)
      assert String.contains?(rules, "deep reasoning")
      assert String.contains?(rules, "step by step")
    end

    test "returns image generation rules for :image_generation mode" do
      rules = SystemPrompts.mode_rules(:image_generation)

      assert is_binary(rules)
      assert String.contains?(rules, "image generation")
      assert String.contains?(rules, "composition")
    end

    test "returns video generation rules for :video_generation mode" do
      rules = SystemPrompts.mode_rules(:video_generation)

      assert is_binary(rules)
      assert String.contains?(rules, "video generation")
      assert String.contains?(rules, "motion")
    end

    test "returns chat rules for unknown mode" do
      rules = SystemPrompts.mode_rules(:unknown)

      assert rules == SystemPrompts.mode_rules(:chat)
    end
  end

  describe "build/1" do
    test "with default options uses chat mode" do
      prompt = SystemPrompts.build()

      # Should include base rules
      assert String.contains?(prompt, "Magus")

      # Should include chat mode rules
      assert String.contains?(prompt, "Notes on pdf generation")
    end

    test "with mode option uses mode-specific rules" do
      prompt = SystemPrompts.build(mode: :search)

      # Should include base rules
      assert String.contains?(prompt, "Magus")

      # Should include search mode rules
      assert String.contains?(prompt, "web search")
      assert String.contains?(prompt, "Cite your sources")
    end

    test "with conversation system_prompt uses conversation override" do
      conversation = %{system_prompt: "You are a custom assistant for testing."}

      prompt = SystemPrompts.build(conversation: conversation)

      # Should include base rules
      assert String.contains?(prompt, "Magus")

      # Should include custom prompt
      assert String.contains?(prompt, "custom assistant for testing")

      # Should NOT include default chat rules
      refute String.contains?(prompt, "general-purpose tasks")
    end

    test "with system_prompt uses system_prompt content" do
      system_prompt = %{content: "You are a helpful coding assistant."}

      prompt = SystemPrompts.build(system_prompt: system_prompt)

      # Should include base rules
      assert String.contains?(prompt, "Magus")

      # Should include system_prompt content
      assert String.contains?(prompt, "coding assistant")

      # Should NOT include default chat rules
      refute String.contains?(prompt, "general-purpose tasks")
    end

    test "conversation system_prompt takes priority over system_prompt" do
      conversation = %{system_prompt: "Conversation override prompt."}
      system_prompt = %{content: "System prompt content should not appear."}

      prompt = SystemPrompts.build(conversation: conversation, system_prompt: system_prompt)

      # Should include base rules
      assert String.contains?(prompt, "Magus")

      # Should include conversation prompt
      assert String.contains?(prompt, "Conversation override prompt")

      # Should NOT include system_prompt content
      refute String.contains?(prompt, "System prompt content should not appear")
    end

    test "system_prompt takes priority over mode defaults" do
      system_prompt = %{content: "Custom system prompt instructions."}

      prompt = SystemPrompts.build(mode: :search, system_prompt: system_prompt)

      # Should include base rules
      assert String.contains?(prompt, "Magus")

      # Should include system_prompt content
      assert String.contains?(prompt, "Custom system prompt instructions")

      # Should NOT include search mode rules
      refute String.contains?(prompt, "web search")
    end

    test "ignores empty conversation system_prompt" do
      conversation = %{system_prompt: ""}

      prompt = SystemPrompts.build(mode: :chat, conversation: conversation)

      # Should fall back to default chat rules
      assert String.contains?(prompt, "Notes on pdf generation")
    end

    test "ignores nil conversation system_prompt" do
      conversation = %{system_prompt: nil}

      prompt = SystemPrompts.build(mode: :chat, conversation: conversation)

      # Should fall back to default chat rules
      assert String.contains?(prompt, "Notes on pdf generation")
    end

    test "ignores empty system_prompt content" do
      system_prompt = %{content: ""}

      prompt = SystemPrompts.build(mode: :chat, system_prompt: system_prompt)

      # Should fall back to default chat rules
      assert String.contains?(prompt, "Notes on pdf generation")
    end

    test "ignores nil system_prompt content" do
      system_prompt = %{content: nil}

      prompt = SystemPrompts.build(mode: :chat, system_prompt: system_prompt)

      # Should fall back to default chat rules
      assert String.contains?(prompt, "Notes on pdf generation")
    end

    test "empty conversation falls back to system_prompt" do
      conversation = %{system_prompt: ""}
      system_prompt = %{content: "Fallback system prompt content."}

      prompt = SystemPrompts.build(conversation: conversation, system_prompt: system_prompt)

      # Should include system_prompt content (since conversation is empty)
      assert String.contains?(prompt, "Fallback system prompt content")
    end

    test "always includes base rules" do
      test_cases = [
        [],
        [mode: :chat],
        [mode: :search],
        [mode: :reasoning],
        [mode: :image_generation],
        [mode: :video_generation],
        [conversation: %{system_prompt: "Custom"}],
        [system_prompt: %{content: "Custom"}]
      ]

      for opts <- test_cases do
        prompt = SystemPrompts.build(opts)

        assert String.contains?(prompt, "Magus"),
               "Base rules missing for opts: #{inspect(opts)}"
      end
    end

    test "returns trimmed string" do
      prompt = SystemPrompts.build()

      refute String.starts_with?(prompt, "\n")
      refute String.ends_with?(prompt, "\n")
    end

    test "includes static scheduling guidance with the user's timezone" do
      user = %{timezone: "America/New_York"}

      prompt = SystemPrompts.build(user: user)

      assert String.contains?(prompt, "## Scheduling")
      assert String.contains?(prompt, "America/New_York")
      assert String.contains?(prompt, "Convert all times to UTC for cron expressions")
    end

    test "uses UTC scheduling guidance when user has no timezone" do
      user = %{timezone: nil}

      prompt = SystemPrompts.build(user: user)

      assert String.contains?(prompt, "## Scheduling")
      assert String.contains?(prompt, "UTC")
    end

    test "uses UTC scheduling guidance when no user provided" do
      prompt = SystemPrompts.build()

      assert String.contains?(prompt, "## Scheduling")
      assert String.contains?(prompt, "UTC")
    end

    test "does NOT include the volatile current-time block" do
      # The live clock now lives in the current user turn, never the system prompt.
      prompt = SystemPrompts.build(user: %{timezone: "Europe/Zurich"})

      refute String.contains?(prompt, "## Current Time")
      refute String.contains?(prompt, "Server time")
      refute String.contains?(prompt, "Your local time")
    end

    test "contains no timestamp or date-derived value (cache-stable prefix)" do
      # A date pattern (YYYY-MM-DD) anywhere in the prompt would bust the cache
      # every day; a current-time string would bust it every minute.
      for opts <- [
            [],
            [user: %{timezone: "Europe/Zurich"}],
            [user: %{timezone: "America/Los_Angeles"}],
            [user: %{timezone: nil}]
          ] do
        prompt = SystemPrompts.build(opts)

        refute Regex.match?(~r/\d{4}-\d{2}-\d{2}/, prompt),
               "Prompt unexpectedly contains a date pattern for opts: #{inspect(opts)}"

        refute String.contains?(prompt, "Current Time"),
               "Prompt unexpectedly contains a current-time label for opts: #{inspect(opts)}"
      end
    end

    test "is byte-identical across successive builds with identical args" do
      opts = [user: %{timezone: "Europe/Zurich"}, jobs_context: "## Active Jobs\n\n- thing"]

      first = SystemPrompts.build(opts)
      second = SystemPrompts.build(opts)

      assert first == second
      # And it carries no date/time, so even builds across a clock change match.
      refute Regex.match?(~r/\d{4}-\d{2}-\d{2}/, first)
    end

    test "includes skills when load_skills is true" do
      prompt = SystemPrompts.build(load_skills: true)

      assert String.contains?(prompt, "Available Skills")
    end

    test "excludes skills when load_skills is false" do
      prompt = SystemPrompts.build(load_skills: false)

      refute String.contains?(prompt, "Available Skills")
    end
  end

  describe "build/1 with workspace_context" do
    test "includes workspace_context when provided" do
      workspace_ctx = "## Active Workspace\n\n**Status:** Active\n**Workspace:** Empty"

      prompt = SystemPrompts.build(workspace_context: workspace_ctx)

      assert String.contains?(prompt, "Active Workspace")
      assert String.contains?(prompt, "**Status:** Active")
    end

    test "excludes workspace_context when nil" do
      prompt = SystemPrompts.build(workspace_context: nil)

      refute String.contains?(prompt, "Active Workspace")
    end

    test "workspace context appears after skills section" do
      workspace_ctx = "## Active Workspace\n\nSandbox ready."

      prompt = SystemPrompts.build(load_skills: true, workspace_context: workspace_ctx)

      skills_pos = :binary.match(prompt, "Available Skills")
      workspace_pos = :binary.match(prompt, "Active Workspace")

      assert skills_pos != :nomatch
      assert workspace_pos != :nomatch

      {skills_start, _} = skills_pos
      {workspace_start, _} = workspace_pos

      assert workspace_start > skills_start
    end
  end

  describe "build/1 stable-prefix ordering" do
    test "scheduling guidance (stable prefix) appears before dynamic suffix sections" do
      prompt =
        SystemPrompts.build(
          load_skills: true,
          user: %{timezone: "Europe/Zurich"},
          workspace_context: "## Active Workspace\n\nSandbox ready.",
          jobs_context: "## Active Jobs\n\n- **My Job**: 0 9 * * *"
        )

      skills_pos = :binary.match(prompt, "Available Skills")
      scheduling_pos = :binary.match(prompt, "## Scheduling")
      workspace_pos = :binary.match(prompt, "Active Workspace")
      jobs_pos = :binary.match(prompt, "Active Jobs")

      assert skills_pos != :nomatch
      assert scheduling_pos != :nomatch
      assert workspace_pos != :nomatch
      assert jobs_pos != :nomatch

      {skills_start, _} = skills_pos
      {scheduling_start, _} = scheduling_pos
      {workspace_start, _} = workspace_pos
      {jobs_start, _} = jobs_pos

      # Stable prefix: skills (prefix) before scheduling guidance (end of prefix).
      assert skills_start < scheduling_start
      # Scheduling guidance (last of stable prefix) before the dynamic suffix.
      assert scheduling_start < workspace_start
      assert scheduling_start < jobs_start
    end

    test "scheduling guidance present and timestamp-free" do
      prompt = SystemPrompts.build(user: %{timezone: "Europe/Zurich"})

      assert String.contains?(prompt, "## Scheduling")
      assert String.contains?(prompt, "Europe/Zurich")
      refute Regex.match?(~r/\d{4}-\d{2}-\d{2}/, prompt)
    end
  end

  describe "scheduling_guidance/1" do
    test "returns UTC guidance for nil user" do
      guidance = SystemPrompts.scheduling_guidance(nil)

      assert String.contains?(guidance, "## Scheduling")
      assert String.contains?(guidance, "UTC")
    end

    test "returns UTC guidance for user with nil timezone" do
      guidance = SystemPrompts.scheduling_guidance(%{timezone: nil})

      assert String.contains?(guidance, "UTC")
    end

    test "returns the user's timezone and a UTC conversion instruction" do
      guidance = SystemPrompts.scheduling_guidance(%{timezone: "Europe/Berlin"})

      assert String.contains?(guidance, "Europe/Berlin")
      assert String.contains?(guidance, "Convert all times to UTC for cron expressions")
    end

    test "carries no timestamp or date-derived value" do
      guidance = SystemPrompts.scheduling_guidance(%{timezone: "America/Los_Angeles"})

      refute Regex.match?(~r/\d{4}-\d{2}-\d{2}/, guidance)
      refute Regex.match?(~r/\d{1,2}:\d{2}/, guidance)
      refute String.contains?(guidance, "Example")
    end
  end

  describe "build/1 with jobs_context" do
    test "includes jobs_context when provided" do
      jobs_ctx = "## Active Jobs\n\n- **Daily Report**: 0 9 * * * (UTC)"

      prompt = SystemPrompts.build(jobs_context: jobs_ctx)

      assert String.contains?(prompt, "Active Jobs")
      assert String.contains?(prompt, "Daily Report")
    end

    test "excludes jobs_context when nil" do
      prompt = SystemPrompts.build(jobs_context: nil)

      refute String.contains?(prompt, "Active Jobs")
    end

    test "jobs context appears after workspace context" do
      workspace_ctx = "## Active Workspace\n\nSandbox ready."
      jobs_ctx = "## Active Jobs\n\n- **My Job**: 0 9 * * *"

      prompt =
        SystemPrompts.build(workspace_context: workspace_ctx, jobs_context: jobs_ctx)

      workspace_pos = :binary.match(prompt, "Active Workspace")
      jobs_pos = :binary.match(prompt, "Active Jobs")

      assert workspace_pos != :nomatch
      assert jobs_pos != :nomatch

      {workspace_start, _} = workspace_pos
      {jobs_start, _} = jobs_pos

      assert jobs_start > workspace_start
    end
  end

  describe "time_context/1" do
    test "returns UTC context for nil user" do
      context = SystemPrompts.time_context(nil)

      assert String.contains?(context, "## Current Time")
      assert String.contains?(context, "UTC")
    end

    test "returns UTC context for user with nil timezone" do
      context = SystemPrompts.time_context(%{timezone: nil})

      assert String.contains?(context, "UTC")
    end

    test "returns user timezone context" do
      context = SystemPrompts.time_context(%{timezone: "Europe/Berlin"})

      assert String.contains?(context, "Europe/Berlin")
      assert String.contains?(context, "When creating scheduled jobs")
    end

    test "includes example time conversion" do
      context = SystemPrompts.time_context(%{timezone: "America/Los_Angeles"})

      assert String.contains?(context, "Example: \"9 AM\"")
      assert String.contains?(context, "America/Los_Angeles")
    end

    test "handles invalid timezone gracefully" do
      # Should fall back to UTC-like behavior
      context = SystemPrompts.time_context(%{timezone: "Invalid/Timezone"})

      assert String.contains?(context, "## Current Time")
    end
  end
end
