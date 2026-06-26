defmodule Magus.Agents.Providers.OpenRouterImageTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Providers.OpenRouterImage

  describe "build_request_body/3" do
    test "requests image modality and inline usage accounting" do
      context = [ReqLLM.Context.user("a red bird")]

      body =
        OpenRouterImage.build_request_body("google/gemini-3.1-flash-image-preview", context, [])

      assert body.model == "google/gemini-3.1-flash-image-preview"
      assert body.modalities == ["image"]
      # usage.include must be set so OpenRouter returns the real cost
      assert body.usage == %{include: true}
    end

    test "merges image_config when present" do
      context = [ReqLLM.Context.user("a red bird")]

      body =
        OpenRouterImage.build_request_body(
          "google/gemini-3.1-flash-image-preview",
          context,
          image_config: %{"aspect_ratio" => "16:9"}
        )

      assert body.usage == %{include: true}
      assert get_in(body, [:image_config, :aspect_ratio]) == "16:9"
    end
  end
end
