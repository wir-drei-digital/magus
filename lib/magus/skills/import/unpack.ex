defmodule Magus.Skills.Import.Unpack do
  @moduledoc """
  Safe in-process unpack of a skill bundle zip. Rejects path traversal and
  enforces size/count limits. Returns the SKILL.md body and the remaining
  bundle files keyed by forward-slash relative path.
  """

  @max_files 500
  @max_total_bytes 25 * 1024 * 1024
  @max_file_bytes 10 * 1024 * 1024

  @spec unpack(binary) ::
          {:ok, %{skill_md: binary, files: [{String.t(), binary}]}}
          | {:error, atom}
  def unpack(zip_bytes) when is_binary(zip_bytes) do
    case :zip.unzip(zip_bytes, [:memory]) do
      {:ok, entries} -> from_entries(entries)
      {:error, _} -> {:error, :invalid_zip}
    end
  end

  defp from_entries(entries) do
    normalized =
      entries
      |> Enum.map(fn {name, content} -> {to_string(name), content} end)
      |> maybe_strip_top_dir()

    cond do
      length(normalized) > @max_files ->
        {:error, :too_many_files}

      total_bytes(normalized) > @max_total_bytes ->
        {:error, :bundle_too_large}

      Enum.any?(normalized, fn {_p, c} -> byte_size(c) > @max_file_bytes end) ->
        {:error, :file_too_large}

      Enum.any?(normalized, fn {p, _c} -> unsafe?(p) end) ->
        {:error, :unsafe_path}

      true ->
        case Enum.split_with(normalized, fn {p, _} -> p == "SKILL.md" end) do
          {[{"SKILL.md", md} | _], rest} -> {:ok, %{skill_md: md, files: rest}}
          {[], _} -> {:error, :missing_skill_md}
        end
    end
  end

  # Strip a single shared top-level directory from all entries, only when every
  # entry lives under one common prefix AND at least one entry is actually nested
  # (so a flat bundle is untouched).
  defp maybe_strip_top_dir(entries) do
    top_dirs =
      entries
      |> Enum.map(fn {p, _} -> p |> Path.split() |> List.first() end)
      |> Enum.uniq()

    case top_dirs do
      [prefix] when is_binary(prefix) ->
        if Enum.any?(entries, fn {p, _} -> String.contains?(p, "/") end) do
          Enum.map(entries, fn {p, c} -> {String.replace_prefix(p, prefix <> "/", ""), c} end)
        else
          entries
        end

      _ ->
        entries
    end
  end

  defp total_bytes(entries),
    do: Enum.reduce(entries, 0, fn {_p, c}, acc -> acc + byte_size(c) end)

  # Reject absolute paths, "." / ".." segments, and anything that would resolve
  # outside a notional base, mirroring Magus.Files.Storage.Local.full_path/1.
  defp unsafe?(path) do
    base = Path.expand("/__skill_base__")
    full = Path.expand(Path.join(base, path))

    String.starts_with?(path, "/") or
      Enum.any?(Path.split(path), &(&1 in [".", ".."])) or
      not (full == base or String.starts_with?(full, base <> "/"))
  end
end
