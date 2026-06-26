defmodule Magus.Docs.Registry.Compiler do
  @moduledoc false
  # Compile-time helpers for parsing doc files.
  # Extracted into a separate module so these functions are available
  # when the Registry module computes its @compiled_docs attribute.

  def parse_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [yaml, body] ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, meta} -> {:ok, meta, String.trim(body)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse_frontmatter(_), do: :error

  def render_markdown(body) do
    MDEx.to_html(body,
      extension: [
        strikethrough: true,
        table: true,
        autolink: true,
        tasklist: true,
        footnotes: true
      ],
      parse: [smart: true],
      render: [github_pre_lang: true, unsafe: true],
      sanitize: MDEx.Document.default_sanitize_options()
    )
  end
end

defmodule Magus.Docs.Registry do
  @moduledoc """
  Compile-time registry for user documentation.

  Reads markdown files from `docs/user/<category>/<slug>.<locale>.md`,
  parses YAML frontmatter, and renders HTML via MDEx at compile time.
  """

  alias Magus.Docs.Registry.Compiler

  @docs_path Path.expand("../../../priv/docs/user", __DIR__)

  @category_order ~w(
    getting-started
    conversations
    prompts
    knowledge
    collaboration
    agents
    integrations
    account
  )
  @category_labels %{
    "getting-started" => %{"en" => "Getting Started", "de" => "Erste Schritte"},
    "conversations" => %{"en" => "Conversations", "de" => "Unterhaltungen"},
    "prompts" => %{"en" => "Prompts & Library", "de" => "Prompts & Bibliothek"},
    "collaboration" => %{"en" => "Collaboration", "de" => "Zusammenarbeit"},
    "agents" => %{"en" => "Agents", "de" => "Agenten"},
    "knowledge" => %{"en" => "Knowledge & Files", "de" => "Wissen & Dateien"},
    "integrations" => %{"en" => "Integrations", "de" => "Integrationen"},
    "account" => %{"en" => "Account & Settings", "de" => "Konto & Einstellungen"}
  }

  @supported_locales ~w(en de)

  # Register external resources for recompilation on change
  for category <- @category_order,
      path <- Path.wildcard(Path.join([@docs_path, category, "*.md"])) do
    @external_resource path
  end

  # Parse all docs at compile time
  @compiled_docs (
                   supported = @supported_locales
                   category_order = @category_order
                   docs_path = @docs_path

                   for category <- category_order,
                       path <-
                         Path.wildcard(Path.join([docs_path, category, "*.md"])) |> Enum.sort(),
                       reduce: [] do
                     acc ->
                       filename = Path.basename(path, ".md")

                       case String.split(filename, ".") do
                         [slug, locale] ->
                           if locale in supported do
                             content = File.read!(path)

                             case Compiler.parse_frontmatter(content) do
                               {:ok, meta, body} ->
                                 {:ok, html} = Compiler.render_markdown(body)

                                 doc = %{
                                   slug: slug,
                                   locale: locale,
                                   category: category,
                                   title: meta["title"] || slug,
                                   description: meta["description"] || "",
                                   order: meta["order"] || 999,
                                   html: html
                                 }

                                 [doc | acc]

                               :error ->
                                 acc
                             end
                           else
                             acc
                           end

                         _ ->
                           acc
                       end
                   end
                   |> Enum.reverse()
                 )

  @doc "Returns all docs for a locale, ordered by category then doc order."
  @spec list_docs(String.t()) :: [map()]
  def list_docs(locale) do
    locale = if locale in @supported_locales, do: locale, else: "en"

    @compiled_docs
    |> Enum.filter(&(&1.locale == locale))
    |> Enum.sort_by(fn doc ->
      cat_idx = Enum.find_index(@category_order, fn c -> c == doc.category end) || 999
      {cat_idx, doc.order}
    end)
    |> Enum.map(&Map.drop(&1, [:locale, :html, :order]))
  end

  @doc "Returns a single doc by slug for the given locale, with rendered HTML."
  @spec get_doc(String.t(), String.t()) :: map() | nil
  def get_doc(locale, slug) do
    locale = if locale in @supported_locales, do: locale, else: "en"

    case Enum.find(@compiled_docs, &(&1.locale == locale && &1.slug == slug)) do
      nil ->
        if locale != "en" do
          Enum.find(@compiled_docs, &(&1.locale == "en" && &1.slug == slug))
        end

      doc ->
        doc
    end
  end

  @doc "Returns ordered categories with labels for the given locale."
  @spec categories(String.t()) :: [map()]
  def categories(locale) do
    locale = if locale in @supported_locales, do: locale, else: "en"

    Enum.map(@category_order, fn key ->
      label = get_in(@category_labels, [key, locale]) || get_in(@category_labels, [key, "en"])
      %{key: key, label: label}
    end)
  end
end
