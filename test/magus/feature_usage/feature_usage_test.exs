defmodule Magus.FeatureUsageTest do
  @moduledoc """
  Tests for FeatureUsage domain helper functions.
  """
  use Magus.ResourceCase, async: true

  alias Magus.FeatureUsage

  describe "track/3" do
    test "creates an event and returns :ok" do
      user = generate(user())

      assert :ok = FeatureUsage.track(user.id, "chat", "first_message")
    end

    test "broadcasts on PubSub topic" do
      user = generate(user())

      Phoenix.PubSub.subscribe(Magus.PubSub, "feature_usage:#{user.id}")

      :ok = FeatureUsage.track(user.id, "chat", "first_message")

      assert_receive %{
        type: "feature.used",
        feature: "chat",
        action: "first_message",
        user_id: user_id,
        metadata: %{},
        timestamp: _timestamp
      }

      assert user_id == user.id
    end
  end

  describe "track/4" do
    test "creates an event with metadata" do
      user = generate(user())

      assert :ok = FeatureUsage.track(user.id, "prompts", "create", %{"type" => "system"})

      assert FeatureUsage.discovered?(user.id, "prompts")
    end
  end

  describe "discovered?/2" do
    test "returns false when the feature has not been used" do
      user = generate(user())

      refute FeatureUsage.discovered?(user.id, "chat")
    end

    test "returns true when the feature has been used" do
      user = generate(user())

      :ok = FeatureUsage.track(user.id, "chat", "first_message")

      assert FeatureUsage.discovered?(user.id, "chat")
    end
  end

  describe "undiscovered_features/1" do
    test "returns all onboarding features when none discovered" do
      user = generate(user())

      assert Enum.sort(FeatureUsage.undiscovered_features(user.id)) ==
               Enum.sort(FeatureUsage.onboarding_feature_keys())
    end

    test "returns only remaining features when some discovered" do
      user = generate(user())

      :ok = FeatureUsage.track(user.id, "prompts", "create")
      :ok = FeatureUsage.track(user.id, "web_search", "search")

      undiscovered = FeatureUsage.undiscovered_features(user.id)
      all_keys = FeatureUsage.onboarding_feature_keys()

      assert Enum.sort(undiscovered) ==
               Enum.sort(all_keys -- ["prompts", "web_search"])
    end

    test "returns empty list when all onboarding features discovered" do
      user = generate(user())

      for feature <- FeatureUsage.onboarding_feature_keys() do
        :ok = FeatureUsage.track(user.id, feature, "used")
      end

      assert FeatureUsage.undiscovered_features(user.id) == []
    end
  end
end
