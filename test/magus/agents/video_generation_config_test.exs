defmodule Magus.Agents.VideoGenerationConfigTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.VideoGenerationConfig

  describe "aspect_ratios/0" do
    test "returns a list of valid aspect ratios" do
      ratios = VideoGenerationConfig.aspect_ratios()
      assert is_list(ratios)
      assert "16:9" in ratios
      assert "9:16" in ratios
    end
  end

  describe "durations/0" do
    test "returns a list of valid durations" do
      durations = VideoGenerationConfig.durations()
      assert durations == ~w(2 3 4 5 6 8 10 12 16 20)
    end
  end

  describe "resolutions/0" do
    test "returns a list of valid resolutions" do
      resolutions = VideoGenerationConfig.resolutions()
      assert resolutions == ~w(auto 480p 720p 1080p 4k)
    end
  end

  describe "sanitize/1" do
    test "returns empty map for nil" do
      assert VideoGenerationConfig.sanitize(nil) == %{}
    end

    test "returns empty map for empty map" do
      assert VideoGenerationConfig.sanitize(%{}) == %{}
    end

    test "keeps valid aspect_ratio" do
      result = VideoGenerationConfig.sanitize(%{"aspect_ratio" => "16:9"})
      assert result == %{"aspect_ratio" => "16:9"}
    end

    test "keeps valid duration" do
      result = VideoGenerationConfig.sanitize(%{"duration" => "5"})
      assert result == %{"duration" => "5"}
    end

    test "keeps valid resolution" do
      result = VideoGenerationConfig.sanitize(%{"resolution" => "1080p"})
      assert result == %{"resolution" => "1080p"}
    end

    test "keeps valid generate_audio boolean" do
      assert VideoGenerationConfig.sanitize(%{"generate_audio" => true}) ==
               %{"generate_audio" => true}

      assert VideoGenerationConfig.sanitize(%{"generate_audio" => false}) ==
               %{"generate_audio" => false}
    end

    test "coerces generate_audio string to boolean" do
      assert VideoGenerationConfig.sanitize(%{"generate_audio" => "true"}) ==
               %{"generate_audio" => true}

      assert VideoGenerationConfig.sanitize(%{"generate_audio" => "false"}) ==
               %{"generate_audio" => false}
    end

    test "keeps all valid values" do
      settings = %{
        "aspect_ratio" => "9:16",
        "duration" => "10",
        "resolution" => "720p",
        "generate_audio" => true
      }

      assert VideoGenerationConfig.sanitize(settings) == settings
    end

    test "drops invalid aspect_ratio" do
      result = VideoGenerationConfig.sanitize(%{"aspect_ratio" => "5:4"})
      assert result == %{}
    end

    test "drops invalid duration" do
      result = VideoGenerationConfig.sanitize(%{"duration" => "15"})
      assert result == %{}
    end

    test "drops invalid resolution" do
      result = VideoGenerationConfig.sanitize(%{"resolution" => "4K"})
      assert result == %{}
    end

    test "drops invalid generate_audio values" do
      result = VideoGenerationConfig.sanitize(%{"generate_audio" => "maybe"})
      assert result == %{}
    end

    test "drops unexpected keys" do
      result =
        VideoGenerationConfig.sanitize(%{
          "aspect_ratio" => "16:9",
          "duration" => "5",
          "malicious_key" => "injected_value"
        })

      assert result == %{"aspect_ratio" => "16:9", "duration" => "5"}
    end

    test "drops non-string values for string fields" do
      result = VideoGenerationConfig.sanitize(%{"aspect_ratio" => 123, "duration" => nil})
      assert result == %{}
    end
  end

  describe "to_keyword_opts/1" do
    test "returns empty list for nil" do
      assert VideoGenerationConfig.to_keyword_opts(nil) == []
    end

    test "returns empty list for empty map" do
      assert VideoGenerationConfig.to_keyword_opts(%{}) == []
    end

    test "converts settings to keyword list" do
      settings = %{
        "aspect_ratio" => "16:9",
        "duration" => "5",
        "resolution" => "1080p",
        "generate_audio" => true
      }

      opts = VideoGenerationConfig.to_keyword_opts(settings)
      assert Keyword.get(opts, :aspect_ratio) == "16:9"
      assert Keyword.get(opts, :duration) == 5
      assert Keyword.get(opts, :resolution) == "1080p"
      assert Keyword.get(opts, :generate_audio) == true
    end

    test "parses duration string to integer" do
      opts = VideoGenerationConfig.to_keyword_opts(%{"duration" => "10"})
      assert Keyword.get(opts, :duration) == 10
    end

    test "skips nil values" do
      opts = VideoGenerationConfig.to_keyword_opts(%{"aspect_ratio" => nil})
      assert opts == []
    end

    test "omits non-numeric duration string" do
      opts = VideoGenerationConfig.to_keyword_opts(%{"duration" => "abc"})
      assert opts == []
    end
  end
end
