defmodule Magus.Chat.ModelTest do
  @moduledoc """
  Tests for the Model resource.

  Note: Model is a system configuration resource without authorization policies.
  All operations use authorize?: false as this is admin-only functionality.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  describe "create/1" do
    test "creates model with required attributes" do
      # Model has no authorizer - system/admin resource
      {:ok, model} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Test Model",
          key: "test/model-1",
          provider: "test"
        })
        |> Ash.create(authorize?: false)

      assert model.name == "Test Model"
      assert model.key == "test/model-1"
      assert model.provider == "test"
      assert model.active? == true
    end

    test "creates model with all attributes" do
      {:ok, model} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Full Model",
          key: "test/full-model",
          provider: "anthropic",
          api_provider: :openrouter,
          context_window: 100_000,
          input_cost: "$3/M",
          output_cost: "$15/M",
          input_cost_value: Decimal.new("3.00"),
          input_cost_unit: :per_million_tokens,
          output_cost_value: Decimal.new("15.00"),
          output_cost_unit: :per_million_tokens,
          supports_search?: true,
          supports_reasoning?: true,
          supports_tools?: true,
          input_modalities: ["text", "image"],
          output_modalities: ["text"],
          short_description: "A test model",
          detailed_description: "A detailed description of the test model"
        })
        |> Ash.create(authorize?: false)

      assert model.context_window == 100_000
      assert model.input_cost == "$3/M"
      assert model.output_cost == "$15/M"
      assert Decimal.eq?(model.input_cost_value, Decimal.new("3.00"))
      assert model.input_cost_unit == :per_million_tokens
      assert Decimal.eq?(model.output_cost_value, Decimal.new("15.00"))
      assert model.output_cost_unit == :per_million_tokens
      assert model.supports_search? == true
      assert model.supports_reasoning? == true
      assert model.input_modalities == ["text", "image"]
    end

    test "creates image model with per-image cost unit" do
      {:ok, model} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Image Model",
          key: "test/image-model",
          provider: "test",
          output_cost_value: Decimal.new("0.04"),
          output_cost_unit: :per_image,
          output_modalities: ["image"]
        })
        |> Ash.create(authorize?: false)

      assert Decimal.eq?(model.output_cost_value, Decimal.new("0.04"))
      assert model.output_cost_unit == :per_image
    end

    test "creates video model with per-second cost unit" do
      {:ok, model} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Video Model",
          key: "test/video-model",
          provider: "test",
          output_cost_value: Decimal.new("0.21"),
          output_cost_unit: :per_second,
          output_modalities: ["video"]
        })
        |> Ash.create(authorize?: false)

      assert Decimal.eq?(model.output_cost_value, Decimal.new("0.21"))
      assert model.output_cost_unit == :per_second
    end
  end

  describe "list_active/1" do
    test "returns only active models" do
      # Create active model
      {:ok, active} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Active Model",
          key: "test/active",
          provider: "test",
          active?: true
        })
        |> Ash.create(authorize?: false)

      # Create inactive model
      {:ok, _inactive} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Inactive Model",
          key: "test/inactive",
          provider: "test",
          active?: false
        })
        |> Ash.create(authorize?: false)

      {:ok, models} = Chat.list_active_models(authorize?: false)

      model_ids = Enum.map(models, & &1.id)
      assert active.id in model_ids
    end

    test "returns models sorted by name" do
      {:ok, model_z} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Zebra Model",
          key: "test/zebra",
          provider: "test"
        })
        |> Ash.create(authorize?: false)

      {:ok, model_a} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Alpha Model",
          key: "test/alpha",
          provider: "test"
        })
        |> Ash.create(authorize?: false)

      {:ok, models} = Chat.list_active_models(authorize?: false)

      # Find the positions of our test models
      alpha_index = Enum.find_index(models, &(&1.id == model_a.id))
      zebra_index = Enum.find_index(models, &(&1.id == model_z.id))

      assert alpha_index < zebra_index
    end
  end

  describe "list_image_generation/1" do
    test "returns models with image output modality" do
      {:ok, image_model} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Image Gen Model",
          key: "test/image-gen",
          provider: "test",
          output_modalities: ["image"]
        })
        |> Ash.create(authorize?: false)

      {:ok, text_model} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Text Model",
          key: "test/text-only",
          provider: "test",
          output_modalities: ["text"]
        })
        |> Ash.create(authorize?: false)

      {:ok, models} = Chat.list_image_generation_models(authorize?: false)

      model_ids = Enum.map(models, & &1.id)
      assert image_model.id in model_ids
      refute text_model.id in model_ids
    end
  end

  describe "list_video_generation/1" do
    test "returns models with video output modality" do
      {:ok, video_model} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Video Gen Model",
          key: "test/video-gen",
          provider: "test",
          output_modalities: ["video"]
        })
        |> Ash.create(authorize?: false)

      {:ok, text_model} =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Text Only Model",
          key: "test/text-only-2",
          provider: "test",
          output_modalities: ["text"]
        })
        |> Ash.create(authorize?: false)

      {:ok, models} = Chat.list_video_generation_models(authorize?: false)

      model_ids = Enum.map(models, & &1.id)
      assert video_model.id in model_ids
      refute text_model.id in model_ids
    end
  end

  describe "update/1" do
    test "updates model attributes" do
      model = generate(model())

      {:ok, updated} =
        model
        |> Ash.Changeset.for_update(:update, %{
          name: "Updated Name",
          context_window: 200_000
        })
        |> Ash.update(authorize?: false)

      assert updated.name == "Updated Name"
      assert updated.context_window == 200_000
    end
  end

  describe "request_cost_cents calculation" do
    test "loads the picker per-request estimate for a token model" do
      model =
        generate(
          model(
            input_cost_value: Decimal.new("1"),
            output_cost_value: Decimal.new("5"),
            output_cost_unit: :per_million_tokens
          )
        )

      loaded = Ash.load!(model, [:request_cost_cents], authorize?: false)

      assert is_integer(loaded.request_cost_cents)

      assert loaded.request_cost_cents ==
               Magus.Usage.PolicyEnforcer.picker_request_cost_cents(model)
    end

    test "is nil for image/video models" do
      model =
        generate(
          model(
            output_cost_unit: :per_image,
            output_cost_value: Decimal.new("40")
          )
        )

      loaded = Ash.load!(model, [:request_cost_cents], authorize?: false)

      assert loaded.request_cost_cents == nil
    end
  end
end
