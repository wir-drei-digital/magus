defmodule Magus.Integrations.Providers.CustomApiTest do
  use ExUnit.Case, async: true

  alias Magus.Integrations.Providers.CustomApi.Provider

  test "implements required behaviour callbacks" do
    assert Provider.key() == :custom_api
    assert Provider.name() == "Custom API"
    assert is_binary(Provider.description())
    assert Provider.auth_type() == :api_key
    assert Provider.source_type() == :tool_provider
  end

  test "tools/0 returns empty list" do
    assert Provider.tools() == []
  end

  test "auth_fields/0 returns empty list" do
    assert Provider.auth_fields() == []
  end

  test "execute/3 returns not_supported" do
    assert {:error, :not_supported} = Provider.execute(:anything, %{}, %{})
  end
end
