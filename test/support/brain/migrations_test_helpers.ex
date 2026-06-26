defmodule Magus.Brain.MigrationsTestHelpers do
  @moduledoc """
  Test-only helpers for migration tests. Seeds rows into the legacy
  `brain_blocks` / `brain_block_versions` tables via raw `Repo` calls,
  since `Magus.Brain.Block` is read-only post-cleanup and the migration
  workers must operate on real legacy data.
  """

  import Ecto.Query

  alias Magus.Repo

  @doc """
  Inserts a row directly into `brain_blocks` and returns a map shaped
  like the Ash record fields the migration workers read (`:id`,
  `:type`, `:content`, `:position`, `:parent_block_id`, etc.).

  `attrs` accepts the same shape the old `Brain.create_block`
  interface did: `%{type:, content:, parent_block_id:, metadata:,
  is_pinned:, depth:}`. Position auto-assigns to `count + 1.0` for the
  given `page_id` (mirroring the old `AutoPosition` change).
  """
  @spec insert_block!(binary() | Ecto.UUID.t(), map()) :: map()
  def insert_block!(page_id, attrs) when is_binary(page_id) do
    id_bin = Ash.UUIDv7.generate() |> Ecto.UUID.dump!()
    page_id_bin = ensure_uuid_bin(page_id)

    parent_block_id_bin =
      case Map.get(attrs, :parent_block_id) do
        nil -> nil
        id -> ensure_uuid_bin(id)
      end

    position =
      Repo.one(
        from b in "brain_blocks",
          where: b.page_id == ^page_id_bin,
          select: count(b.id)
      ) + 1.0

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      id: id_bin,
      type: Atom.to_string(Map.fetch!(attrs, :type)),
      content: Map.get(attrs, :content, %{}),
      position: position,
      depth: Map.get(attrs, :depth, 0),
      metadata: Map.get(attrs, :metadata, %{}),
      is_pinned: Map.get(attrs, :is_pinned, false),
      contributor_type: "user",
      contributor_id: nil,
      embedding: nil,
      lock_version: 0,
      page_id: page_id_bin,
      parent_block_id: parent_block_id_bin,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all("brain_blocks", [row])

    %{
      id: Ecto.UUID.load!(id_bin),
      type: Map.fetch!(attrs, :type),
      content: Map.get(attrs, :content, %{}),
      position: position,
      page_id: page_id,
      parent_block_id: Map.get(attrs, :parent_block_id),
      metadata: Map.get(attrs, :metadata, %{}),
      updated_at: now
    }
  end

  defp ensure_uuid_bin(<<_::128>> = bin), do: bin

  defp ensure_uuid_bin(str) when is_binary(str) do
    case Ecto.UUID.dump(str) do
      {:ok, bin} -> bin
      :error -> raise ArgumentError, "invalid uuid: #{inspect(str)}"
    end
  end
end
