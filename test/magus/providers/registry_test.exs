defmodule Magus.Providers.RegistryTest do
  use ExUnit.Case, async: true

  alias Magus.Providers.Registry

  describe "all_regions/0" do
    test "returns all configured regions" do
      regions = Registry.all_regions()
      assert Map.has_key?(regions, "US")
      assert Map.has_key?(regions, "EU")
      assert Map.has_key?(regions, "CH")
      assert Map.has_key?(regions, "CN")
      assert Map.has_key?(regions, "SG")
    end
  end

  describe "default_allowed/0" do
    test "returns default allowed regions" do
      assert Registry.default_allowed() == ["US", "EU", "CH"]
    end
  end

  describe "regions_requiring_consent/0" do
    test "returns only consent-required regions" do
      result = Registry.regions_requiring_consent()
      assert "CN" in result
      assert "SG" in result
      refute "US" in result
      refute "EU" in result
      refute "CH" in result
    end
  end

  describe "requires_consent?/1" do
    test "returns true for CN" do
      assert Registry.requires_consent?("CN")
    end

    test "returns false for US" do
      refute Registry.requires_consent?("US")
    end
  end

  describe "region_for_provider/1" do
    test "returns region for known provider" do
      assert Registry.region_for_provider("together") == "US"
      assert Registry.region_for_provider("mistral") == "EU"
      assert Registry.region_for_provider("deepseek") == "CN"
      assert Registry.region_for_provider("publicai") == "CH"
    end

    test "returns nil for unknown provider" do
      assert Registry.region_for_provider("unknown_provider") == nil
    end
  end

  describe "providers_for_regions/1" do
    test "returns all providers for given regions" do
      providers = Registry.providers_for_regions(["US"])
      assert "together" in providers
      assert "anthropic" in providers
      refute "mistral" in providers
      refute "deepseek" in providers
    end

    test "returns providers for multiple regions" do
      providers = Registry.providers_for_regions(["US", "EU"])
      assert "together" in providers
      assert "mistral" in providers
      refute "deepseek" in providers
    end

    test "returns empty list for empty regions" do
      assert Registry.providers_for_regions([]) == []
    end
  end

  describe "regions_for_model/1" do
    test "derives regions from allowed_providers" do
      model = %{
        allowed_providers: ["together", "deepinfra", "deepseek"],
        api_provider: :openrouter
      }

      regions = Registry.regions_for_model(model)
      assert "US" in regions
      assert "CN" in regions
      refute "EU" in regions
    end

    test "returns region from api_provider when allowed_providers is empty" do
      model = %{allowed_providers: [], api_provider: :xai}
      regions = Registry.regions_for_model(model)
      assert regions == ["US"]
    end

    test "returns region from api_provider when allowed_providers is nil" do
      model = %{allowed_providers: nil, api_provider: :publicai}
      regions = Registry.regions_for_model(model)
      assert regions == ["CH"]
    end
  end

  describe "region_config/1" do
    test "returns config for valid region" do
      config = Registry.region_config("CN")
      assert config.label == "China"
      assert config.requires_consent == true
    end

    test "returns nil for unknown region" do
      assert Registry.region_config("XX") == nil
    end
  end
end
