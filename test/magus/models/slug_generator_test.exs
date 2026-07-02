defmodule Magus.Models.SlugGeneratorTest do
  use ExUnit.Case, async: true
  alias Magus.Models.SlugGenerator

  test "generates a slug matching the provider slug constraint" do
    slug = SlugGenerator.generate()
    assert slug =~ ~r/\A[a-z0-9_]+\z/
    assert String.starts_with?(slug, "u_")
    assert String.length(slug) <= 64
  end

  test "generates distinct slugs across calls" do
    slugs = for _ <- 1..50, do: SlugGenerator.generate()
    assert length(Enum.uniq(slugs)) == 50
  end
end
