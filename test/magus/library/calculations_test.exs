defmodule Magus.Library.CalculationsTest do
  @moduledoc """
  Tests for Ash calculations in the Library domain.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Library

  describe "Prompt.favorite_count" do
    test "returns 0 when no favorites" do
      user = generate(user())

      {:ok, prompt} =
        Library.create_prompt(
          %{name: "Test Prompt", content: "Content", type: :user},
          actor: user
        )

      {:ok, loaded} = Ash.load(prompt, :favorite_count, actor: user)

      assert loaded.favorite_count == 0
    end
  end
end
