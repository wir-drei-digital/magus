defmodule Magus.SuperBrain.CanonicalId do
  @moduledoc """
  Single source of truth for the `:CanonicalEntity.id` formula shared by
  `Magus.SuperBrain.Workers.BuildSuperFull` and
  `Magus.SuperBrain.Workers.BuildSuperIncremental`.

  Pre-Wave-2 each worker had its own private `canonical_id_for/?` with
  documented "mirror exactly" semantics but different signatures and
  different name-source choices. Incremental hashed the FIRST entity's
  name; Full hashed the longest-name-winner cluster pick. So an identical
  Layer 1 read-set produced DIFFERENT canonical ids on the incremental
  path vs the next nightly rebuild, breaking caches and any
  cross-snapshot reference to a canonical.

  ## Hash key

  The hash key is `"\#{super_graph}|\#{type}|\#{subtype_key}|\#{name_key}"`,
  where `name_key` is the trimmed + downcased entity name (`nil`/blank ->
  `__noname__`). The name IS part of the key so distinct entities of the
  same `(type, normalized_subtype)` get distinct canonicals. Without it
  (the prior formula) every person / concept / organization in a graph
  collapsed into a single canonical node.

  Both build paths key on the entity's OWN name: the incremental path
  sees one entity at a time, and `BuildSuperFull` groups entities by
  `(type, normalized_subtype, name_key/1)`, so the two converge on the
  same id. Different-named ALIASES ("Daniel" vs "Daniel Smith") therefore
  land in separate canonicals; merging aliases is deferred to a future
  LLM-judge fusion pass, per the Super Brain design.

  ## Sentinels

  `nil` normalized_subtype is hashed as the explicit `__none__` sentinel
  rather than the empty string. This is a known-unknown: subtype-less
  entities of the same `(name, type)` still fuse with each other (same
  `__none__` bucket), but they no longer collide with any real-subtype
  bucket if a future change makes the empty string a valid
  normalized_subtype.

  ## Migration note

  Folding `name_key` into the hash changes every canonical id. Existing
  super graphs carry ids under the prior (name-less) formula and WILL
  NOT match what this module now produces. A one-time `BuildSuperFull`
  rebuild per accessor is required after deploying this change.
  """

  @doc """
  Compute the 32-char lowercase hex `CanonicalEntity.id` for a given
  `(super_graph, type, normalized_subtype, name_hint)` tuple.

  `name_hint` is folded into the hash via `name_key/1` (trimmed and
  downcased, with blank collapsing to `__noname__`), so distinct names
  yield distinct canonicals. See the moduledoc for the rationale.
  """
  @spec for(String.t(), String.t() | atom() | nil, String.t() | nil, String.t() | nil) ::
          String.t()
  def for(super_graph, type, normalized_subtype, name_hint \\ nil)

  def for(super_graph, type, normalized_subtype, name_hint) do
    type_key = type_to_key(type)
    subtype_key = normalized_subtype || "__none__"
    name_key = name_key(name_hint)

    :crypto.hash(:sha256, "#{super_graph}|#{type_key}|#{subtype_key}|#{name_key}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc """
  Normalize an entity name into the stable key folded into the
  canonical-id hash: trimmed + downcased, with `nil`/blank collapsing to
  the `__noname__` sentinel. Exposed so `BuildSuperFull` groups entities
  into canonicals on the SAME key the id is derived from (keeping the
  full and incremental build paths convergent).
  """
  def name_key(nil), do: "__noname__"

  def name_key(name) do
    case name |> to_string() |> String.trim() |> String.downcase() do
      "" -> "__noname__"
      normalized -> normalized
    end
  end

  defp type_to_key(nil), do: ""
  defp type_to_key(t) when is_atom(t), do: Atom.to_string(t)
  defp type_to_key(t) when is_binary(t), do: t
  defp type_to_key(other), do: to_string(other)
end
