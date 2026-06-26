defmodule Magus.Agents.Context.AttachedDocumentsContext do
  @moduledoc """
  Renders the <attached_documents> system-prompt segment for a custom
  agent's :always-mode attachments. Files without ready chunks are
  silently skipped (and the strategy logs a soft warning).

  Caller is responsible for loading [attachments: [file: [:chunks]]]
  on the agent before calling build/1.
  """

  alias Magus.Agents.CustomAgentAttachment

  @doc "Returns the rendered block, or empty string when there is nothing to include."
  def build(nil), do: ""

  def build(%{attachments: attachments}) when is_list(attachments) do
    docs =
      attachments
      |> Enum.filter(&(&1.mode == :always))
      |> Enum.sort_by(&{&1.position, &1.inserted_at})
      |> Enum.map(&render_doc/1)
      |> Enum.reject(&is_nil/1)

    case docs do
      [] -> ""
      list -> "<attached_documents>\n" <> Enum.join(list, "\n") <> "\n</attached_documents>"
    end
  end

  def build(_), do: ""

  defp render_doc(%CustomAgentAttachment{file: file} = att) do
    case extract_text(file) do
      "" ->
        nil

      text ->
        """
          <document name="#{escape(file.name)}" attachment_id="#{att.id}">
        #{text}
          </document>\
        """
    end
  end

  defp extract_text(%{chunks: chunks}) when is_list(chunks) do
    chunks
    |> Enum.sort_by(& &1.position)
    |> Enum.map_join("\n", & &1.content)
  end

  defp extract_text(_), do: ""

  defp escape(name) when is_binary(name),
    do: name |> String.replace("\"", "&quot;")

  defp escape(_), do: ""
end
