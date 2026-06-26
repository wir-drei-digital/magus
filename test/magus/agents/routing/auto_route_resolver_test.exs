defmodule Magus.Agents.Routing.AutoRouteResolverTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Routing.AutoRouteResolver

  defp run_step(model_keys, message, conversation \\ nil, recent_messages \\ []) do
    AutoRouteResolver.resolve(model_keys, message, conversation, recent_messages: recent_messages)
  end

  defp make_message(attrs \\ %{}) do
    Map.merge(
      %{text: "Hello", mode: nil, selected_model_id: nil, attachments: [], metadata: %{}},
      attrs
    )
  end

  defp create_routable_model(opts) do
    specialty = Keyword.fetch!(opts, :specialty)
    tier = Keyword.fetch!(opts, :tier)
    model_opts = Keyword.drop(opts, [:specialty, :tier])

    model = generate(model(model_opts))
    routing_slot(model_id: model.id, specialty: specialty, tier: tier)
    model
  end

  describe "passthrough for explicit model keys" do
    test "returns model_keys unchanged when chat is a string" do
      keys = %{chat: "openrouter:anthropic/claude-sonnet-4", image: "img-key", video: "vid-key"}
      message = make_message()

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)
      assert result.model_keys == keys
      assert result.routing_reason == nil
    end
  end

  describe "auto-routing" do
    test "resolves :auto to a routable model" do
      model = create_routable_model(specialty: :general, tier: :simple)

      keys = %{chat: :auto, image: "img-key", video: "vid-key"}
      message = make_message(%{text: "Hi there"})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)
      assert result.model_keys.chat == model.key
      assert result.model_keys.image == "img-key"
      assert result.model_keys.video == "vid-key"
    end

    test "includes routing_reason when auto-routed" do
      _model = create_routable_model(specialty: :general, tier: :simple)

      keys = %{chat: :auto, image: "img-key", video: "vid-key"}
      message = make_message(%{text: "Hi there"})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)
      assert is_binary(result.routing_reason)
      assert result.routing_reason =~ "Auto-routed to"
      assert result.routing_reason =~ "conversation"
    end

    test "routes to general/chat model by default" do
      general = create_routable_model(specialty: :general, tier: :simple)

      keys = %{chat: :auto, image: "img-key", video: "vid-key"}

      message =
        make_message(%{text: "Help me debug this function, it has a compile error in my module"})

      # Without LLM, classifier defaults to :chat intent
      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)
      assert result.model_keys.chat == general.key
      assert result.routing_reason =~ "conversation"
    end
  end

  describe "fallback to system default" do
    test "falls back to system default when no routable models exist" do
      keys = %{chat: :auto, image: "img-key", video: "vid-key"}
      message = make_message(%{text: "Hello"})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)
      assert is_binary(result.model_keys.chat)
      assert result.routing_reason == nil
    end
  end

  describe "nil text handling" do
    test "handles nil text gracefully" do
      _model = create_routable_model(specialty: :general, tier: :simple)

      keys = %{chat: :auto, image: "img-key", video: "vid-key"}
      message = make_message(%{text: nil})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)
      assert is_binary(result.model_keys.chat)
    end
  end

  describe "search mode override" do
    test "routes to search model when mode is :search" do
      _general = create_routable_model(specialty: :general, tier: :simple)
      search = create_routable_model(specialty: :search, tier: :standard)

      keys = %{chat: :auto, image: "img-key", video: "vid-key"}
      message = make_message(%{text: "Tell me about Elixir", mode: :search})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)
      assert result.model_keys.chat == search.key
      assert result.routing_reason =~ "web search"
    end
  end

  describe "tier capping via conversation" do
    test "caps tier to simple for user on free plan" do
      # Set up: complex general model + simple general model
      simple_model = create_routable_model(specialty: :general, tier: :simple)
      _complex_model = create_routable_model(specialty: :general, tier: :complex)

      # Create user with free plan (max_routing_tier: :simple)
      user = generate(user())

      plan =
        generate(
          usage_plan(
            key: "free-test-#{System.unique_integer([:positive])}",
            max_routing_tier: :simple
          )
        )

      {:ok, _sub} =
        Magus.Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: plan.id, status: :active},
          authorize?: false
        )

      # Build a fake conversation struct with user_id and user.timezone
      conversation = %{user_id: user.id, user: %{timezone: "Etc/UTC"}}

      keys = %{chat: :auto, image: "img-key", video: "vid-key"}

      message =
        make_message(%{text: "Help me debug this function, it has a compile error in my module"})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message, conversation)
      # Should be capped to simple tier model
      assert result.model_keys.chat == simple_model.key
      assert result.routing_reason =~ "tier capped to simple"
    end

    test "does not cap tier for user on complex plan" do
      model = create_routable_model(specialty: :general, tier: :complex)

      user = generate(user())

      plan =
        generate(
          usage_plan(
            key: "pro-test-#{System.unique_integer([:positive])}",
            max_routing_tier: :complex
          )
        )

      {:ok, _sub} =
        Magus.Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: plan.id, status: :active},
          authorize?: false
        )

      conversation = %{user_id: user.id, user: %{timezone: "Etc/UTC"}}

      keys = %{chat: :auto, image: "img-key", video: "vid-key"}

      message =
        make_message(%{text: "Help me debug this function, it has a compile error in my module"})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message, conversation)
      assert result.model_keys.chat == model.key
      assert result.routing_reason =~ "conversation"
    end

    test "no capping when conversation is nil" do
      complex_model = create_routable_model(specialty: :general, tier: :complex)

      keys = %{chat: :auto, image: "img-key", video: "vid-key"}

      message =
        make_message(%{text: "Help me debug this function, it has a compile error in my module"})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message, nil)
      assert result.model_keys.chat == complex_model.key
    end
  end

  describe "model access is ungated in routing" do
    test "an expensive model is routable regardless of plan (cost no longer constrains routing)" do
      expensive_model =
        create_routable_model(
          specialty: :general,
          tier: :simple
        )

      user = generate(user())

      plan =
        generate(
          usage_plan(
            key: "ungated-#{System.unique_integer([:positive])}",
            max_routing_tier: :complex
          )
        )

      {:ok, _sub} =
        Magus.Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: plan.id, status: :active},
          authorize?: false
        )

      conversation = %{user_id: user.id, user: %{timezone: "Etc/UTC"}}
      keys = %{chat: :auto, image: "img-key", video: "vid-key"}
      message = make_message(%{text: "Hi there"})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message, conversation)
      assert result.model_keys.chat == expensive_model.key
    end
  end

  describe "image auto-routing" do
    test "resolves :auto image to system default" do
      keys = %{chat: "explicit-chat", image: :auto, video: "vid-key"}
      message = make_message(%{text: "Generate a cat picture"})

      assert {:ok, result} = run_step(keys, message)
      assert is_binary(result.model_keys.image)
      assert result.model_keys.chat == "explicit-chat"
      assert result.model_keys.video == "vid-key"
    end

    test "preserves explicit image key" do
      keys = %{chat: "explicit-chat", image: "my-image-model", video: "vid-key"}
      message = make_message(%{text: "Generate a cat picture"})

      assert {:ok, result} = run_step(keys, message)
      assert result.model_keys.image == "my-image-model"
    end
  end

  describe "video auto-routing" do
    test "resolves :auto video to system default when no classification model" do
      keys = %{chat: "explicit-chat", image: "img-key", video: :auto}
      message = make_message(%{text: "Make a video of a sunset"})

      assert {:ok, result} = run_step(keys, message)
      assert is_binary(result.model_keys.video)
      assert result.model_keys.chat == "explicit-chat"
      assert result.model_keys.image == "img-key"
    end

    test "preserves explicit video key" do
      keys = %{chat: "explicit-chat", image: "img-key", video: "my-video-model"}
      message = make_message(%{text: "Make a video of a sunset"})

      assert {:ok, result} = run_step(keys, message)
      assert result.model_keys.video == "my-video-model"
    end
  end

  describe "video auto-routing with classification" do
    test "resolves :auto video with conversation context" do
      keys = %{chat: "explicit-chat", image: "img-key", video: :auto}
      message = make_message(%{text: "Make a sunset video"})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)

      assert is_binary(result.model_keys.video)
    end

    test "resolves :auto video with image reference in context" do
      context = [
        %{
          role: :user,
          text: "Animate this image",
          attachments: [%{"url" => "https://example.com/photo.jpg", "type" => "image"}]
        }
      ]

      keys = %{chat: "explicit-chat", image: "img-key", video: :auto}
      message = make_message(%{text: "Animate this image"})

      assert {:ok, result} =
               AutoRouteResolver.resolve(keys, message, nil, recent_messages: context)

      # Should resolve to a video model (system default since no image-capable model in test DB)
      assert is_binary(result.model_keys.video)
    end
  end

  describe "image auto-routing via routing slot" do
    test "resolves :auto image to routing slot model" do
      image_model = generate(model(output_modalities: ["image"]))
      routing_slot(model_id: image_model.id, specialty: :image, tier: :standard)

      keys = %{chat: "explicit-chat", image: :auto, video: "vid-key"}
      message = make_message(%{text: "Generate a cat picture"})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)
      assert result.model_keys.image == image_model.key
    end
  end

  describe "video auto-routing via routing slots" do
    test "resolves :auto video to text_to_video slot" do
      video_model = generate(model(output_modalities: ["video"]))
      routing_slot(model_id: video_model.id, specialty: :text_to_video, tier: :standard)

      keys = %{chat: "explicit-chat", image: "img-key", video: :auto}
      message = make_message(%{text: "Make a sunset video"})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)
      assert result.model_keys.video == video_model.key
    end

    test "resolves :auto video to image_to_video slot when animate request" do
      i2v_model =
        generate(
          model(
            input_modalities: ["text", "image"],
            output_modalities: ["video"]
          )
        )

      routing_slot(model_id: i2v_model.id, specialty: :image_to_video, tier: :standard)

      context = [
        %{
          role: :user,
          text: "Animate this image",
          attachments: [%{"url" => "https://example.com/photo.jpg", "type" => "image"}]
        }
      ]

      keys = %{chat: "explicit-chat", image: "img-key", video: :auto}
      message = make_message(%{text: "Animate this image"})

      assert {:ok, result} =
               AutoRouteResolver.resolve(keys, message, nil, recent_messages: context)

      assert result.model_keys.video == i2v_model.key
    end
  end

  describe "all :auto keys resolved together" do
    test "resolves all three :auto keys in one step" do
      _model = create_routable_model(specialty: :general, tier: :simple)

      keys = %{chat: :auto, image: :auto, video: :auto}
      message = make_message(%{text: "Hello"})

      assert {:ok, result} = run_step(keys, message)
      assert is_binary(result.model_keys.chat)
      assert is_binary(result.model_keys.image)
      assert is_binary(result.model_keys.video)
    end
  end

  describe "routing_reason format" do
    test "extracts model name from key with slashes" do
      _model =
        create_routable_model(
          key: "openrouter:anthropic/claude-sonnet-4",
          specialty: :general,
          tier: :standard
        )

      keys = %{chat: :auto, image: "img-key", video: "vid-key"}
      message = make_message(%{text: "Tell me about Elixir"})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)
      assert result.routing_reason =~ "claude-sonnet-4"
    end

    test "includes correct intent label for search" do
      _model = create_routable_model(specialty: :search, tier: :standard)

      keys = %{chat: :auto, image: "img-key", video: "vid-key"}
      message = make_message(%{text: "What are the latest news about AI in 2026?", mode: :search})

      assert {:ok, result} = AutoRouteResolver.resolve(keys, message)
      assert result.routing_reason =~ "web search"
    end
  end
end
