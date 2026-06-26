defmodule Magus.Agents.Routing.ModelMatcherTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Routing.AutoRouter.Classification
  alias Magus.Agents.Routing.ModelMatcher

  defp create_routable_model(opts) do
    specialty = Keyword.fetch!(opts, :specialty)
    tier = Keyword.fetch!(opts, :tier)
    model_opts = Keyword.drop(opts, [:specialty, :tier])

    model = generate(model(model_opts))
    routing_slot(model_id: model.id, specialty: specialty, tier: tier)
    model
  end

  describe "find_model/1 - exact specialty + tier match" do
    test "matches coding/pro" do
      model = create_routable_model(specialty: :coding, tier: :complex)

      classification = %Classification{intent: :coding, complexity: :hard, confidence: 0.9}
      assert {:ok, model.key} == ModelMatcher.find_model(classification)
    end

    test "matches search/starter" do
      model = create_routable_model(specialty: :search, tier: :standard)

      classification = %Classification{intent: :search, complexity: :simple, confidence: 0.9}
      assert {:ok, model.key} == ModelMatcher.find_model(classification)
    end

    test "matches chat/simple → simple/general" do
      model = create_routable_model(specialty: :general, tier: :simple)

      classification = %Classification{intent: :chat, complexity: :simple, confidence: 0.9}
      assert {:ok, model.key} == ModelMatcher.find_model(classification)
    end
  end

  describe "find_model/1 - fallback matching" do
    test "falls back to specialty match when tier doesn't match" do
      model = create_routable_model(specialty: :coding, tier: :standard)

      # Wants complex/coding but only standard/coding exists
      classification = %Classification{intent: :coding, complexity: :hard, confidence: 0.9}
      assert {:ok, model.key} == ModelMatcher.find_model(classification)
    end

    test "falls back to tier match when specialty doesn't match" do
      model = create_routable_model(specialty: :general, tier: :complex)

      # Wants complex/reasoning but only complex/general exists
      classification = %Classification{intent: :reasoning, complexity: :hard, confidence: 0.9}
      assert {:ok, model.key} == ModelMatcher.find_model(classification)
    end

    test "falls back to any routable model as last resort" do
      model = create_routable_model(specialty: :creative, tier: :simple)

      # Wants complex/reasoning but only simple/creative exists
      classification = %Classification{intent: :reasoning, complexity: :hard, confidence: 0.9}
      assert {:ok, model.key} == ModelMatcher.find_model(classification)
    end
  end

  describe "find_model/1 - no models available" do
    test "returns :no_match when no routing-eligible models exist" do
      classification = %Classification{intent: :chat, complexity: :simple, confidence: 0.9}
      assert :no_match == ModelMatcher.find_model(classification)
    end

    test "ignores inactive models" do
      model = generate(model(active?: false))
      routing_slot(model_id: model.id, specialty: :general, tier: :simple)

      classification = %Classification{intent: :chat, complexity: :simple, confidence: 0.9}
      assert :no_match == ModelMatcher.find_model(classification)
    end
  end

  describe "find_model/1 - prefers exact match over fallback" do
    test "picks exact match over more generic model" do
      _general = create_routable_model(specialty: :general, tier: :complex)
      coding = create_routable_model(specialty: :coding, tier: :complex)

      classification = %Classification{intent: :coding, complexity: :hard, confidence: 0.9}
      assert {:ok, coding.key} == ModelMatcher.find_model(classification)
    end
  end

  describe "find_model/1 - same model in multiple slots" do
    test "model can fill multiple routing slots" do
      model = generate(model())
      routing_slot(model_id: model.id, specialty: :general, tier: :standard)
      routing_slot(model_id: model.id, specialty: :coding, tier: :standard)

      # Both intents should resolve to the same model
      chat = %Classification{intent: :chat, complexity: :medium, confidence: 0.9}
      coding = %Classification{intent: :coding, complexity: :medium, confidence: 0.9}

      assert {:ok, model.key} == ModelMatcher.find_model(chat)
      assert {:ok, model.key} == ModelMatcher.find_model(coding)
    end
  end

  describe "find_model/2 - max_tier capping" do
    test "caps tier from complex to simple" do
      simple_model = create_routable_model(specialty: :coding, tier: :simple)
      _complex_model = create_routable_model(specialty: :coding, tier: :complex)

      # Without cap, hard coding would route to complex
      classification = %Classification{intent: :coding, complexity: :hard, confidence: 0.9}
      assert {:ok, _key} = ModelMatcher.find_model(classification)

      # With max_tier: :simple, it gets capped down
      assert {:ok, simple_model.key} == ModelMatcher.find_model(classification, max_tier: :simple)
    end

    test "no capping when max_tier is nil" do
      complex_model = create_routable_model(specialty: :coding, tier: :complex)

      classification = %Classification{intent: :coding, complexity: :hard, confidence: 0.9}
      assert {:ok, complex_model.key} == ModelMatcher.find_model(classification, max_tier: nil)
    end

    test "no capping when target tier is within limit" do
      simple_model = create_routable_model(specialty: :general, tier: :simple)

      # Simple chat → simple tier, max_tier: :standard allows it
      classification = %Classification{intent: :chat, complexity: :simple, confidence: 0.9}

      assert {:ok, simple_model.key} ==
               ModelMatcher.find_model(classification, max_tier: :standard)
    end

    test "caps tier from complex to standard" do
      _complex_model = create_routable_model(specialty: :general, tier: :complex)
      standard_model = create_routable_model(specialty: :general, tier: :standard)

      classification = %Classification{intent: :chat, complexity: :hard, confidence: 0.9}

      assert {:ok, standard_model.key} ==
               ModelMatcher.find_model(classification, max_tier: :standard)
    end
  end

  describe "find_media_model/1 - media slot lookup" do
    test "finds image model by routing slot" do
      model = create_routable_model(specialty: :image, tier: :standard)

      assert {:ok, model.key} == ModelMatcher.find_media_model(:image)
    end

    test "finds text_to_video model by routing slot" do
      model = create_routable_model(specialty: :text_to_video, tier: :standard)

      assert {:ok, model.key} == ModelMatcher.find_media_model(:text_to_video)
    end

    test "finds image_to_video model by routing slot" do
      model = create_routable_model(specialty: :image_to_video, tier: :standard)

      assert {:ok, model.key} == ModelMatcher.find_media_model(:image_to_video)
    end

    test "returns :no_match when no slot exists for the media specialty" do
      # Create a slot for a different media specialty
      _model = create_routable_model(specialty: :image, tier: :standard)

      assert :no_match == ModelMatcher.find_media_model(:text_to_video)
    end

    test "returns :no_match when no routing slots exist at all" do
      assert :no_match == ModelMatcher.find_media_model(:image)
    end

    test "skips inactive models" do
      model = generate(model(active?: false))
      routing_slot(model_id: model.id, specialty: :image, tier: :standard)

      assert :no_match == ModelMatcher.find_media_model(:image)
    end
  end

  describe "find_model/2 - media slot isolation" do
    test "does NOT fall back to media slots for chat routing" do
      # Only create media slots, no chat slots
      _image_model = create_routable_model(specialty: :image, tier: :standard)
      _video_model = create_routable_model(specialty: :text_to_video, tier: :standard)

      classification = %Classification{intent: :chat, complexity: :simple, confidence: 0.9}
      assert :no_match == ModelMatcher.find_model(classification)
    end

    test "chat routing works when both chat and media slots exist" do
      chat_model = create_routable_model(specialty: :general, tier: :simple)
      _image_model = create_routable_model(specialty: :image, tier: :standard)

      classification = %Classification{intent: :chat, complexity: :simple, confidence: 0.9}
      assert {:ok, chat_model.key} == ModelMatcher.find_model(classification)
    end
  end

  describe "find_model/2 - required_modalities filtering" do
    test "filters out models that don't support required modalities" do
      _text_only =
        create_routable_model(specialty: :general, tier: :simple, input_modalities: ["text"])

      vision =
        create_routable_model(
          specialty: :general,
          tier: :standard,
          input_modalities: ["text", "image"]
        )

      classification = %Classification{intent: :chat, complexity: :simple, confidence: 0.9}

      assert {:ok, vision.key} ==
               ModelMatcher.find_model(classification, required_modalities: ["image"])
    end

    test "returns :no_match when no models support required modalities" do
      _text_only =
        create_routable_model(specialty: :general, tier: :simple, input_modalities: ["text"])

      classification = %Classification{intent: :chat, complexity: :simple, confidence: 0.9}

      assert :no_match == ModelMatcher.find_model(classification, required_modalities: ["image"])
    end

    test "no filtering when required_modalities is empty" do
      model =
        create_routable_model(specialty: :general, tier: :simple, input_modalities: ["text"])

      classification = %Classification{intent: :chat, complexity: :simple, confidence: 0.9}

      assert {:ok, model.key} == ModelMatcher.find_model(classification, required_modalities: [])
    end

    test "falls back through tiers when exact match is filtered out by modality" do
      _text_simple =
        create_routable_model(specialty: :general, tier: :simple, input_modalities: ["text"])

      vision_standard =
        create_routable_model(
          specialty: :general,
          tier: :standard,
          input_modalities: ["text", "image"]
        )

      # Wants simple/general but only standard/general has image support
      classification = %Classification{intent: :chat, complexity: :simple, confidence: 0.9}

      assert {:ok, vision_standard.key} ==
               ModelMatcher.find_model(classification, required_modalities: ["image"])
    end
  end

  describe "find_model/2 - model access is ungated" do
    test "an expensive model is routable (cost no longer constrains routing)" do
      model =
        create_routable_model(
          specialty: :general,
          tier: :simple
        )

      classification = %Classification{intent: :chat, complexity: :simple, confidence: 0.9}

      assert {:ok, model.key} == ModelMatcher.find_model(classification)
    end
  end
end
