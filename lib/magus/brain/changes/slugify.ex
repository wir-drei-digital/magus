defmodule Magus.Brain.Changes.Slugify do
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    case {opts[:attribute], opts[:target]} do
      {nil, _} -> {:error, "Slugify change requires :attribute option"}
      {_, nil} -> {:error, "Slugify change requires :target option"}
      _ -> {:ok, opts}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    attribute = opts[:attribute]
    target = opts[:target]

    value = Ash.Changeset.get_attribute(changeset, attribute) || ""

    slug =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    # Fallback for nil, empty, or non-ASCII titles
    slug = if slug == "", do: "untitled", else: slug

    suffix =
      :crypto.strong_rand_bytes(3)
      |> Base.url_encode64(padding: false)
      |> String.downcase()

    slug = "#{slug}-#{suffix}"

    Ash.Changeset.force_change_attribute(changeset, target, slug)
  end
end
