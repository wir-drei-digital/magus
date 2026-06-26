defmodule Magus.Models.OpenAICompatibleTest do
  use ExUnit.Case, async: true

  test "provider is registered under :openai_compatible" do
    assert {:ok, Magus.Models.Providers.OpenAICompatible} =
             ReqLLM.Providers.get(:openai_compatible)
  end
end
