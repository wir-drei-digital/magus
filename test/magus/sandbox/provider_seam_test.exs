defmodule Magus.Sandbox.ProviderSeamTest do
  @moduledoc """
  Locks in the sandbox capability seam: `configured?/0` (for tool gating) and
  the provider -> client dispatch, including a graceful fallback for legacy
  provider values whose adapters have been removed (e.g. :northflank, :modal).
  """
  # async: false — mutates global :magus app env (the active sandbox provider).
  use ExUnit.Case, async: false

  alias Magus.Sandbox.Clients
  alias Magus.Sandbox.Provider

  setup do
    original_sandbox = Application.get_env(:magus, Magus.Sandbox)
    original_sprites = Application.get_env(:magus, Clients.Sprites)

    on_exit(fn ->
      restore(Magus.Sandbox, original_sandbox)
      restore(Clients.Sprites, original_sprites)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:magus, key)
  defp restore(key, value), do: Application.put_env(:magus, key, value)

  describe "configured?/0" do
    test "is false for the test provider (no real backend)" do
      Application.put_env(:magus, Magus.Sandbox, provider: :test)

      refute Provider.configured?()
    end

    test "is true when the active provider has credentials" do
      Application.put_env(:magus, Magus.Sandbox, provider: :sprites)
      Application.put_env(:magus, Clients.Sprites, api_key: "k")

      assert Provider.configured?()
    end

    test "is false when the active provider lacks credentials" do
      Application.put_env(:magus, Magus.Sandbox, provider: :sprites)
      Application.put_env(:magus, Clients.Sprites, api_key: nil)

      refute Provider.configured?()
    end
  end

  describe "client_for/1" do
    test "maps the remaining providers to their clients" do
      assert Provider.client_for(%{provider: :sprites}) == Clients.Sprites
      assert Provider.client_for(%{provider: :daytona}) == Clients.Daytona
      assert Provider.client_for(%{provider: :test}) == Clients.Test
    end

    test "falls back to Sprites for legacy/unknown providers (removed adapters)" do
      assert Provider.client_for(%{provider: :northflank}) == Clients.Sprites
      assert Provider.client_for(%{provider: :modal}) == Clients.Sprites
    end
  end
end
