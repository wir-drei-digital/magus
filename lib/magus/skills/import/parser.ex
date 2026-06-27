defmodule Magus.Skills.Import.Parser do
  @moduledoc """
  Parse a SKILL.md into normalized Skill attributes. Keeps all standard
  Agent Skills frontmatter (name, description, license, compatibility,
  allowed-tools, metadata) and lifts Magus extensions out of the
  metadata["x-magus"] JSON string.
  """

  @spec parse(binary) :: {:ok, map} | {:error, atom}
  def parse(skill_md) when is_binary(skill_md) do
    case YamlFrontMatter.parse(skill_md) do
      {:ok, fm, body} when is_map(fm) -> normalize(fm, body)
      _ -> {:error, :invalid_frontmatter}
    end
  end

  defp normalize(fm, body) do
    case fm["name"] do
      name when is_binary(name) and name != "" ->
        ext = magus_extensions(fm)

        {:ok,
         %{
           name: name,
           description: fm["description"] || "",
           body: String.trim(body),
           license: fm["license"],
           compatibility: fm["compatibility"],
           requested_tools: split_allowed_tools(fm["allowed-tools"]),
           required_secrets: Map.get(ext, "required_secrets", []),
           runtime_hints: Map.get(ext, "runtime_hints", %{}),
           version: Map.get(ext, "version"),
           metadata: Map.drop(fm["metadata"] || %{}, ["x-magus"]),
           source_format: :skill_md
         }}

      _ ->
        {:error, :missing_name}
    end
  end

  defp split_allowed_tools(nil), do: []
  defp split_allowed_tools(s) when is_binary(s), do: String.split(s, ~r/\s+/, trim: true)
  defp split_allowed_tools(list) when is_list(list), do: Enum.map(list, &to_string/1)

  defp magus_extensions(fm) do
    with %{} = meta <- fm["metadata"],
         raw when is_binary(raw) <- meta["x-magus"],
         {:ok, decoded} when is_map(decoded) <- Jason.decode(raw) do
      decoded
    else
      _ -> %{}
    end
  end
end
