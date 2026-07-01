defmodule Magus.Models.SlugGenerator do
  @moduledoc """
  Mints server-side provider slugs for user-owned providers. The slug is the
  local, globally unique handle that namespaces a user model's `key`; it never
  reaches ReqLLM or the atom catalog. High entropy keeps DB collisions
  negligible; the create action still verifies uniqueness before use.
  """

  # 80 bits of entropy, lowercase base32 (Crockford-ish, [a-z0-9]).
  @spec generate() :: String.t()
  def generate do
    "u_" <>
      (:crypto.strong_rand_bytes(10)
       |> Base.encode32(case: :lower, padding: false))
  end
end
