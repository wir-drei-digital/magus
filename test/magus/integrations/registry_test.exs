defmodule Magus.Integrations.RegistryTest do
  @moduledoc """
  Tests for `Magus.Integrations.Registry`, the runtime integration-provider
  registry used by the open-core seam (built-ins + runtime `register/2`).
  """
  # async: false — runtime registrations live in :persistent_term (global).
  use ExUnit.Case, async: false

  alias Magus.Integrations.Registry

  defmodule FakeProvider do
    def name, do: "Fake"
  end

  setup do
    original_extra = Application.fetch_env(:magus, :extra_integration_providers)

    on_exit(fn ->
      :persistent_term.erase({Magus.Integrations.Registry, :registered})

      case original_extra do
        {:ok, value} -> Application.put_env(:magus, :extra_integration_providers, value)
        :error -> Application.delete_env(:magus, :extra_integration_providers)
      end
    end)
  end

  test "builtins/0 and all/0 include the shipped providers" do
    assert Registry.builtins()[:telegram] == Magus.Integrations.Providers.Telegram
    assert Registry.all()[:log_source] == Magus.Integrations.Providers.LogSource
    assert map_size(Registry.all()) >= map_size(Registry.builtins())
  end

  test "get/1 resolves built-ins and returns nil for unknown keys" do
    assert Registry.get(:telegram) == Magus.Integrations.Providers.Telegram
    assert Registry.get(:does_not_exist) == nil
  end

  test "register/2 adds a provider at runtime" do
    refute Registry.get(:fake_provider)
    assert :ok = Registry.register(:fake_provider, FakeProvider)
    assert Registry.get(:fake_provider) == FakeProvider
    assert Registry.all()[:fake_provider] == FakeProvider
  end

  test "register/2 overrides a built-in for the same key" do
    assert :ok = Registry.register(:telegram, FakeProvider)
    assert Registry.get(:telegram) == FakeProvider
  end

  describe "seed_from_config/0" do
    test "registers nothing and returns [] when no extra providers are configured" do
      Application.delete_env(:magus, :extra_integration_providers)

      assert Registry.seed_from_config() == []
      refute Registry.get(:fake_provider)
      assert Registry.all() == Registry.builtins()
    end

    test "registers each configured provider so it is present before first lookup" do
      Application.put_env(:magus, :extra_integration_providers, fake_provider: FakeProvider)

      assert Registry.seed_from_config() == [:fake_provider]
      assert Registry.get(:fake_provider) == FakeProvider
      assert Registry.all()[:fake_provider] == FakeProvider
    end

    test "a seeded provider can override a built-in by key" do
      Application.put_env(:magus, :extra_integration_providers, telegram: FakeProvider)

      assert Registry.seed_from_config() == [:telegram]
      assert Registry.get(:telegram) == FakeProvider
    end

    test "accepts a map as well as a keyword list" do
      Application.put_env(:magus, :extra_integration_providers, %{fake_provider: FakeProvider})

      assert Registry.seed_from_config() == [:fake_provider]
      assert Registry.get(:fake_provider) == FakeProvider
    end
  end
end
