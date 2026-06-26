defmodule Magus.Brain.Page.Validations.FileReferencesInWorkspace do
  @moduledoc """
  Validates that every `magus://file/<uuid>` or `magus://image/<uuid>`
  reference in the page body points at a `Magus.Files.File` row whose
  `workspace_id` matches the brain's `workspace_id`.

  Mirrors `Magus.Brain.Block.Validations.FileInSameWorkspace`, but
  parses the markdown body instead of a block content map. Personal
  brain (workspace_id = nil) requires personal files.

  Skips validation when:

    * `body` is not changing on this update (no parse needed)
    * the body contains no `magus://` references

  Rejects when:

    * a referenced file id doesn't exist in `Magus.Files.File`
    * a referenced file's workspace differs from the brain's workspace

  The brain's `workspace_id` is loaded once per validation call (single
  query against `brain_pages`).
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  require Ash.Query

  # Pattern matches both `magus://file/<uuid>` and `magus://image/<uuid>`.
  # We don't try to be strict about uuid format here; downstream file
  # lookup will simply miss invalid ids and surface a clear error.
  @ref_regex ~r{magus://(?:file|image)/([A-Za-z0-9-]+)}

  @impl true
  def validate(changeset, _opts, _context) do
    cond do
      not Ash.Changeset.changing_attribute?(changeset, :body) ->
        :ok

      true ->
        body = Ash.Changeset.get_attribute(changeset, :body) || ""
        file_ids = extract_file_ids(body)

        if file_ids == [] do
          :ok
        else
          check_workspace_scope(changeset, file_ids)
        end
    end
  end

  defp extract_file_ids(body) do
    @ref_regex
    |> Regex.scan(body)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
  end

  defp check_workspace_scope(changeset, file_ids) do
    with {:ok, brain_workspace_id} <- fetch_brain_workspace_id(changeset) do
      case fetch_files(file_ids) do
        {:ok, files} ->
          missing = file_ids -- Enum.map(files, & &1.id)

          cond do
            missing != [] ->
              {:error,
               InvalidAttribute.exception(
                 field: :body,
                 message: "body references missing files: #{Enum.join(missing, ", ")}",
                 vars: [reason: :file_not_found, missing_ids: missing]
               )}

            true ->
              mismatched =
                Enum.filter(files, fn f -> f.workspace_id != brain_workspace_id end)

              if mismatched == [] do
                :ok
              else
                ids = Enum.map(mismatched, & &1.id)

                {:error,
                 InvalidAttribute.exception(
                   field: :body,
                   message:
                     "body references files from a different workspace: #{Enum.join(ids, ", ")}",
                   vars: [reason: :workspace_mismatch, mismatched_ids: ids]
                 )}
              end
          end
      end
    else
      {:error, :brain_not_resolvable} ->
        {:error,
         InvalidAttribute.exception(
           field: :body,
           message: "could not resolve brain workspace",
           vars: [reason: :brain_not_resolvable]
         )}
    end
  end

  defp fetch_files(file_ids) do
    case Magus.Files.File
         |> Ash.Query.filter(id in ^file_ids)
         |> Ash.read(authorize?: false) do
      {:ok, files} -> {:ok, files}
      {:error, _} -> {:ok, []}
    end
  end

  defp fetch_brain_workspace_id(changeset) do
    brain_id =
      Ash.Changeset.get_attribute(changeset, :brain_id) ||
        Map.get(changeset.data, :brain_id)

    if is_nil(brain_id) do
      {:error, :brain_not_resolvable}
    else
      case Magus.Brain.BrainResource
           |> Ash.Query.filter(id == ^brain_id)
           |> Ash.read_one(authorize?: false) do
        {:ok, %{workspace_id: ws_id}} -> {:ok, ws_id}
        _ -> {:error, :brain_not_resolvable}
      end
    end
  end
end
