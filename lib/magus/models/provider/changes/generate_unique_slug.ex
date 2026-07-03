defmodule Magus.Models.Provider.Changes.GenerateUniqueSlug do
  @moduledoc """
  Mints a server-side unique slug for an owned provider. Retries a bounded
  number of times against the DB before surfacing an error, so the astronomically
  unlikely collision fails loudly rather than looping.
  """
  use Ash.Resource.Change
  require Ash.Query

  @max_attempts 5

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      case mint(@max_attempts) do
        {:ok, slug} ->
          Ash.Changeset.force_change_attribute(cs, :slug, slug)

        :error ->
          Ash.Changeset.add_error(cs, field: :slug, message: "could not mint a unique slug")
      end
    end)
  end

  defp mint(0), do: :error

  defp mint(attempts) do
    slug = Magus.Models.SlugGenerator.generate()

    exists? =
      Magus.Models.Provider
      |> Ash.Query.filter(slug == ^slug)
      |> Ash.exists?(authorize?: false)

    if exists?, do: mint(attempts - 1), else: {:ok, slug}
  end
end
