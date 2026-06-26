defmodule Magus.Providers.RoutingTest do
  use ExUnit.Case, async: true

  alias Magus.Providers.Routing

  describe "build_provider_routing/2" do
    test "returns nil for non-OpenRouter models" do
      model = %{api_provider: :xai, allowed_providers: []}
      user = %{data_region_preference: ["US", "EU", "CH"]}
      assert Routing.build_provider_routing(model, user) == nil
    end

    test "returns data_collection deny for OpenRouter models with empty allowed_providers" do
      model = %{api_provider: :openrouter, allowed_providers: []}
      user = %{data_region_preference: ["US", "EU", "CH"]}
      assert Routing.build_provider_routing(model, user) == %{"data_collection" => "deny"}
    end

    test "filters providers by user region preference" do
      model = %{
        api_provider: :openrouter,
        allowed_providers: ["together", "deepinfra", "deepseek", "siliconflow"]
      }

      user = %{data_region_preference: ["US", "EU", "CH"]}
      result = Routing.build_provider_routing(model, user)

      assert result["data_collection"] == "deny"
      assert "together" in result["only"]
      assert "deepinfra" in result["only"]
      refute "deepseek" in result["only"]
      refute "siliconflow" in result["only"]
    end

    test "includes CN providers when user has CN enabled" do
      model = %{api_provider: :openrouter, allowed_providers: ["together", "deepseek"]}
      user = %{data_region_preference: ["US", "CN"]}
      result = Routing.build_provider_routing(model, user)

      assert "together" in result["only"]
      assert "deepseek" in result["only"]
    end
  end

  describe "model_available_for_user?/2" do
    test "returns true when model has providers in user's regions" do
      model = %{api_provider: :openrouter, allowed_providers: ["together", "deepseek"]}
      user = %{data_region_preference: ["US", "EU", "CH"]}
      assert Routing.model_available_for_user?(model, user)
    end

    test "returns false when model has no providers in user's regions" do
      model = %{api_provider: :openrouter, allowed_providers: ["deepseek", "siliconflow"]}
      user = %{data_region_preference: ["US", "EU", "CH"]}
      refute Routing.model_available_for_user?(model, user)
    end

    test "returns true for non-OpenRouter models in user's regions" do
      model = %{api_provider: :xai, allowed_providers: []}
      user = %{data_region_preference: ["US", "EU", "CH"]}
      assert Routing.model_available_for_user?(model, user)
    end

    test "returns false for non-OpenRouter models not in user's regions" do
      model = %{api_provider: :publicai, allowed_providers: []}
      user = %{data_region_preference: ["US"]}
      refute Routing.model_available_for_user?(model, user)
    end

    test "returns true when allowed_providers is empty (OpenRouter, no restriction)" do
      model = %{api_provider: :openrouter, allowed_providers: []}
      user = %{data_region_preference: ["US"]}
      assert Routing.model_available_for_user?(model, user)
    end
  end

  describe "missing_consent_regions/2" do
    test "returns consent-required regions the model needs that user hasn't consented to" do
      model = %{api_provider: :openrouter, allowed_providers: ["deepseek", "siliconflow"]}
      user = %{data_region_preference: ["US", "EU", "CH"], data_region_consents: %{}}
      assert Routing.missing_consent_regions(model, user) == ["CN", "SG"]
    end

    test "returns empty list when user already consented" do
      model = %{api_provider: :openrouter, allowed_providers: ["deepseek"]}

      user = %{
        data_region_preference: ["US"],
        data_region_consents: %{"CN" => "2026-03-14T00:00:00Z"}
      }

      assert Routing.missing_consent_regions(model, user) == []
    end

    test "returns empty list when model only needs non-consent regions" do
      model = %{api_provider: :openrouter, allowed_providers: ["anthropic"]}
      user = %{data_region_preference: ["US"], data_region_consents: %{}}
      assert Routing.missing_consent_regions(model, user) == []
    end
  end
end
