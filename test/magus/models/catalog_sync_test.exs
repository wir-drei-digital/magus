defmodule Magus.Models.CatalogSyncTest do
  use Magus.DataCase, async: false

  alias Magus.Models.CatalogSync

  setup do
    # Clear seeded catalog rows (and their referencing rows) so these tests
    # assert on a clean catalog. Rolled back after the test.
    Magus.DataCase.clear_catalog!()

    {:ok, openrouter} =
      Magus.Models.create_provider(
        %{name: "OpenRouter", slug: "openrouter", req_llm_id: "openrouter"},
        authorize?: false
      )

    {:ok, custom} =
      Magus.Models.create_provider(
        %{
          name: "Local vLLM",
          slug: "local_vllm",
          req_llm_id: "openai_compatible",
          base_url: "http://localhost:8000/v1"
        },
        authorize?: false
      )

    %{openrouter: openrouter, custom: custom}
  end

  defp create_model!(attrs) do
    Magus.Chat.Model
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{provider: "Test", context_window: 100_000, active?: true},
        attrs
      )
    )
    |> Ash.create!()
  end

  test "groups models by provider slug with name and base_url", ctx do
    create_model!(%{
      name: "M1",
      key: "openrouter:foo/m1",
      model_provider_id: ctx.openrouter.id,
      input_cost_value: Decimal.new("3"),
      output_cost_value: Decimal.new("15"),
      supports_reasoning?: true,
      input_modalities: ["text", "image"],
      output_modalities: ["text"],
      llm_metadata: %{"output_limit" => 64_000, "cache_read" => 0.3}
    })

    create_model!(%{
      name: "Llama",
      key: "local_vllm:llama-3",
      model_provider_id: ctx.custom.id,
      input_cost_value: Decimal.new("0"),
      output_cost_value: Decimal.new("0"),
      input_modalities: ["text"],
      output_modalities: ["text"]
    })

    custom_map = CatalogSync.build_custom()

    assert [name: "OpenRouter", base_url: "https://openrouter.ai/api/v1", models: or_models] =
             custom_map[:openrouter]

    entry = or_models["foo/m1"]
    assert entry.name == "M1"
    assert entry.cost == %{input: 3.0, output: 15.0, cache_read: 0.3}
    assert entry.limits == %{context: 100_000, output: 64_000}
    assert entry.capabilities.reasoning == %{enabled: true}
    assert entry.modalities == %{input: [:text, :image], output: [:text]}

    assert [name: "Local vLLM", base_url: "http://localhost:8000/v1", models: custom_models] =
             custom_map[:local_vllm]

    assert Map.has_key?(custom_models, "llama-3")
  end

  test "skips inactive models and disabled providers", ctx do
    create_model!(%{
      name: "Inactive",
      key: "openrouter:foo/inactive",
      model_provider_id: ctx.openrouter.id,
      active?: false
    })

    {:ok, _} = Magus.Models.update_provider(ctx.custom, %{enabled?: false}, authorize?: false)

    create_model!(%{
      name: "OnDisabled",
      key: "local_vllm:gone",
      model_provider_id: ctx.custom.id
    })

    custom_map = CatalogSync.build_custom()
    refute Map.has_key?(custom_map, :local_vllm)
    # openrouter's only model is inactive, so the provider has no entry at all
    refute Map.has_key?(custom_map, :openrouter)
  end

  test "models without a provider link are skipped" do
    create_model!(%{name: "Orphan", key: "openrouter:foo/orphan"})
    custom_map = CatalogSync.build_custom()
    orphan = custom_map[:openrouter] && custom_map[:openrouter][:models]["foo/orphan"]
    assert orphan == nil
  end

  describe "reload/0" do
    test "registers DB-defined custom models into LLMDB", ctx do
      create_model!(%{
        name: "Sync Probe",
        key: "openrouter:magus-test/sync-probe",
        model_provider_id: ctx.openrouter.id,
        context_window: 12_345,
        llm_metadata: %{"output_limit" => 4_096}
      })

      assert :ok = CatalogSync.reload()

      assert {:ok, model} = LLMDB.model("openrouter:magus-test/sync-probe")
      assert model.limits.context == 12_345
    end

    test "succeeds with no relevant rows (fresh install)" do
      assert :ok = CatalogSync.reload()
    end
  end

  describe "malformed catalog data (reload must survive)" do
    # These rows bypass the Ash modality/context validations on purpose: the
    # prod blocker was an admin row that lands in the DB (directly, or from a
    # pre-constraint write) and then crash-loops the reload. We force the bad
    # state with raw SQL to prove the build/reload path tolerates it.
    defp force_modalities!(model_id, input, output) do
      Magus.Repo.query!(
        "UPDATE models SET input_modalities = $1, output_modalities = $2 WHERE id = $3",
        [input, output, Ecto.UUID.dump!(model_id)]
      )
    end

    test "unknown modalities are dropped, not raised, and fall back to [:text]", ctx do
      model =
        create_model!(%{
          name: "Weird Modalities",
          key: "openrouter:weird/modalities",
          model_provider_id: ctx.openrouter.id
        })

      # only-unknown input -> [:text]; mixed output -> known atoms only
      force_modalities!(model.id, ["totally_unknown_modality"], ["text", "not_a_real_one"])

      custom = CatalogSync.build_custom()
      entry = custom[:openrouter][:models]["weird/modalities"]

      assert entry.modalities == %{input: [:text], output: [:text]}
    end

    test "zero/nil context_window does not produce an invalid LLMDB entry", ctx do
      zero =
        create_model!(%{
          name: "Zero Context",
          key: "openrouter:zero/context",
          model_provider_id: ctx.openrouter.id,
          context_window: 0
        })

      _nilctx =
        create_model!(%{
          name: "Nil Context",
          key: "openrouter:nil/context",
          model_provider_id: ctx.openrouter.id,
          context_window: nil
        })

      custom = CatalogSync.build_custom()

      assert custom[:openrouter][:models]["zero/context"].limits.context >= 1
      assert custom[:openrouter][:models]["nil/context"].limits.context >= 1

      # the whole map must load into LLMDB without raising (Zoi.min(1))
      assert :ok = CatalogSync.reload()
      assert {:ok, _} = LLMDB.model("openrouter:zero/context")

      _ = zero
    end

    test "reload survives a row with both bad context and bad modalities", ctx do
      model =
        create_model!(%{
          name: "Fully Malformed",
          key: "openrouter:fully/malformed",
          model_provider_id: ctx.openrouter.id,
          context_window: 0
        })

      force_modalities!(model.id, ["nonsense"], ["nonsense"])

      assert :ok = CatalogSync.reload()
    end
  end

  describe "CatalogSync.Server survives malformed data" do
    test "server stays alive after a reload over a malformed row", ctx do
      # The app-supervised server is already running; this async: false test
      # shares its sandbox connection, so request_reload's :do_reload sees our
      # committed-in-tx row. Even if the underlying load raised, the guarded
      # reload must keep the GenServer alive (the prod crash-loop fix).
      pid = Process.whereis(Magus.Models.CatalogSync.Server)
      assert is_pid(pid)

      model =
        create_model!(%{
          name: "Server Malformed",
          key: "openrouter:server/malformed",
          model_provider_id: ctx.openrouter.id,
          context_window: 0
        })

      force_modalities!(model.id, ["bogus"], ["bogus"])

      :ok = Magus.Models.CatalogSync.request_reload()
      assert :ok = await_idle(pid)
      assert Process.alive?(pid)
    end

    defp await_idle(pid, attempts \\ 50) do
      cond do
        attempts <= 0 -> :timeout
        :sys.get_state(pid).pending -> Process.sleep(10) && await_idle(pid, attempts - 1)
        true -> :ok
      end
    end
  end

  describe "CatalogSync.Server.refresh/2 (serialized manual refresh)" do
    test "routes through the running Server and returns a flash-usable result", ctx do
      # The app-supervised Server is running. Use the offline :packaged snapshot
      # (no github fetch) so this stays deterministic.
      pid = Process.whereis(Magus.Models.CatalogSync.Server)
      assert is_pid(pid)

      create_model!(%{
        name: "Refresh Probe",
        key: "openrouter:magus-test/refresh-probe",
        model_provider_id: ctx.openrouter.id,
        context_window: 9_999
      })

      # Result shape must match what ProvidersLive's handle_info expects (:ok).
      assert :ok = Magus.Models.CatalogSync.Server.refresh(:packaged)

      # The serializing Server stays alive (the call ran inside it).
      assert Process.alive?(pid)

      assert {:ok, model} = LLMDB.model("openrouter:magus-test/refresh-probe")
      assert model.limits.context == 9_999
    end

    test "guarded reload never raises: returns :ok | {:error, reason}", ctx do
      # The guarded reload (shared by cast + refresh) wraps the rescue/catch.
      # Even over a forced-malformed row, the result is a flash-usable shape,
      # never a raise.
      model =
        create_model!(%{
          name: "Refresh Malformed",
          key: "openrouter:refresh/malformed",
          model_provider_id: ctx.openrouter.id,
          context_window: 0
        })

      force_modalities!(model.id, ["bogus"], ["bogus"])

      result = Magus.Models.CatalogSync.guarded_reload(snapshot_source: :packaged)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "model key uniqueness" do
    test "two models with the same key cannot both exist", ctx do
      create_model!(%{
        name: "First",
        key: "openrouter:dup/key",
        model_provider_id: ctx.openrouter.id
      })

      assert {:error, %Ash.Error.Invalid{}} =
               Magus.Chat.Model
               |> Ash.Changeset.for_create(:create, %{
                 name: "Second",
                 key: "openrouter:dup/key",
                 provider: "Test"
               })
               |> Ash.create()
    end
  end

  describe "modality constraint at the create path" do
    test "an unknown modality is rejected on create", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Magus.Chat.Model
               |> Ash.Changeset.for_create(:create, %{
                 name: "Bad Modality",
                 key: "openrouter:bad/modality",
                 provider: "Test",
                 model_provider_id: ctx.openrouter.id,
                 input_modalities: ["text", "definitely_not_valid"]
               })
               |> Ash.create()
    end

    test "known modalities are accepted on create", ctx do
      assert {:ok, _} =
               Magus.Chat.Model
               |> Ash.Changeset.for_create(:create, %{
                 name: "Good Modality",
                 key: "openrouter:good/modality",
                 provider: "Test",
                 model_provider_id: ctx.openrouter.id,
                 input_modalities: ["text", "image", "file"],
                 output_modalities: ["text", "video"]
               })
               |> Ash.create()
    end
  end
end
