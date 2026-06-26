defmodule Magus.Agents.Tools.Media.GenerateVideoTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Media.GenerateVideo

  test "default model key is the OpenRouter Veo 3.1 Fast model" do
    assert GenerateVideo.default_model_key() == "openrouter:google/veo-3.1-fast"
  end

  test "schema exposes an optional model override" do
    model_opt = Keyword.get(GenerateVideo.schema(), :model)
    assert model_opt[:type] == {:or, [:string, nil]}
    assert model_opt[:default] == nil
  end
end
