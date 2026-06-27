defmodule Magus.Skills.Import do
  @moduledoc """
  Orchestrates importing a skill bundle zip into a `Magus.Skills.Skill`:
  unpack -> parse SKILL.md -> store the archive (non-indexing) -> compute the
  file manifest -> create the Skill via the :import action.
  """

  alias Magus.Skills.Import.{Unpack, Parser}

  @spec import_bundle(binary, keyword) :: {:ok, struct} | {:error, term}
  def import_bundle(zip_bytes, opts) when is_binary(zip_bytes) do
    actor = Keyword.fetch!(opts, :actor)
    workspace_id = Keyword.get(opts, :workspace_id)

    with {:ok, %{skill_md: md, files: files}} <- Unpack.unpack(zip_bytes),
         {:ok, manifest_attrs} <- Parser.parse(md),
         sha <- sha256_hex(zip_bytes),
         bundle_path <- "skills/#{actor.id}/#{sha}.zip",
         {:ok, _} <- Magus.Files.Storage.store(bundle_path, zip_bytes) do
      attrs =
        Map.merge(manifest_attrs, %{
          bundle_path: bundle_path,
          bundle_backend: Magus.Files.Storage.backend_name(),
          bundle_byte_size: byte_size(zip_bytes),
          file_manifest: build_manifest(files),
          has_executable_bundle:
            Enum.any?(files, fn {p, _} -> String.starts_with?(p, "scripts/") end),
          workspace_id: workspace_id
        })

      Magus.Skills.import_skill(attrs, actor: actor)
    end
  end

  defp build_manifest(files) do
    Enum.map(files, fn {path, content} ->
      %{
        "path" => path,
        "size" => byte_size(content),
        "sha256" => sha256_hex(content),
        "executable" => String.starts_with?(path, "scripts/")
      }
    end)
  end

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
