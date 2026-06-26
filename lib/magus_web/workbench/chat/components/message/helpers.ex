defmodule MagusWeb.ChatLive.Components.Message.Helpers do
  @moduledoc """
  Helper functions for message stream components.

  Contains utility functions for markdown rendering, citation handling,
  message alignment, and attachment loading.
  """

  alias Magus.Files.Storage

  @doc """
  Converts markdown text to HTML with citation support.
  """
  def to_markdown(text, citations, opts \\ []) do
    uid = opts[:id] || System.unique_integer([:positive])

    MDEx.new(
      markdown: text,
      extension: [
        strikethrough: true,
        tagfilter: true,
        table: true,
        autolink: true,
        tasklist: true,
        footnotes: true,
        shortcodes: true,
        math_dollars: true,
        math_code: true
      ],
      parse: [
        smart: true,
        relaxed_tasklist_matching: true,
        relaxed_autolinks: true
      ],
      render: [
        github_pre_lang: false
      ],
      syntax_highlight: nil,
      sanitize:
        Keyword.merge(MDEx.Document.default_sanitize_options(),
          add_generic_attribute_prefixes: ["data-", "phx-"],
          add_tag_attributes: %{"div" => ["id", "class"], "pre" => ["id"]}
        )
    )
    |> MDExKatex.attach(
      katex_init: "",
      katex_block_attrs: fn seq ->
        ~s(id="katex-#{uid}-#{seq}" class="katex-block" phx-update="ignore")
      end
    )
    |> MDExMermaid.attach(
      mermaid_init: "",
      mermaid_pre_attrs: fn seq ->
        ~s(id="mermaid-#{uid}-#{seq}" class="mermaid")
      end
    )
    |> deduplicate_plugin_steps()
    |> MDEx.to_html()
    |> case do
      {:ok, html} ->
        agents = opts[:agents] || []

        html
        |> replace_citation_references(citations)
        |> highlight_agent_mentions(agents)
        |> highlight_slash_commands()
        |> Phoenix.HTML.raw()

      {:error, _} ->
        text
    end
  end

  @doc """
  Gets citations that are actually referenced in the text.
  """
  def get_referenced_citations(text, citations) when is_binary(text) and is_list(citations) do
    if citations == [] do
      []
    else
      # Find all [N] references in the text
      referenced_indices =
        Regex.scan(~r/\[(\d+)\]/, text)
        |> Enum.map(fn [_, num_str] ->
          case Integer.parse(num_str) do
            {num, ""} when num >= 1 -> num - 1
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      referenced =
        referenced_indices
        |> Enum.map(&Enum.at(citations, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(&citation_url/1)

      # Fallback: if citations exist but none were referenced via [N] in the text,
      # show all citations (handles models that don't use [N] format like some Sonar responses)
      if referenced == [] do
        Enum.uniq_by(citations, &citation_url/1)
      else
        referenced
      end
    end
  end

  def get_referenced_citations(_, _), do: []

  # Access citation URL handling both string and atom keys
  defp citation_url(%{"url" => url}), do: url
  defp citation_url(%{url: url}), do: url
  defp citation_url(_), do: nil

  @doc """
  Determines message alignment for chat bubbles.
  In multiplayer: own messages on right, others on left.
  In single player: user messages on right, agent on left.
  """
  def message_alignment(item, is_multiplayer, current_user) do
    cond do
      item.source == :agent ->
        "start"

      is_multiplayer ->
        if is_own_message?(item, current_user), do: "end", else: "start"

      true ->
        "end"
    end
  end

  @doc """
  Checks if a message was created by the current user.
  """
  def is_own_message?(item, current_user) do
    created_by = Map.get(item, :created_by)

    cond do
      match?(%Ash.NotLoaded{}, created_by) ->
        Map.get(item, :created_by_id) == current_user.id

      is_map(created_by) && Map.has_key?(created_by, :id) ->
        created_by.id == current_user.id

      true ->
        Map.get(item, :created_by_id) == current_user.id
    end
  end

  @doc """
  Gets the display name for a message sender.
  """
  def get_message_user_name(item, is_multiplayer, current_user) do
    cond do
      item.source == :agent ->
        Map.get(item, :model_name)

      is_multiplayer && !is_own_message?(item, current_user) ->
        created_by = Map.get(item, :created_by)

        if created_by && is_struct(created_by) do
          created_by.display_name || to_string(created_by.email)
        end

      true ->
        nil
    end
  end

  @doc """
  Loads attachments by ID when not preloaded.
  """
  def load_attachments_for_display(item, current_user) do
    attachment_ids = Map.get(item, :attachments, []) || []
    Magus.Files.load_for_display!(attachment_ids, actor: current_user)
  end

  @doc """
  Converts preloaded File structs to display maps.
  """
  def files_to_display(files) do
    Enum.map(files, fn file ->
      url =
        case Storage.get_url(file.file_path) do
          {:ok, url} -> url
          _ -> nil
        end

      %{
        "id" => file.id,
        "type" => to_string(file.type),
        "name" => file.name,
        "url" => url,
        "mime_type" => file.mime_type,
        "size" => file.file_size
      }
    end)
  end

  # Private helpers

  # MDExKatex and MDExMermaid both register steps with the same names
  # (enable_unsafe, inject_init, update_code_blocks). MDEx uses Keyword.fetch!/2
  # to look up steps by name, which only returns the first match — so the second
  # plugin's steps never run. This renames duplicate keys to make them unique.
  defp deduplicate_plugin_steps(doc) do
    seen = MapSet.new()

    {steps, _} =
      Enum.map_reduce(doc.steps, seen, fn {key, fun}, seen ->
        if MapSet.member?(seen, key) do
          new_key = :"#{key}_2"
          {{new_key, fun}, MapSet.put(seen, new_key)}
        else
          {{key, fun}, MapSet.put(seen, key)}
        end
      end)

    %{doc | steps: steps, current_steps: Keyword.keys(steps)}
  end

  # Replace [N] citation references with clickable badges showing domain name
  defp replace_citation_references(html, []), do: html

  defp replace_citation_references(html, citations) when is_list(citations) do
    Regex.replace(~r/\[(\d+)\]/, html, fn full_match, num_str ->
      case Integer.parse(num_str) do
        {num, ""} when num >= 1 ->
          index = num - 1

          case Enum.at(citations, index) do
            nil ->
              full_match

            citation ->
              url = citation_url(citation) || "#"
              domain = extract_domain(url)
              title = get_citation_tooltip(citation)
              build_citation_badge(domain, url, title)
          end

        _ ->
          full_match
      end
    end)
  end

  defp replace_citation_references(html, _), do: html

  # Highlight @handle mentions that match a known custom agent
  defp highlight_agent_mentions(html, []), do: html

  defp highlight_agent_mentions(html, agents) when is_list(agents) do
    handle_map =
      Map.new(agents, fn a -> {a.handle, a.name} end)

    Regex.replace(~r/(?<=^|[\s>])@([a-z0-9][a-z0-9-]*)/, html, fn full_match, handle ->
      case Map.get(handle_map, handle) do
        nil ->
          full_match

        name ->
          ~s(<span class="mention-agent" title="#{escape_attr(name)}">@#{escape_attr(handle)}</span>)
      end
    end)
  end

  defp highlight_agent_mentions(html, _), do: html

  # Highlight /command at the start of user messages when it matches a known slash command
  defp highlight_slash_commands(html) do
    commands = Magus.Agents.SlashCommands.list()
    names = MapSet.new(commands, & &1.name)

    Regex.replace(~r{(?<=^|<p>)/([a-z0-9][a-z0-9-]*)}, html, fn full_match, name ->
      if MapSet.member?(names, name) do
        ~s(<span class="slash-command">/#{escape_attr(name)}</span>)
      else
        full_match
      end
    end)
  end

  defp extract_domain(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host |> String.replace_leading("www.", "")

      _ ->
        "source"
    end
  end

  defp extract_domain(_), do: "source"

  defp get_citation_tooltip(citation) do
    title = citation["title"] || citation[:title]
    url = citation_url(citation)

    case title do
      nil -> url || "Source"
      "" -> url || "Source"
      t -> t
    end
  end

  defp build_citation_badge(domain, url, title) do
    ~s(<a href="#{escape_attr(safe_href(url))}" target="_blank" rel="noopener noreferrer" title="#{escape_attr(title)}" class="inline-flex items-center justify-center h-5 px-1.5 text-xs font-medium rounded bg-primary/20 text-primary hover:bg-primary/30 no-underline align-baseline mx-0.5">#{escape_attr(domain)}</a>)
  end

  # Allowlist the href scheme: a citation url is model-provided and bypasses the
  # MDEx sanitizer (the badge is injected into already-rendered HTML), so a
  # `javascript:`/`data:` url would otherwise become a clickable XSS vector.
  defp safe_href(url) when is_binary(url) do
    if Regex.match?(~r/^(https?:|mailto:)/i, String.trim(url)), do: url, else: "#"
  end

  defp safe_href(_), do: "#"

  defp escape_attr(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp escape_attr(_), do: ""
end
