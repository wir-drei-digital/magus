defmodule Magus.Integrations.ProviderRegistryTest do
  use ExUnit.Case, async: true

  test "list_available_providers returns all registered providers" do
    providers = Magus.Integrations.list_available_providers()
    assert is_list(providers)
    assert length(providers) > 0
    keys = Enum.map(providers, & &1.key)
    assert :telegram in keys
    assert :log_source in keys
  end

  test "each provider has required metadata fields" do
    for provider <- Magus.Integrations.list_available_providers() do
      assert is_atom(provider.key)
      assert is_binary(provider.name)
      assert is_binary(provider.description)
      assert provider.auth_type in [:oauth2, :api_key, :imap, :webhook_only, :none]
      assert provider.source_type in [:channel, :tool_provider, :data_source, :knowledge]
    end
  end

  test "list_available_providers/1 filters by source_type" do
    channels = Magus.Integrations.list_available_providers(:channel)
    assert Enum.all?(channels, &(&1.source_type == :channel))
    assert length(channels) > 0

    data_sources = Magus.Integrations.list_available_providers(:data_source)
    assert Enum.all?(data_sources, &(&1.source_type == :data_source))
  end
end
