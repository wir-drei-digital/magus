defmodule Mix.Tasks.Agent.Preflight do
  @shortdoc "Dump the preflight LLM context (system prompt + messages + metadata) for a conversation."

  @moduledoc """
  Inspect the full context Preflight assembles for a conversation before it is
  sent to the LLM: the system prompt, the message history, and the simulated
  current user turn, plus metadata (model, tool list, approximate token
  counts).

  No LLM call is made and nothing is persisted. Model resolution skips
  usage/region checks and auto-routing (for an `:auto` conversation the default
  chat model is shown; override with `--model`).

      # by conversation
      mix agent.preflight --conversation 0190... --text "what's next?"

      # most recent conversation for a user
      mix agent.preflight --user alice@example.com

      # machine-readable
      mix agent.preflight --conversation 0190... --json

  Flags:

    * `--conversation UUID` - conversation to inspect
    * `--user EMAIL` - use the user's most recent conversation when
      `--conversation` is omitted
    * `--text TEXT` - simulate the next user message, appended after history
      (default: empty)
    * `--mode MODE` - chat | search | reasoning | image_generation |
      video_generation (default: the conversation's mode)
    * `--model KEY` - override the resolved chat model key
    * `--json` - emit JSON instead of human-readable text

  Token counts are approximate (a `chars/4` heuristic; the project ships no
  exact tokenizer) and exclude image/file parts.
  """

  use Mix.Task

  alias Magus.Agents.Context.ContextReport
  alias Magus.Agents.Plugins.Support.Preflight

  require Ash.Query

  @modes ~w(chat search reasoning image_generation video_generation)

  # Heading of the section that ends the stable, cacheable prefix. Everything up
  # to and including this section is byte-stable within a conversation; the rest
  # (workspace/draft/brain/jobs/tasks/skill context, plus memory/RAG/brain/
  # super-brain appended even later by the Builder) is recomputed per turn.
  # Kept here only for the human-readable note copy; the split/marker logic lives
  # in `Magus.Agents.Context.ContextReport`.
  @stable_prefix_marker "## Scheduling"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          conversation: :string,
          user: :string,
          text: :string,
          mode: :string,
          model: :string,
          json: :boolean
        ]
      )

    Mix.Task.run("app.start")

    conversation_id = resolve_conversation_id(opts)

    assemble_opts =
      [text: opts[:text] || ""]
      |> maybe_put(:mode, parse_mode(opts[:mode]))
      |> maybe_put(:model_key, opts[:model])

    case Preflight.assemble_context(conversation_id, assemble_opts) do
      {:ok, result} ->
        if opts[:json], do: emit_json(result), else: emit_human(result)

      {:error, reason} ->
        Mix.raise("Failed to assemble preflight context: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Input resolution
  # ---------------------------------------------------------------------------

  defp resolve_conversation_id(opts) do
    cond do
      is_binary(opts[:conversation]) ->
        opts[:conversation]

      is_binary(opts[:user]) ->
        most_recent_conversation_id(opts[:user])

      true ->
        Mix.raise("Provide --conversation <uuid> or --user <email>")
    end
  end

  defp most_recent_conversation_id(email) do
    user =
      case Magus.Accounts.get_by_email(email, authorize?: false) do
        {:ok, user} -> user
        _ -> Mix.raise("No user found with email #{email}")
      end

    query =
      Magus.Chat.Conversation
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, authorize?: false) do
      {:ok, %{id: id}} -> id
      _ -> Mix.raise("No conversations found for #{email}")
    end
  end

  defp parse_mode(nil), do: nil

  defp parse_mode(mode) when is_binary(mode) do
    if mode in @modes do
      String.to_existing_atom(mode)
    else
      Mix.raise("Unknown --mode #{inspect(mode)} (allowed: #{Enum.join(@modes, ", ")})")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # ---------------------------------------------------------------------------
  # Output
  # ---------------------------------------------------------------------------

  defp emit_human(result) do
    %{conversation: conversation, mode: mode, model: model, text: text, request_context: rc} =
      result

    system_prompt = rc.system_prompt || ""
    messages = rc.initial_messages || []
    tools = rc.tools || []

    sp_tokens = ContextReport.approx_tokens(system_prompt)
    {rendered, msg_tokens} = render_messages(messages)

    {tool_lines, tools_tokens} = ContextReport.tool_token_breakdown(tools)
    sections = ContextReport.split_sections(system_prompt)
    {prefix_tokens, suffix_tokens} = ContextReport.prefix_suffix_split(system_prompt)
    grand_total = sp_tokens + msg_tokens + tools_tokens

    Mix.shell().info("""
    === PREFLIGHT CONTEXT ===
    conversation:   #{conversation.id}
    user:           #{conversation.user_id}
    mode:           #{mode}
    model:          #{model_label(model)}
    messages:       #{length(messages)}
    tools:          #{length(tools)}#{tool_names_suffix(tools)}
    simulated text: #{inspect(text)}

    tokens (approx, chars/4):
      system_prompt: #{sp_tokens}
      messages:      #{msg_tokens}
      tools:         #{tools_tokens}
      total:         #{grand_total}

    system prompt cacheability (approx, chars/4):
      stable_prefix:  #{prefix_tokens}#{stable_prefix_note(system_prompt)}
      dynamic_suffix: #{suffix_tokens}
      (memory/RAG/brain/super-brain are appended even later by the Builder
       and are NOT shown here.)
    """)

    Mix.shell().info("----- TOOL SCHEMA TOKENS (approx, chars/4) -----")

    Enum.each(tool_lines, fn {name, tokens} ->
      Mix.shell().info("  #{String.pad_trailing(name, 32)} #{tokens}")
    end)

    Mix.shell().info("  #{String.pad_trailing("TOOLS TOTAL", 32)} #{tools_tokens}")

    Mix.shell().info("\n----- SYSTEM PROMPT SECTIONS (approx, chars/4) -----")

    Enum.each(sections, fn {label, tokens} ->
      Mix.shell().info("  #{String.pad_trailing(label, 40)} #{tokens}")
    end)

    Mix.shell().info("\n----- SYSTEM PROMPT -----")
    Mix.shell().info(system_prompt)
    Mix.shell().info("\n----- MESSAGES -----")

    Enum.each(rendered, fn {idx, role, content} ->
      Mix.shell().info("[#{idx}] #{role}:")
      Mix.shell().info(content)
      Mix.shell().info("")
    end)
  end

  defp stable_prefix_note(system_prompt) do
    if ContextReport.has_stable_prefix_marker?(system_prompt) do
      ""
    else
      " (marker #{inspect(@stable_prefix_marker)} absent; whole prompt counted as prefix)"
    end
  end

  defp emit_json(result) do
    %{conversation: conversation, mode: mode, model: model, text: text, request_context: rc} =
      result

    system_prompt = rc.system_prompt || ""
    messages = rc.initial_messages || []
    tools = rc.tools || []

    sp_tokens = ContextReport.approx_tokens(system_prompt)
    {rendered, msg_tokens} = render_messages(messages)

    {tool_lines, tools_tokens} = ContextReport.tool_token_breakdown(tools)
    sections = ContextReport.split_sections(system_prompt)
    {prefix_tokens, suffix_tokens} = ContextReport.prefix_suffix_split(system_prompt)

    payload = %{
      conversation_id: conversation.id,
      user_id: conversation.user_id,
      mode: mode,
      model: %{key: model_key(model), name: model_name(model)},
      tools: Enum.map(tool_lines, fn {name, tokens} -> %{name: name, tokens: tokens} end),
      tools_tokens: tools_tokens,
      sections: Enum.map(sections, fn {label, tokens} -> %{label: label, tokens: tokens} end),
      stable_prefix_tokens: prefix_tokens,
      dynamic_suffix_tokens: suffix_tokens,
      stable_prefix_marker_present: ContextReport.has_stable_prefix_marker?(system_prompt),
      tokens: %{
        approximate: true,
        system_prompt: sp_tokens,
        messages: msg_tokens,
        tools: tools_tokens,
        total: sp_tokens + msg_tokens + tools_tokens
      },
      system_prompt: system_prompt,
      messages:
        Enum.map(rendered, fn {idx, role, content} ->
          %{index: idx, role: role, content: content}
        end),
      simulated_text: text
    }

    Mix.shell().info(Jason.encode!(payload, pretty: true))
  end

  # ---------------------------------------------------------------------------
  # Rendering helpers
  # ---------------------------------------------------------------------------

  # Returns `{[{index, role, content_string}], total_approx_tokens}`.
  defp render_messages(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map_reduce(0, fn {msg, idx}, acc ->
      content = render_content(message_content(msg))
      {{idx, message_role(msg), content}, acc + ContextReport.approx_tokens(content)}
    end)
  end

  defp message_role(%{role: role}), do: role
  defp message_role(_), do: :unknown

  defp message_content(%{content: content}), do: content
  defp message_content(other), do: other

  defp render_content(content) when is_binary(content), do: content

  defp render_content(content) when is_list(content),
    do: Enum.map_join(content, "\n", &render_part/1)

  defp render_content(other), do: inspect(other)

  defp render_part(%{type: :text, text: t}) when is_binary(t), do: t
  defp render_part(%{text: t}) when is_binary(t), do: t
  defp render_part(%{type: type}), do: "[#{type} part]"
  defp render_part(part) when is_binary(part), do: part
  defp render_part(part), do: inspect(part)

  defp tool_names_suffix([]), do: ""
  defp tool_names_suffix(tools), do: " [" <> Enum.map_join(tools, ", ", &tool_name/1) <> "]"

  defp tool_name(tool) when is_atom(tool) do
    if function_exported?(tool, :name, 0), do: tool.name(), else: inspect(tool)
  end

  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(tool), do: inspect(tool)

  defp model_label(model), do: "#{model_key(model)} (#{model_name(model)})"

  defp model_key(%{key: key}) when is_binary(key), do: key
  defp model_key(_), do: "unknown"

  defp model_name(%{name: name}) when is_binary(name), do: name
  defp model_name(_), do: "unknown"
end
