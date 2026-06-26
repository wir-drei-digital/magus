defmodule Magus.Agents.Context.ContextReportTest do
  use ExUnit.Case, async: true
  alias Magus.Agents.Context.ContextReport

  @separator "\n\n---\n\n"

  test "approx_tokens uses chars/4" do
    assert ContextReport.approx_tokens(String.duplicate("x", 40)) == 10
    assert ContextReport.approx_tokens(nil) == 0
  end

  describe "split_sections/1" do
    test "labels each ---joined section by its first non-blank line" do
      prompt = "# Persona\nbe nice\n\n---\n\n## Scheduling\nclock"
      assert [{"# Persona", _}, {"## Scheduling", _}] = ContextReport.split_sections(prompt)
    end

    test "returns one labeled entry per separator-joined section" do
      prompt =
        [
          "## First Section\nbody of the first section",
          "## Second Section\nbody of the second section that is longer here",
          "## Third Section\ntiny"
        ]
        |> Enum.join(@separator)

      sections = ContextReport.split_sections(prompt)

      assert length(sections) == 3

      labels = Enum.map(sections, fn {label, _tokens} -> label end)
      assert labels == ["## First Section", "## Second Section", "## Third Section"]

      # Every section has a non-negative token count and at least one is positive.
      assert Enum.all?(sections, fn {_label, tokens} -> tokens >= 0 end)
      assert Enum.any?(sections, fn {_label, tokens} -> tokens > 0 end)
    end

    test "labels a section without a heading by its first non-blank line" do
      prompt = "\n\nplain paragraph with no heading here"
      assert [{label, tokens}] = ContextReport.split_sections(prompt)
      assert label == "plain paragraph with no heading here"
      assert tokens > 0
    end

    test "labels are truncated to ~40 chars" do
      long_first_line = String.duplicate("x", 100)
      assert [{label, _}] = ContextReport.split_sections(long_first_line)
      assert String.length(label) == 40
    end
  end

  describe "prefix_suffix_split/1" do
    test "splits at the Scheduling section inclusive" do
      prompt = "# A\nx\n\n---\n\n## Scheduling\ny\n\n---\n\n## Tail\nz"
      {prefix, suffix} = ContextReport.prefix_suffix_split(prompt)
      assert prefix > 0 and suffix > 0
    end

    test "everything up to and including ## Scheduling is the prefix" do
      prefix_sections = [
        "## Base Rules\nfoo",
        "## Identity\nbar",
        "## Scheduling\n\nWhen creating scheduled jobs:\n- timezone stuff"
      ]

      suffix_sections = [
        "## Workspace\nworkspace context here",
        "## Tasks\nopen tasks here"
      ]

      prompt = Enum.join(prefix_sections ++ suffix_sections, @separator)

      {prefix_tokens, suffix_tokens} = ContextReport.prefix_suffix_split(prompt)

      expected_prefix = prefix_sections |> Enum.join(@separator)
      expected_suffix = suffix_sections |> Enum.join(@separator)

      assert prefix_tokens == div(String.length(expected_prefix), 4)
      assert suffix_tokens == div(String.length(expected_suffix), 4)
      assert prefix_tokens > 0
      assert suffix_tokens > 0
    end

    test "falls back to whole prompt as prefix when ## Scheduling is absent" do
      prompt =
        ["## Base Rules\nfoo", "## Workspace\nbar"]
        |> Enum.join(@separator)

      {prefix_tokens, suffix_tokens} = ContextReport.prefix_suffix_split(prompt)

      assert prefix_tokens == div(String.length(prompt), 4)
      assert suffix_tokens == 0
    end
  end

  describe "has_stable_prefix_marker?/1" do
    test "true when a ## Scheduling section is present" do
      prompt = "## Base Rules\nfoo\n\n---\n\n## Scheduling\nclock"
      assert ContextReport.has_stable_prefix_marker?(prompt)
    end

    test "false when the marker section is absent" do
      prompt = "## Base Rules\nfoo\n\n---\n\n## Workspace\nbar"
      refute ContextReport.has_stable_prefix_marker?(prompt)
    end
  end

  describe "tool_token_breakdown/1" do
    test "returns positive per-tool tokens and a total equal to their sum" do
      tools = [Magus.Agents.Tools.DiceRoll, Magus.Agents.Tools.Web.WebSearch]

      {lines, total} = ContextReport.tool_token_breakdown(tools)

      assert length(lines) == 2

      # Each tool reports a positive approximate token count.
      assert Enum.all?(lines, fn {name, tokens} ->
               is_binary(name) and tokens > 0
             end)

      # The total equals the sum of the per-tool counts.
      assert total == lines |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      assert total > 0
    end

    test "is sorted by tokens descending" do
      tools = [Magus.Agents.Tools.DiceRoll, Magus.Agents.Tools.Web.WebSearch]
      {lines, _total} = ContextReport.tool_token_breakdown(tools)

      token_counts = Enum.map(lines, &elem(&1, 1))
      assert token_counts == Enum.sort(token_counts, :desc)
    end

    test "ignores non-module entries and returns zero total for empty list" do
      assert {[], 0} = ContextReport.tool_token_breakdown([])
      assert {[], 0} = ContextReport.tool_token_breakdown([%{name: "not_a_module"}])
    end
  end

  describe "categorize/1 (via build/1) splits the former Other (system) bucket" do
    # Each section's first-line heading is what categorize/1 keys off. These are
    # the real headings the context builders emit (SystemPrompts, WorkspaceContext,
    # DraftContext, JobsContext, TaskContext, AttachedDocumentsContext), which all
    # used to fall through to :other_system.
    @cases [
      {:agents, "## Available Agents\nyou can delegate to @x"},
      {:apis, "## Available APIs\ncall these with http_request"},
      {:workspace, "## Active Workspace\nyour sandbox is ready"},
      {:drafts, "## Active Draft\nthere is an active draft document"},
      {:drafts, "## Drafts\nthere are drafts in the side pane"},
      {:jobs, "## Active Jobs\nthis conversation has scheduled jobs"},
      {:tasks, "## Tasks\n- [ ] do the thing"},
      {:documents,
       "<attached_documents>\n<document name=\"a\">x</document>\n</attached_documents>"},
      {:persona, "Your name is Aria (@aria). Respond as this agent."}
    ]

    for {expected_key, section} <- @cases do
      test "#{section |> String.split("\n") |> hd()} → #{expected_key}" do
        snap =
          ContextReport.build(%{
            system_prompt: unquote(section),
            tools: [],
            messages: [],
            model_key: "openrouter:test",
            max_context: 200_000
          })

        keys = Enum.map(snap.categories, & &1.key)
        assert unquote(expected_key) in keys
        refute :other_system in keys
      end
    end

    test "a genuinely unrecognized system section still falls back to :other_system" do
      snap =
        ContextReport.build(%{
          system_prompt: "## Quantum Flux Capacitor\nundocumented system section",
          tools: [],
          messages: [],
          model_key: "openrouter:test",
          max_context: 200_000
        })

      assert [%{key: :other_system, label: "Other (system)"}] = snap.categories
    end
  end

  describe "categorize/1 (via build/1) is marker-driven" do
    test "an explicit section marker wins over a misleading heading" do
      # The body's heading looks like our Tasks section, but the marker says it
      # is the user's custom instructions — the marker must win.
      section =
        Magus.Agents.Context.SectionMarker.wrap(
          :instructions,
          "## Tasks\nactually a custom prompt"
        )

      snap =
        ContextReport.build(%{
          system_prompt: section,
          tools: [],
          messages: [],
          model_key: "openrouter:test",
          max_context: 200_000
        })

      keys = Enum.map(snap.categories, & &1.key)
      assert :instructions in keys
      refute :tasks in keys
    end

    test "a regular heading with no marker is NOT counted as one of our sections" do
      # This is the brittleness the markers fix: an unmarked '## Available Agents'
      # heading appearing in arbitrary content must not be mistaken for the real,
      # marked Agents section. (Here it still resolves via the legacy heading
      # fallback, but a marked Agents section is what production emits.)
      marked = Magus.Agents.Context.SectionMarker.wrap(:agents, "## Available Agents\n@x")

      snap =
        ContextReport.build(%{
          system_prompt: marked,
          tools: [],
          messages: [],
          model_key: "openrouter:test",
          max_context: 200_000
        })

      assert [%{key: :agents, label: "Agents"}] = snap.categories
    end
  end

  test "build/1 returns categorized snapshot with reconciling total" do
    prompt =
      "# Persona\nrules\n\n---\n\n## Skills\nindex\n\n---\n\n" <>
        "## Relevant memories\nm\n\n---\n\n## Relevant files\nf"

    messages = [%{role: :user, content: "hello there friend"}]

    snap =
      Magus.Agents.Context.ContextReport.build(%{
        system_prompt: prompt,
        tools: [],
        messages: messages,
        model_key: "openrouter:test",
        max_context: 200_000
      })

    keys = Enum.map(snap.categories, & &1.key)
    assert :persona in keys
    assert :skills in keys
    assert :memory in keys
    assert :files_rag in keys
    assert :messages in keys
    assert snap.max_context == 200_000
    assert snap.total_tokens == Enum.reduce(snap.categories, 0, &(&1.tokens + &2))
  end
end
