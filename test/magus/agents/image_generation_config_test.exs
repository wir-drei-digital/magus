defmodule Magus.Agents.ImageGenerationConfigTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.ImageGenerationConfig

  describe "aspect_ratios/0" do
    test "returns a list of valid aspect ratios" do
      ratios = ImageGenerationConfig.aspect_ratios()
      assert is_list(ratios)
      assert "1:1" in ratios
      assert "16:9" in ratios
      assert "9:16" in ratios
    end
  end

  describe "image_sizes/0" do
    test "returns a list of valid image sizes" do
      sizes = ImageGenerationConfig.image_sizes()
      assert sizes == ~w(1K 2K 4K)
    end
  end

  describe "sanitize/1" do
    test "returns empty map for nil" do
      assert ImageGenerationConfig.sanitize(nil) == %{}
    end

    test "returns empty map for empty map" do
      assert ImageGenerationConfig.sanitize(%{}) == %{}
    end

    test "keeps valid aspect_ratio" do
      result = ImageGenerationConfig.sanitize(%{"aspect_ratio" => "16:9"})
      assert result == %{"aspect_ratio" => "16:9"}
    end

    test "keeps valid image_size" do
      result = ImageGenerationConfig.sanitize(%{"image_size" => "4K"})
      assert result == %{"image_size" => "4K"}
    end

    test "keeps both valid values" do
      settings = %{"aspect_ratio" => "1:1", "image_size" => "2K"}
      assert ImageGenerationConfig.sanitize(settings) == settings
    end

    test "drops invalid aspect_ratio" do
      result = ImageGenerationConfig.sanitize(%{"aspect_ratio" => "99:1"})
      assert result == %{}
    end

    test "drops invalid image_size" do
      result = ImageGenerationConfig.sanitize(%{"image_size" => "8K"})
      assert result == %{}
    end

    test "drops unexpected keys" do
      result =
        ImageGenerationConfig.sanitize(%{
          "aspect_ratio" => "1:1",
          "image_size" => "1K",
          "malicious_key" => "injected_value"
        })

      assert result == %{"aspect_ratio" => "1:1", "image_size" => "1K"}
    end

    test "drops non-string values" do
      result = ImageGenerationConfig.sanitize(%{"aspect_ratio" => 123, "image_size" => nil})
      assert result == %{}
    end
  end
end
