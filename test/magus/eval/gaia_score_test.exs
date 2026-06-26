defmodule Magus.Eval.GaiaScoreTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.GaiaScore

  test "number normalization (commas, units, currency)" do
    assert GaiaScore.match?("1,234", "1234")
    assert GaiaScore.match?("$1,234.0", "1234")
    assert GaiaScore.match?("17 ", "17")
    refute GaiaScore.match?("18", "17")
  end

  test "string normalization (case, articles, punctuation, whitespace)" do
    assert GaiaScore.match?("The  Answer.", "answer")
    assert GaiaScore.match?("Paris", "paris")
    refute GaiaScore.match?("London", "Paris")
  end

  test "comma list element-wise" do
    assert GaiaScore.match?("apple, Banana , cherry", "apple,banana,cherry")
    refute GaiaScore.match?("apple, banana", "apple, banana, cherry")
  end
end
