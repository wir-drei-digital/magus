defmodule Magus.Models.ResolverTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Models.{Resolution, Resolver}

  describe "explicit selection" do
    test "explicit selected_model_id resolves to that model as :explicit" do
      m = generate(model())

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: :auto, image: nil, video: nil},
          mode: :chat,
          selected_model_id: m.id
        })

      assert res.model.id == m.id
      assert res.selection_source == :explicit
      assert res.requested_selection == %{by: :id, value: m.id}
      refute Resolution.degraded?(res)
      assert res.access_source == :global
      assert res.credential_owner_user_id == nil
      assert res.cost_source == :platform_key
      assert res.provider_id == m.model_provider_id
    end

    test "a broken selected_model_id degrades to the keys map and is flagged" do
      chat = generate(model())
      bad_id = Ash.UUID.generate()

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: chat.key, image: nil, video: nil},
          mode: :chat,
          selected_model_id: bad_id
        })

      assert res.model.key == chat.key
      assert res.requested_selection == %{by: :id, value: bad_id}
      assert Resolution.degraded?(res)
    end

    test "an explicit chat key (no provenance) is :explicit and records the ask" do
      m = generate(model())

      {:ok, res} =
        Resolver.resolve(nil, %{model_keys: %{chat: m.key, image: nil, video: nil}, mode: :chat})

      assert res.model.key == m.key
      assert res.selection_source == :explicit
      assert res.requested_selection == %{by: :key, value: m.key}
      refute Resolution.degraded?(res)
    end
  end

  describe "auto-routing provenance" do
    test "a pre-resolved auto-routed chat key is :auto, not :explicit" do
      m = generate(model())

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: m.key, image: nil, video: nil},
          mode: :chat,
          auto_routed: %{chat: true, image: false, video: false}
        })

      assert res.model.key == m.key
      assert res.selection_source == :auto
      assert res.requested_selection == nil
      refute Resolution.degraded?(res)
    end
  end

  describe ":auto and media resolution" do
    test "resolves :auto image to the image model via routing slot, as :auto" do
      image_model = generate(model(output_modalities: ["image"]))
      routing_slot(model_id: image_model.id, specialty: :image, tier: :standard)

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: "some-chat", image: :auto, video: "some-video"},
          mode: :image_generation
        })

      assert res.model.key == image_model.key
      assert res.selection_source == :auto
    end

    test "resolves :auto image to the image_default role when no slot, as :role_default" do
      image_model = generate(model(output_modalities: ["image"]))

      {:ok, _} =
        Magus.Models.assign_role(%{role: "image_default", model_id: image_model.id},
          authorize?: false
        )

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: "some-chat", image: :auto, video: "some-video"},
          mode: :image_generation
        })

      assert res.model.key == image_model.key
      assert res.selection_source == :role_default
    end

    test "image mode with no image key falls back to the chat key" do
      chat_model = generate(model())

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: chat_model.key, image: nil, video: nil},
          mode: :image_generation
        })

      assert res.model.key == chat_model.key
    end

    test "chat :auto with no route falls back to a model struct (product/role default)" do
      {:ok, res} =
        Resolver.resolve(nil, %{model_keys: %{chat: :auto, image: "i", video: "v"}, mode: :chat})

      assert %Magus.Chat.Model{} = res.model
      assert res.selection_source in [:role_default, :product_default]
    end
  end

  describe "degradation telemetry" do
    test "emits [:magus, :models, :resolution, :degraded] when an explicit key misses" do
      ref = make_ref()

      :telemetry.attach(
        {:resolver_degraded, ref},
        [:magus, :models, :resolution, :degraded],
        fn _event, measurements, metadata, pid ->
          send(pid, {:degraded, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach({:resolver_degraded, ref}) end)

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: "missing:does-not-exist", image: nil, video: nil},
          mode: :chat
        })

      assert res.selection_source == :product_default
      assert Resolution.degraded?(res)
      assert_received {:degraded, %{count: 1}, %{selection_source: :product_default}}
    end
  end

  describe "no secrets" do
    test "carries provider_id (a UUID), never a provider struct or api_key" do
      {:ok, provider} =
        Magus.Models.create_provider(
          %{name: "P", slug: "pv_secret", req_llm_id: "openrouter", api_key: "sk-secret"},
          authorize?: false
        )

      model =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "M",
          key: "pv_secret:m",
          provider: "T",
          context_window: 1_000,
          model_provider_id: provider.id
        })
        |> Ash.create!()

      {:ok, res} =
        Resolver.resolve(nil, %{
          model_keys: %{chat: model.key, image: nil, video: nil},
          mode: :chat
        })

      assert res.provider_id == provider.id
      assert is_binary(res.provider_id)
      refute Map.has_key?(Map.from_struct(res), :provider)
      refute Map.has_key?(Map.from_struct(res), :api_key)
    end
  end

  describe "phase 2a carryover" do
    test "explicit-id miss falls to :auto image key and propagates inherited_requested" do
      {:ok, res} =
        Magus.Models.Resolver.resolve(nil, %{
          model_keys: %{chat: "openrouter:foo/chat", image: :auto},
          mode: :image_generation,
          selected_model_id: "00000000-0000-0000-0000-000000000000"
        })

      assert res.requested_selection == %{by: :id, value: "00000000-0000-0000-0000-000000000000"}
      assert Magus.Models.Resolution.degraded?(res)
    end

    test "explicit key equal to the default model is :explicit and not degraded" do
      default = Magus.Agents.Config.default_model()

      {:ok, res} =
        Magus.Models.Resolver.resolve(nil, %{model_keys: %{chat: default}, mode: :chat})

      assert res.selection_source == :explicit
      refute Magus.Models.Resolution.degraded?(res)
    end
  end

  describe "bare binary actor id" do
    test "a binary actor id scopes exactly like %{id: id}" do
      Magus.DataCase.clear_catalog!()
      user = generate(user())

      {:ok, provider} =
        Magus.Models.create_owned_provider(
          %{name: "Mine", req_llm_id: "anthropic", api_key: "sk"},
          actor: user
        )

      {:ok, model} =
        Magus.Chat.create_owned_model(
          %{name: "C", model_id: "claude-x", model_provider_id: provider.id},
          actor: user
        )

      {:ok, res} =
        Magus.Models.Resolver.resolve(user.id, %{model_keys: %{chat: model.key}, mode: :chat})

      assert res.model.key == model.key
      assert res.cost_source == :byok
    end
  end
end
