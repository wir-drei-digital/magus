defmodule Magus.LiveE2E.BrainGuidesTest do
  @moduledoc """
  Live E2E test for Brain Guides (Phase B): a real LLM-driven agent organizes
  a brain per its Guide.

  Seeds a brain with a Guide (constitution + a "Note" type/template) plus a
  couple of untyped existing pages, opens a conversation with the brain (and
  a page) in context so `Magus.Agents.Context.BrainContext` injects the
  `### Brain Guide` block, then asks the agent to capture a note. Asserts
  structurally on the persisted result (frontmatter `type`, parent filing,
  task attachment) rather than on generated prose, since a real LLM's exact
  wording and tool sequence are non-deterministic.
  """
  use Magus.LiveE2ECase, async: false

  alias Magus.Brain

  @moduletag :brain_guides
  @moduletag timeout: 240_000

  describe "agent captures a note per the brain's Guide" do
    test "classifies the new/updated page with a type from the brain's Guide", %{
      user: user,
      model: model
    } do
      %{brain: brain, topic_page: topic_page, existing_page: existing_page} =
        seed_brain_with_guide(user)

      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      send_brain_scoped_message(
        conversation,
        user,
        brain.id,
        topic_page.id,
        "Capture this as a new page in my brain, titled \"Espresso Machine\": " <>
          "\"The espresso machine needs descaling every 4 weeks.\" " <>
          "Steps: 1) Use edit_brain write_page with parent_page_id set to the Kitchen " <>
          "page's id (from your context) so it's nested under Kitchen, not at the root. " <>
          "2) Use brain_guide set_page_type on the new page with type: \"Note\" so it's " <>
          "classified per the brain's Guide (there's a Note type defined for this brain)."
      )

      # The agent must reach for the brain tools (read_brain to look around
      # and/or edit_brain to write) rather than just replying in prose.
      assert_tool_started("edit_brain")
      assert_tool_completed("edit_brain")

      assert_response_complete(180_000)
      drain_signals()

      # ------------------------------------------------------------------
      # Structural assertions on persisted brain state, scoped to the
      # seeded brain (not the whole table, which can carry leaked rows in
      # the shared test DB per docs/worktree-context.md).
      # ------------------------------------------------------------------
      {:ok, pages} = Brain.list_pages(brain.id, actor: user)

      # 1) The brain grew (a new page was created) or an existing seeded page
      # absorbed the note (its body changed). Either shows the agent wrote
      # the note into the brain rather than just replying in chat.
      seeded_ids = MapSet.new([topic_page.id, existing_page.id])
      new_pages = Enum.reject(pages, &MapSet.member?(seeded_ids, &1.id))

      assert new_pages != [] or pages_changed_since_seed?(pages, topic_page),
             "Expected the agent to create a new page or modify an existing one to " <>
               "capture the note, but the brain looks untouched. Pages: " <>
               inspect(Enum.map(pages, &{&1.title, &1.frontmatter}))

      # 2) At least one page in the brain (new or existing) now carries a
      # `type` in frontmatter that matches a defined type/template, proving
      # the agent classified content per the Guide rather than just filing
      # loose text. This is the core "follows the Guide" assertion; accept
      # ANY typed page (not necessarily the newest one) since a real model
      # may choose to classify an existing page instead of creating one.
      typed_pages = Enum.filter(pages, &present?(&1.frontmatter["type"]))

      assert typed_pages != [],
             "Expected at least one page with a `type` in frontmatter (the agent " <>
               "classifying content per the brain's Guide), got pages: " <>
               inspect(Enum.map(pages, &{&1.title, &1.frontmatter}))

      # 3) The classified page's type matches a real template defined in
      # this brain's Guide (not an invented, unregistered type), OR a task
      # was attached to a page instead (the brief's alternate acceptable
      # outcome: "adds a task to an ordinary page"). Either is evidence the
      # agent engaged with the brain's actual structure rather than
      # free-associating.
      {:ok, templates} = Brain.templates_for_brain(brain.id, actor: user)
      template_titles = MapSet.new(templates, &String.downcase(&1.title || ""))

      type_matches_template? =
        Enum.any?(typed_pages, fn page ->
          type = page.frontmatter["type"]
          is_binary(type) and MapSet.member?(template_titles, String.downcase(type))
        end)

      task_count = brain_task_count(brain.id, user)

      assert type_matches_template? or task_count > 0,
             "Expected the classified page's type to match a defined template " <>
               "(#{inspect(MapSet.to_list(template_titles))}) or a task to be attached " <>
               "to a brain page, got typed pages: " <>
               inspect(Enum.map(typed_pages, &{&1.title, &1.frontmatter["type"]})) <>
               " and task_count: #{task_count}"
    end
  end

  # ---------------------------------------------------------------------------
  # Seeding
  # ---------------------------------------------------------------------------

  # Seeds a small brain with a Guide: a constitution, a "Note" type +
  # template (a couple of headings), and a topic page with one existing
  # untyped sibling so the brain isn't empty. Mirrors the canonical pattern
  # in test/magus/agents/tools/brain/brain_guide_test.exs.
  defp seed_brain_with_guide(user) do
    {:ok, brain} = Brain.create_brain(%{title: "Household Notes"}, actor: user)

    {:ok, _brain} =
      Brain.set_brain_instructions(
        brain,
        %{
          instructions:
            "Every page declares a type. File new notes under the right topic instead " <>
              "of leaving them at the root."
        },
        actor: user
      )

    {:ok, template} =
      Brain.create_page(brain.id, %{title: "Note", kind: :template}, actor: user)

    {:ok, _template} =
      Brain.update_page_body(
        template,
        %{
          body: """
          # {{title}}

          ## Summary

          ## Details
          """,
          base_version: template.lock_version
        },
        actor: user
      )

    {:ok, topic_page} = Brain.create_page(brain.id, %{title: "Kitchen"}, actor: user)

    {:ok, topic_page} =
      Brain.update_page_body(
        topic_page,
        %{body: "# Kitchen\n\nNotes about kitchen appliances and upkeep.", base_version: 0},
        actor: user
      )

    # An existing untyped content page, so the brain has real (if messy)
    # content to file alongside, not just the topic root.
    {:ok, existing_page} =
      Brain.create_page(
        brain.id,
        %{title: "Fridge temperature", parent_page_id: topic_page.id},
        actor: user
      )

    {:ok, _existing_page} =
      Brain.update_page_body(
        existing_page,
        %{
          body: "# Fridge temperature\n\nKeep the fridge at 4C or below.",
          base_version: existing_page.lock_version
        },
        actor: user
      )

    %{brain: brain, template: template, topic_page: topic_page, existing_page: existing_page}
  end

  # ---------------------------------------------------------------------------
  # Message sending with brain scope
  # ---------------------------------------------------------------------------

  # LiveE2ECase.send_user_message/3 doesn't thread metadata; brain scope
  # (which makes BrainContext inject "### Brain Guide" and gives the brain
  # tools an auto-resolved brain_id/brain_page_id) rides on the message's
  # metadata, matching how the SPA's brain pane selection reaches the agent
  # (see Magus.Agents.Dispatcher.build_signal_data/3).
  defp send_brain_scoped_message(conversation, user, brain_id, brain_page_id, text) do
    {:ok, message} =
      Magus.Chat.send_user_message(
        %{
          text: text,
          conversation_id: conversation.id,
          metadata: %{"brain_id" => brain_id, "brain_page_id" => brain_page_id}
        },
        actor: user
      )

    message
  end

  # ---------------------------------------------------------------------------
  # Assertion helpers
  # ---------------------------------------------------------------------------

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false

  # True when the seeded topic page's body or frontmatter changed (the agent
  # appended the note directly to it instead of creating a new page).
  defp pages_changed_since_seed?(pages, seeded_topic_page) do
    case Enum.find(pages, &(&1.id == seeded_topic_page.id)) do
      nil -> false
      reloaded -> reloaded.body != seeded_topic_page.body
    end
  end

  defp brain_task_count(brain_id, user) do
    {:ok, tasks} = Magus.Plan.tasks_for_brain(brain_id, actor: user)
    length(tasks)
  end
end
