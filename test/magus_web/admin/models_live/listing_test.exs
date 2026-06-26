defmodule MagusWeb.Admin.ModelsLive.ListingTest do
  use ExUnit.Case, async: true

  alias MagusWeb.Admin.ModelsLive.Listing

  # Plain maps keep this a pure unit test (no DB, no Ash struct). The helper
  # only reads fields, so any map with the accessed keys works.
  defp model(attrs) do
    Map.merge(
      %{
        name: "model",
        active?: true,
        provider: nil,
        model_provider: nil,
        supports_tools?: false,
        supports_search?: false,
        supports_reasoning?: false,
        output_modalities: ["text"],
        input_cost: nil,
        output_cost: nil,
        usage_count: 0,
        usage_input_cost: Decimal.new(0),
        usage_output_cost: Decimal.new(0)
      },
      Map.new(attrs)
    )
  end

  defp names(result), do: Enum.map(result.models, & &1.name)

  describe "provider_label/1" do
    test "prefers linked provider name over brand" do
      assert Listing.provider_label(
               model(model_provider: %{name: "OpenRouter"}, provider: "Anthropic")
             ) ==
               "OpenRouter"
    end

    test "falls back to brand, then dash" do
      assert Listing.provider_label(model(provider: "Anthropic")) == "Anthropic"
      assert Listing.provider_label(model(provider: nil)) == "-"
      assert Listing.provider_label(model(provider: "")) == "-"
    end

    test "ignores an unloaded (Ash.NotLoaded) relationship" do
      assert Listing.provider_label(model(model_provider: %Ash.NotLoaded{}, provider: "X")) == "X"
    end
  end

  describe "status filter" do
    setup do
      %{models: [model(name: "on", active?: true), model(name: "off", active?: false)]}
    end

    test "active", %{models: models} do
      assert names(Listing.apply(models, %{"status" => "active"})) == ["on"]
    end

    test "disabled", %{models: models} do
      assert names(Listing.apply(models, %{"status" => "disabled"})) == ["off"]
    end

    test "all / unknown defaults to no status filter", %{models: models} do
      assert length(Listing.apply(models, %{"status" => "all"}).models) == 2
      assert length(Listing.apply(models, %{"status" => "bogus"}).models) == 2
      assert Listing.apply(models, %{"status" => "bogus"}).status == "all"
    end
  end

  describe "provider filter" do
    test "keeps only matching displayed provider" do
      models = [
        model(name: "a", model_provider: %{name: "OpenRouter"}),
        model(name: "b", provider: "Anthropic"),
        model(name: "c", model_provider: %{name: "OpenRouter"})
      ]

      assert Listing.apply(models, %{"provider" => "OpenRouter"}) |> names() == ["a", "c"]
      assert Listing.apply(models, %{"provider" => "Anthropic"}) |> names() == ["b"]
    end

    test "provider_options lists distinct displayed values from the full list, sorted" do
      models = [
        model(model_provider: %{name: "OpenRouter"}),
        model(provider: "Anthropic"),
        model(provider: nil)
      ]

      assert Listing.apply(models, %{}).provider_options == ["-", "Anthropic", "OpenRouter"]
    end
  end

  describe "capability filter (AND)" do
    test "single capability" do
      models = [
        model(name: "tools", supports_tools?: true),
        model(name: "none")
      ]

      assert Listing.apply(models, %{"caps" => "tools"}) |> names() == ["tools"]
    end

    test "multiple capabilities require all" do
      models = [
        model(name: "both", supports_tools?: true, supports_reasoning?: true),
        model(name: "tools-only", supports_tools?: true),
        model(name: "reasoning-only", supports_reasoning?: true)
      ]

      assert Listing.apply(models, %{"caps" => "tools,reasoning"}) |> names() == ["both"]
    end

    test "image / video come from output_modalities" do
      models = [
        model(name: "img", output_modalities: ["text", "image"]),
        model(name: "vid", output_modalities: ["video"]),
        model(name: "txt", output_modalities: ["text"])
      ]

      assert Listing.apply(models, %{"caps" => "image"}) |> names() == ["img"]
      assert Listing.apply(models, %{"caps" => "video"}) |> names() == ["vid"]
    end

    test "junk capability keys are ignored" do
      models = [model(name: "a", supports_tools?: true)]
      assert Listing.apply(models, %{"caps" => "tools,bogus,;"}) |> names() == ["a"]
    end
  end

  describe "sorting" do
    test "by name asc/desc, case-insensitive" do
      models = [model(name: "Beta"), model(name: "alpha"), model(name: "Gamma")]

      assert Listing.apply(models, %{"sort" => "name", "dir" => "asc"}) |> names() == [
               "alpha",
               "Beta",
               "Gamma"
             ]

      assert Listing.apply(models, %{"sort" => "name", "dir" => "desc"}) |> names() == [
               "Gamma",
               "Beta",
               "alpha"
             ]
    end

    test "by status puts active first when ascending" do
      models = [model(name: "off", active?: false), model(name: "on", active?: true)]

      assert Listing.apply(models, %{"sort" => "status", "dir" => "asc"}) |> names() == [
               "on",
               "off"
             ]
    end

    test "by input_cost numerically (not lexicographically), nils last" do
      models = [
        model(name: "ten", input_cost: "10.00"),
        model(name: "nine", input_cost: "9.00"),
        model(name: "cheap", input_cost: "2.50"),
        model(name: "free", input_cost: nil)
      ]

      assert Listing.apply(models, %{"sort" => "input_cost", "dir" => "asc"}) |> names() ==
               ["cheap", "nine", "ten", "free"]
    end

    test "nils stay last even when descending" do
      models = [
        model(name: "ten", input_cost: "10.00"),
        model(name: "two", input_cost: "2.00"),
        model(name: "free", input_cost: nil)
      ]

      assert Listing.apply(models, %{"sort" => "input_cost", "dir" => "desc"}) |> names() ==
               ["ten", "two", "free"]
    end

    test "by usage count" do
      models = [
        model(name: "lo", usage_count: 3),
        model(name: "hi", usage_count: 42)
      ]

      assert Listing.apply(models, %{"sort" => "usage", "dir" => "desc"}) |> names() == [
               "hi",
               "lo"
             ]
    end

    test "by spend (input + output sums)" do
      models = [
        model(
          name: "lo",
          usage_input_cost: Decimal.new("1"),
          usage_output_cost: Decimal.new("1")
        ),
        model(name: "hi", usage_input_cost: Decimal.new("5"), usage_output_cost: Decimal.new("5"))
      ]

      assert Listing.apply(models, %{"sort" => "spend", "dir" => "desc"}) |> names() == [
               "hi",
               "lo"
             ]
    end

    test "unknown sort/dir fall back to name asc" do
      models = [model(name: "b"), model(name: "a")]
      result = Listing.apply(models, %{"sort" => "bogus", "dir" => "sideways"})
      assert result.sort == "name"
      assert result.dir == "asc"
      assert names(result) == ["a", "b"]
    end
  end

  describe "pagination" do
    setup do
      models = for i <- 1..125, do: model(name: String.pad_leading(to_string(i), 3, "0"))
      %{models: models}
    end

    test "caps at 50 per page", %{models: models} do
      result = Listing.apply(models, %{})
      assert length(result.models) == 50
      assert result.page_size == 50
      assert result.total == 125
      assert result.total_pages == 3
      assert result.page == 1
    end

    test "second page returns the next slice", %{models: models} do
      result = Listing.apply(models, %{"page" => "2"})
      assert result.page == 2
      assert hd(result.models).name == "051"
    end

    test "last page holds the remainder", %{models: models} do
      result = Listing.apply(models, %{"page" => "3"})
      assert length(result.models) == 25
    end

    test "out-of-range / junk page clamps into bounds", %{models: models} do
      assert Listing.apply(models, %{"page" => "999"}).page == 3
      assert Listing.apply(models, %{"page" => "0"}).page == 1
      assert Listing.apply(models, %{"page" => "abc"}).page == 1
    end

    test "empty list still reports one page" do
      result = Listing.apply([], %{})
      assert result.total == 0
      assert result.total_pages == 1
      assert result.page == 1
      assert result.models == []
    end
  end

  describe "toggle_dir/3" do
    test "same column flips asc->desc, new column starts asc" do
      assert Listing.toggle_dir("name", "asc", "name") == "desc"
      assert Listing.toggle_dir("name", "desc", "name") == "asc"
      assert Listing.toggle_dir("name", "desc", "provider") == "asc"
    end
  end
end
