defmodule Magus.FeatureUsage.FeatureUsageEventTest do
  @moduledoc """
  Tests for the FeatureUsageEvent resource.
  """
  use Magus.ResourceCase, async: true

  alias Magus.FeatureUsage

  describe "track" do
    test "creates an event with required attributes" do
      user = generate(user())

      {:ok, event} =
        FeatureUsage.track_feature(user.id, "chat", "first_message")

      assert event.feature == "chat"
      assert event.action == "first_message"
      assert event.metadata == %{}
      assert event.user_id == user.id
      assert event.inserted_at != nil
    end

    test "creates an event with metadata" do
      user = generate(user())

      {:ok, event} =
        FeatureUsage.track_feature(user.id, "prompt_library", "create_prompt", %{
          metadata: %{"prompt_type" => "system"}
        })

      assert event.feature == "prompt_library"
      assert event.action == "create_prompt"
      assert event.metadata == %{"prompt_type" => "system"}
    end
  end

  describe "for_user" do
    test "returns only events for the actor" do
      user1 = generate(user())
      user2 = generate(user())

      {:ok, _} = FeatureUsage.track_feature(user1.id, "chat", "first_message")
      {:ok, _} = FeatureUsage.track_feature(user1.id, "chat", "second_message")
      {:ok, _} = FeatureUsage.track_feature(user2.id, "chat", "first_message")

      {:ok, events} = FeatureUsage.list_user_events(actor: user1)

      assert length(events) == 2
      assert Enum.all?(events, &(&1.user_id == user1.id))
    end

    test "returns events sorted by inserted_at desc" do
      user = generate(user())

      {:ok, _} = FeatureUsage.track_feature(user.id, "chat", "first")
      {:ok, _} = FeatureUsage.track_feature(user.id, "prompt", "second")

      {:ok, events} = FeatureUsage.list_user_events(actor: user)

      assert length(events) == 2
      # Most recent first
      assert hd(events).feature == "prompt"
    end
  end
end
