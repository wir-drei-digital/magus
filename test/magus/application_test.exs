defmodule Magus.ApplicationTest do
  @moduledoc """
  Tests for the open-core / `magus_cloud` composition seam in
  `Magus.Application.child_specs/0`.

  The supervision tree must not hardcode `MagusWeb.Endpoint`: it resolves the
  web endpoint through the `Magus.Endpoint` facade (`:magus, :endpoint`) and
  injects a configurable `:magus, :extra_children` list, so `magus_cloud` can
  serve `MagusCloudWeb.Endpoint` and start billing supervisors without the core
  naming either.
  """
  # async: false — these tests mutate the global :magus, :endpoint and
  # :magus, :extra_children app env.
  use ExUnit.Case, async: false

  defmodule FakeEndpoint do
    def config_change(_changed, _removed), do: :ok
  end

  defp restore_env(key) do
    original = Application.fetch_env(:magus, key)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:magus, key, value)
        :error -> Application.delete_env(:magus, key)
      end
    end)
  end

  describe "default composition (pure OSS install)" do
    test "returns a non-empty list anchored by the real core children" do
      specs = Magus.Application.child_specs()

      assert is_list(specs) and specs != []
      assert Magus.Repo in specs
      assert {AshAuthentication.Supervisor, [otp_app: :magus]} in specs
    end

    test "serves MagusWeb.Endpoint by default" do
      assert MagusWeb.Endpoint in Magus.Application.child_specs()
    end

    test "injects no extra children by default" do
      refute :sentinel_child in Magus.Application.child_specs()
    end
  end

  describe "configurable web endpoint" do
    setup do
      restore_env(:endpoint)
      Application.put_env(:magus, :endpoint, FakeEndpoint)
      :ok
    end

    test "serves the configured endpoint instead of MagusWeb.Endpoint" do
      specs = Magus.Application.child_specs()

      assert FakeEndpoint in specs
      refute MagusWeb.Endpoint in specs
    end
  end

  describe "configurable extra children" do
    setup do
      restore_env(:extra_children)
      Application.put_env(:magus, :extra_children, [:sentinel_child])
      :ok
    end

    test "injects the configured extra children" do
      assert :sentinel_child in Magus.Application.child_specs()
    end

    test "starts extra children before the web endpoint begins serving" do
      specs = Magus.Application.child_specs()
      endpoint = Magus.Endpoint.endpoint()

      assert index_of(specs, :sentinel_child) < index_of(specs, endpoint)
    end
  end

  defp index_of(list, value), do: Enum.find_index(list, &(&1 == value))
end
